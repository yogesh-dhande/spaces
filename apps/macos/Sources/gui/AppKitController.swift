import AppKit
import Carbon
import Foundation
import streamctl

@MainActor
public final class AppKitController: NSObject, NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSSplitViewDelegate, NSWindowDelegate, NSTextFieldDelegate
{
    private var window: NSWindow!
    private var splitView: NSSplitView?
    private let outlineView = NSOutlineView()
    private let detailContainer = NSView()

    private var orchestrator: SpaceshipOrchestrator!
    private var projects: [ProjectSummary] = []
    private var workspacesByProject: [String: [WorkspaceSummary]] = [:]

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

    private var configCache: AppConfig?
    private let defaultSplitViewWidth: CGFloat = 360
    private let shortcutLabelColumnWidth: CGFloat = 250
    private var isApplyingSplitViewWidth = false
    private var hasAppliedSplitViewWidth = false

    private lazy var hotkeyHandlerProc: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<AppKitController>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        if status != noErr {
            return status
        }
        Task { @MainActor in
            controller.handleGlobalHotkey(id: hotKeyID.id)
        }
        return noErr
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try DatabaseLocator.defaultPath()
            let configPath = try ConfigStore.defaultPath()
            let store = try SQLiteStore(path: db)
            let configStore = ConfigStore(path: configPath)
            orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)
            configCache = try orchestrator.syncConfig()
            loadShortcutSpecs()
        } catch {
            showError(error)
            return
        }

        buildWindow()
        reloadData()
        setupGlobalHotkey()
        setupShortcutMonitor()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        teardownGlobalHotkey()
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
        }
    }

    private func buildWindow() {
        let rect = NSRect(x: 200, y: 200, width: 1100, height: 700)
        window = NSWindow(
            contentRect: rect, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.title = "spaceship"
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
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    private func makeLeftPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let sectionHeader = sidebarSectionHeader(
            title: "Projects",
            actions: [
                (symbol: "plus", tooltip: "New project", action: #selector(addProject)),
                (
                    symbol: "gearshape",
                    tooltip: "Settings",
                    action: #selector(showSettings)
                ),
                (
                    symbol: "arrow.clockwise",
                    tooltip: "Reload",
                    action: #selector(reloadTapped)
                ),
            ]
        )

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Projects"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.selectionHighlightStyle = .regular

        scroll.documentView = outlineView

        container.addSubview(sectionHeader)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            sectionHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            sectionHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            sectionHeader.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func makeRightPane() -> NSView {
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
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
            for project in projects {
                let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
                workspacesByProject[project.id] = workspaces
            }
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
            refreshSelection()
        } catch {
            showError(error)
        }
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
        for view in detailContainer.subviews {
            view.removeFromSuperview()
        }
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
        for view in detailContainer.subviews {
            view.removeFromSuperview()
        }
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
            if let current = currentEditor,
                let item = popUp.itemArray.first(where: {
                    ($0.representedObject as? EditorPreference) == current
                })
            {
                popUp.select(item)
            } else {
                popUp.selectItem(at: 0)
            }
            popUp.target = self
            popUp.action = #selector(editorPreferenceChanged(_:))
            stack.addArrangedSubview(popUp)
            constrainFormFieldToFillWidth(popUp, in: stack)
        }

        if let current = currentEditor,
            !options.contains(where: { $0.preference == current })
        {
            let note = NSTextField(
                labelWithString: "Saved editor \"\(editorDisplayName(current))\" is not installed.")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
        }

        stack.addArrangedSubview(label(text: "Keyboard shortcuts"))
        let shortcutsNote = NSTextField(
            labelWithString:
                "Click a shortcut, then press the key combination you want. Next/Previous cycle running workspaces when spaceship is focused, and cycle workspace windows when a workspace window is focused."
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
        for view in detailContainer.subviews {
            view.removeFromSuperview()
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        let header = NSTextField(labelWithString: project.name)
        header.font = .systemFont(ofSize: 20, weight: .semibold)
        let addWorkspaceButton = actionButton(
            title: "New Workspace",
            symbol: "plus.rectangle.on.rectangle",
            tooltip: "New workspace for \(project.name)",
            action: #selector(addWorkspaceFromToolbar),
            primary: false
        )
        addWorkspaceButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        headerRow.addArrangedSubview(header)
        headerRow.addArrangedSubview(NSView())
        if project.isGitRepo {
            headerRow.addArrangedSubview(addWorkspaceButton)
        }

        let dirLabel = labeledValue(title: "Directory", value: project.dir)

        let setupView = makeEditableTextView()
        let stopView = makeEditableTextView()

        let processEditor = ProcessEditor()
        let browserView = makeEditableTextView()
        let browserScroll = scrollableTextView(browserView, height: 80)

        let statusEditor = StatusCheckEditor(processNamesProvider: { processEditor.processNames() })
        statusEditor.setChecks([])

        if let config = configCache?.projects.first(where: { normalizePath($0.dir) == project.dir }) {
            setupView.string = config.setupScript ?? ""
            stopView.string = config.stopScript ?? ""
            processEditor.setProcesses(config.processes)
            browserView.string = config.browserSessions.compactMap { $0.url }.joined(separator: "\n")
            statusEditor.setChecks(config.statusChecks)
        }

        let saveButton = actionButton(
            title: "Save Project", symbol: "square.and.arrow.down", tooltip: "Save project (⌘S)",
            action: #selector(saveProject(_:)), primary: true)
        saveButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        saveButton.keyEquivalent = "\r"
        let deleteButton = iconButton(symbol: "trash", tooltip: "Delete project", action: #selector(deleteProject(_:)))
        deleteButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        deleteButton.contentTintColor = .systemRed

        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(dirLabel)
        stack.addArrangedSubview(label(text: "Setup script"))
        stack.addArrangedSubview(
            helpTextLabel("Runs when this workspace is created or revived from archive.")
        )
        let setupScroll = scrollableTextView(setupView, height: 90)
        stack.addArrangedSubview(setupScroll)
        stack.addArrangedSubview(label(text: "Processes"))
        stack.addArrangedSubview(processEditor.container)
        stack.addArrangedSubview(label(text: "Browser sessions (URL per line)"))
        stack.addArrangedSubview(browserScroll)
        stack.addArrangedSubview(label(text: "Status checks (per process)"))
        stack.addArrangedSubview(statusEditor.container)
        stack.addArrangedSubview(label(text: "Stop script"))
        stack.addArrangedSubview(
            helpTextLabel("Runs on stop/restart/archive after automatic process termination.")
        )
        let stopScroll = scrollableTextView(stopView, height: 90)
        stack.addArrangedSubview(stopScroll)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(deleteButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(setupScroll, in: stack)
        constrainFormFieldToFillWidth(processEditor.container, in: stack)
        constrainFormFieldToFillWidth(browserScroll, in: stack)
        constrainFormFieldToFillWidth(statusEditor.container, in: stack)
        constrainFormFieldToFillWidth(stopScroll, in: stack)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        saveButton.tag = storeProjectFields(
            projectID: project.id,
            setupView: setupView,
            stopView: stopView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
        registerDirtyTracking(
            setupView: setupView,
            stopView: stopView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
    }

    private func showAddProjectForm() {
        showingSettings = false
        for view in detailContainer.subviews {
            view.removeFromSuperview()
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "New Project")
        header.font = .systemFont(ofSize: 20, weight: .semibold)

        let sourcePopup = NSPopUpButton()
        sourcePopup.addItems(withTitles: ["Existing directory", "Clone repository"])
        sourcePopup.selectItem(at: 0)
        sourcePopup.target = self
        sourcePopup.action = #selector(projectSourceChanged(_:))

        let dirField = NSTextField(labelWithString: "Choose a project directory")
        dirField.toolTip = nil
        dirField.textColor = .secondaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        let browseButton = NSButton(title: "", target: self, action: #selector(browseProjectDir(_:)))
        browseButton.bezelStyle = .texturedRounded
        browseButton.controlSize = .small
        browseButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose directory")
        browseButton.toolTip = "Choose directory"
        let repoURLField = NSTextField(string: "")
        repoURLField.placeholderString = "https://github.com/org/repo.git"

        let setupView = makeEditableTextView()
        let stopView = makeEditableTextView()

        let processEditor = ProcessEditor()

        let browserView = makeEditableTextView()
        let browserScroll = scrollableTextView(browserView, height: 80)

        let statusEditor = StatusCheckEditor(processNamesProvider: { processEditor.processNames() })
        statusEditor.setChecks([])

        let createButton = actionButton(
            title: "Create Project",
            symbol: nil,
            tooltip: "Create project",
            action: #selector(createProject(_:)),
            primary: true
        )
        createButton.keyEquivalent = "\r"
        let cancelButton = actionButton(
            title: "Cancel",
            symbol: nil,
            tooltip: "Cancel",
            action: #selector(cancelProjectForm),
            primary: false
        )

        let localSourceSection = NSStackView()
        localSourceSection.orientation = .vertical
        localSourceSection.alignment = .leading
        localSourceSection.spacing = 8
        localSourceSection.detachesHiddenViews = true
        localSourceSection.addArrangedSubview(label(text: "Project directory"))
        let dirRow = NSView()
        dirRow.translatesAutoresizingMaskIntoConstraints = false
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        dirField.translatesAutoresizingMaskIntoConstraints = false
        dirField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dirRow.addSubview(browseButton)
        dirRow.addSubview(dirField)
        NSLayoutConstraint.activate([
            browseButton.leadingAnchor.constraint(equalTo: dirRow.leadingAnchor),
            browseButton.centerYAnchor.constraint(equalTo: dirRow.centerYAnchor),
            browseButton.widthAnchor.constraint(equalToConstant: 36),
            browseButton.heightAnchor.constraint(equalToConstant: 28),

            dirField.leadingAnchor.constraint(equalTo: browseButton.trailingAnchor, constant: 8),
            dirField.trailingAnchor.constraint(equalTo: dirRow.trailingAnchor),
            dirField.centerYAnchor.constraint(equalTo: browseButton.centerYAnchor),
            dirField.topAnchor.constraint(equalTo: dirRow.topAnchor),
            dirField.bottomAnchor.constraint(equalTo: dirRow.bottomAnchor),

            dirRow.heightAnchor.constraint(greaterThanOrEqualTo: browseButton.heightAnchor),
        ])
        localSourceSection.addArrangedSubview(dirRow)

        let cloneSourceSection = NSStackView()
        cloneSourceSection.orientation = .vertical
        cloneSourceSection.alignment = .leading
        cloneSourceSection.spacing = 8
        cloneSourceSection.detachesHiddenViews = true
        cloneSourceSection.addArrangedSubview(label(text: "Git repository URL"))
        cloneSourceSection.addArrangedSubview(repoURLField)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(label(text: "Project source"))
        stack.addArrangedSubview(sourcePopup)
        stack.addArrangedSubview(localSourceSection)
        stack.addArrangedSubview(cloneSourceSection)
        stack.addArrangedSubview(label(text: "Setup script"))
        stack.addArrangedSubview(
            helpTextLabel("Runs when each new workspace is created or revived from archive.")
        )
        let setupScroll = scrollableTextView(setupView, height: 90)
        stack.addArrangedSubview(setupScroll)
        stack.addArrangedSubview(label(text: "Processes"))
        stack.addArrangedSubview(processEditor.container)
        stack.addArrangedSubview(label(text: "Browser sessions (URL per line)"))
        stack.addArrangedSubview(browserScroll)
        stack.addArrangedSubview(label(text: "Status checks (per process)"))
        stack.addArrangedSubview(statusEditor.container)
        stack.addArrangedSubview(label(text: "Stop script"))
        stack.addArrangedSubview(
            helpTextLabel("Seeded into workspaces and run on stop/restart/archive after process termination.")
        )
        let stopScroll = scrollableTextView(stopView, height: 90)
        stack.addArrangedSubview(stopScroll)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(createButton)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(sourcePopup, in: stack)
        constrainFormFieldToFillWidth(localSourceSection, in: stack)
        constrainFormFieldToFillWidth(dirRow, in: localSourceSection)
        constrainFormFieldToFillWidth(cloneSourceSection, in: stack)
        constrainFormFieldToFillWidth(repoURLField, in: cloneSourceSection)
        constrainFormFieldToFillWidth(setupScroll, in: stack)
        constrainFormFieldToFillWidth(processEditor.container, in: stack)
        constrainFormFieldToFillWidth(browserScroll, in: stack)
        constrainFormFieldToFillWidth(statusEditor.container, in: stack)
        constrainFormFieldToFillWidth(stopScroll, in: stack)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        createButton.tag = storeAddProjectFields(
            sourcePopup: sourcePopup,
            localSourceSection: localSourceSection,
            cloneSourceSection: cloneSourceSection,
            dirField: dirField,
            repoURLField: repoURLField,
            setupView: setupView,
            stopView: stopView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor,
            browseButton: browseButton
        )
        if let refs = AddProjectFieldCache.shared.cache[createButton.tag] {
            updateAddProjectSourceUI(refs)
        }
    }

    private func showAddWorkspaceForm(project: ProjectSummary) {
        showingSettings = false
        for view in detailContainer.subviews {
            view.removeFromSuperview()
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "New Workspace for \(project.name)")
        header.font = .systemFont(ofSize: 20, weight: .semibold)
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
        let autoNameState = project.isGitRepo ? AddWorkspaceAutoNameState() : nil

        let createButton = actionButton(
            title: "Create Workspace",
            symbol: nil,
            tooltip: "Create workspace",
            action: #selector(createWorkspace(_:)),
            primary: true
        )
        createButton.keyEquivalent = "\r"
        let cancelButton = actionButton(
            title: "Cancel",
            symbol: nil,
            tooltip: "Cancel",
            action: #selector(cancelProjectForm),
            primary: false
        )

        stack.addArrangedSubview(header)
        if project.isGitRepo {
            stack.addArrangedSubview(label(text: "Target branch"))
            stack.addArrangedSubview(targetBranchField)
            stack.addArrangedSubview(label(text: "Branch name"))
            stack.addArrangedSubview(branchField)
            stack.addArrangedSubview(label(text: "Workspace name"))
            stack.addArrangedSubview(nameField)
        } else {
            stack.addArrangedSubview(label(text: "Workspace name"))
            stack.addArrangedSubview(nameField)
        }

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(createButton)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(nameField, in: stack)
        if project.isGitRepo {
            constrainFormFieldToFillWidth(targetBranchField, in: stack)
            constrainFormFieldToFillWidth(branchField, in: stack)
        }
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        createButton.tag = storeAddWorkspaceFields(
            projectID: project.id,
            isGitRepo: project.isGitRepo,
            targetBranchField: project.isGitRepo ? targetBranchField : nil,
            nameField: nameField,
            branchField: project.isGitRepo ? branchField : nil,
            autoNameState: autoNameState
        )
    }

    private func showWorkspaceDetail(project: ProjectSummary, workspace: WorkspaceSummary) {
        showingSettings = false
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews {
            view.removeFromSuperview()
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "\(project.name) / \(workspace.name)")
        header.font = .systemFont(ofSize: 20, weight: .semibold)

        let dirLabel = labeledValue(title: "Directory", value: workspace.dir)
        let statusLabel = statusRow(isRunning: workspace.isRunning)

        let launchOrRestartButton: NSButton
        if workspace.isRunning {
            launchOrRestartButton = actionButton(
                title: "Restart (⌘L)",
                symbol: "arrow.clockwise.circle",
                tooltip: "Restart",
                action: #selector(restartWorkspace(_:)),
                primary: false
            )
        } else {
            launchOrRestartButton = actionButton(
                title: "Launch (⌘L)",
                symbol: "play.circle",
                tooltip: "Launch",
                action: #selector(launchWorkspace(_:)),
                primary: false
            )
        }
        launchOrRestartButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        let stopButton = actionButton(
            title: "Stop (⌘.)", symbol: "stop.circle", tooltip: "Stop", action: #selector(stopWorkspace(_:)),
            primary: false)
        stopButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        let archiveButton = actionButton(
            title: "Archive", symbol: "archivebox", tooltip: "Archive", action: #selector(archiveWorkspace(_:)),
            primary: false)
        archiveButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        archiveButton.isEnabled = !workspace.isDefault

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(launchOrRestartButton)
        buttonRow.addArrangedSubview(stopButton)
        buttonRow.addArrangedSubview(archiveButton)
        buttonRow.addArrangedSubview(NSView())

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

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(dirLabel)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(tabs)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 20),
            tabs.heightAnchor.constraint(equalToConstant: 460),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        detailContainer.layoutSubtreeIfNeeded()
    }

    private func workspaceRunView(workspace: WorkspaceSummary) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let openRow = NSStackView()
        openRow.orientation = .horizontal
        openRow.spacing = 8
        let openEditorButton = actionButton(
            title: actionTitle(base: "Open Editor", setting: .guiOpenEditorShortcut),
            symbol: nil,
            tooltip: actionTooltip(base: "Open preferred editor", setting: .guiOpenEditorShortcut),
            action: #selector(openWorkspaceEditor(_:)),
            primary: false
        )
        let openTerminalButton = actionButton(
            title: actionTitle(base: "Open Terminal", setting: .guiOpenTerminalShortcut),
            symbol: nil,
            tooltip: actionTooltip(base: "Open terminal window", setting: .guiOpenTerminalShortcut),
            action: #selector(openWorkspaceTerminal(_:)),
            primary: false
        )
        let openFinderButton = actionButton(
            title: actionTitle(base: "Open Finder", setting: .guiOpenFinderShortcut),
            symbol: nil,
            tooltip: actionTooltip(base: "Open Finder window", setting: .guiOpenFinderShortcut),
            action: #selector(openWorkspaceFinder(_:)),
            primary: false
        )
        openEditorButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        openTerminalButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        openFinderButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        if let editor = configCache?.editor, editor != .none {
            openEditorButton.toolTip = "\(editorDisplayName(editor)) (\(shortcutHint(for: .guiOpenEditorShortcut)))"
        } else {
            openEditorButton.isEnabled = false
            openEditorButton.toolTip = "Preferred editor not configured"
        }
        openRow.addArrangedSubview(openEditorButton)
        openRow.addArrangedSubview(openTerminalButton)
        openRow.addArrangedSubview(openFinderButton)
        openRow.addArrangedSubview(NSView())

        let processesLabel = label(text: "Running processes")
        let windowsLabel = label(text: "Windows (cmd+<n>)")

        let processList = NSTextView()
        processList.isEditable = false
        processList.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let processes = (try? orchestrator.runningProcesses(workspaceID: workspace.id)) ?? []
        let results = (try? orchestrator.runStatusChecks(workspaceID: workspace.id)) ?? []
        processList.string = processes.map { process in
            let checks = results.filter { $0.processID == process.id }
            if checks.isEmpty {
                return "\(process.templateName) [\(process.status.rawValue)]"
            }
            let checkInfo = checks.map { "\($0.checkName)=\($0.status)" }.joined(separator: ", ")
            return "\(process.templateName) [\(process.status.rawValue)] { \(checkInfo) }"
        }.joined(separator: "\n")
        let processScroll = scrollableTextView(processList, height: 120)

        let windowsList = NSTextView()
        windowsList.isEditable = false
        windowsList.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let windows = (try? orchestrator.windows(workspaceID: workspace.id)) ?? []
        windowsList.string = windows.enumerated().map { idx, win in
            let title = win.targetURL ?? win.title ?? win.app
            return "cmd+\(idx + 1)  \(win.app) — \(title)"
        }.joined(separator: "\n")
        let windowsScroll = scrollableTextView(windowsList, height: 120)

        container.addArrangedSubview(openRow)
        container.addArrangedSubview(processesLabel)
        container.addArrangedSubview(processScroll)
        container.addArrangedSubview(windowsLabel)
        container.addArrangedSubview(windowsScroll)
        constrainFormFieldToFillWidth(openRow, in: container)
        constrainFormFieldToFillWidth(processScroll, in: container)
        constrainFormFieldToFillWidth(windowsScroll, in: container)
        return insetContainerView(container)
    }

    private func workspaceEnvView(project: ProjectSummary, workspace: WorkspaceSummary) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        let envView = NSTextView()
        envView.isEditable = false
        envView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let reservedPorts = (try? orchestrator.workspacePorts(workspaceID: workspace.id)) ?? []
        var lines: [String] = []
        for (idx, port) in reservedPorts.enumerated() {
            lines.append("PORT\(idx)=\(port)")
        }
        lines.append("spaceship_WORKSPACE_DIR=\(workspace.dir)")
        let scopedKey = "spaceship_\(sanitizeEnvKey(project.name))_\(sanitizeEnvKey(workspace.name))_WORKSPACE_DIR"
        lines.append("\(scopedKey)=\(workspace.dir)")
        envView.string = lines.joined(separator: "\n")
        if let container = envView.textContainer, let layout = envView.layoutManager {
            layout.ensureLayout(for: container)
        }
        let scroll = scrollableTextView(envView, height: 240)
        container.addArrangedSubview(scroll)
        constrainFormFieldToFillWidth(scroll, in: container)
        return insetContainerView(container)
    }

    private func workspaceSettingsView(project: ProjectSummary, workspace: WorkspaceSummary) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let processEditor = ProcessEditor()
        let stopView = makeEditableTextView()
        let stopScroll = scrollableTextView(stopView, height: 90)
        let browserView = makeEditableTextView()
        let browserScroll = scrollableTextView(browserView, height: 80)

        let statusEditor = StatusCheckEditor(processNamesProvider: { processEditor.processNames() })
        statusEditor.setChecks([])

        if let config = try? orchestrator.workspaceSettings(workspaceID: workspace.id) {
            stopView.string = config.stopScript ?? ""
            processEditor.setProcesses(config.processes)
            browserView.string = config.browserSessions.compactMap { $0.url }.joined(separator: "\n")
            statusEditor.setChecks(config.statusChecks)
        } else if let config = configCache?.projects.first(where: { normalizePath($0.dir) == project.dir }) {
            stopView.string = config.stopScript ?? ""
            processEditor.setProcesses(config.processes)
            browserView.string = config.browserSessions.compactMap { $0.url }.joined(separator: "\n")
            statusEditor.setChecks(config.statusChecks)
        }

        let saveButton = actionButton(
            title: "Save Workspace",
            symbol: "square.and.arrow.down",
            tooltip: "Save workspace settings",
            action: #selector(saveWorkspace(_:)),
            primary: true
        )

        contentStack.addArrangedSubview(label(text: "Processes"))
        contentStack.addArrangedSubview(processEditor.container)
        contentStack.addArrangedSubview(label(text: "Stop script"))
        contentStack.addArrangedSubview(
            helpTextLabel("Workspace override. Runs on stop/restart/archive after process termination.")
        )
        contentStack.addArrangedSubview(stopScroll)
        contentStack.addArrangedSubview(label(text: "Browser sessions (URL per line)"))
        contentStack.addArrangedSubview(browserScroll)
        contentStack.addArrangedSubview(label(text: "Status checks (per process)"))
        contentStack.addArrangedSubview(statusEditor.container)

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
            contentStack.bottomAnchor.constraint(equalTo: scrollContent.bottomAnchor),
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
        constrainFormFieldToFillWidth(processEditor.container, in: contentStack)
        constrainFormFieldToFillWidth(stopScroll, in: contentStack)
        constrainFormFieldToFillWidth(browserScroll, in: contentStack)
        constrainFormFieldToFillWidth(statusEditor.container, in: contentStack)

        saveButton.tag = storeWorkspaceFields(
            workspaceID: workspace.id,
            stopView: stopView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
        registerWorkspaceDirtyTracking(
            stopView: stopView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )

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
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let paths = [
            applications.appendingPathComponent(bundleName).path,
            userApplications.appendingPathComponent(bundleName).path,
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private func editorDisplayName(_ editor: EditorPreference) -> String {
        switch editor {
        case .vscode:
            return "VS Code"
        case .cursor:
            return "Cursor"
        case .windsurf:
            return "Windsurf"
        case .vim:
            return "Vim"
        case .none:
            return "None"
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
            title: shortcutCaptureButtonTitle(setting: setting),
            symbol: nil,
            tooltip: "Click to capture shortcut",
            action: #selector(beginShortcutCapture(_:)),
            primary: false
        )
        captureButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
        captureButton.alignment = .center
        captureButton.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        captureButton.isBordered = false
        captureButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        captureButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captureButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        captureButton.widthAnchor.constraint(equalToConstant: 170).isActive = true
        updateShortcutCaptureButtonText(
            captureButton,
            text: shortcutCaptureButtonTitle(setting: setting),
            active: false
        )
        styleShortcutCaptureButton(captureButton, active: false)
        shortcutButtonsBySetting[setting.settingKey] = captureButton

        let resetButton = actionButton(
            title: "Reset",
            symbol: nil,
            tooltip: "Reset to default shortcut",
            action: #selector(resetShortcutSetting(_:)),
            primary: false
        )
        resetButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
        resetButton.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(title)
        row.addArrangedSubview(captureButton)
        row.addArrangedSubview(resetButton)
        return row
    }

    private func shortcutCaptureButtonTitle(setting: ShortcutSetting) -> String {
        if activeShortcutCaptureSetting == setting {
            return "Press shortcut"
        }
        return shortcutDisplayText(for: setting)
    }

    private func shortcutDisplayText(for setting: ShortcutSetting) -> String {
        shortcutSpec(for: setting)?.normalized ?? setting.defaultSpec
    }

    private func actionTitle(base: String, setting: ShortcutSetting) -> String {
        "\(base) (\(shortcutHint(for: setting)))"
    }

    private func actionTooltip(base: String, setting: ShortcutSetting) -> String {
        "\(base) (\(shortcutHint(for: setting)))"
    }

    private func shortcutHint(for setting: ShortcutSetting) -> String {
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        return displayShortcut(spec)
    }

    private func displayShortcut(_ spec: HotkeySpec) -> String {
        var parts: [String] = []
        if spec.modifiers.contains(.cmd) {
            parts.append("⌘")
        }
        if spec.modifiers.contains(.shift) {
            parts.append("⇧")
        }
        if spec.modifiers.contains(.alt) {
            parts.append("⌥")
        }
        if spec.modifiers.contains(.ctrl) {
            parts.append("⌃")
        }
        parts.append(displayShortcutKey(spec.key))
        return parts.joined()
    }

    private func displayShortcutKey(_ key: String) -> String {
        switch key {
        case "return", "enter":
            return "↩"
        case "space":
            return "Space"
        case "tab":
            return "⇥"
        case "escape":
            return "⎋"
        case "delete", "backspace":
            return "⌫"
        case "forwarddelete":
            return "⌦"
        case "left":
            return "←"
        case "right":
            return "→"
        case "up":
            return "↑"
        case "down":
            return "↓"
        default:
            return key.uppercased()
        }
    }

    @objc private func beginShortcutCapture(_ sender: NSButton) {
        guard let settingKey = sender.identifier?.rawValue,
            let setting = ShortcutSetting(settingKey: settingKey)
        else { return }

        if activeShortcutCaptureSetting == setting {
            activeShortcutCaptureSetting = nil
        } else {
            activeShortcutCaptureSetting = setting
        }
        refreshShortcutCaptureButtons()
    }

    @objc private func resetShortcutSetting(_ sender: NSButton) {
        guard let settingKey = sender.identifier?.rawValue,
            let setting = ShortcutSetting(settingKey: settingKey)
        else { return }

        if activeShortcutCaptureSetting == setting {
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
        }

        do {
            try setShortcutSetting(setting: setting, value: nil)
            loadShortcutSpecs()
            setupGlobalHotkey()
            refreshSelection()
        } catch {
            showError(error)
        }
    }

    private func refreshShortcutCaptureButtons() {
        for (settingKey, button) in shortcutButtonsBySetting {
            guard let setting = ShortcutSetting(settingKey: settingKey) else { continue }
            let isActive = activeShortcutCaptureSetting == setting
            updateShortcutCaptureButtonText(
                button,
                text: shortcutCaptureButtonTitle(setting: setting),
                active: isActive
            )
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
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .paragraphStyle: paragraph,
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
            return isDark
                ? NSColor(calibratedWhite: 0.16, alpha: 1.0)
                : NSColor(calibratedWhite: 0.82, alpha: 1.0)
        }
    }

    private func shortcutKeycapBorderColor(active: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            if active {
                return .systemBlue
            }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(calibratedWhite: 0.28, alpha: 1.0)
                : NSColor(calibratedWhite: 0.65, alpha: 1.0)
        }
    }

    private func sidebarSectionHeader(
        title: String,
        actions: [(symbol: String, tooltip: String, action: Selector)]
    ) -> NSView {
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
            stack.addArrangedSubview(
                sidebarRowIconButton(symbol: action.symbol, tooltip: action.tooltip, action: action.action)
            )
        }

        return stack
    }

    private func sidebarRowIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: tooltip
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
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

    private func actionButton(title: String, symbol: String?, tooltip: String, action: Selector, primary: Bool)
        -> NSButton
    {
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
            scroll.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            contentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func scrollableTextView(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
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
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
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
        projectID: String,
        setupView: NSTextView,
        stopView: NSTextView,
        processEditor: ProcessEditor,
        browserView: NSTextView,
        statusEditor: StatusCheckEditor
    ) -> Int {
        let id = projectID.hashValue
        ProjectFieldCache.shared.cache[id] = ProjectFieldRefs(
            projectID: projectID,
            setupView: setupView,
            stopView: stopView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
        return id
    }

    private func storeWorkspaceFields(
        workspaceID: String,
        stopView: NSTextView,
        processEditor: ProcessEditor,
        browserView: NSTextView,
        statusEditor: StatusCheckEditor
    ) -> Int {
        let id = workspaceID.hashValue
        WorkspaceFieldCache.shared.cache[id] = WorkspaceFieldRefs(
            workspaceID: workspaceID,
            stopView: stopView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
        return id
    }

    private func storeAddProjectFields(
        sourcePopup: NSPopUpButton,
        localSourceSection: NSStackView,
        cloneSourceSection: NSStackView,
        dirField: NSTextField,
        repoURLField: NSTextField,
        setupView: NSTextView,
        stopView: NSTextView,
        processEditor: ProcessEditor,
        browserView: NSTextView,
        statusEditor: StatusCheckEditor,
        browseButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddProjectFieldCache.shared.cache[id] = AddProjectFieldRefs(
            sourcePopup: sourcePopup,
            localSourceSection: localSourceSection,
            cloneSourceSection: cloneSourceSection,
            dirField: dirField,
            repoURLField: repoURLField,
            browseButton: browseButton,
            setupView: setupView,
            stopView: stopView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
        sourcePopup.tag = id
        browseButton.tag = id
        return id
    }

    private func storeAddWorkspaceFields(
        projectID: String,
        isGitRepo: Bool,
        targetBranchField: NSComboBox?,
        nameField: NSTextField,
        branchField: NSTextField?,
        autoNameState: AddWorkspaceAutoNameState?
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddWorkspaceFieldCache.shared.cache[id] = AddWorkspaceFieldRefs(
            projectID: projectID,
            isGitRepo: isGitRepo,
            targetBranchField: targetBranchField,
            nameField: nameField,
            branchField: branchField,
            autoNameState: autoNameState
        )
        return id
    }

    @objc private func reloadTapped() {
        reloadData()
    }

    @objc private func showSettings() {
        if projectHasUnsavedChanges || workspaceHasUnsavedChanges {
            let response = unsavedChangesPrompt()
            if response == .alertFirstButtonReturn {
                if !saveCurrentDetail() {
                    return
                }
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
        do {
            configCache = try orchestrator.updateEditorPreference(preference)
        } catch {
            showError(error)
        }
    }

    @objc private func addProject() {
        showAddProjectForm()
    }

    @objc private func addWorkspace(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue,
            let project = projects.first(where: { $0.id == projectID })
        else { return }
        showAddWorkspaceForm(project: project)
    }

    @objc private func addWorkspaceFromToolbar(_ sender: NSButton) {
        if let projectID = sender.identifier?.rawValue,
            let project = projects.first(where: { $0.id == projectID })
        {
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
        if let selectedProjectID, let project = projects.first(where: { $0.id == selectedProjectID }) {
            return project
        }
        if let selectedWorkspaceID, let (project, _) = findWorkspace(id: selectedWorkspaceID) {
            return project
        }
        return nil
    }

    @objc private func saveProject(_ sender: NSButton) {
        commitEditing()
        guard let refs = ProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            try orchestrator.updateProjectConfig(projectID: refs.projectID) { config in
                config.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
                config.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = parseBrowserSessions(refs.browserView.string)
                config.statusChecks = refs.statusEditor.currentChecks()
            }
            projectHasUnsavedChanges = false
            reloadData()
        } catch {
            showError(error)
        }
    }

    @objc private func deleteProject(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue,
            let project = projects.first(where: { $0.id == projectID })
        else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete project?"
        alert.informativeText =
            """
            This removes the project and its workspaces from spaceship.
            If this project was cloned into ~/spaceship/projects by spaceship, that project directory is deleted.
            For git projects, related workspace directories under ~/spaceship/workspaces are also deleted.
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
        } catch {
            showError(error)
        }
    }

    @objc private func saveWorkspace(_ sender: NSButton) {
        commitEditing()
        guard let refs = WorkspaceFieldCache.shared.cache[sender.tag] else { return }
        do {
            try orchestrator.updateWorkspaceSettings(workspaceID: refs.workspaceID) { config in
                config.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = parseBrowserSessions(refs.browserView.string)
                config.statusChecks = refs.statusEditor.currentChecks()
            }
            workspaceHasUnsavedChanges = false
            reloadData()
        } catch {
            showError(error)
        }
    }

    @objc private func createProject(_ sender: NSButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            let record: ProjectRecord
            if refs.sourcePopup.indexOfSelectedItem == 1 {
                let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !repoURL.isEmpty else {
                    throw SpaceshipError.invalidArgument(message: "Git repository URL is required.")
                }
                record = try orchestrator.addProject(gitURL: repoURL)
            } else {
                let dir = refs.dirField.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !dir.isEmpty else { return }
                record = try orchestrator.addProject(dir: dir)
            }
            var config = ProjectConfig(dir: record.dir)
            config.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
            config.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
            config.processes = refs.processEditor.currentProcesses()
            config.browserSessions = parseBrowserSessions(refs.browserView.string)
            config.statusChecks = refs.statusEditor.currentChecks()
            try orchestrator.updateProjectConfig(config)
            reloadData()
        } catch {
            showError(error)
        }
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
            }
        }
    }

    private func updateAddProjectSourceUI(_ refs: AddProjectFieldRefs) {
        let cloneSelected = refs.sourcePopup.indexOfSelectedItem == 1
        refs.localSourceSection.isHidden = cloneSelected
        refs.cloneSourceSection.isHidden = !cloneSelected
    }

    private func defaultWorkspaceTargetBranch(project: ProjectSummary, branches: [String]) -> String? {
        if let configured = project.defaultBranch, !configured.isEmpty {
            return configured
        }
        if branches.contains("main") {
            return "main"
        }
        if branches.contains("master") {
            return "master"
        }
        return branches.first
    }

    @objc private func createWorkspace(_ sender: NSButton) {
        guard let refs = AddWorkspaceFieldCache.shared.cache[sender.tag] else { return }
        do {
            let name = refs.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw SpaceshipError.invalidArgument(message: "Workspace name is required.")
            }
            let targetBranch = refs.targetBranchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = refs.branchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if refs.isGitRepo, (branch == nil || branch?.isEmpty == true) {
                throw SpaceshipError.invalidArgument(message: "Branch name is required for git projects.")
            }
            if refs.isGitRepo, (targetBranch == nil || targetBranch?.isEmpty == true) {
                throw SpaceshipError.invalidArgument(message: "Target branch is required for git projects.")
            }
            _ = try orchestrator.createWorkspace(
                projectID: refs.projectID,
                name: name,
                branch: branch,
                targetBranch: targetBranch
            )
            reloadData()
        } catch {
            showError(error)
        }
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
            return
        }
    }

    @objc private func cancelProjectForm() {
        refreshSelection()
    }

    @objc private func launchWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        do {
            try orchestrator.launchWorkspace(workspaceID: id)
            reloadData()
        } catch {
            showError(error)
        }
    }

    @objc private func restartWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        do {
            try orchestrator.restartWorkspace(workspaceID: id)
            reloadData()
        } catch {
            showError(error)
        }
    }

    @objc private func stopWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        do {
            try orchestrator.stopWorkspace(workspaceID: id)
            reloadData()
        } catch {
            showError(error)
        }
    }

    @objc private func archiveWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        do {
            try orchestrator.archiveWorkspace(workspaceID: id)
            reloadData()
        } catch {
            showError(error)
        }
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
        } catch {
            showError(error)
        }
    }

    private func openWorkspaceTerminal(workspaceID: String) {
        do {
            try orchestrator.openWorkspaceTerminal(workspaceID: workspaceID)
            reloadData()
        } catch {
            showError(error)
        }
    }

    private func openWorkspaceFinder(workspaceID: String) {
        guard let (_, workspace) = findWorkspace(id: workspaceID) else { return }
        let url = URL(fileURLWithPath: workspace.dir, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    private func findWorkspace(id: String) -> (ProjectSummary, WorkspaceSummary)? {
        for project in projects {
            if let workspaces = workspacesByProject[project.id],
                let workspace = workspaces.first(where: { $0.id == id })
            {
                return (project, workspace)
            }
        }
        return nil
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func sanitizeEnvKey(_ raw: String) -> String {
        raw.uppercased().map { char in
            if char.isLetter || char.isNumber { return char }
            return "_"
        }.reduce("") { $0 + String($1) }
    }

    private func setupGlobalHotkey() {
        guard let toggleShortcutSpec else {
            teardownGlobalHotkey()
            return
        }
        registerHotkeys(toggle: toggleShortcutSpec, next: nextShortcutSpec, previous: previousShortcutSpec)
    }

    private func teardownGlobalHotkey() {
        for ref in hotkeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()
        if let hotkeyHandler {
            RemoveEventHandler(hotkeyHandler)
        }
        hotkeyHandler = nil
    }

    private func registerHotkeys(toggle: HotkeySpec, next: HotkeySpec?, previous: HotkeySpec?) {
        teardownGlobalHotkey()
        let signature = OSType(UInt32(truncatingIfNeeded: "AMUX".utf8.reduce(0) { ($0 << 8) + UInt32($1) }))
        let target = GetEventDispatcherTarget()
        registerHotkey(
            spec: toggle,
            id: GlobalHotkey.toggle.rawValue,
            signature: signature,
            target: target
        )
        if let next {
            registerHotkey(
                spec: next,
                id: GlobalHotkey.next.rawValue,
                signature: signature,
                target: target
            )
        }
        if let previous {
            registerHotkey(
                spec: previous,
                id: GlobalHotkey.previous.rawValue,
                signature: signature,
                target: target
            )
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(
            target,
            hotkeyHandlerProc,
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotkeyHandler
        )
    }

    private func registerHotkey(spec: HotkeySpec, id: UInt32, signature: OSType, target: EventTargetRef?) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(UInt32(spec.keyCode), spec.modifiersCarbon, hotKeyID, target, 0, &ref)
        if status == noErr, let ref {
            hotkeyRefs[id] = ref
        }
    }

    private func setupShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleShortcutCaptureEvent(event: event) {
                return nil
            }
            if self.handleFocusedTextInputShortcut(event: event) {
                return nil
            }
            if self.isTextInputFocused() {
                return event
            }
            if let openEditorShortcutSpec, matches(event: event, spec: openEditorShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID {
                    self.openWorkspaceEditor(workspaceID: workspaceID)
                }
                return nil
            }
            if let openTerminalShortcutSpec, matches(event: event, spec: openTerminalShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID {
                    self.openWorkspaceTerminal(workspaceID: workspaceID)
                }
                return nil
            }
            if let openFinderShortcutSpec, matches(event: event, spec: openFinderShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID {
                    self.openWorkspaceFinder(workspaceID: workspaceID)
                }
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

    private func shortcutCaptureKey(for keyCode: UInt16) -> String? {
        AppKitController.shortcutCaptureKeyMap[keyCode]
    }

    private func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        let filtered = flags.intersection([.command, .shift, .option, .control])
        var modifiers = Set<HotkeyModifier>()
        if filtered.contains(.command) {
            modifiers.insert(.cmd)
        }
        if filtered.contains(.shift) {
            modifiers.insert(.shift)
        }
        if filtered.contains(.option) {
            modifiers.insert(.alt)
        }
        if filtered.contains(.control) {
            modifiers.insert(.ctrl)
        }
        return modifiers
    }

    private static let shortcutCaptureKeyMap: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "a",
        UInt16(kVK_ANSI_B): "b",
        UInt16(kVK_ANSI_C): "c",
        UInt16(kVK_ANSI_D): "d",
        UInt16(kVK_ANSI_E): "e",
        UInt16(kVK_ANSI_F): "f",
        UInt16(kVK_ANSI_G): "g",
        UInt16(kVK_ANSI_H): "h",
        UInt16(kVK_ANSI_I): "i",
        UInt16(kVK_ANSI_J): "j",
        UInt16(kVK_ANSI_K): "k",
        UInt16(kVK_ANSI_L): "l",
        UInt16(kVK_ANSI_M): "m",
        UInt16(kVK_ANSI_N): "n",
        UInt16(kVK_ANSI_O): "o",
        UInt16(kVK_ANSI_P): "p",
        UInt16(kVK_ANSI_Q): "q",
        UInt16(kVK_ANSI_R): "r",
        UInt16(kVK_ANSI_S): "s",
        UInt16(kVK_ANSI_T): "t",
        UInt16(kVK_ANSI_U): "u",
        UInt16(kVK_ANSI_V): "v",
        UInt16(kVK_ANSI_W): "w",
        UInt16(kVK_ANSI_X): "x",
        UInt16(kVK_ANSI_Y): "y",
        UInt16(kVK_ANSI_Z): "z",
        UInt16(kVK_ANSI_0): "0",
        UInt16(kVK_ANSI_1): "1",
        UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4",
        UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6",
        UInt16(kVK_ANSI_7): "7",
        UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_Minus): "minus",
        UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Quote): "'",
        UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".",
        UInt16(kVK_ANSI_Slash): "/",
        UInt16(kVK_ANSI_Backslash): "\\",
        UInt16(kVK_ANSI_Grave): "`",
        UInt16(kVK_Space): "space",
        UInt16(kVK_Tab): "tab",
        UInt16(kVK_Return): "return",
        UInt16(kVK_Escape): "escape",
        UInt16(kVK_Delete): "delete",
        UInt16(kVK_ForwardDelete): "forwarddelete",
        UInt16(kVK_LeftArrow): "left",
        UInt16(kVK_RightArrow): "right",
        UInt16(kVK_UpArrow): "up",
        UInt16(kVK_DownArrow): "down",
        UInt16(kVK_F1): "f1",
        UInt16(kVK_F2): "f2",
        UInt16(kVK_F3): "f3",
        UInt16(kVK_F4): "f4",
        UInt16(kVK_F5): "f5",
        UInt16(kVK_F6): "f6",
        UInt16(kVK_F7): "f7",
        UInt16(kVK_F8): "f8",
        UInt16(kVK_F9): "f9",
        UInt16(kVK_F10): "f10",
        UInt16(kVK_F11): "f11",
        UInt16(kVK_F12): "f12",
        UInt16(kVK_F13): "f13",
        UInt16(kVK_F14): "f14",
        UInt16(kVK_F15): "f15",
        UInt16(kVK_F16): "f16",
        UInt16(kVK_F17): "f17",
        UInt16(kVK_F18): "f18",
        UInt16(kVK_F19): "f19",
        UInt16(kVK_F20): "f20",
    ]

    private func isTextInputFocused() -> Bool {
        guard let window else { return false }
        if let textView = window.firstResponder as? NSTextView {
            return textView.isEditable || textView.isFieldEditor
        }
        return false
    }

    private func handleFocusedTextInputShortcut(event: NSEvent) -> Bool {
        guard isTextInputFocused() else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "v":
                return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case "c":
                return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case "x":
                return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case "a":
                return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case "z":
                return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            default:
                return false
            }
        }
        if flags == [.command, .shift], key == "z" {
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        }
        return false
    }

    private func handleGlobalHotkey(id: UInt32) {
        guard let hotkey = GlobalHotkey(rawValue: id) else { return }
        switch hotkey {
        case .toggle:
            toggleWindowFromHotkey()
        case .next:
            focusGlobalWindowNavigation(direction: 1)
        case .previous:
            focusGlobalWindowNavigation(direction: -1)
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
        if let stored = try? HotkeySpec.parse(shortcutRawValue(for: setting)) {
            return stored
        }
        return try? HotkeySpec.parse(setting.defaultSpec)
    }

    private func shortcutRawValue(for setting: ShortcutSetting) throws -> String {
        switch setting {
        case .guiHotkey:
            return try orchestrator.guiHotkey()
        case .guiNextShortcut:
            return try orchestrator.guiNextShortcut()
        case .guiPreviousShortcut:
            return try orchestrator.guiPreviousShortcut()
        case .guiShowShortcut:
            return try orchestrator.guiShowShortcut()
        case .guiAddProjectShortcut:
            return try orchestrator.guiAddProjectShortcut()
        case .guiAddWorkspaceShortcut:
            return try orchestrator.guiAddWorkspaceShortcut()
        case .guiReloadShortcut:
            return try orchestrator.guiReloadShortcut()
        case .guiOpenEditorShortcut:
            return try orchestrator.guiOpenEditorShortcut()
        case .guiOpenTerminalShortcut:
            return try orchestrator.guiOpenTerminalShortcut()
        case .guiOpenFinderShortcut:
            return try orchestrator.guiOpenFinderShortcut()
        case .guiOpenSettingsShortcut:
            return try orchestrator.guiOpenSettingsShortcut()
        }
    }

    private func setShortcutSetting(setting: ShortcutSetting, value: String?) throws {
        switch setting {
        case .guiHotkey:
            try orchestrator.setGUIHotkey(value)
        case .guiNextShortcut:
            try orchestrator.setGUINextShortcut(value)
        case .guiPreviousShortcut:
            try orchestrator.setGUIPreviousShortcut(value)
        case .guiShowShortcut:
            try orchestrator.setGUIShowShortcut(value)
        case .guiAddProjectShortcut:
            try orchestrator.setGUIAddProjectShortcut(value)
        case .guiAddWorkspaceShortcut:
            try orchestrator.setGUIAddWorkspaceShortcut(value)
        case .guiReloadShortcut:
            try orchestrator.setGUIReloadShortcut(value)
        case .guiOpenEditorShortcut:
            try orchestrator.setGUIOpenEditorShortcut(value)
        case .guiOpenTerminalShortcut:
            try orchestrator.setGUIOpenTerminalShortcut(value)
        case .guiOpenFinderShortcut:
            try orchestrator.setGUIOpenFinderShortcut(value)
        case .guiOpenSettingsShortcut:
            try orchestrator.setGUIOpenSettingsShortcut(value)
        }
    }

    private func shortcutSpec(for setting: ShortcutSetting) -> HotkeySpec? {
        switch setting {
        case .guiHotkey:
            return toggleShortcutSpec
        case .guiNextShortcut:
            return nextShortcutSpec
        case .guiPreviousShortcut:
            return previousShortcutSpec
        case .guiShowShortcut:
            return activateShortcutSpec
        case .guiAddProjectShortcut:
            return nil
        case .guiAddWorkspaceShortcut:
            return nil
        case .guiReloadShortcut:
            return nil
        case .guiOpenEditorShortcut:
            return openEditorShortcutSpec
        case .guiOpenTerminalShortcut:
            return openTerminalShortcutSpec
        case .guiOpenFinderShortcut:
            return openFinderShortcutSpec
        case .guiOpenSettingsShortcut:
            return nil
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
        if let selectedWorkspaceID,
            let idx = running.firstIndex(where: { $0.id == selectedWorkspaceID })
        {
            let next = running[(idx + 1) % running.count]
            selectWorkspace(next)
        } else {
            selectWorkspace(running[0])
        }
    }

    private func selectPreviousRunningWorkspace() {
        let running = allRunningWorkspaces()
        guard !running.isEmpty else { return }
        if let selectedWorkspaceID,
            let idx = running.firstIndex(where: { $0.id == selectedWorkspaceID })
        {
            let prev = running[(idx - 1 + running.count) % running.count]
            selectWorkspace(prev)
        } else {
            selectWorkspace(running[0])
        }
    }

    private func activateSelectedWorkspace() {
        guard let selectedWorkspaceID else { return }
        do {
            try orchestrator.focusWorkspace(workspaceID: selectedWorkspaceID)
        } catch {
            showError(error)
        }
    }

    private func focusWindowShortcut(index: Int) {
        guard let selectedWorkspaceID else { return }
        do {
            try orchestrator.focusWorkspaceWindow(workspaceID: selectedWorkspaceID, index: index)
        } catch {
            showError(error)
        }
    }

    private func windowShortcutIndex(for event: NSEvent) -> Int? {
        guard event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.shift),
            !event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.control)
        else {
            return nil
        }
        let keyMap: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 1,
            UInt16(kVK_ANSI_2): 2,
            UInt16(kVK_ANSI_3): 3,
            UInt16(kVK_ANSI_4): 4,
            UInt16(kVK_ANSI_5): 5,
            UInt16(kVK_ANSI_6): 6,
            UInt16(kVK_ANSI_7): 7,
            UInt16(kVK_ANSI_8): 8,
            UInt16(kVK_ANSI_9): 9,
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
        } catch {
            showError(error)
        }
    }

    private func globalWindowNavigationWorkspaceID() -> String? {
        if let workspaceID = try? orchestrator.workspaceIDForFocusedWindow() {
            return workspaceID
        }
        if let workspaceID = try? orchestrator.activeWorkspaceID() {
            return workspaceID
        }
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
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if selectedWorkspaceID != nil {
            refreshSelection()
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return projects.count
        }
        if case .project(let project) = item as? OutlineItem {
            return workspacesByProject[project.id]?.count ?? 0
        }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .project = item as? OutlineItem {
            return true
        }
        return false
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return OutlineItem.project(projects[index])
        }
        if case .project(let project) = item as? OutlineItem {
            let workspace =
                workspacesByProject[project.id]?[index]
                ?? WorkspaceSummary(
                    id: "",
                    name: "",
                    branch: nil,
                    dir: "",
                    isRunning: false,
                    isArchived: false,
                    isDefault: false
                )
            return OutlineItem.workspace(project, workspace)
        }
        return OutlineItem.project(projects[0])
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if case .project(let project) = item as? OutlineItem {
            return projectRowCell(project: project)
        }
        if case .workspace(_, let workspace) = item as? OutlineItem {
            return workspaceRowCell(workspace: workspace)
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
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 10),
            icon.heightAnchor.constraint(equalToConstant: 10),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            accessoryStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            accessoryStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if project.isGitRepo {
            let addButton = sidebarRowIconButton(
                symbol: "plus",
                tooltip: "New workspace in \(project.name)",
                action: #selector(addWorkspace(_:))
            )
            addButton.identifier = NSUserInterfaceItemIdentifier(project.id)
            accessoryStack.addArrangedSubview(addButton)
        }
        return cell
    }

    private func workspaceRowCell(workspace: WorkspaceSummary) -> NSTableCellView {
        let cell = NSTableCellView()
        let statusIcon = NSImageView()
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.image = NSImage(
            systemSymbolName: workspace.isRunning ? "circle.fill" : "circle",
            accessibilityDescription: "Status"
        )
        statusIcon.contentTintColor = workspace.isRunning ? .systemGreen : .tertiaryLabelColor

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: workspace.name)
        nameLabel.font = .systemFont(ofSize: 12)
        if workspace.isArchived {
            nameLabel.textColor = .secondaryLabelColor
        }
        textStack.addArrangedSubview(nameLabel)

        if let branch = workspace.branch, !branch.isEmpty {
            let branchRow = NSStackView()
            branchRow.orientation = .horizontal
            branchRow.alignment = .centerY
            branchRow.spacing = 4

            let branchIcon = NSImageView()
            branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")
            branchIcon.contentTintColor = .secondaryLabelColor
            branchIcon.translatesAutoresizingMaskIntoConstraints = false
            branchIcon.widthAnchor.constraint(equalToConstant: 10).isActive = true
            branchIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true

            let branchLabel = NSTextField(labelWithString: branch)
            branchLabel.font = .systemFont(ofSize: 11)
            branchLabel.textColor = .secondaryLabelColor

            branchRow.addArrangedSubview(branchIcon)
            branchRow.addArrangedSubview(branchLabel)
            textStack.addArrangedSubview(branchRow)
        }

        cell.addSubview(statusIcon)
        cell.addSubview(textStack)
        NSLayoutConstraint.activate([
            statusIcon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            statusIcon.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            statusIcon.widthAnchor.constraint(equalToConstant: 10),
            statusIcon.heightAnchor.constraint(equalToConstant: 10),
            textStack.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 6),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            textStack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            textStack.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
        ])
        return cell
    }

    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .workspace = item as? OutlineItem {
            return 36
        }
        return 24
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
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
        setupView: NSTextView,
        stopView: NSTextView,
        processEditor: ProcessEditor,
        browserView: NSTextView,
        statusEditor: StatusCheckEditor
    ) {
        projectHasUnsavedChanges = false
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: setupView, queue: .main) {
            [weak self] _ in
            Task { @MainActor in
                self?.projectHasUnsavedChanges = true
            }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: stopView, queue: .main)
        { [weak self] _ in
            Task { @MainActor in
                self?.projectHasUnsavedChanges = true
            }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: browserView, queue: .main)
        { [weak self] _ in
            Task { @MainActor in
                self?.projectHasUnsavedChanges = true
            }
        }
        processEditor.onDirty = { [weak self] in
            Task { @MainActor in
                self?.projectHasUnsavedChanges = true
                statusEditor.refreshProcessOptions()
            }
        }
        statusEditor.onDirty = { [weak self] in
            Task { @MainActor in
                self?.projectHasUnsavedChanges = true
            }
        }
    }

    private func registerWorkspaceDirtyTracking(
        stopView: NSTextView,
        processEditor: ProcessEditor,
        browserView: NSTextView,
        statusEditor: StatusCheckEditor
    ) {
        workspaceHasUnsavedChanges = false
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: stopView, queue: .main)
        { [weak self] _ in
            Task { @MainActor in
                self?.workspaceHasUnsavedChanges = true
            }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: browserView, queue: .main)
        { [weak self] _ in
            Task { @MainActor in
                self?.workspaceHasUnsavedChanges = true
            }
        }
        processEditor.onDirty = { [weak self] in
            Task { @MainActor in
                self?.workspaceHasUnsavedChanges = true
                statusEditor.refreshProcessOptions()
            }
        }
        statusEditor.onDirty = { [weak self] in
            Task { @MainActor in
                self?.workspaceHasUnsavedChanges = true
            }
        }
    }

    private func saveCurrentDetail() -> Bool {
        if selectedWorkspaceID != nil {
            return saveCurrentWorkspace()
        }
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
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = parseBrowserSessions(refs.browserView.string)
                config.statusChecks = refs.statusEditor.currentChecks()
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
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = parseBrowserSessions(refs.browserView.string)
                config.statusChecks = refs.statusEditor.currentChecks()
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
