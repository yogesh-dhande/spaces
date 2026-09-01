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

final class CommandPaletteSearchField: NSSearchField { override var needsPanelToBecomeKey: Bool { true } }

final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the Command Palette's state and behavior. `AppKitController` holds a single
/// instance and delegates palette interactions to it. The controller reaches back
/// into the host for shared window/hotkey/orchestration services via `host`.
@MainActor final class CommandPaletteController {
    unowned let host: AppKitController
    /// Injected directly rather than reached through `host` on every load: `loadCommandPaletteItemsSnapshot`
    /// needs both to build an alert-aware snapshot, matching how `AlertsController`/`ShortcutsController`
    /// own their dependencies directly instead of reaching back through `host` for them.
    let deviceModel: DeviceModelStore
    let alerts: AlertsController

    init(host: AppKitController, deviceModel: DeviceModelStore, alerts: AlertsController) {
        self.host = host
        self.deviceModel = deviceModel
        self.alerts = alerts
    }

    var commandPalettePanel: NSPanel?
    var commandPaletteSearchField: NSSearchField?
    var commandPaletteTableView: NSTableView?
    var commandPaletteLoadingIndicator: NSProgressIndicator?
    var commandPaletteEmptyLabel: NSTextField?
    var commandPaletteSummaryLabel: NSTextField?
    var commandPaletteLoadTask: Task<Void, Never>?
    var commandPaletteItems: [CommandPaletteItem] = []
    var commandPaletteFilteredItems: [CommandPaletteItem] = []
    var commandPaletteContextWorkspaceID: String?
    var commandPaletteSelectedIndex = 0
    var commandPaletteNeedsReload = true
    var isDismissingCommandPalette = false
    var pendingCommandPalettePresentation: AppKitController.PendingCommandPalettePresentation?
    var commandPaletteMainWindowVisibility: Bool?
    var recentCommandPaletteFocusIdentities: [String] = []
    var commandPaletteReturnTerminalSessionID: String?
    /// The code-pane counterpart of `commandPaletteReturnTerminalSessionID`, captured when a focused
    /// code pane has no session id of its own to remember. See `restoreCommandPaletteReturnFocus`.
    var commandPaletteReturnCodePaneID: String?
    var commandPaletteReturnApplicationProcessID: pid_t?

    private struct PendingSelectionExecution {
        let id = UUID()
        let returnTerminalSessionID: String?
        let returnCodePaneID: String?
        let returnApplicationProcessID: pid_t?
    }

    private var pendingSelectionExecution: PendingSelectionExecution?

    /// Non-nil while the palette runs in session-picker mode (filling a pane split):
    /// the rows are "New terminal session" plus existing sessions in scope, Enter
    /// resolves the choice through `completion` instead of focusing a window, and
    /// dismissal reports nil. Normal palette items reload on the next presentation.
    struct SessionPickerContext {
        let scope: PanelScope
        let newTerminalWorkspaceID: String
        let choicesByItemID: [String: AppKitController.SessionPickerChoice]
        let completion: (AppKitController.SessionPickerChoice?) -> Void
    }

    var sessionPickerContext: SessionPickerContext?

    func filteredCommandPaletteItems(_ items: [CommandPaletteItem]) -> [CommandPaletteItem] {
        items.filter { item in
            guard let attentionID = item.alertsAttentionID else { return true }
            return !host.alerts.dismissedAlertsAttentionItemIDs.contains(attentionID)
        }
    }

    func rememberRecentCommandPaletteFocusIdentity(_ identity: String) {
        recentCommandPaletteFocusIdentities.removeAll(where: { $0 == identity })
        recentCommandPaletteFocusIdentities.insert(identity, at: 0)
        if recentCommandPaletteFocusIdentities.count > 64 {
            recentCommandPaletteFocusIdentities.removeLast(recentCommandPaletteFocusIdentities.count - 64)
        }
    }

    func invalidateCommandPaletteCache() { commandPaletteNeedsReload = true }

    func commandPaletteFooterRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5

        func addSep() {
            let sep = NSTextField(labelWithString: "|")
            sep.font = Typography.caption
            sep.textColor = .quaternaryLabelColor
            row.addArrangedSubview(sep)
        }

        func addSegment(keys: [String], label: String) {
            let group = NSStackView()
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 3
            for key in keys { group.addArrangedSubview(RowPrimitives.shortcutChip(key)) }
            let lbl = NSTextField(labelWithString: label)
            lbl.font = Typography.caption
            lbl.textColor = .secondaryLabelColor
            group.addArrangedSubview(lbl)
            row.addArrangedSubview(group)
        }

        let jumpKey = host.shortcuts.footerShortcutHint(for: .guiWindowShortcut)
        addSegment(keys: ["↑", "↓"], label: "Move")
        addSep()
        addSegment(keys: ["↵"], label: "Open")
        addSep()
        addSegment(keys: ["esc"], label: "Close")
        addSep()
        addSegment(keys: [jumpKey], label: "Jump")
        addSep()
        addSegment(keys: ["⌘ X"], label: "Dismiss alert")
        row.addArrangedSubview(NSView())
        return row
    }

    func completePendingCommandPalettePresentationIfNeeded() {
        guard let pending = pendingCommandPalettePresentation, let panel = commandPalettePanel else { return }
        guard AppKitController.commandPalettePresentationIsComplete(panelIsVisible: panel.isVisible, panelIsKey: panel.isKeyWindow) else { return }
        pendingCommandPalettePresentation = nil
        commandPaletteMainWindowVisibility = pending.mainWindowWasVisible
        host.logHotkeyDebug("present_palette end \(host.hotkeyWindowStateSummary())")
        if let perfContext = pending.perfContext { host.logHotkeyPerfMetric("toggle_palette", action: "show", context: perfContext) }
    }

    func dismissCommandPaletteForBuiltInWindowNavigation() {
        if let panel = commandPalettePanel, panel.isVisible {
            // Ordering out a key panel makes it resign key synchronously, and the resign observer
            // runs the ordinary `dismissCommandPalette()`. Clearing the return targets first and
            // holding the same dismissal guard keeps that reentry from restoring focus, which is
            // the one thing this variant exists to skip.
            commandPaletteContextWorkspaceID = nil
            commandPaletteMainWindowVisibility = nil
            commandPaletteReturnTerminalSessionID = nil
            commandPaletteReturnCodePaneID = nil
            commandPaletteReturnApplicationProcessID = nil
            isDismissingCommandPalette = true
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            isDismissingCommandPalette = false
            // A dismissal in picker mode resolves the picker as cancelled, matching
            // `dismissCommandPalette()`: its completion must be delivered exactly once.
            takeSessionPickerContext()?.completion(nil)
        }
    }

    /// The funnel every "open a built-in window" action (⌘⌥E, the sidebar's "Open in Editor" item,
    /// the palette's own row) routes through so none of them has to know the palette is involved.
    /// Built-in window opens key their window synchronously: if the palette is currently key, that
    /// keying makes it resign key, and an ORDINARY resign-key dismissal would restore the palette's
    /// captured return focus, pulling key straight back from the window `open()` just raised. So when
    /// the palette is visible, this dismisses it (via `dismissCommandPaletteForBuiltInWindowNavigation`,
    /// which is built exactly for this reentrancy) BEFORE calling `open()`, not after. A failed open
    /// still owes the user their prior focus — dismissing up front must not silently drop whatever the
    /// palette interrupted — so `open()` returning `false` restores the return focus captured before
    /// the dismissal. When the palette isn't visible there is nothing to protect against, so `open()`
    /// just runs directly.
    func withPaletteDismissedForBuiltInOpen(_ open: () -> Bool) -> Bool {
        guard let panel = commandPalettePanel, panel.isVisible else { return open() }
        let returnTerminalSessionID = commandPaletteReturnTerminalSessionID
        let returnCodePaneID = commandPaletteReturnCodePaneID
        let returnApplicationProcessID = commandPaletteReturnApplicationProcessID
        dismissCommandPaletteForBuiltInWindowNavigation()
        let opened = open()
        if !opened {
            restoreCommandPaletteReturnFocus(
                terminalSessionID: returnTerminalSessionID, codePaneID: returnCodePaneID, applicationProcessID: returnApplicationProcessID)
        }
        return opened
    }

    func commandPaletteDefaultWorkspaceID() -> String? {
        let focusedTerminalWorkspaceID: String?
        if let terminalSessionID = host.panelCoordinator.focusedSessionID() {
            let lookupStartedAt = Date()
            focusedTerminalWorkspaceID = host.clientWorkspaceID(forTerminalSession: terminalSessionID)
            host.logPerfMetric(
                "toggle_palette_terminal_workspace_lookup", target: "session=\(terminalSessionID)",
                elapsedMS: host.windowShortcutElapsedMS(since: lookupStartedAt), success: focusedTerminalWorkspaceID != nil)
        } else {
            focusedTerminalWorkspaceID = nil
        }

        let focusedWindowWorkspaceID: String?
        if host.selectedWorkspaceID == nil, focusedTerminalWorkspaceID == nil {
            let lookupStartedAt = Date()
            focusedWindowWorkspaceID = host.clientWorkspaceIDForFocusedWindow()
            host.logPerfMetric(
                "toggle_palette_focused_window_workspace_lookup", target: "frontmost_window",
                elapsedMS: host.windowShortcutElapsedMS(since: lookupStartedAt), success: focusedWindowWorkspaceID != nil)
        } else {
            focusedWindowWorkspaceID = nil
        }

        return AppKitController.preferredWorkspaceIDForCommandPalette(
            selectedWorkspaceID: host.selectedWorkspaceID, focusedTerminalSessionWorkspaceID: focusedTerminalWorkspaceID,
            focusedWindowWorkspaceID: focusedWindowWorkspaceID)
    }

    func handleCommandPaletteShortcut(event: NSEvent) -> Bool {
        guard commandPalettePanel?.isVisible == true else { return false }
        if let windowIndex = host.windowShortcutIndex(for: event) {
            executeCommandPaletteShortcut(index: windowIndex)
            return true
        }
        if matchesCommandPaletteDismissShortcut(event: event) {
            dismissSelectedCommandPaletteAlertsItem()
            return true
        }
        return false
    }

    func matchesCommandPaletteDismissShortcut(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let selectedItemIsAlert =
            commandPaletteFilteredItems.indices.contains(commandPaletteSelectedIndex)
            && commandPaletteFilteredItems[commandPaletteSelectedIndex].alertsAttentionID != nil
        return AppKitController.commandPaletteDismissShortcutMatches(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers, modifiers: host.shortcuts.shortcutModifiers(from: flags),
            selectedItemIsAlert: selectedItemIsAlert, searchEditorCanCutSelectedText: commandPaletteSearchEditorCanCutSelectedText())
    }

    /// The palette monitor runs before the app's ordinary text-editing shortcuts. Let a focused
    /// field editor keep Command-X when it has an editable selection; an alert dismissal only owns
    /// the otherwise-unused chord.
    private func commandPaletteSearchEditorCanCutSelectedText() -> Bool {
        guard let editor = commandPaletteSearchField?.currentEditor() as? NSTextView, editor.isEditable else { return false }
        return editor.selectedRange().length > 0
    }

    func executeCommandPaletteShortcut(index: Int) {
        let row = index - 1
        guard commandPaletteFilteredItems.indices.contains(row) else {
            NSSound.beep()
            return
        }
        commandPaletteSelectedIndex = row
        commandPaletteTableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        commandPaletteTableView?.scrollRowToVisible(row)
        executeSelectedCommandPaletteItem()
    }

    func dismissSelectedCommandPaletteAlertsItem() {
        guard commandPaletteFilteredItems.indices.contains(commandPaletteSelectedIndex) else {
            NSSound.beep()
            return
        }
        let item = commandPaletteFilteredItems[commandPaletteSelectedIndex]
        guard let attentionID = item.alertsAttentionID else {
            NSSound.beep()
            return
        }
        host.alerts.dismissAlertsAttentionItem(attentionID)
        commandPaletteItems.removeAll { $0.alertsAttentionID == attentionID }
        applyCommandPaletteFilter()
    }

    func toggleCommandPaletteFromHotkey() {
        let perfContext = host.captureHotkeyPerfContext()
        host.logHotkeyDebug("toggle_palette begin \(host.hotkeyWindowStateSummary())")
        // The launch setup flow occupies the main window; the command palette must not surface
        // workspace actions behind it, so the palette hotkey only shows/hides the window until the
        // flow completes.
        guard host.setupFlowController == nil else {
            host.logHotkeyDebug("toggle_palette reroute_permission_setup")
            host.toggleWindowFromHotkey()
            return
        }
        if let panel = commandPalettePanel,
            AppKitController.shouldDismissCommandPaletteForToggle(panelIsVisible: panel.isVisible, panelIsFocused: panel.isKeyWindow)
        {
            host.logHotkeyDebug("toggle_palette dismiss_visible_panel")
            dismissCommandPalette(perfContext: perfContext)
            return
        }
        if let panel = commandPalettePanel, panel.isVisible {
            host.logHotkeyDebug("toggle_palette refocus_visible_panel")
            host.revealTargetedHotkeyWindow(panel)
            if let commandPaletteSearchField { panel.makeFirstResponder(commandPaletteSearchField) }
            pendingCommandPalettePresentation = AppKitController.PendingCommandPalettePresentation(
                perfContext: perfContext, mainWindowWasVisible: host.rawMainWindowVisibility())
            completePendingCommandPalettePresentationIfNeeded()
            return
        }
        presentCommandPalette(perfContext: perfContext)
    }

    func presentCommandPalette(perfContext: AppKitController.HotkeyPerfContext? = nil) {
        // A selection can perform its focus side effect before its await returns. Do not
        // present a panel that the older operation could immediately make resign key.
        guard pendingSelectionExecution == nil else {
            host.logHotkeyDebug("present_palette skipped selection_in_flight")
            return
        }
        let panel = ensureCommandPalettePanel()
        let mainWindowWasVisible = host.rawMainWindowVisibility()
        host.logHotkeyDebug("present_palette begin \(host.hotkeyWindowStateSummary())")
        let focusedTerminalSessionID = host.panelCoordinator.focusedSessionID()
        // A focused code pane has no session id, so it needs its own capture; only checked when no
        // terminal session was focused, mirroring the precedence the restore side gives terminal focus.
        let focusedCodePaneID = focusedTerminalSessionID == nil ? host.panelCoordinator.focusedCodePaneID() : nil
        let returnApplicationProcessID = AppKitController.returnApplicationProcessIDForAppToggle(
            frontmostApplicationProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            currentProcessID: ProcessInfo.processInfo.processIdentifier)
        commandPaletteReturnTerminalSessionID = focusedTerminalSessionID
        commandPaletteReturnCodePaneID = focusedCodePaneID
        commandPaletteReturnApplicationProcessID = (focusedTerminalSessionID == nil && focusedCodePaneID == nil) ? returnApplicationProcessID : nil
        let contextLookupStartedAt = Date()
        commandPaletteContextWorkspaceID = commandPaletteDefaultWorkspaceID()
        host.logPerfMetric(
            "toggle_palette_context_workspace", target: "workspace=\(commandPaletteContextWorkspaceID ?? "nil")",
            elapsedMS: host.windowShortcutElapsedMS(since: contextLookupStartedAt), success: true)
        panel.center()
        let revealStartedAt = Date()
        host.revealTargetedHotkeyWindow(panel)
        host.logPerfMetric(
            "toggle_palette_reveal_target", target: "palette", elapsedMS: host.windowShortcutElapsedMS(since: revealStartedAt), success: true)
        commandPaletteSearchField?.stringValue = ""
        commandPaletteSelectedIndex = 0
        if let commandPaletteSearchField { panel.makeFirstResponder(commandPaletteSearchField) }
        let filterStartedAt = Date()
        applyCommandPaletteFilter()
        host.logPerfMetric(
            "toggle_palette_apply_filter", target: "query=<empty>", elapsedMS: host.windowShortcutElapsedMS(since: filterStartedAt), success: true)
        if commandPaletteItems.isEmpty {
            reloadCommandPaletteItems()
        } else if commandPaletteNeedsReload, commandPaletteLoadTask == nil {
            reloadCommandPaletteItems()
        }
        pendingCommandPalettePresentation = AppKitController.PendingCommandPalettePresentation(
            perfContext: perfContext, mainWindowWasVisible: mainWindowWasVisible)
        completePendingCommandPalettePresentationIfNeeded()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.completePendingCommandPalettePresentationIfNeeded()
        }
    }

    func dismissCommandPalette(perfContext: AppKitController.HotkeyPerfContext? = nil) {
        guard let panel = commandPalettePanel else { return }
        guard !isDismissingCommandPalette else { return }
        isDismissingCommandPalette = true
        host.logHotkeyDebug(
            "dismiss_palette begin visible=\(panel.isVisible ? 1 : 0) key=\(panel.isKeyWindow ? 1 : 0) \(host.hotkeyWindowStateSummary())")
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        commandPaletteContextWorkspaceID = nil
        // Selection owns the captured return target until execution resolves. Resigning
        // key while focus is in flight dismisses the panel without racing either outcome.
        if pendingSelectionExecution == nil {
            restoreCommandPaletteReturnFocus(
                terminalSessionID: commandPaletteReturnTerminalSessionID, codePaneID: commandPaletteReturnCodePaneID,
                applicationProcessID: commandPaletteReturnApplicationProcessID)
        }
        isDismissingCommandPalette = false
        host.logHotkeyDebug("dismiss_palette end \(host.hotkeyWindowStateSummary())")
        commandPaletteMainWindowVisibility = nil
        commandPaletteReturnTerminalSessionID = nil
        commandPaletteReturnCodePaneID = nil
        commandPaletteReturnApplicationProcessID = nil
        if let perfContext { host.logHotkeyPerfMetric("toggle_palette", action: "hide", context: perfContext) }
        // Dismissing while picking (esc, click-away) resolves the picker as cancelled;
        // Enter takes the context before dismissing, so this only fires for real cancels.
        takeSessionPickerContext()?.completion(nil)
    }

    /// Restores the palette's captured return focus in priority order: the terminal session it was
    /// focused on, else the code pane it was focused on (a code pane has no session id, so it needs its
    /// own field — see `commandPaletteReturnCodePaneID`), else the application that was frontmost before
    /// the palette, else revealing the main window if it was visible.
    private func restoreCommandPaletteReturnFocus(terminalSessionID: String?, codePaneID: String?, applicationProcessID: pid_t?) {
        if AppKitController.shouldRestoreTerminalFocusAfterPaletteHide(returnTerminalSessionID: terminalSessionID), let terminalSessionID {
            host.panelCoordinator.focusPane(forSessionID: terminalSessionID)
        } else if AppKitController.shouldRestoreCodePaneFocusAfterPaletteHide(
            returnTerminalSessionID: terminalSessionID, returnCodePaneID: codePaneID), let codePaneID
        {
            host.panelCoordinator.focusPane(forCodePaneID: codePaneID)
        } else if AppKitController.shouldRestoreReturnApplicationAfterPaletteHide(
            returnTerminalSessionID: terminalSessionID, returnCodePaneID: codePaneID, returnApplicationProcessID: applicationProcessID),
            let applicationProcessID
        {
            host.activateReturnApplication(processIdentifier: applicationProcessID)
        } else if host.rawMainWindowVisibility(), let window = host.window {
            host.revealTargetedHotkeyWindow(window)
        }
    }

    func ensureCommandPalettePanel() -> NSPanel {
        if let commandPalettePanel { return commandPalettePanel }

        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 470), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.delegate = host
        panel.setAccessibilityIdentifier("spaces-command-palette")

        if let closeButton = panel.standardWindowButton(.closeButton) { closeButton.isHidden = true }
        if let miniButton = panel.standardWindowButton(.miniaturizeButton) { miniButton.isHidden = true }
        if let zoomButton = panel.standardWindowButton(.zoomButton) { zoomButton.isHidden = true }

        let root = ColoredBackgroundView()
        root.fillColor = Theme.paletteSurface
        root.cornerRadius = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.borderWidth = 1
        bindAppearanceReactiveLayer(root) { view in view.layer?.borderColor = Theme.border.cgColor }

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView()
        headerRow.orientation = .vertical
        headerRow.alignment = .leading
        headerRow.spacing = 2
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.setContentHuggingPriority(.required, for: .vertical)
        headerRow.setContentCompressionResistancePriority(.required, for: .vertical)

        let brandRow = NSStackView()
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 7
        brandRow.translatesAutoresizingMaskIntoConstraints = false

        let titleIconView = NSImageView()
        if let appIcon = NSApp.applicationIconImage.copy() as? NSImage {
            appIcon.size = NSSize(width: 18, height: 18)
            titleIconView.image = appIcon
        } else {
            titleIconView.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Spaces")
            titleIconView.contentTintColor = Theme.accentStrong
        }
        titleIconView.translatesAutoresizingMaskIntoConstraints = false
        titleIconView.setContentHuggingPriority(.required, for: .horizontal)
        titleIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            titleIconView.widthAnchor.constraint(equalToConstant: 18), titleIconView.heightAnchor.constraint(equalToConstant: 18),
        ])

        let titleLabel = NSTextField(labelWithString: "Spaces")
        titleLabel.font = Typography.sheetTitle
        titleLabel.textColor = Theme.text
        brandRow.addArrangedSubview(titleIconView)
        brandRow.addArrangedSubview(titleLabel)
        headerRow.addArrangedSubview(brandRow)

        let searchField = CommandPaletteSearchField()
        searchField.placeholderString = "fuzzy search workspaces, targets, and details"
        searchField.font = Typography.body
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = host
        searchField.focusRingType = .default
        searchField.setAccessibilityIdentifier("command-palette-search")
        searchField.controlSize = .large
        searchField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        searchField.setContentHuggingPriority(.required, for: .vertical)
        searchField.setContentCompressionResistancePriority(.required, for: .vertical)

        let countBadge = ColoredBackgroundView()
        countBadge.fillColor = Theme.chipBg
        countBadge.cornerRadius = 4
        countBadge.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = Typography.monoBadge
        countLabel.textColor = Theme.muted
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countBadge.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: 5),
            countLabel.trailingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: -5),
            countLabel.topAnchor.constraint(equalTo: countBadge.topAnchor, constant: 2),
            countLabel.bottomAnchor.constraint(equalTo: countBadge.bottomAnchor, constant: -2),
        ])
        searchField.addSubview(countBadge)
        NSLayoutConstraint.activate([
            countBadge.trailingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: -8),
            countBadge.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
        ])

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.setContentHuggingPriority(.required, for: .vertical)
        divider.setContentCompressionResistancePriority(.required, for: .vertical)

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.setContentHuggingPriority(.required, for: .vertical)
        footerSeparator.setContentCompressionResistancePriority(.required, for: .vertical)

        let footerRow = commandPaletteFooterRow()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.setContentHuggingPriority(.required, for: .vertical)
        footerRow.setContentCompressionResistancePriority(.required, for: .vertical)

        let tableView = NSTableView()
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command-palette-column"))
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.rowHeight = 42
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.delegate = host
        tableView.dataSource = host
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let emptyLabel = NSTextField(labelWithString: "No matching targets")
        emptyLabel.font = Typography.rowDetail
        emptyLabel.textColor = Theme.muted
        emptyLabel.isHidden = true
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setContentHuggingPriority(.required, for: .vertical)
        emptyLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.setContentHuggingPriority(.required, for: .vertical)
        loadingIndicator.setContentCompressionResistancePriority(.required, for: .vertical)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView

        content.addSubview(headerRow)
        content.addSubview(searchField)
        content.addSubview(divider)
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)
        content.addSubview(loadingIndicator)
        content.addSubview(footerSeparator)
        content.addSubview(footerRow)

        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            headerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            headerRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            headerRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),

            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 10),

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),

            footerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footerRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            footerSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footerSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footerSeparator.bottomAnchor.constraint(equalTo: footerRow.topAnchor, constant: -6),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            tableView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        panel.contentView = container
        commandPalettePanel = panel
        commandPaletteSearchField = searchField
        commandPaletteTableView = tableView
        commandPaletteLoadingIndicator = loadingIndicator
        commandPaletteEmptyLabel = emptyLabel
        commandPaletteSummaryLabel = countLabel
        host.logHotkeyDebug("ensure_palette_panel created")
        return panel
    }

    /// Presents the palette in session-picker mode for filling a pane split. The items
    /// and their choice mapping are built by the host from the scope's overviews.
    func presentSessionPicker(
        scope: PanelScope, newTerminalWorkspaceID: String, items: [CommandPaletteItem],
        choicesByItemID: [String: AppKitController.SessionPickerChoice], completion: @escaping (AppKitController.SessionPickerChoice?) -> Void
    ) {
        guard pendingSelectionExecution == nil else {
            host.logHotkeyDebug("present_session_picker skipped selection_in_flight")
            completion(nil)
            return
        }
        // A picker opening over a live normal palette cancels it cleanly first.
        if sessionPickerContext != nil { dismissCommandPalette() }
        commandPaletteLoadTask?.cancel()
        commandPaletteLoadTask = nil
        sessionPickerContext = SessionPickerContext(
            scope: scope, newTerminalWorkspaceID: newTerminalWorkspaceID, choicesByItemID: choicesByItemID, completion: completion)
        let panel = ensureCommandPalettePanel()
        commandPaletteItems = items
        commandPaletteContextWorkspaceID = newTerminalWorkspaceID
        commandPaletteReturnTerminalSessionID = nil
        commandPaletteReturnCodePaneID = nil
        commandPaletteReturnApplicationProcessID = nil
        setCommandPaletteLoading(false)
        panel.center()
        host.revealTargetedHotkeyWindow(panel)
        commandPaletteSearchField?.stringValue = ""
        commandPaletteSelectedIndex = 0
        if let commandPaletteSearchField { panel.makeFirstResponder(commandPaletteSearchField) }
        applyCommandPaletteFilter()
    }

    /// Ends picker mode and returns its context (nil when not picking), restoring the
    /// palette to normal mode for its next presentation. Callers deliver the completion
    /// exactly once with their outcome.
    private func takeSessionPickerContext() -> SessionPickerContext? {
        guard let context = sessionPickerContext else { return nil }
        sessionPickerContext = nil
        commandPaletteItems = []
        commandPaletteNeedsReload = true
        return context
    }

    func reloadCommandPaletteItems() {
        // Picker rows are host-provided; a background overview reload must not replace them.
        guard sessionPickerContext == nil else { return }
        commandPaletteLoadTask?.cancel()
        setCommandPaletteLoading(true)
        host.logHotkeyDebug("reload_palette_items begin")
        commandPaletteLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.loadCommandPaletteItemsSnapshot()
            guard !Task.isCancelled else { return }
            self.commandPaletteLoadTask = nil
            self.setCommandPaletteLoading(false)
            switch result {
            case .success(let items):
                self.host.logHotkeyDebug("reload_palette_items success count=\(items.count)")
                self.commandPaletteNeedsReload = false
                self.commandPaletteItems = self.filteredCommandPaletteItems(items)
                self.applyCommandPaletteFilter()
            case .failure(let error):
                self.host.logHotkeyDebug("reload_palette_items failure error=\(error)")
                if !self.host.handleDeferredSetupRequirementIfNeeded(error) {
                    self.dismissCommandPalette()
                    self.host.showError(error)
                }
            }
        }
    }

    func setCommandPaletteLoading(_ loading: Bool) {
        host.logHotkeyDebug("set_palette_loading loading=\(loading ? 1 : 0)")
        commandPaletteLoadingIndicator?.isHidden = !loading
        if loading { commandPaletteLoadingIndicator?.startAnimation(nil) } else { commandPaletteLoadingIndicator?.stopAnimation(nil) }
        commandPaletteEmptyLabel?.isHidden = loading
        commandPaletteTableView?.isHidden = loading && commandPaletteItems.isEmpty
    }

    func applyCommandPaletteFilter() {
        let query = commandPaletteSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        commandPaletteFilteredItems =
            sessionPickerContext != nil
            ? Self.visibleSessionPickerItems(allItems: commandPaletteItems, query: query)
            : Self.visibleCommandPaletteItems(
                allItems: commandPaletteItems, query: query, currentWorkspaceID: commandPaletteContextWorkspaceID,
                recentFocusIdentities: recentCommandPaletteFocusIdentities)
        commandPaletteSelectedIndex = commandPaletteFilteredItems.isEmpty ? 0 : 0
        host.logHotkeyDebug(
            "apply_palette_filter query=\(query.isEmpty ? "<empty>" : query) all=\(commandPaletteItems.count) filtered=\(commandPaletteFilteredItems.count) context_workspace=\(commandPaletteContextWorkspaceID ?? "nil")"
        )
        rebuildCommandPaletteRows()
    }

    func rebuildCommandPaletteRows() {
        guard let tableView = commandPaletteTableView else { return }
        tableView.isHidden = commandPaletteFilteredItems.isEmpty
        let showEmptyState =
            commandPaletteFilteredItems.isEmpty
            && !(commandPaletteSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        commandPaletteEmptyLabel?.isHidden = !showEmptyState
        host.logHotkeyDebug("rebuild_palette_rows count=\(commandPaletteFilteredItems.count) selected=\(commandPaletteSelectedIndex)")
        tableView.reloadData()
        if commandPaletteFilteredItems.indices.contains(commandPaletteSelectedIndex) {
            tableView.selectRowIndexes(IndexSet(integer: commandPaletteSelectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(commandPaletteSelectedIndex)
        } else {
            tableView.deselectAll(nil)
        }
        host.logHotkeyDebug("rebuild_palette_rows_done rows=\(tableView.numberOfRows) selected_row=\(tableView.selectedRow)")
        let count = commandPaletteFilteredItems.count
        commandPaletteSummaryLabel?.stringValue = count > 0 ? "\(count)" : ""
        commandPaletteSummaryLabel?.superview?.isHidden = count == 0
    }

    func moveCommandPaletteSelection(delta: Int) {
        guard !commandPaletteFilteredItems.isEmpty else { return }
        let nextIndex = min(max(commandPaletteSelectedIndex + delta, 0), commandPaletteFilteredItems.count - 1)
        guard nextIndex != commandPaletteSelectedIndex else { return }
        commandPaletteSelectedIndex = nextIndex
        commandPaletteTableView?.selectRowIndexes(IndexSet(integer: nextIndex), byExtendingSelection: false)
        commandPaletteTableView?.scrollRowToVisible(nextIndex)
    }

    func executeSelectedCommandPaletteItem() {
        guard commandPaletteFilteredItems.indices.contains(commandPaletteSelectedIndex) else {
            NSSound.beep()
            return
        }
        // A focus request can suspend on daemon or browser work while the palette is
        // still visible. Keep the first request authoritative so repeated Enter/click
        // cannot duplicate mutations or replace its saved cancellation focus target.
        guard pendingSelectionExecution == nil else { return }
        let item = commandPaletteFilteredItems[commandPaletteSelectedIndex]
        if let picker = sessionPickerContext {
            guard let choice = picker.choicesByItemID[item.id] else {
                NSSound.beep()
                return
            }
            // Take the context before dismissing so the dismissal path cannot resolve
            // this pick as a cancel.
            let context = takeSessionPickerContext()
            dismissCommandPalette()
            context?.completion(choice)
            return
        }
        guard let focusRequest = item.focusRequest else {
            // An `.editorAction` row (currently just "Open in Editor") carries no focus
            // request: opening the workspace's Editor is a synchronous, in-process call, not
            // a window to await, so it skips the pending-execution/return-focus machinery
            // below entirely. Mirrors AlertsController's `automationRunTarget` branch, which
            // is the same "no focusRequest means a different, synchronous action" shape.
            //
            // Palette dismissal and failure-restore for a builtin Editor open are owned by the
            // funnel itself (`AppKitController.openWorkspaceEditor`, via
            // `withPaletteDismissedForBuiltInOpen`) rather than here, since ⌘⌥E and the sidebar's
            // "Open in Editor" item need that exact same dismiss-before-open contract and would
            // otherwise have to duplicate it. For a failed EXTERNAL editor launch the palette
            // intentionally stays open — the external branch dismisses only after a successful
            // launch, see its comment in `openWorkspaceEditor`.
            host.openWorkspaceEditor(workspaceID: item.workspaceID)
            host.reloadData()
            return
        }
        // Return focus is a cancellation contract. Selection keeps a private copy so a
        // failed execution can still restore it, while the dismissal callback cannot race
        // a successful target focus.
        let execution = PendingSelectionExecution(
            returnTerminalSessionID: commandPaletteReturnTerminalSessionID, returnCodePaneID: commandPaletteReturnCodePaneID,
            returnApplicationProcessID: commandPaletteReturnApplicationProcessID)
        pendingSelectionExecution = execution
        commandPaletteReturnTerminalSessionID = nil
        commandPaletteReturnCodePaneID = nil
        commandPaletteReturnApplicationProcessID = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let focused = await self.host.executeWindowFocus(focusRequest)
            guard self.pendingSelectionExecution?.id == execution.id else { return }
            self.pendingSelectionExecution = nil
            guard focused else {
                if self.commandPalettePanel?.isVisible == true {
                    self.commandPaletteReturnTerminalSessionID = execution.returnTerminalSessionID
                    self.commandPaletteReturnCodePaneID = execution.returnCodePaneID
                    self.commandPaletteReturnApplicationProcessID = execution.returnApplicationProcessID
                } else {
                    self.restoreCommandPaletteReturnFocus(
                        terminalSessionID: execution.returnTerminalSessionID, codePaneID: execution.returnCodePaneID,
                        applicationProcessID: execution.returnApplicationProcessID)
                }
                return
            }
            // Every successful focus is remembered as the recent palette focus identity.
            self.rememberRecentCommandPaletteFocusIdentity(item.recentFocusIdentity)
            self.dismissCommandPaletteForBuiltInWindowNavigation()
            self.host.reloadData()
        }
    }
}
