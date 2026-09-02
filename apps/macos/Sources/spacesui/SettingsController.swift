import AppKit
import Carbon
import CoreImage
import Foundation
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty
import spacesterminalui
import systembridge
import workspacecore

/// Owns the Settings window and its General, Shortcuts, and MCP sections, plus the
/// preference-change handlers. `AppKitController` holds a single instance and
/// delegates settings interactions to it. The controller reaches back into the host
/// for shared form/colour helpers, the shortcut-capture machinery, and the device
/// settings bridge via `host`.
///
/// The Devices section's content (device pairing/management) is owned by
/// `host.devicePairing`; the controller renders it by delegating to
/// `host.devicePairing.renderDeviceSettings(...)`, and the device-pairing controller
/// drives the open settings window back through this controller's window/section state.
@MainActor final class SettingsController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    typealias SettingsSection = AppKitController.SettingsSection

    var settingsWindow: NSWindow?
    var selectedSettingsSection: SettingsSection = .general
    private var selectedMCPClient: CodingAgent = .claudeCode
    weak var settingsSectionContentContainer: NSView?
    var settingsSectionRowViews: [SettingsSection: SettingsSidebarRowView] = [:]
    private weak var mcpConfigTextView: NSTextView?
    private weak var mcpConfigHintLabel: NSTextField?

    /// The Coding Agents section, shared with the launch setup flow's coding-agents step. Lazy so its
    /// first status fetch happens when the user opens the section, not when Settings is constructed.
    lazy var codingAgents = CodingAgentsView(host: host)

    /// Opens user settings as a floating dialog on the given section. The dialog floats over the
    /// main window, so the current sidebar selection and detail pane are left untouched.
    func openSettings(section: SettingsSection) {
        // Same handoff as a sidebar section switch: this rebuilds the window's content, and the Devices pane
        // keeps state in the views that are about to go away.
        if selectedSettingsSection == .devices { host.devicePairing.prepareDeviceSettingsForContentReplacement() }
        selectedSettingsSection = section
        host.showingSettings = true
        presentSettingsWindow()
    }

    func closeSettingsWindow() { settingsWindow?.performClose(nil) }

    /// Clears settings-window UI references when the window closes. Called from the
    /// host's shared `windowWillClose` delegate.
    func handleSettingsWindowClosed() {
        if selectedSettingsSection == .devices { host.devicePairing.prepareDeviceSettingsForContentReplacement() }
        settingsSectionContentContainer = nil
        settingsSectionRowViews.removeAll()
    }

    private func presentSettingsWindow() {
        settingsSectionRowViews.removeAll()
        let content = buildSettingsWindowContent()

        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 680, height: 460)
            // Hard cap the width so no pane content (e.g. a long error path) can auto-expand the window
            // to an unusable size; pane labels wrap within this bound.
            created.maxSize = NSSize(width: 1100, height: 2000)
            created.standardWindowButton(.miniaturizeButton)?.isHidden = true
            created.standardWindowButton(.zoomButton)?.isHidden = true
            created.standardWindowButton(.closeButton)?.isHidden = true
            created.delegate = host
            created.center()
            settingsWindow = created
            window = created
        }
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        renderSelectedSettingsSection()
    }

    private func buildSettingsWindowContent() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        bindAppearanceReactiveLayer(root) { [unowned host] view in view.layer?.backgroundColor = host.sidebar.sidebarPanelBackgroundColor().cgColor }

        let headerBar = buildSettingsWindowHeader()
        let headerDivider = host.settingsHairlineDivider()

        let sidebar = buildSettingsSidebar()
        let bodyDivider = host.settingsHairlineDivider()
        let rightContainer = NSView()
        rightContainer.translatesAutoresizingMaskIntoConstraints = false
        settingsSectionContentContainer = rightContainer

        for view in [headerBar, headerDivider, sidebar, bodyDivider, rightContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            headerBar.leadingAnchor.constraint(equalTo: root.leadingAnchor), headerBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerBar.topAnchor.constraint(equalTo: root.topAnchor), headerBar.heightAnchor.constraint(equalToConstant: 52),

            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerDivider.topAnchor.constraint(equalTo: headerBar.bottomAnchor), headerDivider.heightAnchor.constraint(equalToConstant: 1),

            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 200),

            bodyDivider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), bodyDivider.widthAnchor.constraint(equalToConstant: 1),
            bodyDivider.topAnchor.constraint(equalTo: headerDivider.bottomAnchor), bodyDivider.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            rightContainer.leadingAnchor.constraint(equalTo: bodyDivider.trailingAnchor),
            rightContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rightContainer.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            rightContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func buildSettingsWindowHeader() -> NSView {
        let header = NSView()

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Settings")
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

        let title = NSTextField(labelWithString: "Settings")
        title.font = Typography.sheetTitle
        title.textColor = .labelColor

        let closeButton = iconButton(
            symbol: "xmark", tooltip: "Close settings", action: #selector(AppKitController.closeSettingsWindow), target: host)
        closeButton.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [iconView, title, NSView(), closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor), stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.topAnchor), stack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    private func buildSettingsSidebar() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        for section in SettingsSection.allCases {
            let row = buildSettingsSidebarRow(section)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private func buildSettingsSidebarRow(_ section: SettingsSection) -> SettingsSidebarRowView {
        let row = SettingsSidebarRowView()
        row.identifier = NSUserInterfaceItemIdentifier(section.rawValue)
        row.setAccessibilityIdentifier("settings-section-\(section.rawValue)")
        row.selectedBackgroundColor = host.sidebar.sidebarSelectedCardBackgroundColor()
        row.isSelected = section == selectedSettingsSection

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

        let label = NSTextField(labelWithString: section.title)
        label.font = Typography.rowLabel
        label.textColor = .labelColor
        row.setAccessibilityLabel(section.title)

        let hstack = NSStackView(views: [iconView, label])
        hstack.orientation = .horizontal
        hstack.alignment = .centerY
        hstack.spacing = 10
        hstack.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(hstack)
        NSLayoutConstraint.activate([
            hstack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            hstack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -10),
            hstack.topAnchor.constraint(equalTo: row.topAnchor, constant: 7), hstack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7),
        ])

        row.onClick = { [weak self] in self?.selectSettingsSection(section) }

        settingsSectionRowViews[section] = row
        return row
    }

    private func selectSettingsSection(_ section: SettingsSection) {
        guard section != selectedSettingsSection else { return }
        // The outgoing section's views are about to be torn down; the Devices pane keeps state in its own.
        if selectedSettingsSection == .devices { host.devicePairing.prepareDeviceSettingsForContentReplacement() }
        selectedSettingsSection = section
        for (candidate, row) in settingsSectionRowViews { row.isSelected = candidate == section }
        renderSelectedSettingsSection()
    }

    private func renderSelectedSettingsSection() {
        host.shortcuts.activeShortcutCaptureSetting = nil
        host.shortcuts.shortcutButtonsBySetting.removeAll()
        switch selectedSettingsSection {
        case .general: renderSettingsCards(generalSettingsCards())
        case .shortcuts: renderSettingsCards(shortcutsSettingsCards())
        case .devices: host.devicePairing.renderDeviceSettings(response: host.devicePairing.currentDeviceControlResponse())
        case .codingAgents: renderCodingAgentsSection()
        case .mcp: renderSettingsCards(mcpSettingsCards())
        }
    }

    func renderSettingsCards(_ cards: [NSView]) {
        guard let container = settingsSectionContentContainer else { return }
        for view in container.subviews { view.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        for card in cards {
            stack.addArrangedSubview(card)
            constrainFormFieldToFillWidth(card, in: stack)
        }

        showScrollableDetailStack(stack, in: container)
    }

    private func generalSettingsCards() -> [NSView] {
        // `.builtin` is always first and always available: it opens the app's own Editor window and
        // needs nothing installed, so `options` is never empty.
        let options = host.installedEditorOptions()
        let currentEditor = host.deviceModel.configCache?.editor ?? .builtin
        let editorPopUp = NSPopUpButton()
        editorPopUp.translatesAutoresizingMaskIntoConstraints = false
        editorPopUp.autoenablesItems = false
        for option in options {
            editorPopUp.addItem(withTitle: option.displayName)
            editorPopUp.itemArray.last?.representedObject = option
        }
        if !options.contains(currentEditor) {
            // The saved preference points at an editor that is no longer installed (e.g. it was
            // uninstalled after being chosen). Represent it as a disabled item rather than silently
            // falling back to selecting Built-in: the popup must reflect the actual stored setting,
            // even though it can't be launched until the user picks a different, enabled option.
            editorPopUp.addItem(withTitle: "\(currentEditor.displayName) (not installed)")
            editorPopUp.itemArray.last?.representedObject = currentEditor
            editorPopUp.itemArray.last?.isEnabled = false
        }
        if let item = editorPopUp.itemArray.first(where: { ($0.representedObject as? EditorPreference) == currentEditor }) {
            editorPopUp.select(item)
        }
        editorPopUp.target = self
        editorPopUp.action = #selector(editorPreferenceChanged(_:))
        editorPopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        editorPopUp.setAccessibilityIdentifier("settings-editor")

        let editorContentViews: [NSView] = [
            host.settingsLabeledField(
                name: "Preferred editor", hint: "Opened when you use the editor shortcut from inside a workspace", control: editorPopUp)
        ]
        let editorCard = host.formSectionCard(icon: "square.and.pencil", title: "Editor", contentViews: editorContentViews)

        return [appearanceSettingsCard(), editorCard, updatesSettingsCard()]
    }

    private func updatesSettingsCard() -> NSView {
        let checkbox = NSButton(
            checkboxWithTitle: "Receive pre-release updates", target: self, action: #selector(prereleaseUpdatesChanged(_:)))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.state = SpacesUpdaterDelegate.prereleaseUpdatesEnabled() ? .on : .off
        checkbox.setAccessibilityIdentifier("settings-prerelease-updates")

        let hint = host.helpTextLabel("Update to each tagged release as soon as it is published, before it is promoted to everyone.")
        let stack = NSStackView(views: [checkbox, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return host.formSectionCard(icon: "arrow.down.circle", title: "Updates", contentViews: [stack])
    }

    @objc private func prereleaseUpdatesChanged(_ sender: NSButton) {
        do {
            try host.clientDatabase().setSetting(key: ClientSettingsKey.appPrereleaseUpdates, value: sender.state == .on ? "1" : "0")
        } catch {
            // Leave the checkbox showing what is actually stored, not what the click asked for.
            sender.state = SpacesUpdaterDelegate.prereleaseUpdatesEnabled() ? .on : .off
            host.showError(error)
        }
    }

    private func appearanceSettingsCard() -> NSView {
        let current = host.storedAppAppearanceMode()
        let popUp = NSPopUpButton()
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.autoenablesItems = false
        for mode in AppAppearanceMode.allCases {
            popUp.addItem(withTitle: mode.displayName)
            popUp.itemArray.last?.representedObject = mode
        }
        if let item = popUp.itemArray.first(where: { ($0.representedObject as? AppAppearanceMode) == current }) { popUp.select(item) }
        popUp.target = self
        popUp.action = #selector(appearanceModeChanged(_:))
        popUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popUp.setAccessibilityIdentifier("settings-appearance")

        let field = host.settingsLabeledField(name: "Appearance", hint: "Match the system setting or force a light or dark interface", control: popUp)
        return host.formSectionCard(icon: "circle.lefthalf.filled", title: "Appearance", contentViews: [field])
    }

    @objc private func appearanceModeChanged(_ sender: NSPopUpButton) {
        guard let mode = sender.selectedItem?.representedObject as? AppAppearanceMode else { return }
        guard mode != host.storedAppAppearanceMode() else { return }
        do {
            try host.clientDatabase().setSetting(key: ClientSettingsKey.appAppearanceMode, value: mode.rawValue)
            host.applyAppAppearance(mode)
        } catch { host.showError(error) }
    }

    private func shortcutsSettingsCards() -> [NSView] {
        let shortcutContainer = host.buildShortcutRowsContainer()
        let shortcutCard = host.formSectionCard(
            icon: "keyboard", title: "Keyboard shortcuts",
            subtitle: "Click record on a row to capture a new chord. Leader-based shortcuts inherit the leader modifier.",
            contentViews: [shortcutContainer])
        return [shortcutCard]
    }

    private func mcpSettingsCards() -> [NSView] {
        let clients = CodingAgent.allCases
        let picker = NSSegmentedControl(
            labels: clients.map(\.mcpClientTitle), trackingMode: .selectOne, target: self, action: #selector(mcpClientSegmentChanged(_:)))
        picker.selectedSegment = clients.firstIndex(of: selectedMCPClient) ?? 0
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setAccessibilityIdentifier("settings-mcp-client-picker")
        let pickerRow = NSStackView(views: [picker, NSView()])
        pickerRow.orientation = .horizontal
        pickerRow.alignment = .centerY

        let cliPath = MCPClientConfiguration.resolvedCLIPath()
        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Typography.monoMetadata
        textView.string = selectedMCPClient.mcpConfigSnippet(cliPath: cliPath)
        textView.setAccessibilityIdentifier("settings-mcp-config")
        mcpConfigTextView = textView
        let configScroll = scrollableTextView(
            textView, height: 90, inputBackgroundColor: host.sidebar.sidebarThemeColor(light: (235, 233, 225), dark: (10, 15, 17)),
            borderColor: host.sidebar.sidebarCardBorderColor(isSelected: false))

        let hint = host.helpTextLabel(selectedMCPClient.mcpConfigHint)
        mcpConfigHintLabel = hint

        let setupCard = host.formSectionCard(icon: "puzzlepiece.extension", title: "MCP Client Setup", contentViews: [pickerRow, hint, configScroll])

        return [setupCard]
    }

    @objc private func mcpClientSegmentChanged(_ sender: NSSegmentedControl) {
        let clients = CodingAgent.allCases
        guard clients.indices.contains(sender.selectedSegment) else { return }
        selectedMCPClient = clients[sender.selectedSegment]
        let cliPath = MCPClientConfiguration.resolvedCLIPath()
        mcpConfigTextView?.string = selectedMCPClient.mcpConfigSnippet(cliPath: cliPath)
        mcpConfigHintLabel?.stringValue = selectedMCPClient.mcpConfigHint
    }

    @objc private func editorPreferenceChanged(_ sender: NSPopUpButton) {
        guard let preference = sender.selectedItem?.representedObject as? EditorPreference else { return }
        if (host.deviceModel.configCache?.editor ?? .builtin) == preference { return }
        do {
            try host.clientDatabase().setSetting(key: ClientSettingsKey.appEditor, value: preference.rawValue)
            host.deviceModel.configCache = try AppKitController.clientAppConfig()
        } catch { host.showError(error) }
    }

}
