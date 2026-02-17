import AppKit
import Carbon
import Foundation
import streamctl

@MainActor
public final class AppKitController: NSObject, NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate,
    NSWindowDelegate, NSTextFieldDelegate
{
    private var window: NSWindow!
    private var splitView: NSSplitView?
    private let outlineView = NSOutlineView()
    private let detailContainer = NSView()

    private var orchestrator: MuxyOrchestrator!
    private var projects: [ProjectSummary] = []
    private var workspacesByProject: [String: [WorkspaceSummary]] = [:]
    private var gitActivityByWorkspaceID: [String: GitTrackedFileActivity] = [:]

    private var selectedProjectID: String?
    private var selectedWorkspaceID: String?
    private var lastSelectedRow: Int = -1
    private var projectHasUnsavedChanges = false
    private var workspaceHasUnsavedChanges = false
    private var showingSettings = false

    private var hotkeyHandler: EventHandlerRef?
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var toggleShortcutSpec: HotkeySpec?
    private var shortcutMonitor: Any?
    private var nextShortcutSpec: HotkeySpec?
    private var previousShortcutSpec: HotkeySpec?
    private var activateShortcutSpec: HotkeySpec?
    private var openEditorShortcutSpec: HotkeySpec?
    private var openTerminalShortcutSpec: HotkeySpec?
    private var openFinderShortcutSpec: HotkeySpec?
    private var shortcutButtonsBySetting: [String: NSButton] = [:]
    private var activeShortcutCaptureSetting: ShortcutSetting?
    private var periodicWorkspaceRefreshTask: Task<Void, Never>?
    private var periodicUpdateCheckTask: Task<Void, Never>?
    private var lastTrackedWindowCounts: [String: Int] = [:]
    private let updateChecker = UpdateChecker()
    private let appUpdater = AppUpdater()
    private var checkForUpdatesMenuItem: NSMenuItem?
    private var availableUpdate: UpdateInfo?

    private var configCache: AppConfig?
    private let defaultSplitViewWidth: CGFloat = 360
    private let shortcutLabelColumnWidth: CGFloat = 250
    private var isApplyingSplitViewWidth = false
    private var hasAppliedSplitViewWidth = false
    private lazy var relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private lazy var hotkeyHandlerProc: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<AppKitController>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        if status != noErr { return status }
        Task { @MainActor in controller.handleGlobalHotkey(id: hotKeyID.id) }
        return noErr
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try DatabaseLocator.defaultPath()
            let store = try SQLiteStore(path: db)
            orchestrator = MuxyOrchestrator(store: store)
            configCache = try orchestrator.syncConfig()
            loadShortcutSpecs()
        } catch {
            showError(error)
            return
        }

        buildWindow()
        buildMainMenu()
        reloadData()
        setupGlobalHotkey()
        setupShortcutMonitor()
        startPeriodicWorkspaceWindowRefresh()
        startPeriodicUpdateCheck()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        periodicWorkspaceRefreshTask?.cancel()
        periodicUpdateCheckTask?.cancel()
        teardownGlobalHotkey()
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
    }

    private func startPeriodicWorkspaceWindowRefresh() {
        periodicWorkspaceRefreshTask?.cancel()
        periodicWorkspaceRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await Self.refreshWorkspaceWindowsSnapshot()
                if Task.isCancelled { break }
                switch result {
                case .success(let refreshResult):
                    let windowCountsChanged = refreshResult.trackedWindowCounts != self.lastTrackedWindowCounts
                    self.lastTrackedWindowCounts = refreshResult.trackedWindowCounts
                    if (refreshResult.didMutateDB || windowCountsChanged) && self.canReloadAfterBackgroundWorkspaceRefresh() {
                        self.reloadData()
                    }
                case .failure(let error):
                    self.showError(error)
                }
                do {
                    try await Task.sleep(for: .seconds(PollingConstants.workspaceWindowRefreshInterval))
                } catch {
                    break
                }
            }
        }
    }

    private func startPeriodicUpdateCheck() {
        periodicUpdateCheckTask?.cancel()
        periodicUpdateCheckTask = Task { [weak self] in
            guard let self else { return }
            await self.performUpdateCheck()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(4 * 60 * 60))
                } catch { break }
                await self.performUpdateCheck()
            }
        }
    }

    private func performUpdateCheck() async {
        let info = await updateChecker.checkForUpdate()
        availableUpdate = info
        if let info {
            checkForUpdatesMenuItem?.title = "Update Available: v\(info.version)"
        } else {
            checkForUpdatesMenuItem?.title = "Up to Date"
            checkForUpdatesMenuItem?.action = #selector(checkForUpdatesMenuAction(_:))
        }
    }

    @objc private func checkForUpdatesMenuAction(_ sender: Any?) {
        Task {
            checkForUpdatesMenuItem?.title = "Checking..."
            checkForUpdatesMenuItem?.isEnabled = false
            let info = await updateChecker.forceCheck()
            availableUpdate = info
            checkForUpdatesMenuItem?.isEnabled = true
            if let info {
                checkForUpdatesMenuItem?.title = "Update Available: v\(info.version)"
                showUpdateAlert(info: info)
            } else {
                checkForUpdatesMenuItem?.title = "Up to Date"
                let alert = NSAlert()
                alert.messageText = "You're up to date"
                alert.informativeText = "Muxy \(AppVersion.current) is the latest version."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
                checkForUpdatesMenuItem?.title = "Check for Updates..."
            }
        }
    }

    private func showUpdateAlert(info: UpdateInfo) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Muxy v\(info.version) is available (you have v\(AppVersion.current)).\n\n\(info.releaseNotes.prefix(500))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performUpdate(info: info)
        }
    }

    private func performUpdate(info: UpdateInfo) {
        Task {
            checkForUpdatesMenuItem?.title = "Downloading..."
            checkForUpdatesMenuItem?.isEnabled = false
            do {
                try await appUpdater.downloadAndInstall(from: info.downloadURL)
            } catch {
                checkForUpdatesMenuItem?.title = "Update Available: v\(info.version)"
                checkForUpdatesMenuItem?.isEnabled = true
                showError(error)
            }
        }
    }

    private func canReloadAfterBackgroundWorkspaceRefresh() -> Bool {
        !projectHasUnsavedChanges && !workspaceHasUnsavedChanges && !isTextInputFocused()
    }

    private enum WorkspaceLifecycleAction {
        case launch
        case restart
        case stop
        case archive
    }

    nonisolated private static func refreshWorkspaceWindowsSnapshot() async -> Result<MuxyOrchestrator.RefreshResult, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                let result = try orchestrator.refreshAllWorkspaceWindows()
                return .success(result)
            } catch {
                return .failure(error)
            }
        }.value
    }

    nonisolated private static func runWorkspaceLifecycleAction(_ action: WorkspaceLifecycleAction, workspaceID: String) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                switch action {
                case .launch:
                    try orchestrator.launchWorkspace(workspaceID: workspaceID)
                case .restart:
                    try orchestrator.restartWorkspace(workspaceID: workspaceID)
                case .stop:
                    try orchestrator.stopWorkspace(workspaceID: workspaceID)
                case .archive:
                    try orchestrator.archiveWorkspace(workspaceID: workspaceID)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Muxy")
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesMenuAction(_:)), keyEquivalent: "")
        updateItem.target = self
        checkForUpdatesMenuItem = updateItem
        appMenu.addItem(updateItem)
        let versionItem = NSMenuItem(title: "Version \(AppVersion.current)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        appMenu.addItem(versionItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Muxy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let rect = NSRect(x: 200, y: 200, width: 1100, height: 700)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.title = "Muxy"
        window.center()
        window.delegate = self

        let splitView = NSSplitView()
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.delegate = self
        self.splitView = splitView

        let leftPane = makeLeftPane()
        let rightPane = makeRightPane()

        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        let content = NSView()
        content.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor), splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor), splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    private func makeLeftPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let sectionHeader = sidebarSectionHeader(
            title: "Projects",
            actions: [
                (symbol: "plus", tooltip: "New project", action: #selector(addProject)),
                (symbol: "gearshape", tooltip: "Settings", action: #selector(showSettings)),
                (symbol: "arrow.clockwise", tooltip: "Reload", action: #selector(reloadTapped)),
            ])

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Projects"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .none
        outlineView.backgroundColor = .clear
        outlineView.delegate = self
        outlineView.dataSource = self

        scroll.documentView = outlineView

        container.addSubview(sectionHeader)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            sectionHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            sectionHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            sectionHeader.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func makeRightPane() -> NSView {
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor
        let placeholder = NSTextField(labelWithString: "Select a project or workspace.")
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
        ])
        return detailContainer
    }

    private func reloadData() {
        do {
            configCache = try orchestrator.syncConfig()
            loadShortcutSpecs()
            projects = try orchestrator.listProjects()
            workspacesByProject = [:]
            gitActivityByWorkspaceID = [:]
            for project in projects {
                let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false)
                workspacesByProject[project.id] = workspaces
                guard project.isGitRepo else { continue }
                for workspace in workspaces {
                    if let activity = try orchestrator.workspaceGitTrackedFileActivity(workspaceID: workspace.id) {
                        gitActivityByWorkspaceID[workspace.id] = activity
                    }
                }
            }
            for (projectID, workspaces) in workspacesByProject {
                workspacesByProject[projectID] = workspaces.sorted { a, b in
                    let aDate = gitActivityByWorkspaceID[a.id]?.latestTrackedFileModificationDate ?? .distantPast
                    let bDate = gitActivityByWorkspaceID[b.id]?.latestTrackedFileModificationDate ?? .distantPast
                    return aDate > bDate
                }
            }
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
            refreshSelection()
        } catch { showError(error) }
    }

    private func refreshSelection() {
        if showingSettings {
            showSettingsDetail()
            return
        }
        if let selectedWorkspaceID {
            if let (project, workspace) = findWorkspace(id: selectedWorkspaceID) {
                showWorkspaceDetail(project: project, workspace: workspace)
                return
            }
        }
        if let selectedProjectID, let project = projects.first(where: { $0.id == selectedProjectID }) {
            showProjectDetail(project: project)
            return
        }
        showPlaceholder()
    }

    private func showPlaceholder() {
        showingSettings = false
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }
        let placeholder = NSTextField(labelWithString: "Select a project or workspace.")
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
        ])
    }

    private func showSettingsDetail() {
        showingSettings = true
        shortcutButtonsBySetting.removeAll()
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Settings")
        header.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(label(text: "Preferred editor"))

        let options = installedEditorOptions()
        let currentEditor: EditorPreference? = {
            guard let editor = configCache?.editor, editor != .none else { return nil }
            return editor
        }()
        if options.isEmpty {
            let note = NSTextField(labelWithString: "No supported editors detected (VS Code, Cursor, Windsurf).")
            note.font = .systemFont(ofSize: 12)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
        } else {
            let popUp = NSPopUpButton()
            popUp.translatesAutoresizingMaskIntoConstraints = false
            popUp.autoenablesItems = false
            popUp.addItem(withTitle: "Select editor")
            popUp.item(at: 0)?.isEnabled = false
            for option in options {
                popUp.addItem(withTitle: option.displayName)
                popUp.itemArray.last?.representedObject = option.preference
            }
            if let current = currentEditor, let item = popUp.itemArray.first(where: { ($0.representedObject as? EditorPreference) == current }) {
                popUp.select(item)
            } else {
                popUp.selectItem(at: 0)
            }
            popUp.target = self
            popUp.action = #selector(editorPreferenceChanged(_:))
            stack.addArrangedSubview(popUp)
            constrainFormFieldToFillWidth(popUp, in: stack)
        }

        if let current = currentEditor, !options.contains(where: { $0.preference == current }) {
            let note = NSTextField(labelWithString: "Saved editor \"\(editorDisplayName(current))\" is not installed.")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
        }

        stack.addArrangedSubview(label(text: "Keyboard shortcuts"))
        let shortcutsNote = NSTextField(
            labelWithString:
                "Click a shortcut, then press the key combination you want. Next/Previous cycle running workspaces when muxy is focused, and cycle workspace windows when a workspace window is focused."
        )
        shortcutsNote.font = .systemFont(ofSize: 11)
        shortcutsNote.textColor = .secondaryLabelColor
        shortcutsNote.maximumNumberOfLines = 0
        shortcutsNote.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(shortcutsNote)

        for setting in ShortcutSetting.settingsPanelCases {
            let row = shortcutSettingsRow(setting: setting)
            stack.addArrangedSubview(row)
            constrainFormFieldToFillWidth(row, in: stack)
        }

        showScrollableDetailStack(stack)
    }

    private func showProjectDetail(project: ProjectSummary) {
        showingSettings = false
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let fullProject = (try? orchestrator.project(id: project.id))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Header ---
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let headerIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: project.name) {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor]).applying(
                NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
            headerIcon.image = img.withSymbolConfiguration(config)
        }
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([headerIcon.widthAnchor.constraint(equalToConstant: 28), headerIcon.heightAnchor.constraint(equalToConstant: 28)])

        let headerTitle = NSTextField(labelWithString: project.name)
        headerTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        headerTitle.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)

        let addWorkspaceButton = actionButton(
            title: "New Workspace", symbol: "plus.rectangle.on.rectangle", tooltip: "New workspace for \(project.name)",
            action: #selector(addWorkspaceFromToolbar), primary: false)
        addWorkspaceButton.identifier = NSUserInterfaceItemIdentifier(project.id)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.addArrangedSubview(headerIcon)
        headerRow.addArrangedSubview(headerTitle)
        headerRow.addArrangedSubview(NSView())
        if project.isGitRepo { headerRow.addArrangedSubview(addWorkspaceButton) }

        let headerSubtitle = NSTextField(labelWithString: project.dir)
        headerSubtitle.font = .systemFont(ofSize: 12)
        headerSubtitle.textColor = .secondaryLabelColor
        headerSubtitle.lineBreakMode = .byTruncatingMiddle

        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(headerSubtitle)
        constrainFormFieldToFillWidth(headerRow, in: stack)

        // --- Fields ---
        let setupView = makeEditableTextView()
        let stopView = makeEditableTextView()
        let portEditor = PortEditor()
        let processEditor = ProcessEditor()
        let browserView = makeEditableTextView()
        let browserScroll = scrollableTextView(browserView, height: 80)
        setupView.string = fullProject?.setupScript ?? ""
        stopView.string = fullProject?.stopScript ?? ""
        portEditor.setDefinitions(fullProject?.ports ?? [])
        processEditor.setProcessesWithChecks(fullProject?.processes ?? [], statusChecks: fullProject?.statusChecks ?? [])
        browserView.string = (fullProject?.browserSessions ?? []).compactMap { $0.url }.joined(separator: "\n")

        // --- Setup script card ---
        let setupScroll = scrollableTextView(setupView, height: 90)
        let setupCard = formSectionCard(
            icon: "terminal", title: "Setup script", subtitle: "Runs when each new workspace is created or revived from archive.",
            contentViews: [setupScroll])
        stack.addArrangedSubview(setupCard)
        constrainFormFieldToFillWidth(setupCard, in: stack)

        // --- Port definitions card ---
        let portCard = formSectionCard(
            icon: "network", title: "Port definitions",
            subtitle: "Named ports allocated per workspace. Available as env vars in scripts and commands.",
            contentViews: [portEditor.container])
        stack.addArrangedSubview(portCard)
        constrainFormFieldToFillWidth(portCard, in: stack)

        // --- Processes card ---
        let processCard = formSectionCard(
            icon: "terminal.fill", title: "Processes", subtitle: "Define the commands that run inside your workspace.",
            contentViews: [processEditor.container])
        stack.addArrangedSubview(processCard)
        constrainFormFieldToFillWidth(processCard, in: stack)

        // --- Browser sessions card ---
        let browserCard = formSectionCard(
            icon: "globe", title: "Browser sessions", subtitle: "URLs to open automatically, one per line.", contentViews: [browserScroll])
        stack.addArrangedSubview(browserCard)
        constrainFormFieldToFillWidth(browserCard, in: stack)

        // --- Stop script card ---
        let stopScroll = scrollableTextView(stopView, height: 90)
        let stopCard = formSectionCard(
            icon: "stop.circle", title: "Stop script", subtitle: "Runs on stop/restart/archive after process termination.", contentViews: [stopScroll]
        )
        stack.addArrangedSubview(stopCard)
        constrainFormFieldToFillWidth(stopCard, in: stack)

        // --- Buttons ---
        let saveButton = actionButton(
            title: "Save Project", symbol: "square.and.arrow.down", tooltip: "Save project (⌘S)", action: #selector(saveProject(_:)), primary: true)
        saveButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .texturedRounded
        saveButton.wantsLayer = true
        saveButton.layer?.backgroundColor = accentColor.cgColor
        saveButton.layer?.cornerRadius = 6
        let buttonTextColor = NSColor.white
        saveButton.attributedTitle = NSAttributedString(
            string: "Save Project", attributes: [.foregroundColor: buttonTextColor, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        if let saveImg = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save") {
            let imgConfig = NSImage.SymbolConfiguration(paletteColors: [buttonTextColor])
            saveButton.image = saveImg.withSymbolConfiguration(imgConfig)
        }

        let deleteButton = iconButton(symbol: "trash", tooltip: "Delete project", action: #selector(deleteProject(_:)))
        deleteButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        let muted = NSColor.systemRed.withAlphaComponent(0.6)
        deleteButton.contentTintColor = muted

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(deleteButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        saveButton.tag = storeProjectFields(
            projectID: project.id, setupView: setupView, stopView: stopView, portEditor: portEditor, processEditor: processEditor,
            browserView: browserView)
        registerDirtyTracking(
            setupView: setupView, stopView: stopView, portEditor: portEditor, processEditor: processEditor, browserView: browserView)
    }

    private func formSectionCard(icon: String, title: String, subtitle: String, trailingView: NSView? = nil, contentViews: [NSView]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = sidebarCardBorderColor(isSelected: false).cgColor
        card.layer?.backgroundColor = sidebarCardBackgroundColor(isArchived: false).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setContentHuggingPriority(.required, for: .vertical)

        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))

        // Header row: icon + title/subtitle + optional trailing view
        let iconView = NSImageView()
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor])
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 20), iconView.heightAnchor.constraint(equalToConstant: 20)])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(subtitleLabel)
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 10
        headerRow.addArrangedSubview(iconView)
        headerRow.addArrangedSubview(titleStack)
        if let trailing = trailingView {
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            headerRow.addArrangedSubview(trailing)
        }

        let innerStack = NSStackView()
        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 10
        innerStack.translatesAutoresizingMaskIntoConstraints = false
        innerStack.addArrangedSubview(headerRow)
        for view in contentViews { innerStack.addArrangedSubview(view) }

        card.addSubview(innerStack)
        NSLayoutConstraint.activate([
            innerStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            innerStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            innerStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            innerStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        for view in contentViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        }

        return card
    }

    private func showAddProjectForm() {
        showingSettings = false
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Header ---
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let headerIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Project") {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor]).applying(
                NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
            headerIcon.image = img.withSymbolConfiguration(config)
        }
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([headerIcon.widthAnchor.constraint(equalToConstant: 28), headerIcon.heightAnchor.constraint(equalToConstant: 28)])

        let headerTitle = NSTextField(labelWithString: "New Project")
        headerTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        headerTitle.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.addArrangedSubview(headerIcon)
        headerRow.addArrangedSubview(headerTitle)

        let headerSubtitle = NSTextField(labelWithString: "Configure your workspace, processes, and lifecycle scripts.")
        headerSubtitle.font = .systemFont(ofSize: 12)
        headerSubtitle.textColor = .secondaryLabelColor

        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(headerSubtitle)

        // --- Fields ---
        let sourcePopup = NSPopUpButton()
        sourcePopup.addItems(withTitles: ["Existing directory", "Clone repository"])
        sourcePopup.selectItem(at: 0)
        sourcePopup.target = self
        sourcePopup.action = #selector(projectSourceChanged(_:))

        let dirField = NSTextField(labelWithString: "")
        dirField.toolTip = nil
        dirField.textColor = .secondaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.isHidden = true
        let browseButton = NSButton(title: "Choose a project directory", target: self, action: #selector(browseProjectDir(_:)))
        browseButton.bezelStyle = .texturedRounded
        browseButton.controlSize = .regular
        browseButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose directory")
        browseButton.imagePosition = .imageLeading
        browseButton.toolTip = "Choose directory"
        let repoURLField = NSTextField(string: "")
        repoURLField.placeholderString = "https://github.com/org/repo.git"

        let setupView = makeEditableTextView()
        let stopView = makeEditableTextView()
        let portEditor = PortEditor()
        let processEditor = ProcessEditor()
        let browserView = makeEditableTextView()
        let browserScroll = scrollableTextView(browserView, height: 80)
        // --- Source row: popup + dir/URL input on same line ---
        let localSourceSection = NSStackView()
        localSourceSection.orientation = .horizontal
        localSourceSection.alignment = .centerY
        localSourceSection.spacing = 8
        localSourceSection.detachesHiddenViews = true

        browseButton.translatesAutoresizingMaskIntoConstraints = false
        browseButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browseButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([browseButton.heightAnchor.constraint(equalToConstant: 28)])

        dirField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        localSourceSection.addArrangedSubview(browseButton)
        localSourceSection.addArrangedSubview(dirField)

        let cloneSourceSection = NSStackView()
        cloneSourceSection.orientation = .horizontal
        cloneSourceSection.alignment = .centerY
        cloneSourceSection.spacing = 8
        cloneSourceSection.detachesHiddenViews = true

        repoURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        repoURLField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cloneSourceSection.addArrangedSubview(repoURLField)

        // --- Source section (combined): popup on top, then dir/url row ---
        let sourceInputRow = NSStackView()
        sourceInputRow.orientation = .horizontal
        sourceInputRow.alignment = .centerY
        sourceInputRow.spacing = 8
        sourceInputRow.detachesHiddenViews = true

        sourcePopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sourcePopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        sourceInputRow.addArrangedSubview(sourcePopup)
        sourceInputRow.addArrangedSubview(localSourceSection)
        sourceInputRow.addArrangedSubview(cloneSourceSection)

        let sourceContentStack = NSStackView()
        sourceContentStack.orientation = .vertical
        sourceContentStack.alignment = .leading
        sourceContentStack.spacing = 8
        sourceContentStack.detachesHiddenViews = true
        sourceContentStack.addArrangedSubview(sourceInputRow)
        constrainFormFieldToFillWidth(sourceInputRow, in: sourceContentStack)

        let sourceCard = formSectionCard(
            icon: "folder.badge.plus", title: "Source", subtitle: "Where does your project live?", contentViews: [sourceContentStack])
        stack.addArrangedSubview(sourceCard)

        // --- Setup script card ---
        let setupScroll = scrollableTextView(setupView, height: 90)
        let setupCard = formSectionCard(
            icon: "terminal", title: "Setup script", subtitle: "Runs when each new workspace is created or revived from archive.",
            contentViews: [setupScroll])
        stack.addArrangedSubview(setupCard)

        // --- Port definitions card ---
        let addPortCard = formSectionCard(
            icon: "network", title: "Port definitions",
            subtitle: "Named ports allocated per workspace. Available as env vars in scripts and commands.",
            contentViews: [portEditor.container])
        stack.addArrangedSubview(addPortCard)

        // --- Processes card ---
        let processCard = formSectionCard(
            icon: "terminal.fill", title: "Processes", subtitle: "Define the commands that run inside your workspace.",
            contentViews: [processEditor.container])
        stack.addArrangedSubview(processCard)

        // --- Browser sessions card ---
        let browserCard = formSectionCard(
            icon: "globe", title: "Browser sessions", subtitle: "URLs to open automatically, one per line.", contentViews: [browserScroll])
        stack.addArrangedSubview(browserCard)

        // --- Stop script card ---
        let stopScroll = scrollableTextView(stopView, height: 90)
        let stopCard = formSectionCard(
            icon: "stop.circle", title: "Stop script", subtitle: "Seeded into workspaces and run on stop/restart/archive", contentViews: [stopScroll])
        stack.addArrangedSubview(stopCard)

        // --- Buttons ---
        let createButton = actionButton(
            title: "Create Project", symbol: nil, tooltip: "Create project", action: #selector(createProject(_:)), primary: true)
        createButton.keyEquivalent = "\r"
        createButton.bezelStyle = .texturedRounded
        createButton.wantsLayer = true
        createButton.layer?.backgroundColor = accentColor.cgColor
        createButton.layer?.cornerRadius = 6
        let buttonTextColor = NSColor.white
        createButton.attributedTitle = NSAttributedString(
            string: "Create Project", attributes: [.foregroundColor: buttonTextColor, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        let cancelButton = actionButton(title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(createButton)
        stack.addArrangedSubview(buttonRow)

        // --- Width constraints ---
        constrainFormFieldToFillWidth(sourceCard, in: stack)
        constrainFormFieldToFillWidth(setupCard, in: stack)
        constrainFormFieldToFillWidth(addPortCard, in: stack)
        constrainFormFieldToFillWidth(processCard, in: stack)
        constrainFormFieldToFillWidth(browserCard, in: stack)
        constrainFormFieldToFillWidth(stopCard, in: stack)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        createButton.tag = storeAddProjectFields(
            sourcePopup: sourcePopup, localSourceSection: localSourceSection, cloneSourceSection: cloneSourceSection, dirField: dirField,
            repoURLField: repoURLField, setupView: setupView, stopView: stopView, portEditor: portEditor, processEditor: processEditor,
            browserView: browserView, browseButton: browseButton)
        if let refs = AddProjectFieldCache.shared.cache[createButton.tag] { updateAddProjectSourceUI(refs) }
    }

    private func showAddWorkspaceForm(project: ProjectSummary) {
        showingSettings = false
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Header ---
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let headerIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "plus.rectangle.on.folder", accessibilityDescription: "New Workspace") {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor]).applying(
                NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
            headerIcon.image = img.withSymbolConfiguration(config)
        }
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([headerIcon.widthAnchor.constraint(equalToConstant: 28), headerIcon.heightAnchor.constraint(equalToConstant: 28)])

        let headerTitle = NSTextField(labelWithString: "New Workspace")
        headerTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        headerTitle.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.addArrangedSubview(headerIcon)
        headerRow.addArrangedSubview(headerTitle)

        let headerSubtitle = NSTextField(labelWithString: "Create a new workspace for \(project.name).")
        headerSubtitle.font = .systemFont(ofSize: 12)
        headerSubtitle.textColor = .secondaryLabelColor

        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(headerSubtitle)

        // --- Fields ---
        let suggestedName = (try? orchestrator.suggestedWorkspaceName(projectID: project.id)) ?? ""
        let nameField = NSTextField(string: project.isGitRepo ? "" : suggestedName)
        nameField.placeholderString = "workspace name"
        let targetBranchField = NSComboBox()
        targetBranchField.usesDataSource = false
        targetBranchField.completes = true
        targetBranchField.numberOfVisibleItems = 10
        let targetBranches = (try? orchestrator.gitBranchOptions(projectID: project.id)) ?? []
        targetBranchField.addItems(withObjectValues: targetBranches)
        if let defaultTargetBranch = defaultWorkspaceTargetBranch(project: project, branches: targetBranches) {
            targetBranchField.stringValue = defaultTargetBranch
        }
        let branchField = NSTextField(string: "")
        branchField.placeholderString = "branch name"
        branchField.delegate = self
        let directoryNameField = NSTextField(string: "")
        directoryNameField.placeholderString = "optional: letters, numbers, -, _"
        let autoNameState = project.isGitRepo ? AddWorkspaceAutoNameState() : nil

        // --- Single card with all inputs ---
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8

        if project.isGitRepo {
            contentStack.addArrangedSubview(label(text: "Target branch"))
            contentStack.addArrangedSubview(helpTextLabel("The existing branch your new branch will be based on."))
            contentStack.addArrangedSubview(targetBranchField)
            contentStack.addArrangedSubview(label(text: "Branch name"))
            contentStack.addArrangedSubview(helpTextLabel("Enter an existing branch or a new branch name to create."))
            contentStack.addArrangedSubview(branchField)
            constrainFormFieldToFillWidth(targetBranchField, in: contentStack)
            constrainFormFieldToFillWidth(branchField, in: contentStack)
        }

        contentStack.addArrangedSubview(label(text: "Workspace name"))
        contentStack.addArrangedSubview(helpTextLabel("Display name for this workspace in the sidebar."))
        contentStack.addArrangedSubview(nameField)
        constrainFormFieldToFillWidth(nameField, in: contentStack)

        if project.isGitRepo {
            contentStack.addArrangedSubview(label(text: "Directory name"))
            contentStack.addArrangedSubview(helpTextLabel("Auto-filled from branch name. Only letters, numbers, -, _ allowed."))
            contentStack.addArrangedSubview(directoryNameField)
            constrainFormFieldToFillWidth(directoryNameField, in: contentStack)
        }

        let card = formSectionCard(
            icon: "plus.rectangle.on.folder", title: "Workspace",
            subtitle: project.isGitRepo ? "Configure branch, name, and directory for your new workspace." : "Name your new workspace.",
            contentViews: [contentStack])
        stack.addArrangedSubview(card)
        constrainFormFieldToFillWidth(card, in: stack)

        // --- Buttons ---
        let createButton = actionButton(
            title: "Create Workspace", symbol: nil, tooltip: "Create workspace", action: #selector(createWorkspace(_:)), primary: true)
        createButton.keyEquivalent = "\r"
        createButton.bezelStyle = .texturedRounded
        createButton.wantsLayer = true
        createButton.layer?.backgroundColor = accentColor.cgColor
        createButton.layer?.cornerRadius = 6
        let buttonTextColor = NSColor.white
        createButton.attributedTitle = NSAttributedString(
            string: "Create Workspace", attributes: [.foregroundColor: buttonTextColor, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        let cancelButton = actionButton(title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(createButton)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        createButton.tag = storeAddWorkspaceFields(
            projectID: project.id, isGitRepo: project.isGitRepo, targetBranchField: project.isGitRepo ? targetBranchField : nil, nameField: nameField,
            directoryNameField: project.isGitRepo ? directoryNameField : nil, branchField: project.isGitRepo ? branchField : nil,
            autoNameState: autoNameState)
    }

    private func showWorkspaceDetail(project: ProjectSummary, workspace: WorkspaceSummary) {
        showingSettings = false
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Header with status dot ---
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let statusDot = NSImageView()
        statusDot.image = NSImage(
            systemSymbolName: workspace.isRunning ? "circle.fill" : "circle", accessibilityDescription: workspace.isRunning ? "Running" : "Stopped")
        statusDot.contentTintColor = workspace.isRunning ? accentColor : .tertiaryLabelColor
        statusDot.setContentHuggingPriority(.required, for: .horizontal)
        let headerText = NSTextField(labelWithString: "\(project.name) / \(workspace.name)")
        headerText.font = .systemFont(ofSize: 20, weight: .semibold)
        headerText.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(statusDot)
        headerRow.addArrangedSubview(headerText)

        // --- Metadata rows ---
        var metadataRows: [NSView] = []
        if let branch = workspace.branch {
            let branchRow = NSStackView()
            branchRow.orientation = .horizontal
            branchRow.alignment = .centerY
            branchRow.spacing = 4
            let branchIcon = NSImageView()
            branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")
            branchIcon.contentTintColor = .secondaryLabelColor
            branchIcon.setContentHuggingPriority(.required, for: .horizontal)
            let branchLabel = NSTextField(labelWithString: branch)
            branchLabel.font = .systemFont(ofSize: 12)
            branchLabel.textColor = .secondaryLabelColor
            branchRow.addArrangedSubview(branchIcon)
            branchRow.addArrangedSubview(branchLabel)
            metadataRows.append(branchRow)
        }

        let dirRow = NSStackView()
        dirRow.orientation = .horizontal
        dirRow.alignment = .centerY
        dirRow.spacing = 4
        let folderIcon = NSImageView()
        folderIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Directory")
        folderIcon.contentTintColor = .secondaryLabelColor
        folderIcon.setContentHuggingPriority(.required, for: .horizontal)
        let dirField = NSTextField(labelWithString: workspace.dir)
        dirField.font = .systemFont(ofSize: 12)
        dirField.textColor = .secondaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        let copyDirButton = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy path")!, target: self,
            action: #selector(copyDirectoryPath(_:)))
        copyDirButton.bezelStyle = .inline
        copyDirButton.isBordered = false
        copyDirButton.toolTip = "Copy directory path"
        copyDirButton.identifier = NSUserInterfaceItemIdentifier(workspace.dir)
        dirRow.addArrangedSubview(folderIcon)
        dirRow.addArrangedSubview(dirField)
        dirRow.addArrangedSubview(copyDirButton)
        metadataRows.append(dirRow)

        // --- Action buttons ---
        let launchOrRestartButton: NSButton
        if workspace.isRunning {
            launchOrRestartButton = actionButton(
                title: "Restart", symbol: "arrow.clockwise.circle", tooltip: "Restart", action: #selector(restartWorkspace(_:)), primary: false)
        } else {
            launchOrRestartButton = actionButton(
                title: "Launch", symbol: "play.circle", tooltip: "Launch", action: #selector(launchWorkspace(_:)), primary: false)
        }
        launchOrRestartButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        let stopButton = actionButton(title: "Stop", symbol: "stop.circle", tooltip: "Stop", action: #selector(stopWorkspace(_:)), primary: false)
        stopButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        let archiveButton = actionButton(
            title: "Archive", symbol: "archivebox", tooltip: "Archive", action: #selector(archiveWorkspace(_:)), primary: false)
        archiveButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        archiveButton.isEnabled = !workspace.isDefault
        let muted = NSColor.systemRed.withAlphaComponent(0.6)
        let redTitle = NSMutableAttributedString(
            string: "Archive", attributes: [.foregroundColor: muted, .font: archiveButton.font ?? NSFont.systemFont(ofSize: 13)])
        archiveButton.attributedTitle = redTitle
        if let baseImage = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Archive") {
            let config = NSImage.SymbolConfiguration(paletteColors: [muted])
            archiveButton.image = baseImage.withSymbolConfiguration(config)
        }

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(launchOrRestartButton)
        buttonRow.addArrangedSubview(stopButton)
        buttonRow.addArrangedSubview(NSView())

        // --- Tabs ---
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.tabViewType = .topTabsBezelBorder
        let runTab = NSTabViewItem(identifier: "run")
        runTab.label = "Run"
        runTab.view = workspaceRunView(workspace: workspace)
        let envTab = NSTabViewItem(identifier: "env")
        envTab.label = "Env"
        envTab.view = workspaceEnvView(project: project, workspace: workspace)
        let settingsTab = NSTabViewItem(identifier: "settings")
        settingsTab.label = "Settings"
        settingsTab.view = workspaceSettingsView(project: project, workspace: workspace)
        tabs.addTabViewItem(runTab)
        tabs.addTabViewItem(envTab)
        tabs.addTabViewItem(settingsTab)

        stack.addArrangedSubview(headerRow)
        for row in metadataRows { stack.addArrangedSubview(row) }
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(tabs)
        stack.addArrangedSubview(archiveButton)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 20), tabs.heightAnchor.constraint(equalToConstant: 460),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        detailContainer.layoutSubtreeIfNeeded()
    }

    private func workspaceRunView(workspace: WorkspaceSummary) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.translatesAutoresizingMaskIntoConstraints = false

        // --- Quick actions ---
        let openEditorButton = actionButton(
            title: actionTitle(base: "Open Editor", setting: .guiOpenEditorShortcut), symbol: nil,
            tooltip: actionTooltip(base: "Open preferred editor", setting: .guiOpenEditorShortcut), action: #selector(openWorkspaceEditor(_:)),
            primary: false)
        let openTerminalButton = actionButton(
            title: actionTitle(base: "Open Terminal", setting: .guiOpenTerminalShortcut), symbol: nil,
            tooltip: actionTooltip(base: "Open terminal window", setting: .guiOpenTerminalShortcut), action: #selector(openWorkspaceTerminal(_:)),
            primary: false)
        let openFinderButton = actionButton(
            title: actionTitle(base: "Open Finder", setting: .guiOpenFinderShortcut), symbol: nil,
            tooltip: actionTooltip(base: "Open Finder window", setting: .guiOpenFinderShortcut), action: #selector(openWorkspaceFinder(_:)),
            primary: false)
        openEditorButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        openTerminalButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        openFinderButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        if let editor = configCache?.editor, editor != .none {
            openEditorButton.toolTip = "\(editorDisplayName(editor)) (\(shortcutHint(for: .guiOpenEditorShortcut)))"
        } else {
            openEditorButton.isEnabled = false
            openEditorButton.toolTip = "Preferred editor not configured"
        }
        // --- Quick actions (centered) ---
        let centeredOpenRow = NSStackView()
        centeredOpenRow.orientation = .horizontal
        centeredOpenRow.alignment = .centerY
        centeredOpenRow.spacing = 8
        centeredOpenRow.addArrangedSubview(NSView())
        centeredOpenRow.addArrangedSubview(openEditorButton)
        centeredOpenRow.addArrangedSubview(openTerminalButton)
        centeredOpenRow.addArrangedSubview(openFinderButton)
        centeredOpenRow.addArrangedSubview(NSView())
        container.addArrangedSubview(centeredOpenRow)
        constrainFormFieldToFillWidth(centeredOpenRow, in: container)

        // --- Windows card ---
        let processes = (try? orchestrator.runningProcesses(workspaceID: workspace.id)) ?? []
        let windows = (try? orchestrator.windows(workspaceID: workspace.id)) ?? []
        let processByWindowID: [Int: RunningProcessRecord] = {
            var map: [Int: RunningProcessRecord] = [:]
            for process in processes { if let wid = process.windowID { map[wid] = process } }
            return map
        }()
        let windowsStack = NSStackView()
        windowsStack.orientation = .vertical
        windowsStack.spacing = 4
        if windows.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No captured windows")
            emptyLabel.font = .systemFont(ofSize: 11)
            emptyLabel.textColor = .tertiaryLabelColor
            emptyLabel.alignment = .left
            windowsStack.alignment = .leading
            windowsStack.addArrangedSubview(emptyLabel)
        } else {
            for (idx, win) in windows.enumerated() {
                let windowLabel: String
                let iconName: String
                let iconColor: NSColor
                switch win.role {
                case "browser":
                    windowLabel = win.targetURL ?? win.title ?? win.app
                    iconName = "globe"
                    iconColor = .systemBlue
                case "terminal":
                    if let wid = win.windowID, let process = processByWindowID[wid] {
                        windowLabel = process.command
                    } else {
                        windowLabel = win.title ?? win.app
                    }
                    iconName = "terminal"
                    iconColor = .systemGreen
                default:
                    windowLabel = win.title ?? win.app
                    iconName = "chevron.left.forwardslash.chevron.right"
                    iconColor = .systemPurple
                }
                let row = windowRow(icon: iconName, iconColor: iconColor, label: windowLabel, shortcut: "CMD+\(idx + 1)")
                windowsStack.addArrangedSubview(row)
                constrainFormFieldToFillWidth(row, in: windowsStack)
            }
        }
        let windowsHeader = sectionHeader(icon: "macwindow.on.rectangle", title: "Windows")
        container.addArrangedSubview(windowsHeader)
        constrainFormFieldToFillWidth(windowsHeader, in: container)
        container.addArrangedSubview(windowsStack)
        constrainFormFieldToFillWidth(windowsStack, in: container)

        // --- Processes card ---
        let results = (try? orchestrator.runStatusChecks(workspaceID: workspace.id)) ?? []
        let processesStack = NSStackView()
        processesStack.orientation = .vertical
        processesStack.spacing = 4
        if processes.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No running processes")
            emptyLabel.font = .systemFont(ofSize: 11)
            emptyLabel.textColor = .tertiaryLabelColor
            emptyLabel.alignment = .left
            processesStack.alignment = .leading
            processesStack.addArrangedSubview(emptyLabel)
        } else {
            for process in processes {
                let statusIcon: String
                let statusColor: NSColor
                switch process.status {
                case .running:
                    statusIcon = "circle.fill"
                    statusColor = .systemGreen
                case .exited:
                    statusIcon = "circle"
                    statusColor = .systemRed
                case .idle:
                    statusIcon = "circle"
                    statusColor = .tertiaryLabelColor
                }
                let row = processRow(icon: statusIcon, iconColor: statusColor, name: process.templateName, command: process.command, shortcut: process.status.rawValue)
                processesStack.addArrangedSubview(row)
                constrainFormFieldToFillWidth(row, in: processesStack)

                let checks = results.filter { $0.processID == process.id }
                for check in checks {
                    let checkColor: NSColor = check.status == "green" ? .systemGreen : .systemRed
                    let checkRow = statusCheckSubRow(name: check.checkName, color: checkColor, status: check.status)
                    processesStack.addArrangedSubview(checkRow)
                    constrainFormFieldToFillWidth(checkRow, in: processesStack)
                }
            }
        }
        let processesHeader = sectionHeader(icon: "terminal.fill", title: "Processes")
        container.addArrangedSubview(processesHeader)
        constrainFormFieldToFillWidth(processesHeader, in: container)
        container.addArrangedSubview(processesStack)
        constrainFormFieldToFillWidth(processesStack, in: container)

        // (quick actions moved above Windows section)

        return insetContainerView(container)
    }

    private func workspaceEnvView(project: ProjectSummary, workspace: WorkspaceSummary) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.translatesAutoresizingMaskIntoConstraints = false
        let envView = NSTextView()
        envView.isEditable = false
        envView.isSelectable = true
        envView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let namedPorts = (try? orchestrator.workspacePortsNamed(workspaceID: workspace.id)) ?? []
        var lines: [String] = []
        for namedPort in namedPorts {
            let key = namedPort.name.isEmpty ? "PORT\(lines.count)" : namedPort.name
            lines.append("\(key)=\(namedPort.port)")
        }
        lines.append("MUXY_WORKSPACE_DIR=\(workspace.dir)")
        lines.append("MUXY_PROJECT_DIR=\(project.dir)")
        envView.string = lines.joined(separator: "\n")
        if let container = envView.textContainer, let layout = envView.layoutManager { layout.ensureLayout(for: container) }
        let scroll = scrollableTextView(envView, height: 240)
        let envCard = formSectionCard(
            icon: "list.bullet.rectangle", title: "Environment variables", subtitle: "Injected into workspace processes at launch.",
            contentViews: [scroll])
        container.addArrangedSubview(envCard)
        constrainFormFieldToFillWidth(envCard, in: container)
        return insetContainerView(container)
    }

    private func workspaceSettingsView(project: ProjectSummary, workspace: WorkspaceSummary) -> NSView {
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let portEditor = PortEditor()
        let processEditor = ProcessEditor()
        let stopView = makeEditableTextView()
        let stopScroll = scrollableTextView(stopView, height: 90)
        let browserView = makeEditableTextView()
        let browserScroll = scrollableTextView(browserView, height: 80)

        if let config = try? orchestrator.workspaceSettings(workspaceID: workspace.id) {
            stopView.string = config.stopScript ?? ""
            portEditor.setDefinitions(config.ports)
            processEditor.setProcessesWithChecks(config.processes, statusChecks: config.statusChecks)
            browserView.string = config.browserSessions.compactMap { $0.url }.joined(separator: "\n")
        } else {
            let fullProject = try? orchestrator.project(id: project.id)
            stopView.string = fullProject?.stopScript ?? ""
            portEditor.setDefinitions(fullProject?.ports ?? [])
            processEditor.setProcessesWithChecks(fullProject?.processes ?? [], statusChecks: fullProject?.statusChecks ?? [])
            browserView.string = (fullProject?.browserSessions ?? []).compactMap { $0.url }.joined(separator: "\n")
        }

        let saveButton = actionButton(
            title: "Save Workspace", symbol: "square.and.arrow.down", tooltip: "Save workspace settings", action: #selector(saveWorkspace(_:)),
            primary: true)
        saveButton.bezelStyle = .texturedRounded
        saveButton.wantsLayer = true
        saveButton.layer?.backgroundColor = accentColor.cgColor
        saveButton.layer?.cornerRadius = 6
        let buttonTextColor = NSColor.white
        saveButton.attributedTitle = NSAttributedString(
            string: "Save Workspace", attributes: [.foregroundColor: buttonTextColor, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        if let saveImg = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save") {
            let imgConfig = NSImage.SymbolConfiguration(paletteColors: [buttonTextColor])
            saveButton.image = saveImg.withSymbolConfiguration(imgConfig)
        }

        // --- Port definitions card ---
        let wsPortCard = formSectionCard(
            icon: "network", title: "Port definitions",
            subtitle: "Named ports for this workspace. Override project defaults.",
            contentViews: [portEditor.container])
        contentStack.addArrangedSubview(wsPortCard)
        constrainFormFieldToFillWidth(wsPortCard, in: contentStack)

        // --- Processes card ---
        let processCard = formSectionCard(
            icon: "terminal.fill", title: "Processes", subtitle: "Commands that run inside this workspace.", contentViews: [processEditor.container])
        contentStack.addArrangedSubview(processCard)
        constrainFormFieldToFillWidth(processCard, in: contentStack)

        // --- Stop script card ---
        let stopCard = formSectionCard(
            icon: "stop.circle", title: "Stop script", subtitle: "Workspace override. Runs on stop/restart/archive after process termination.",
            contentViews: [stopScroll])
        contentStack.addArrangedSubview(stopCard)
        constrainFormFieldToFillWidth(stopCard, in: contentStack)

        // --- Browser sessions card ---
        let browserCard = formSectionCard(
            icon: "globe", title: "Browser sessions", subtitle: "URLs to open automatically, one per line.", contentViews: [browserScroll])
        contentStack.addArrangedSubview(browserCard)
        constrainFormFieldToFillWidth(browserCard, in: contentStack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        scroll.contentView.drawsBackground = false

        let scrollContent = NSView()
        scrollContent.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = scrollContent
        scrollContent.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollContent.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            scrollContent.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            scrollContent.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            scrollContent.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scrollContent.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollContent.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollContent.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollContent.topAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: scrollContent.bottomAnchor),
        ])

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(saveButton)
        container.addArrangedSubview(scroll)
        container.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(scroll, in: container)
        constrainFormFieldToFillWidth(buttonRow, in: container)

        saveButton.tag = storeWorkspaceFields(
            workspaceID: workspace.id, stopView: stopView, portEditor: portEditor, processEditor: processEditor, browserView: browserView)
        registerWorkspaceDirtyTracking(
            stopView: stopView, portEditor: portEditor, processEditor: processEditor, browserView: browserView)

        return insetContainerView(container)
    }

    private func label(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func helpTextLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func windowRow(icon: String, iconColor: NSColor, label: String, shortcut: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = iconColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12)
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let badge = NSTextField(labelWithString: shortcut)
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addArrangedSubview(badge)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(labelField)
        return row
    }

    private func processRow(icon: String, iconColor: NSColor, name: String, command: String, shortcut: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let badge = NSTextField(labelWithString: shortcut)
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = iconColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let nameField = NSTextField(labelWithString: name)
        nameField.font = .systemFont(ofSize: 12, weight: .semibold)
        nameField.textColor = .labelColor
        nameField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let commandField = NSTextField(labelWithString: command)
        commandField.font = .systemFont(ofSize: 11)
        commandField.textColor = .secondaryLabelColor
        commandField.lineBreakMode = .byTruncatingTail
        commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(badge)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(nameField)
        row.addArrangedSubview(commandField)
        return row
    }

    private func statusCheckSubRow(name: String, color: NSColor, status: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 2, left: 28, bottom: 2, right: 8)

        let arrow = NSTextField(labelWithString: "↳")
        arrow.font = .systemFont(ofSize: 10)
        arrow.textColor = .tertiaryLabelColor
        arrow.setContentHuggingPriority(.required, for: .horizontal)

        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: status)
        dot.contentTintColor = color
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])

        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(arrow)
        row.addArrangedSubview(dot)
        row.addArrangedSubview(label)
        return row
    }

    private func sectionHeader(icon: String, title: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let iconView = NSImageView()
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor])
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 16), iconView.heightAnchor.constraint(equalToConstant: 16)])

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor

        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        return row
    }

    private func labeledValue(title: String, value: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        let label = NSTextField(labelWithString: "\(title):")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let valueField = NSTextField(labelWithString: value)
        valueField.font = .systemFont(ofSize: 12)
        valueField.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(valueField)
        return stack
    }

    private func statusRow(isRunning: Bool) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        let label = NSTextField(labelWithString: "Status:")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: isRunning ? "circle.fill" : "circle", accessibilityDescription: "Status")
        icon.contentTintColor = isRunning ? .systemGreen : .tertiaryLabelColor
        icon.toolTip = isRunning ? "Running" : "Stopped"
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(icon)
        return stack
    }

    private struct EditorOption {
        let preference: EditorPreference
        let displayName: String
        let bundleName: String
    }

    private func installedEditorOptions() -> [EditorOption] {
        let candidates = [
            EditorOption(preference: .vscode, displayName: "VS Code", bundleName: "Visual Studio Code.app"),
            EditorOption(preference: .cursor, displayName: "Cursor", bundleName: "Cursor.app"),
            EditorOption(preference: .windsurf, displayName: "Windsurf", bundleName: "Windsurf.app"),
        ]
        return candidates.filter { isEditorInstalled(bundleName: $0.bundleName) }
    }

    private func isEditorInstalled(bundleName: String) -> Bool {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let paths = [applications.appendingPathComponent(bundleName).path, userApplications.appendingPathComponent(bundleName).path]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private func editorDisplayName(_ editor: EditorPreference) -> String {
        switch editor {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .vim: return "Vim"
        case .none: return "None"
        }
    }

    private func shortcutSettingsRow(setting: ShortcutSetting) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let title = NSTextField(labelWithString: setting.label)
        title.font = .systemFont(ofSize: 12)
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.widthAnchor.constraint(equalToConstant: shortcutLabelColumnWidth).isActive = true

        let captureButton = actionButton(
            title: shortcutCaptureButtonTitle(setting: setting), symbol: nil, tooltip: "Click to capture shortcut",
            action: #selector(beginShortcutCapture(_:)), primary: false)
        captureButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
        captureButton.alignment = .center
        captureButton.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        captureButton.isBordered = false
        captureButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        captureButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captureButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        captureButton.widthAnchor.constraint(equalToConstant: 170).isActive = true
        updateShortcutCaptureButtonText(captureButton, text: shortcutCaptureButtonTitle(setting: setting), active: false)
        styleShortcutCaptureButton(captureButton, active: false)
        shortcutButtonsBySetting[setting.settingKey] = captureButton

        let resetButton = actionButton(
            title: "Reset", symbol: nil, tooltip: "Reset to default shortcut", action: #selector(resetShortcutSetting(_:)), primary: false)
        resetButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
        resetButton.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(title)
        row.addArrangedSubview(captureButton)
        row.addArrangedSubview(resetButton)
        return row
    }

    private func shortcutCaptureButtonTitle(setting: ShortcutSetting) -> String {
        if activeShortcutCaptureSetting == setting { return "Press shortcut" }
        return shortcutDisplayText(for: setting)
    }

    private func shortcutDisplayText(for setting: ShortcutSetting) -> String { shortcutSpec(for: setting)?.normalized ?? setting.defaultSpec }

    private func actionTitle(base: String, setting: ShortcutSetting) -> String { "\(base) (\(shortcutHint(for: setting)))" }

    private func actionTooltip(base: String, setting: ShortcutSetting) -> String { "\(base) (\(shortcutHint(for: setting)))" }

    private func shortcutHint(for setting: ShortcutSetting) -> String {
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        return displayShortcut(spec)
    }

    private func displayShortcut(_ spec: HotkeySpec) -> String {
        var parts: [String] = []
        if spec.modifiers.contains(.cmd) { parts.append("⌘") }
        if spec.modifiers.contains(.shift) { parts.append("⇧") }
        if spec.modifiers.contains(.alt) { parts.append("⌥") }
        if spec.modifiers.contains(.ctrl) { parts.append("⌃") }
        parts.append(displayShortcutKey(spec.key))
        return parts.joined()
    }

    private func displayShortcutKey(_ key: String) -> String {
        switch key {
        case "return", "enter": return "↩"
        case "space": return "Space"
        case "tab": return "⇥"
        case "escape": return "⎋"
        case "delete", "backspace": return "⌫"
        case "forwarddelete": return "⌦"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return key.uppercased()
        }
    }

    @objc private func beginShortcutCapture(_ sender: NSButton) {
        guard let settingKey = sender.identifier?.rawValue, let setting = ShortcutSetting(settingKey: settingKey) else { return }

        if activeShortcutCaptureSetting == setting { activeShortcutCaptureSetting = nil } else { activeShortcutCaptureSetting = setting }
        refreshShortcutCaptureButtons()
    }

    @objc private func resetShortcutSetting(_ sender: NSButton) {
        guard let settingKey = sender.identifier?.rawValue, let setting = ShortcutSetting(settingKey: settingKey) else { return }

        if activeShortcutCaptureSetting == setting {
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
        }

        do {
            try setShortcutSetting(setting: setting, value: nil)
            loadShortcutSpecs()
            setupGlobalHotkey()
            refreshSelection()
        } catch { showError(error) }
    }

    private func refreshShortcutCaptureButtons() {
        for (settingKey, button) in shortcutButtonsBySetting {
            guard let setting = ShortcutSetting(settingKey: settingKey) else { continue }
            let isActive = activeShortcutCaptureSetting == setting
            updateShortcutCaptureButtonText(button, text: shortcutCaptureButtonTitle(setting: setting), active: isActive)
            styleShortcutCaptureButton(button, active: isActive)
            if activeShortcutCaptureSetting == setting {
                button.toolTip = "Press a key combination (Esc to cancel)"
            } else {
                button.toolTip = "Click to capture shortcut"
            }
        }
    }

    private func styleShortcutCaptureButton(_ button: NSButton, active: Bool) {
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = 1
        button.layer?.backgroundColor = shortcutKeycapBackgroundColor(active: active).cgColor
        button.layer?.borderColor = shortcutKeycapBorderColor(active: active).cgColor
    }

    private func updateShortcutCaptureButtonText(_ button: NSButton, text: String, active: Bool) {
        let color: NSColor = active ? .white : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .paragraphStyle: paragraph,
        ]
        button.attributedTitle = NSAttributedString(string: "  \(text)  ", attributes: attrs)
    }

    private func shortcutKeycapBackgroundColor(active: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if active {
                return isDark
                    ? NSColor(calibratedRed: 0.13, green: 0.28, blue: 0.42, alpha: 1.0)
                    : NSColor(calibratedRed: 0.80, green: 0.89, blue: 0.97, alpha: 1.0)
            }
            return isDark ? NSColor(calibratedWhite: 0.16, alpha: 1.0) : NSColor(calibratedWhite: 0.82, alpha: 1.0)
        }
    }

    private func shortcutKeycapBorderColor(active: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            if active { return .systemBlue }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(calibratedWhite: 0.28, alpha: 1.0) : NSColor(calibratedWhite: 0.65, alpha: 1.0)
        }
    }

    private func sidebarSectionHeader(title: String, actions: [(symbol: String, tooltip: String, action: Selector)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(NSView())
        for action in actions {
            stack.addArrangedSubview(sidebarRowIconButton(symbol: action.symbol, tooltip: action.tooltip, action: action.action))
        }

        return stack
    }

    private func sidebarRowIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(
            .init(pointSize: 12, weight: .semibold))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        return button
    }

    private func iconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        return button
    }

    private func actionButton(title: String, symbol: String?, tooltip: String, action: Selector, primary: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = primary ? .rounded : .texturedRounded
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.imagePosition = .imageLeading
        }
        button.toolTip = tooltip
        if primary {
            button.controlSize = .large
            button.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        return button
    }

    private func constrainFormFieldToFillWidth(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func showScrollableDetailStack(_ stack: NSStackView) {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = contentView
        contentView.addSubview(stack)

        detailContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: detailContainer.topAnchor), scroll.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            contentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func scrollableTextView(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let inputBg = sidebarThemeColor(light: (235, 233, 225), dark: (10, 15, 17))
        scroll.drawsBackground = true
        scroll.backgroundColor = inputBg
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = inputBg
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = sidebarCardBorderColor(isSelected: false).cgColor
        textView.drawsBackground = true
        textView.backgroundColor = inputBg
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func insetContainerView(_ content: NSView, inset: CGFloat = 8) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -inset),
        ])
        return container
    }

    private func makeEditableTextView() -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }

    private func storeProjectFields(
        projectID: String, setupView: NSTextView, stopView: NSTextView, portEditor: PortEditor, processEditor: ProcessEditor,
        browserView: NSTextView
    ) -> Int {
        let id = projectID.hashValue
        ProjectFieldCache.shared.cache[id] = ProjectFieldRefs(
            projectID: projectID, setupView: setupView, stopView: stopView, portEditor: portEditor, processEditor: processEditor,
            browserView: browserView)
        return id
    }

    private func storeWorkspaceFields(
        workspaceID: String, stopView: NSTextView, portEditor: PortEditor, processEditor: ProcessEditor, browserView: NSTextView
    ) -> Int {
        let id = workspaceID.hashValue
        WorkspaceFieldCache.shared.cache[id] = WorkspaceFieldRefs(
            workspaceID: workspaceID, stopView: stopView, portEditor: portEditor, processEditor: processEditor, browserView: browserView)
        return id
    }

    private func storeAddProjectFields(
        sourcePopup: NSPopUpButton, localSourceSection: NSStackView, cloneSourceSection: NSStackView, dirField: NSTextField,
        repoURLField: NSTextField, setupView: NSTextView, stopView: NSTextView, portEditor: PortEditor, processEditor: ProcessEditor,
        browserView: NSTextView, browseButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddProjectFieldCache.shared.cache[id] = AddProjectFieldRefs(
            sourcePopup: sourcePopup, localSourceSection: localSourceSection, cloneSourceSection: cloneSourceSection, dirField: dirField,
            repoURLField: repoURLField, browseButton: browseButton, setupView: setupView, stopView: stopView, portEditor: portEditor,
            processEditor: processEditor, browserView: browserView)
        sourcePopup.tag = id
        browseButton.tag = id
        return id
    }

    private func storeAddWorkspaceFields(
        projectID: String, isGitRepo: Bool, targetBranchField: NSComboBox?, nameField: NSTextField, directoryNameField: NSTextField?,
        branchField: NSTextField?, autoNameState: AddWorkspaceAutoNameState?
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddWorkspaceFieldCache.shared.cache[id] = AddWorkspaceFieldRefs(
            projectID: projectID, isGitRepo: isGitRepo, targetBranchField: targetBranchField, nameField: nameField,
            directoryNameField: directoryNameField, branchField: branchField, autoNameState: autoNameState)
        return id
    }

    @objc private func reloadTapped() { reloadData() }

    @objc private func showSettings() {
        if projectHasUnsavedChanges || workspaceHasUnsavedChanges {
            let response = unsavedChangesPrompt()
            if response == .alertFirstButtonReturn {
                if !saveCurrentDetail() { return }
            } else if response == .alertThirdButtonReturn {
                return
            } else {
                projectHasUnsavedChanges = false
                workspaceHasUnsavedChanges = false
            }
        }
        outlineView.deselectAll(nil)
        selectedProjectID = nil
        selectedWorkspaceID = nil
        lastSelectedRow = -1
        showSettingsDetail()
    }

    @objc private func openWorkspaceEditor(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        openWorkspaceEditor(workspaceID: workspaceID)
    }

    @objc private func openWorkspaceTerminal(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        openWorkspaceTerminal(workspaceID: workspaceID)
    }

    @objc private func openWorkspaceFinder(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        openWorkspaceFinder(workspaceID: workspaceID)
    }

    @objc private func editorPreferenceChanged(_ sender: NSPopUpButton) {
        guard let preference = sender.selectedItem?.representedObject as? EditorPreference else { return }
        if configCache?.editor == preference { return }
        do { configCache = try orchestrator.updateEditorPreference(preference) } catch { showError(error) }
    }

    @objc private func addProject() { showAddProjectForm() }

    @objc private func addWorkspace(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) else { return }
        showAddWorkspaceForm(project: project)
    }

    @objc private func addWorkspaceFromToolbar(_ sender: NSButton) {
        if let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) {
            showAddWorkspaceForm(project: project)
            return
        }
        guard let project = currentProjectForNewWorkspace() else { return }
        showAddWorkspaceForm(project: project)
    }

    private func addWorkspaceFromShortcut() {
        guard let project = currentProjectForNewWorkspace() else { return }
        showAddWorkspaceForm(project: project)
    }

    private func currentProjectForNewWorkspace() -> ProjectSummary? {
        if let selectedProjectID, let project = projects.first(where: { $0.id == selectedProjectID }) { return project }
        if let selectedWorkspaceID, let (project, _) = findWorkspace(id: selectedWorkspaceID) { return project }
        return nil
    }

    @objc private func saveProject(_ sender: NSButton) {
        commitEditing()
        guard let refs = ProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            try orchestrator.updateProjectConfig(projectID: refs.projectID) { config in
                config.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
                config.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
                config.ports = refs.portEditor.currentDefinitions()
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = parseBrowserSessions(refs.browserView.string)
                config.statusChecks = refs.processEditor.currentStatusChecks()
            }
            projectHasUnsavedChanges = false
            reloadData()
        } catch { showError(error) }
    }

    @objc private func deleteProject(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete project?"
        alert.informativeText = """
            This removes the project and its workspaces from muxy.
            If this project was cloned into ~/muxy/projects by muxy, that project directory is deleted.
            For git projects, related workspace directories under ~/muxy/workspaces are also deleted.
            """
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        do {
            try orchestrator.removeProject(dir: project.dir)
            projectHasUnsavedChanges = false
            workspaceHasUnsavedChanges = false
            reloadData()
        } catch { showError(error) }
    }

    @objc private func saveWorkspace(_ sender: NSButton) {
        commitEditing()
        guard let refs = WorkspaceFieldCache.shared.cache[sender.tag] else { return }
        do {
            try orchestrator.updateWorkspaceSettings(workspaceID: refs.workspaceID) { config in
                config.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
                config.ports = refs.portEditor.currentDefinitions()
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = parseBrowserSessions(refs.browserView.string)
                config.statusChecks = refs.processEditor.currentStatusChecks()
            }
            workspaceHasUnsavedChanges = false
            reloadData()
        } catch { showError(error) }
    }

    @objc private func createProject(_ sender: NSButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            let record: ProjectRecord
            if refs.sourcePopup.indexOfSelectedItem == 1 {
                let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !repoURL.isEmpty else { throw MuxyError.invalidArgument(message: "Git repository URL is required.") }
                record = try orchestrator.addProject(gitURL: repoURL)
            } else {
                let dir = refs.dirField.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !dir.isEmpty else { return }
                record = try orchestrator.addProject(dir: dir)
            }
            try orchestrator.updateProjectConfig(projectID: record.id) { project in
                project.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
                project.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
                project.ports = refs.portEditor.currentDefinitions()
                project.processes = refs.processEditor.currentProcesses()
                project.browserSessions = parseBrowserSessions(refs.browserView.string)
                project.statusChecks = refs.processEditor.currentStatusChecks()
            }
            reloadData()
        } catch { showError(error) }
    }

    @objc private func projectSourceChanged(_ sender: NSPopUpButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        updateAddProjectSourceUI(refs)
    }

    @objc private func browseProjectDir(_ sender: NSButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url {
                refs.dirField.stringValue = url.path
                refs.dirField.toolTip = url.path
                refs.dirField.textColor = .labelColor
                refs.dirField.isHidden = false
                refs.browseButton.title = url.lastPathComponent
            }
        }
    }

    private func updateAddProjectSourceUI(_ refs: AddProjectFieldRefs) {
        let cloneSelected = refs.sourcePopup.indexOfSelectedItem == 1
        refs.localSourceSection.isHidden = cloneSelected
        refs.cloneSourceSection.isHidden = !cloneSelected
    }

    private func defaultWorkspaceTargetBranch(project: ProjectSummary, branches: [String]) -> String? {
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        if branches.contains("main") { return "main" }
        if branches.contains("master") { return "master" }
        return branches.first
    }

    @objc private func createWorkspace(_ sender: NSButton) {
        guard let refs = AddWorkspaceFieldCache.shared.cache[sender.tag] else { return }
        do {
            let name = refs.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace name is required.") }
            let targetBranch = refs.targetBranchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = refs.branchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let directoryName = refs.directoryNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDirectoryName: String?
            if let directoryName, directoryName.isEmpty { resolvedDirectoryName = nil } else { resolvedDirectoryName = directoryName }
            if refs.isGitRepo, branch == nil || branch?.isEmpty == true {
                throw MuxyError.invalidArgument(message: "Branch name is required for git projects.")
            }
            if refs.isGitRepo, targetBranch == nil || targetBranch?.isEmpty == true {
                throw MuxyError.invalidArgument(message: "Target branch is required for git projects.")
            }
            _ = try orchestrator.createWorkspace(
                projectID: refs.projectID, name: name, branch: branch, targetBranch: targetBranch, directoryName: resolvedDirectoryName)
            reloadData()
        } catch { showError(error) }
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let changedField = obj.object as? NSTextField else { return }
        for refs in AddWorkspaceFieldCache.shared.cache.values {
            guard refs.branchField === changedField, let autoNameState = refs.autoNameState else { continue }
            let branchValue = changedField.stringValue
            let currentName = refs.nameField.stringValue
            if currentName.isEmpty || currentName == autoNameState.lastAutoWorkspaceName {
                refs.nameField.stringValue = branchValue
                autoNameState.lastAutoWorkspaceName = branchValue
            }
            if let dirField = refs.directoryNameField {
                let currentDir = dirField.stringValue
                let sanitized = branchValue.replacing(/[^A-Za-z0-9\-_]/, with: "-").replacing(/\-{2,}/, with: "-").trimmingCharacters(
                    in: CharacterSet(charactersIn: "-"))
                if currentDir.isEmpty || currentDir == autoNameState.lastAutoDirName {
                    dirField.stringValue = sanitized
                    autoNameState.lastAutoDirName = sanitized
                }
            }
            return
        }
    }

    @objc private func cancelProjectForm() { refreshSelection() }

    @objc private func launchWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result = await Self.runWorkspaceLifecycleAction(.launch, workspaceID: id)
            sender?.isEnabled = true
            switch result {
            case .success:
                reloadData()
            case .failure(let error):
                showError(error)
            }
        }
    }

    @objc private func restartWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result = await Self.runWorkspaceLifecycleAction(.restart, workspaceID: id)
            sender?.isEnabled = true
            switch result {
            case .success:
                reloadData()
            case .failure(let error):
                showError(error)
            }
        }
    }

    @objc private func stopWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result = await Self.runWorkspaceLifecycleAction(.stop, workspaceID: id)
            sender?.isEnabled = true
            switch result {
            case .success:
                reloadData()
            case .failure(let error):
                showError(error)
            }
        }
    }

    @objc private func archiveWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let workspace = workspacesByProject.values.flatMap({ $0 }).first(where: { $0.id == id })
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive workspace?"
        alert.informativeText =
            "Are you sure you want to archive \"\(workspace?.name ?? id)\"? This will remove its git worktree and stop all running processes."
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result = await Self.runWorkspaceLifecycleAction(.archive, workspaceID: id)
            sender?.isEnabled = true
            switch result {
            case .success:
                reloadData()
            case .failure(let error):
                showError(error)
            }
        }
    }

    @objc private func copyDirectoryPath(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func parseProcesses(_ raw: String) -> [ProcessTemplate] {
        _ = raw
        return []
    }

    private func parseBrowserSessions(_ raw: String) -> [BrowserSession] {
        raw.split(separator: "\n").compactMap { line in
            let url = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : BrowserSession(url: url)
        }
    }

    private func parseStatusChecks(_ raw: String) -> [StatusCheckDefinition] {
        _ = raw
        return []
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func openWorkspaceEditor(workspaceID: String) {
        do {
            try orchestrator.openWorkspaceEditor(workspaceID: workspaceID)
            reloadData()
        } catch { showError(error) }
    }

    private func openWorkspaceTerminal(workspaceID: String) {
        do {
            try orchestrator.openWorkspaceTerminal(workspaceID: workspaceID)
            reloadData()
        } catch { showError(error) }
    }

    private func openWorkspaceFinder(workspaceID: String) {
        guard let (_, workspace) = findWorkspace(id: workspaceID) else { return }
        let url = URL(fileURLWithPath: workspace.dir, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    private func findWorkspace(id: String) -> (ProjectSummary, WorkspaceSummary)? {
        for project in projects {
            if let workspaces = workspacesByProject[project.id], let workspace = workspaces.first(where: { $0.id == id }) {
                return (project, workspace)
            }
        }
        return nil
    }

    private func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    private func setupGlobalHotkey() {
        guard let toggleShortcutSpec else {
            teardownGlobalHotkey()
            return
        }
        registerHotkeys(toggle: toggleShortcutSpec, next: nextShortcutSpec, previous: previousShortcutSpec)
    }

    private func teardownGlobalHotkey() {
        for ref in hotkeyRefs.values { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
        hotkeyHandler = nil
    }

    private func registerHotkeys(toggle: HotkeySpec, next: HotkeySpec?, previous: HotkeySpec?) {
        teardownGlobalHotkey()
        let signature = OSType(UInt32(truncatingIfNeeded: "AMUX".utf8.reduce(0) { ($0 << 8) + UInt32($1) }))
        let target = GetEventDispatcherTarget()
        registerHotkey(spec: toggle, id: GlobalHotkey.toggle.rawValue, signature: signature, target: target)
        if let next { registerHotkey(spec: next, id: GlobalHotkey.next.rawValue, signature: signature, target: target) }
        if let previous { registerHotkey(spec: previous, id: GlobalHotkey.previous.rawValue, signature: signature, target: target) }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(
            target, hotkeyHandlerProc, 1, &eventSpec, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &hotkeyHandler)
    }

    private func registerHotkey(spec: HotkeySpec, id: UInt32, signature: OSType, target: EventTargetRef?) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(UInt32(spec.keyCode), spec.modifiersCarbon, hotKeyID, target, 0, &ref)
        if status == noErr, let ref { hotkeyRefs[id] = ref }
    }

    private func setupShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleShortcutCaptureEvent(event: event) { return nil }
            if self.handleFocusedTextInputShortcut(event: event) { return nil }
            if self.isTextInputFocused() { return event }
            if let openEditorShortcutSpec, matches(event: event, spec: openEditorShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID { self.openWorkspaceEditor(workspaceID: workspaceID) }
                return nil
            }
            if let openTerminalShortcutSpec, matches(event: event, spec: openTerminalShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID { self.openWorkspaceTerminal(workspaceID: workspaceID) }
                return nil
            }
            if let openFinderShortcutSpec, matches(event: event, spec: openFinderShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID { self.openWorkspaceFinder(workspaceID: workspaceID) }
                return nil
            }
            if let windowIndex = windowShortcutIndex(for: event) {
                self.focusWindowShortcut(index: windowIndex)
                return nil
            }
            if let nextShortcutSpec, matches(event: event, spec: nextShortcutSpec) {
                self.selectNextRunningWorkspace()
                return nil
            }
            if let previousShortcutSpec, matches(event: event, spec: previousShortcutSpec) {
                self.selectPreviousRunningWorkspace()
                return nil
            }
            if let activateShortcutSpec, matches(event: event, spec: activateShortcutSpec) {
                self.activateSelectedWorkspace()
                return nil
            }
            return event
        }
    }

    private func handleShortcutCaptureEvent(event: NSEvent) -> Bool {
        guard let setting = activeShortcutCaptureSetting else { return false }
        if event.keyCode == UInt16(kVK_Escape) {
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
            return true
        }
        guard let spec = shortcutCaptureSpec(from: event) else {
            NSSound.beep()
            return true
        }
        guard !spec.modifiers.isEmpty else {
            NSSound.beep()
            return true
        }

        do {
            try setShortcutSetting(setting: setting, value: spec.normalized)
            activeShortcutCaptureSetting = nil
            loadShortcutSpecs()
            setupGlobalHotkey()
            refreshSelection()
        } catch {
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
            showError(error)
        }
        return true
    }

    private func shortcutCaptureSpec(from event: NSEvent) -> HotkeySpec? {
        guard let key = shortcutCaptureKey(for: event.keyCode) else { return nil }
        return HotkeySpec(key: key, modifiers: shortcutModifiers(from: event.modifierFlags))
    }

    private func shortcutCaptureKey(for keyCode: UInt16) -> String? { AppKitController.shortcutCaptureKeyMap[keyCode] }

    private func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        let filtered = flags.intersection([.command, .shift, .option, .control])
        var modifiers = Set<HotkeyModifier>()
        if filtered.contains(.command) { modifiers.insert(.cmd) }
        if filtered.contains(.shift) { modifiers.insert(.shift) }
        if filtered.contains(.option) { modifiers.insert(.alt) }
        if filtered.contains(.control) { modifiers.insert(.ctrl) }
        return modifiers
    }

    private static let shortcutCaptureKeyMap: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_C): "c", UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_E): "e",
        UInt16(kVK_ANSI_F): "f", UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_I): "i", UInt16(kVK_ANSI_J): "j",
        UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l", UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_O): "o",
        UInt16(kVK_ANSI_P): "p", UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r", UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t",
        UInt16(kVK_ANSI_U): "u", UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x", UInt16(kVK_ANSI_Y): "y",
        UInt16(kVK_ANSI_Z): "z", UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9", UInt16(kVK_ANSI_Equal): "=", UInt16(kVK_ANSI_Minus): "minus", UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_RightBracket): "]", UInt16(kVK_ANSI_Semicolon): ";", UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/", UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Grave): "`",
        UInt16(kVK_Space): "space", UInt16(kVK_Tab): "tab", UInt16(kVK_Return): "return", UInt16(kVK_Escape): "escape", UInt16(kVK_Delete): "delete",
        UInt16(kVK_ForwardDelete): "forwarddelete", UInt16(kVK_LeftArrow): "left", UInt16(kVK_RightArrow): "right", UInt16(kVK_UpArrow): "up",
        UInt16(kVK_DownArrow): "down", UInt16(kVK_F1): "f1", UInt16(kVK_F2): "f2", UInt16(kVK_F3): "f3", UInt16(kVK_F4): "f4", UInt16(kVK_F5): "f5",
        UInt16(kVK_F6): "f6", UInt16(kVK_F7): "f7", UInt16(kVK_F8): "f8", UInt16(kVK_F9): "f9", UInt16(kVK_F10): "f10", UInt16(kVK_F11): "f11",
        UInt16(kVK_F12): "f12", UInt16(kVK_F13): "f13", UInt16(kVK_F14): "f14", UInt16(kVK_F15): "f15", UInt16(kVK_F16): "f16",
        UInt16(kVK_F17): "f17", UInt16(kVK_F18): "f18", UInt16(kVK_F19): "f19", UInt16(kVK_F20): "f20",
    ]

    private func isTextInputFocused() -> Bool {
        guard let window else { return false }
        if let textView = window.firstResponder as? NSTextView { return textView.isEditable || textView.isFieldEditor }
        return false
    }

    private func handleFocusedTextInputShortcut(event: NSEvent) -> Bool {
        guard isTextInputFocused() else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            default: return false
            }
        }
        if flags == [.command, .shift], key == "z" { return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
        return false
    }

    private func handleGlobalHotkey(id: UInt32) {
        guard let hotkey = GlobalHotkey(rawValue: id) else { return }
        switch hotkey {
        case .toggle: toggleWindowFromHotkey()
        case .next: if NSApp.isActive { selectNextRunningWorkspace() } else { focusGlobalWindowNavigation(direction: 1) }
        case .previous: if NSApp.isActive { selectPreviousRunningWorkspace() } else { focusGlobalWindowNavigation(direction: -1) }
        }
    }

    private func loadShortcutSpecs() {
        toggleShortcutSpec = loadShortcutSpec(setting: .guiHotkey)
        nextShortcutSpec = loadShortcutSpec(setting: .guiNextShortcut)
        previousShortcutSpec = loadShortcutSpec(setting: .guiPreviousShortcut)
        activateShortcutSpec = loadShortcutSpec(setting: .guiShowShortcut)
        openEditorShortcutSpec = loadShortcutSpec(setting: .guiOpenEditorShortcut)
        openTerminalShortcutSpec = loadShortcutSpec(setting: .guiOpenTerminalShortcut)
        openFinderShortcutSpec = loadShortcutSpec(setting: .guiOpenFinderShortcut)
    }

    private func loadShortcutSpec(setting: ShortcutSetting) -> HotkeySpec? {
        if let stored = try? HotkeySpec.parse(shortcutRawValue(for: setting)) { return stored }
        return try? HotkeySpec.parse(setting.defaultSpec)
    }

    private func shortcutRawValue(for setting: ShortcutSetting) throws -> String {
        switch setting {
        case .guiHotkey: return try orchestrator.guiHotkey()
        case .guiNextShortcut: return try orchestrator.guiNextShortcut()
        case .guiPreviousShortcut: return try orchestrator.guiPreviousShortcut()
        case .guiShowShortcut: return try orchestrator.guiShowShortcut()
        case .guiAddProjectShortcut: return try orchestrator.guiAddProjectShortcut()
        case .guiAddWorkspaceShortcut: return try orchestrator.guiAddWorkspaceShortcut()
        case .guiReloadShortcut: return try orchestrator.guiReloadShortcut()
        case .guiOpenEditorShortcut: return try orchestrator.guiOpenEditorShortcut()
        case .guiOpenTerminalShortcut: return try orchestrator.guiOpenTerminalShortcut()
        case .guiOpenFinderShortcut: return try orchestrator.guiOpenFinderShortcut()
        case .guiOpenSettingsShortcut: return try orchestrator.guiOpenSettingsShortcut()
        }
    }

    private func setShortcutSetting(setting: ShortcutSetting, value: String?) throws {
        switch setting {
        case .guiHotkey: try orchestrator.setGUIHotkey(value)
        case .guiNextShortcut: try orchestrator.setGUINextShortcut(value)
        case .guiPreviousShortcut: try orchestrator.setGUIPreviousShortcut(value)
        case .guiShowShortcut: try orchestrator.setGUIShowShortcut(value)
        case .guiAddProjectShortcut: try orchestrator.setGUIAddProjectShortcut(value)
        case .guiAddWorkspaceShortcut: try orchestrator.setGUIAddWorkspaceShortcut(value)
        case .guiReloadShortcut: try orchestrator.setGUIReloadShortcut(value)
        case .guiOpenEditorShortcut: try orchestrator.setGUIOpenEditorShortcut(value)
        case .guiOpenTerminalShortcut: try orchestrator.setGUIOpenTerminalShortcut(value)
        case .guiOpenFinderShortcut: try orchestrator.setGUIOpenFinderShortcut(value)
        case .guiOpenSettingsShortcut: try orchestrator.setGUIOpenSettingsShortcut(value)
        }
    }

    private func shortcutSpec(for setting: ShortcutSetting) -> HotkeySpec? {
        switch setting {
        case .guiHotkey: return toggleShortcutSpec
        case .guiNextShortcut: return nextShortcutSpec
        case .guiPreviousShortcut: return previousShortcutSpec
        case .guiShowShortcut: return activateShortcutSpec
        case .guiAddProjectShortcut: return nil
        case .guiAddWorkspaceShortcut: return nil
        case .guiReloadShortcut: return nil
        case .guiOpenEditorShortcut: return openEditorShortcutSpec
        case .guiOpenTerminalShortcut: return openTerminalShortcutSpec
        case .guiOpenFinderShortcut: return openFinderShortcutSpec
        case .guiOpenSettingsShortcut: return nil
        }
    }

    private func matches(event: NSEvent, spec: HotkeySpec) -> Bool {
        guard UInt32(event.keyCode) == spec.keyCode else { return false }
        let flags = eventModifierCarbonFlags(event)
        return flags == spec.modifiersCarbon
    }

    private func eventModifierCarbonFlags(_ event: NSEvent) -> UInt32 {
        var result: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private func selectNextRunningWorkspace() {
        let running = allRunningWorkspaces()
        guard !running.isEmpty else { return }
        if let selectedWorkspaceID, let idx = running.firstIndex(where: { $0.id == selectedWorkspaceID }) {
            let next = running[(idx + 1) % running.count]
            selectWorkspace(next)
        } else {
            selectWorkspace(running[0])
        }
    }

    private func selectPreviousRunningWorkspace() {
        let running = allRunningWorkspaces()
        guard !running.isEmpty else { return }
        if let selectedWorkspaceID, let idx = running.firstIndex(where: { $0.id == selectedWorkspaceID }) {
            let prev = running[(idx - 1 + running.count) % running.count]
            selectWorkspace(prev)
        } else {
            selectWorkspace(running[0])
        }
    }

    private func activateSelectedWorkspace() {
        guard let selectedWorkspaceID else { return }
        do { try orchestrator.focusWorkspace(workspaceID: selectedWorkspaceID) } catch { showError(error) }
    }

    private func focusWindowShortcut(index: Int) {
        guard let selectedWorkspaceID else { return }
        do { try orchestrator.focusWorkspaceWindow(workspaceID: selectedWorkspaceID, index: index) } catch { showError(error) }
    }

    private func windowShortcutIndex(for event: NSEvent) -> Int? {
        guard event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.control)
        else { return nil }
        let keyMap: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3, UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
            UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9,
        ]
        return keyMap[event.keyCode]
    }

    private func selectWorkspace(_ workspace: WorkspaceSummary) {
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? OutlineItem {
                if case .workspace(_, let ws) = item, ws.id == workspace.id {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    break
                }
            }
        }
    }

    private func focusGlobalWindowNavigation(direction: Int) {
        guard !NSApp.isActive else { return }
        guard let workspaceID = globalWindowNavigationWorkspaceID() else { return }
        do {
            if direction > 0 {
                try orchestrator.focusNextWindow(workspaceID: workspaceID)
            } else {
                try orchestrator.focusPreviousWindow(workspaceID: workspaceID)
            }
        } catch { showError(error) }
    }

    private func globalWindowNavigationWorkspaceID() -> String? {
        if let workspaceID = try? orchestrator.workspaceIDForFocusedWindow() { return workspaceID }
        if let workspaceID = try? orchestrator.activeWorkspaceID() { return workspaceID }
        return nil
    }

    private func allRunningWorkspaces() -> [WorkspaceSummary] {
        var list: [WorkspaceSummary] = []
        for project in projects {
            let workspaces = workspacesByProject[project.id] ?? []
            list.append(contentsOf: workspaces.filter { $0.isRunning && !$0.isArchived })
        }
        return list
    }

    private func toggleWindowFromHotkey() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if selectedWorkspaceID != nil { refreshSelection() }
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return projects.count }
        if case .project(let project) = item as? OutlineItem { return workspacesByProject[project.id]?.count ?? 0 }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .project = item as? OutlineItem { return true }
        return false
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return OutlineItem.project(projects[index]) }
        if case .project(let project) = item as? OutlineItem {
            let workspace =
                workspacesByProject[project.id]?[index]
                ?? WorkspaceSummary(id: "", name: "", branch: nil, dir: "", isRunning: false, isArchived: false, isDefault: false)
            return OutlineItem.workspace(project, workspace)
        }
        return OutlineItem.project(projects[0])
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if case .project(let project) = item as? OutlineItem { return projectRowCell(project: project) }
        if case .workspace(let project, let workspace) = item as? OutlineItem {
            return workspaceRowCell(project: project, workspace: workspace, isSelected: selectedWorkspaceID == workspace.id)
        }
        return nil
    }

    private func projectRowCell(project: ProjectSummary) -> NSTableCellView {
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: project.name)
        text.font = .systemFont(ofSize: 13, weight: .semibold)
        text.translatesAutoresizingMaskIntoConstraints = false
        let accessoryStack = NSStackView()
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .centerY
        accessoryStack.spacing = 4
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        cell.addSubview(text)
        cell.addSubview(icon)
        cell.addSubview(accessoryStack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 10), icon.heightAnchor.constraint(equalToConstant: 10),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            accessoryStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            accessoryStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if project.isGitRepo {
            let addButton = sidebarRowIconButton(symbol: "plus", tooltip: "New workspace in \(project.name)", action: #selector(addWorkspace(_:)))
            addButton.identifier = NSUserInterfaceItemIdentifier(project.id)
            accessoryStack.addArrangedSubview(addButton)
        }
        return cell
    }

    private func workspaceRowCell(project: ProjectSummary, workspace: WorkspaceSummary, isSelected: Bool) -> NSTableCellView {
        let cell = NSTableCellView()

        let cardView = NSView()
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        if isSelected {
            cardView.layer?.cornerRadius = 10
            cardView.layer?.borderWidth = 1
            cardView.layer?.borderColor = sidebarCardBorderColor(isSelected: true).cgColor
            cardView.layer?.backgroundColor = sidebarSelectedCardBackgroundColor().cgColor
        }

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let statusIcon = NSImageView()
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.image = NSImage(systemSymbolName: workspace.isRunning ? "circle.fill" : "circle", accessibilityDescription: "Status")
        statusIcon.contentTintColor = workspace.isRunning ? sidebarRunningIndicatorColor() : sidebarIdleIndicatorColor()
        statusIcon.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let nameLabel = NSTextField(labelWithString: workspace.name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textColor = sidebarPrimaryTextColor(isSelected: isSelected, isArchived: workspace.isArchived)

        titleRow.addArrangedSubview(statusIcon)
        titleRow.addArrangedSubview(nameLabel)
        contentStack.addArrangedSubview(titleRow)

        if let folderName = workspaceFolderName(for: workspace), shouldShowSidebarMetadata(value: folderName, workspaceName: workspace.name) {
            contentStack.addArrangedSubview(sidebarMetadataRow(symbol: "folder", text: folderName, isSelected: isSelected))
        }

        if let branch = workspace.branch, shouldShowSidebarMetadata(value: branch, workspaceName: workspace.name) {
            contentStack.addArrangedSubview(sidebarMetadataRow(symbol: "arrow.triangle.branch", text: branch, isSelected: isSelected))
        }

        if project.isGitRepo {
            let activity =
                gitActivityByWorkspaceID[workspace.id] ?? GitTrackedFileActivity(latestTrackedFileModificationDate: nil, modifiedTrackedFileCount: 0)
            contentStack.addArrangedSubview(sidebarMetadataRow(symbol: "clock", text: gitActivitySummaryLabel(activity), isSelected: isSelected))
        }

        cardView.addSubview(contentStack)
        cell.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            cardView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            cardView.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),

            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -10),
            contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -8),
        ])

        return cell
    }

    private func workspaceFolderName(for workspace: WorkspaceSummary) -> String? {
        let folderName = URL(fileURLWithPath: workspace.dir, isDirectory: true).lastPathComponent
        guard !folderName.isEmpty else { return nil }
        return folderName
    }

    private func shouldShowSidebarMetadata(value: String, workspaceName: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkspaceName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return false }
        return trimmedValue.localizedStandardCompare(trimmedWorkspaceName) != .orderedSame
    }

    private func sidebarMetadataRow(symbol: String, text: String, isSelected: Bool) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = sidebarMetadataTextColor(isSelected: isSelected)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 10).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = sidebarMetadataTextColor(isSelected: isSelected)
        label.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        return row
    }

    private func gitActivitySummaryLabel(_ activity: GitTrackedFileActivity) -> String {
        let modifiedLabel =
            if activity.modifiedTrackedFileCount == 1 { "1 file modified" } else { "\(activity.modifiedTrackedFileCount) files modified" }

        guard let latestModificationDate = activity.latestTrackedFileModificationDate else { return "No tracked files • \(modifiedLabel)" }

        let relativeDate = relativeDateFormatter.localizedString(for: latestModificationDate, relativeTo: Date())
        return "\(relativeDate) • \(modifiedLabel)"
    }

    private func workspaceSidebarLineCount(project: ProjectSummary, workspace: WorkspaceSummary) -> Int {
        var count = 1  // workspace name + status

        if let folderName = workspaceFolderName(for: workspace), shouldShowSidebarMetadata(value: folderName, workspaceName: workspace.name) {
            count += 1
        }

        if let branch = workspace.branch, shouldShowSidebarMetadata(value: branch, workspaceName: workspace.name) { count += 1 }

        if project.isGitRepo { count += 1 }

        return count
    }

    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .workspace(let project, let workspace) = item as? OutlineItem {
            let lineCount = workspaceSidebarLineCount(project: project, workspace: workspace)
            return max(52, CGFloat(22 + (lineCount * 16)))
        }
        return 24
    }

    private func sidebarPanelBackgroundColor() -> NSColor { sidebarThemeColor(light: (248, 247, 241), dark: (15, 21, 23)) }

    private func sidebarCardBackgroundColor(isArchived: Bool) -> NSColor {
        let alpha: CGFloat = isArchived ? 0.42 : 0.55
        return sidebarThemeColor(light: (240, 238, 230), dark: (24, 36, 39), alpha: alpha)
    }

    private func sidebarSelectedCardBackgroundColor() -> NSColor { sidebarCardBackgroundColor(isArchived: false) }

    private func sidebarCardBorderColor(isSelected: Bool) -> NSColor {
        if isSelected { return sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184), alpha: 0.50) }
        return sidebarThemeColor(light: (213, 216, 211), dark: (48, 67, 70), alpha: 0.72)
    }

    private func sidebarPrimaryTextColor(isSelected: Bool, isArchived: Bool) -> NSColor {
        let alpha: CGFloat = if isArchived { 0.70 } else if isSelected { 0.96 } else { 0.92 }
        return sidebarThemeColor(light: (16, 32, 40), dark: (234, 240, 239), alpha: alpha)
    }

    private func sidebarMetadataTextColor(isSelected: Bool) -> NSColor {
        let alpha: CGFloat = isSelected ? 0.88 : 0.82
        return sidebarThemeColor(light: (58, 77, 87), dark: (173, 192, 196), alpha: alpha)
    }

    private func sidebarRunningIndicatorColor() -> NSColor { sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184), alpha: 0.95) }

    private func sidebarIdleIndicatorColor() -> NSColor { sidebarThemeColor(light: (213, 216, 211), dark: (48, 67, 70), alpha: 0.85) }

    private func sidebarThemeColor(light: (Int, Int, Int), dark: (Int, Int, Int), alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let source = isDark ? dark : light
            return NSColor(calibratedRed: CGFloat(source.0) / 255, green: CGFloat(source.1) / 255, blue: CGFloat(source.2) / 255, alpha: alpha)
        }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        let previousRow = lastSelectedRow
        if projectHasUnsavedChanges || workspaceHasUnsavedChanges {
            let response = unsavedChangesPrompt()
            if response == .alertFirstButtonReturn {
                if !saveCurrentDetail() {
                    outlineView.selectRowIndexes(IndexSet(integer: lastSelectedRow), byExtendingSelection: false)
                    return
                }
            } else if response == .alertThirdButtonReturn {
                outlineView.selectRowIndexes(IndexSet(integer: lastSelectedRow), byExtendingSelection: false)
                return
            } else {
                projectHasUnsavedChanges = false
                workspaceHasUnsavedChanges = false
            }
        }
        guard row >= 0, let item = outlineView.item(atRow: row) as? OutlineItem else {
            selectedProjectID = nil
            selectedWorkspaceID = nil
            showingSettings = false
            showPlaceholder()
            refreshSidebarSelectionRows(previousRow: previousRow, currentRow: row)
            return
        }
        lastSelectedRow = row
        switch item {
        case .project(let project):
            selectedProjectID = project.id
            selectedWorkspaceID = nil
            showingSettings = false
            showProjectDetail(project: project)
        case .workspace(let project, let workspace):
            selectedProjectID = project.id
            selectedWorkspaceID = workspace.id
            showingSettings = false
            showWorkspaceDetail(project: project, workspace: workspace)
        }
        refreshSidebarSelectionRows(previousRow: previousRow, currentRow: row)
    }

    private func refreshSidebarSelectionRows(previousRow: Int, currentRow: Int) {
        var rowsToReload = IndexSet()
        if previousRow >= 0, previousRow < outlineView.numberOfRows { rowsToReload.insert(previousRow) }
        if currentRow >= 0, currentRow < outlineView.numberOfRows { rowsToReload.insert(currentRow) }
        guard !rowsToReload.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {}

    public func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        guard let first = splitView.subviews.first else { return true }
        return view !== first
    }

    public func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.subviews.count == 2 else {
            splitView.adjustSubviews()
            return
        }
        let divider = splitView.dividerThickness
        let bounds = splitView.bounds
        let left = splitView.subviews[0]
        let right = splitView.subviews[1]

        let preferredWidth = left.frame.width > 0 ? left.frame.width : defaultSplitViewWidth
        let maxLeftWidth = max(0, bounds.width - divider)
        let leftWidth = min(preferredWidth, maxLeftWidth)

        left.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
        let rightX = leftWidth + divider
        right.frame = NSRect(x: rightX, y: 0, width: max(0, bounds.width - rightX), height: bounds.height)
    }

    private func registerDirtyTracking(
        setupView: NSTextView, stopView: NSTextView, portEditor: PortEditor, processEditor: ProcessEditor, browserView: NSTextView
    ) {
        projectHasUnsavedChanges = false
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: setupView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.projectHasUnsavedChanges = true }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: stopView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.projectHasUnsavedChanges = true }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: browserView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.projectHasUnsavedChanges = true }
        }
        portEditor.onDirty = { [weak self] in Task { @MainActor in self?.projectHasUnsavedChanges = true } }
        processEditor.onDirty = { [weak self] in Task { @MainActor in self?.projectHasUnsavedChanges = true } }
    }

    private func registerWorkspaceDirtyTracking(
        stopView: NSTextView, portEditor: PortEditor, processEditor: ProcessEditor, browserView: NSTextView
    ) {
        workspaceHasUnsavedChanges = false
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: stopView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.workspaceHasUnsavedChanges = true }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: browserView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.workspaceHasUnsavedChanges = true }
        }
        portEditor.onDirty = { [weak self] in Task { @MainActor in self?.workspaceHasUnsavedChanges = true } }
        processEditor.onDirty = { [weak self] in Task { @MainActor in self?.workspaceHasUnsavedChanges = true } }
    }

    private func saveCurrentDetail() -> Bool {
        if selectedWorkspaceID != nil { return saveCurrentWorkspace() }
        return saveCurrentProject()
    }

    private func applySplitViewWidth() {
        guard let splitView else { return }
        isApplyingSplitViewWidth = true
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(defaultSplitViewWidth, ofDividerAt: 0)
        Task { @MainActor in
            await Task.yield()
            self.isApplyingSplitViewWidth = false
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        guard !hasAppliedSplitViewWidth else { return }
        hasAppliedSplitViewWidth = true
        applySplitViewWidth()
    }

    private func saveCurrentWorkspace() -> Bool {
        commitEditing()
        guard let selectedWorkspaceID else { return true }
        let tag = selectedWorkspaceID.hashValue
        guard let refs = WorkspaceFieldCache.shared.cache[tag] else { return true }
        do {
            try orchestrator.updateWorkspaceSettings(workspaceID: refs.workspaceID) { config in
                config.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
                config.ports = refs.portEditor.currentDefinitions()
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = parseBrowserSessions(refs.browserView.string)
                config.statusChecks = refs.processEditor.currentStatusChecks()
            }
            workspaceHasUnsavedChanges = false
            reloadData()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func saveCurrentProject() -> Bool {
        commitEditing()
        guard let selectedProjectID else { return true }
        let tag = selectedProjectID.hashValue
        guard let refs = ProjectFieldCache.shared.cache[tag] else { return true }
        do {
            try orchestrator.updateProjectConfig(projectID: refs.projectID) { config in
                config.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
                config.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
                config.ports = refs.portEditor.currentDefinitions()
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = parseBrowserSessions(refs.browserView.string)
                config.statusChecks = refs.processEditor.currentStatusChecks()
            }
            projectHasUnsavedChanges = false
            reloadData()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func unsavedChangesPrompt() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "You have unsaved changes. Save before leaving?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal()
    }

    private func commitEditing() {
        let windows = [window, NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in windows {
            window.endEditing(for: nil)
            _ = window.makeFirstResponder(nil)
        }
    }
}
