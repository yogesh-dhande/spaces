import AppKit
import Carbon
import Foundation
import streamctl

@MainActor
public final class AppKitController: NSObject, NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private var window: NSWindow!
    private let outlineView = NSOutlineView()
    private let detailContainer = NSView()

    private var orchestrator: AgentmuxOrchestrator!
    private var projects: [ProjectSummary] = []
    private var workspacesByProject: [String: [WorkspaceSummary]] = [:]

    private var selectedProjectID: String?
    private var selectedWorkspaceID: String?
    private var lastSelectedRow: Int = -1
    private var projectHasUnsavedChanges = false

    private var hotkeyHandler: EventHandlerRef?
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var registeredHotkey: HotkeySpec?
    private var shortcutMonitor: Any?
    private var nextShortcutSpec: HotkeySpec?
    private var previousShortcutSpec: HotkeySpec?
    private var activateShortcutSpec: HotkeySpec?

    private var configCache: AppConfig?

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

    private enum GlobalHotkey: UInt32 {
        case toggle = 1
        case next = 2
        case previous = 3
    }

    private enum OutlineItem {
        case project(ProjectSummary)
        case workspace(ProjectSummary, WorkspaceSummary)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try DatabaseLocator.defaultPath()
            let configPath = try ConfigStore.defaultPath()
            let store = try SQLiteStore(path: db)
            let configStore = ConfigStore(path: configPath)
            orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)
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
        window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.title = "agentmux"
        window.center()

        let splitView = NSSplitView()
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let leftPane = makeLeftPane()
        let rightPane = makeRightPane()

        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)
        splitView.setPosition(320, ofDividerAt: 0)

        let content = NSView()
        content.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    private func makeLeftPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Projects")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        let addButton = actionButton(title: "Add Project", symbol: "plus", tooltip: "Add project", action: #selector(addProject), primary: false)

        let reloadButton = iconButton(symbol: "arrow.clockwise", tooltip: "Reload", action: #selector(reloadTapped))

        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(reloadButton)
        header.addArrangedSubview(addButton)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Projects"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.selectionHighlightStyle = .regular

        scroll.documentView = outlineView

        container.addSubview(header)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
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
            placeholder.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor)
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
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let placeholder = NSTextField(labelWithString: "Select a project or workspace.")
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor)
        ])
    }

    private func showProjectDetail(project: ProjectSummary) {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
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
            tooltip: "New workspace for \(project.name) (⌘N)",
            action: #selector(addWorkspaceFromToolbar),
            primary: false
        )
        addWorkspaceButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        headerRow.addArrangedSubview(header)
        headerRow.addArrangedSubview(NSView())
        headerRow.addArrangedSubview(addWorkspaceButton)

        let dirLabel = labeledValue(title: "Directory", value: project.dir)

        let setupView = makeEditableTextView()
        let cleanupView = makeEditableTextView()

        let processEditor = ProcessEditor()
        let browserView = makeEditableTextView()
        let browserScroll = scrollableTextView(browserView, height: 80)

        let statusEditor = StatusCheckEditor(processNamesProvider: { processEditor.processNames() })
        statusEditor.setChecks([])

        if let config = configCache?.projects.first(where: { normalizePath($0.dir) == project.dir }) {
            setupView.string = config.setupScript ?? ""
            cleanupView.string = config.cleanupScript ?? ""
            processEditor.setProcesses(config.processes)
            browserView.string = config.browserSessions.compactMap { $0.url }.joined(separator: "\n")
            statusEditor.setChecks(config.statusChecks)
        }

        let saveButton = actionButton(title: "Save Project", symbol: "square.and.arrow.down", tooltip: "Save project (⌘S)", action: #selector(saveProject(_:)), primary: true)
        saveButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        saveButton.keyEquivalent = "\r"

        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(dirLabel)
        stack.addArrangedSubview(label(text: "Setup script"))
        stack.addArrangedSubview(scrollableTextView(setupView, height: 90))
        stack.addArrangedSubview(label(text: "Cleanup script"))
        stack.addArrangedSubview(scrollableTextView(cleanupView, height: 90))
        stack.addArrangedSubview(label(text: "Processes"))
        stack.addArrangedSubview(processEditor.container)
        stack.addArrangedSubview(label(text: "Browser sessions (URL per line)"))
        stack.addArrangedSubview(browserScroll)
        stack.addArrangedSubview(label(text: "Status checks (per process)"))
        stack.addArrangedSubview(statusEditor.container)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 20)
        ])

        saveButton.tag = storeProjectFields(
            projectID: project.id,
            setupView: setupView,
            cleanupView: cleanupView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
        registerDirtyTracking(
            setupView: setupView,
            cleanupView: cleanupView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
    }

    private func showAddProjectForm() {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "New Project")
        header.font = .systemFont(ofSize: 20, weight: .semibold)

        let dirField = NSTextField(string: "")
        dirField.isEditable = false
        dirField.placeholderString = "Choose a project directory"
        let browseButton = NSButton(title: "", target: self, action: #selector(browseProjectDir(_:)))
        browseButton.bezelStyle = .texturedRounded
        browseButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose directory")
        browseButton.toolTip = "Choose directory"

        let setupView = makeEditableTextView()
        let cleanupView = makeEditableTextView()

        let processEditor = ProcessEditor()

        let browserView = makeEditableTextView()
        let browserScroll = scrollableTextView(browserView, height: 80)

        let statusEditor = StatusCheckEditor(processNamesProvider: { processEditor.processNames() })
        statusEditor.setChecks([])

        let createButton = iconButton(symbol: "checkmark.circle", tooltip: "Create project", action: #selector(createProject(_:)))

        let cancelButton = iconButton(symbol: "xmark.circle", tooltip: "Cancel", action: #selector(cancelProjectForm))

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(label(text: "Project directory"))
        let dirRow = NSStackView()
        dirRow.orientation = .horizontal
        dirRow.spacing = 8
        dirField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browseButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        dirRow.addArrangedSubview(dirField)
        dirRow.addArrangedSubview(browseButton)
        stack.addArrangedSubview(dirRow)
        stack.addArrangedSubview(label(text: "Setup script"))
        stack.addArrangedSubview(scrollableTextView(setupView, height: 90))
        stack.addArrangedSubview(label(text: "Cleanup script"))
        stack.addArrangedSubview(scrollableTextView(cleanupView, height: 90))
        stack.addArrangedSubview(label(text: "Processes"))
        stack.addArrangedSubview(processEditor.container)
        stack.addArrangedSubview(label(text: "Browser sessions (URL per line)"))
        stack.addArrangedSubview(browserScroll)
        stack.addArrangedSubview(label(text: "Status checks (per process)"))
        stack.addArrangedSubview(statusEditor.container)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(createButton)
        stack.addArrangedSubview(buttonRow)

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 20)
        ])

        createButton.tag = storeAddProjectFields(
            dirField: dirField,
            setupView: setupView,
            cleanupView: cleanupView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor,
            browseButton: browseButton
        )
    }

    private func showAddWorkspaceForm(project: ProjectSummary) {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "New Workspace for \(project.name)")
        header.font = .systemFont(ofSize: 20, weight: .semibold)
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "workspace name"

        let createButton = iconButton(symbol: "checkmark.circle", tooltip: "Create workspace", action: #selector(createWorkspace(_:)))
        let cancelButton = iconButton(symbol: "xmark.circle", tooltip: "Cancel", action: #selector(cancelProjectForm))

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(label(text: "Workspace name (branch name for git)"))
        stack.addArrangedSubview(nameField)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(createButton)
        stack.addArrangedSubview(buttonRow)

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 20)
        ])

        createButton.tag = storeAddWorkspaceFields(projectID: project.id, nameField: nameField)
    }

    private func showWorkspaceDetail(project: ProjectSummary, workspace: WorkspaceSummary) {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "\(project.name) / \(workspace.name)")
        header.font = .systemFont(ofSize: 20, weight: .semibold)

        let dirLabel = labeledValue(title: "Directory", value: workspace.dir)
        let statusLabel = statusRow(isRunning: workspace.isRunning)

        let launchButton = actionButton(title: "Launch (⌘L)", symbol: "play.circle", tooltip: "Launch", action: #selector(launchWorkspace(_:)), primary: false)
        launchButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        let stopButton = actionButton(title: "Stop (⌘.)", symbol: "stop.circle", tooltip: "Stop", action: #selector(stopWorkspace(_:)), primary: false)
        stopButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        let archiveButton = actionButton(title: "Archive", symbol: "archivebox", tooltip: "Archive", action: #selector(archiveWorkspace(_:)), primary: false)
        archiveButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        archiveButton.isEnabled = !workspace.isDefault

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(launchButton)
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
        tabs.addTabViewItem(runTab)
        tabs.addTabViewItem(envTab)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(dirLabel)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(tabs)

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 20),
            tabs.heightAnchor.constraint(equalToConstant: 320),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func workspaceRunView(workspace: WorkspaceSummary) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let processesLabel = label(text: "Running processes")
        let windowsLabel = label(text: "Windows (cmd+shift+<n>)")

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
            let title = win.title ?? win.app
            return "cmd+shift+\(idx + 1)  \(win.app) — \(title)"
        }.joined(separator: "\n")
        let windowsScroll = scrollableTextView(windowsList, height: 120)

        container.addArrangedSubview(processesLabel)
        container.addArrangedSubview(processScroll)
        container.addArrangedSubview(windowsLabel)
        container.addArrangedSubview(windowsScroll)
        return insetContainerView(container)
    }

    private func workspaceEnvView(project: ProjectSummary, workspace: WorkspaceSummary) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
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
        lines.append("agentmux_WORKSPACE_DIR=\(workspace.dir)")
        let scopedKey = "agentmux_\(sanitizeEnvKey(project.name))_\(sanitizeEnvKey(workspace.name))_WORKSPACE_DIR"
        lines.append("\(scopedKey)=\(workspace.dir)")
        envView.string = lines.joined(separator: "\n")
        let scroll = scrollableTextView(envView, height: 240)
        container.addArrangedSubview(scroll)
        return insetContainerView(container)
    }

    private func label(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
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

    private func scrollableTextView(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
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
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset)
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
        cleanupView: NSTextView,
        processEditor: ProcessEditor,
        browserView: NSTextView,
        statusEditor: StatusCheckEditor
    ) -> Int {
        let id = projectID.hashValue
        ProjectFieldCache.shared.cache[id] = ProjectFieldRefs(
            projectID: projectID,
            setupView: setupView,
            cleanupView: cleanupView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
        return id
    }

    private func storeAddProjectFields(
        dirField: NSTextField,
        setupView: NSTextView,
        cleanupView: NSTextView,
        processEditor: ProcessEditor,
        browserView: NSTextView,
        statusEditor: StatusCheckEditor,
        browseButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddProjectFieldCache.shared.cache[id] = AddProjectFieldRefs(
            dirField: dirField,
            setupView: setupView,
            cleanupView: cleanupView,
            processEditor: processEditor,
            browserView: browserView,
            statusEditor: statusEditor
        )
        browseButton.tag = id
        return id
    }

    private func storeAddWorkspaceFields(projectID: String, nameField: NSTextField) -> Int {
        let id = UUID().uuidString.hashValue
        AddWorkspaceFieldCache.shared.cache[id] = AddWorkspaceFieldRefs(projectID: projectID, nameField: nameField)
        return id
    }

    @objc private func reloadTapped() {
        reloadData()
    }

    @objc private func addProject() {
        showAddProjectForm()
    }

    @objc private func addWorkspace(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue,
              let project = projects.first(where: { $0.id == projectID }) else { return }
        showAddWorkspaceForm(project: project)
    }

    @objc private func addWorkspaceFromToolbar(_ sender: NSButton) {
        if let projectID = sender.identifier?.rawValue,
           let project = projects.first(where: { $0.id == projectID }) {
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
        guard let refs = ProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            try orchestrator.updateProjectConfig(projectID: refs.projectID) { config in
                config.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
                config.cleanupScript = refs.cleanupView.string.isEmpty ? nil : refs.cleanupView.string
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

    @objc private func createProject(_ sender: NSButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            let dir = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dir.isEmpty else { return }
            let record = try orchestrator.addProject(dir: dir)
            var config = ProjectConfig(dir: record.dir)
            config.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
            config.cleanupScript = refs.cleanupView.string.isEmpty ? nil : refs.cleanupView.string
            config.processes = refs.processEditor.currentProcesses()
            config.browserSessions = parseBrowserSessions(refs.browserView.string)
            config.statusChecks = refs.statusEditor.currentChecks()
            try orchestrator.updateProjectConfig(config)
            reloadData()
        } catch {
            showError(error)
        }
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
            }
        }
    }

    @objc private func createWorkspace(_ sender: NSButton) {
        guard let refs = AddWorkspaceFieldCache.shared.cache[sender.tag] else { return }
        do {
            let name = refs.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            _ = try orchestrator.createWorkspace(projectID: refs.projectID, name: name)
            reloadData()
        } catch {
            showError(error)
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

    private func findWorkspace(id: String) -> (ProjectSummary, WorkspaceSummary)? {
        for project in projects {
            if let workspaces = workspacesByProject[project.id],
               let workspace = workspaces.first(where: { $0.id == id }) {
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
        do {
            let raw = try orchestrator.guiHotkey()
            let spec = try HotkeySpec.parse(raw)
            registerHotkeys(toggle: spec, next: nextShortcutSpec, previous: previousShortcutSpec)
        } catch {
            showError(error)
        }
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
        let handlerStatus = InstallEventHandler(
            target,
            hotkeyHandlerProc,
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotkeyHandler
        )
        if handlerStatus == noErr {
            registeredHotkey = toggle
        }
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
            if event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "n" {
                self.addWorkspaceFromShortcut()
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
        do {
            nextShortcutSpec = try HotkeySpec.parse(orchestrator.guiNextShortcut())
            previousShortcutSpec = try HotkeySpec.parse(orchestrator.guiPreviousShortcut())
            activateShortcutSpec = try HotkeySpec.parse(orchestrator.guiShowShortcut())
        } catch {
            nextShortcutSpec = nil
            previousShortcutSpec = nil
            activateShortcutSpec = nil
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
           let idx = running.firstIndex(where: { $0.id == selectedWorkspaceID }) {
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
           let idx = running.firstIndex(where: { $0.id == selectedWorkspaceID }) {
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
              event.modifierFlags.contains(.shift),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control) else {
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
            UInt16(kVK_ANSI_9): 9
        ]
        return keyMap[event.keyCode]
    }

    private func selectWorkspace(_ workspace: WorkspaceSummary) {
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? OutlineItem {
                if case let .workspace(_, ws) = item, ws.id == workspace.id {
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
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return projects.count
        }
        if case let .project(project) = item as? OutlineItem {
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
        if case let .project(project) = item as? OutlineItem {
            let workspace = workspacesByProject[project.id]?[index] ?? WorkspaceSummary(id: "", name: "", dir: "", isRunning: false, isArchived: false, isDefault: false)
            return OutlineItem.workspace(project, workspace)
        }
        return OutlineItem.project(projects[0])
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 10),
            icon.heightAnchor.constraint(equalToConstant: 10),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        if case let .project(project) = item as? OutlineItem {
            icon.image = nil
            text.stringValue = project.name
            text.font = .systemFont(ofSize: 13, weight: .semibold)
        } else if case let .workspace(_, workspace) = item as? OutlineItem {
            icon.image = NSImage(systemSymbolName: workspace.isRunning ? "circle.fill" : "circle", accessibilityDescription: "Status")
            icon.contentTintColor = workspace.isRunning ? .systemGreen : .tertiaryLabelColor
            text.stringValue = workspace.name
            text.font = .systemFont(ofSize: 12)
            if workspace.isArchived {
                text.textColor = .secondaryLabelColor
            }
        }
        return cell
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        if projectHasUnsavedChanges {
            let response = unsavedChangesPrompt()
            if response == .alertFirstButtonReturn {
                if !saveCurrentProject() {
                    outlineView.selectRowIndexes(IndexSet(integer: lastSelectedRow), byExtendingSelection: false)
                    return
                }
            } else if response == .alertThirdButtonReturn {
                outlineView.selectRowIndexes(IndexSet(integer: lastSelectedRow), byExtendingSelection: false)
                return
            } else {
                projectHasUnsavedChanges = false
            }
        }
        guard row >= 0, let item = outlineView.item(atRow: row) as? OutlineItem else {
            selectedProjectID = nil
            selectedWorkspaceID = nil
            showPlaceholder()
            return
        }
        lastSelectedRow = row
        switch item {
        case let .project(project):
            selectedProjectID = project.id
            selectedWorkspaceID = nil
            showProjectDetail(project: project)
        case let .workspace(project, workspace):
            selectedProjectID = project.id
            selectedWorkspaceID = workspace.id
            showWorkspaceDetail(project: project, workspace: workspace)
        }
    }

    private func registerDirtyTracking(
        setupView: NSTextView,
        cleanupView: NSTextView,
        processEditor: ProcessEditor,
        browserView: NSTextView,
        statusEditor: StatusCheckEditor
    ) {
        projectHasUnsavedChanges = false
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: setupView, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.projectHasUnsavedChanges = true
            }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: cleanupView, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.projectHasUnsavedChanges = true
            }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: browserView, queue: .main) { [weak self] _ in
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

    private func saveCurrentProject() -> Bool {
        guard let selectedProjectID else { return true }
        let tag = selectedProjectID.hashValue
        guard let refs = ProjectFieldCache.shared.cache[tag] else { return true }
        do {
            try orchestrator.updateProjectConfig(projectID: refs.projectID) { config in
                config.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
                config.cleanupScript = refs.cleanupView.string.isEmpty ? nil : refs.cleanupView.string
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
}

@MainActor
private final class ProjectFieldCache {
    static let shared = ProjectFieldCache()
    var cache: [Int: ProjectFieldRefs] = [:]
}

private struct ProjectFieldRefs {
    let projectID: String
    let setupView: NSTextView
    let cleanupView: NSTextView
    let processEditor: ProcessEditor
    let browserView: NSTextView
    let statusEditor: StatusCheckEditor
}

@MainActor
private final class AddProjectFieldCache {
    static let shared = AddProjectFieldCache()
    var cache: [Int: AddProjectFieldRefs] = [:]
}

private struct AddProjectFieldRefs {
    let dirField: NSTextField
    let setupView: NSTextView
    let cleanupView: NSTextView
    let processEditor: ProcessEditor
    let browserView: NSTextView
    let statusEditor: StatusCheckEditor
}

@MainActor
private final class AddWorkspaceFieldCache {
    static let shared = AddWorkspaceFieldCache()
    var cache: [Int: AddWorkspaceFieldRefs] = [:]
}

private struct AddWorkspaceFieldRefs {
    let projectID: String
    let nameField: NSTextField
}

@MainActor
private func makeFieldHeader(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    return label
}

@MainActor
private final class ProcessEditor {
    let container = NSStackView()
    private let rowsStack = NSStackView()
    private let addButton: NSButton
    private var rows: [ProcessRowRefs] = []
    var onDirty: (() -> Void)?

    init() {
        container.orientation = .vertical
        container.spacing = 8
        rowsStack.orientation = .vertical
        rowsStack.spacing = 6
        addButton = NSButton(title: "", target: nil, action: nil)
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Process")
        addButton.toolTip = "Add process"
        addButton.target = self
        addButton.action = #selector(addRowFromButton)
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        let nameHeader = makeFieldHeader("Name")
        let commandHeader = makeFieldHeader("Command")
        header.addArrangedSubview(nameHeader)
        header.addArrangedSubview(commandHeader)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(addButton)
        nameHeader.widthAnchor.constraint(equalToConstant: 160).isActive = true
        commandHeader.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandHeader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(header)
        container.addArrangedSubview(rowsStack)
        addRow(with: nil)
    }

    func setProcesses(_ processes: [ProcessTemplate]) {
        rows.forEach { $0.remove() }
        rows = []
        for process in processes {
            addRow(with: process)
        }
        if processes.isEmpty {
            addRow(with: nil)
        }
    }

    func currentProcesses() -> [ProcessTemplate] {
        rows.compactMap { row in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = row.commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return nil }
            return ProcessTemplate(name: name.isEmpty ? nil : name, command: command)
        }
    }

    func processNames() -> [String] {
        let names = rows.compactMap { row -> String? in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return Array(Set(names)).sorted()
    }

    private func addRow(with process: ProcessTemplate?) {
        let row = ProcessRowRefs()
        rows.append(row)
        rowsStack.addArrangedSubview(row.container)
        if let process {
            row.nameField.stringValue = process.name ?? ""
            row.commandField.stringValue = process.command
        }
        row.onChange = { [weak self] in
            self?.onDirty?()
        }
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            if let idx = self.rows.firstIndex(where: { $0 === row }) {
                self.rows.remove(at: idx)
            }
            row.remove()
            self.onDirty?()
        }
        onDirty?()
    }

    @objc private func addRowFromButton() {
        addRow(with: nil)
    }

    @MainActor
    private final class ProcessRowRefs {
        let container = NSStackView()
        let nameField = NSTextField(string: "")
        let commandField = NSTextField(string: "")
        var onRemove: (() -> Void)?
        var onChange: (() -> Void)?

        init() {
            container.orientation = .horizontal
            container.spacing = 6
            container.alignment = .centerY

            nameField.placeholderString = "name"
            commandField.placeholderString = "command"

            let removeButton = NSButton(title: "", target: self, action: #selector(removeRow))
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Process")
            removeButton.toolTip = "Remove process"

            container.addArrangedSubview(nameField)
            container.addArrangedSubview(commandField)
            container.addArrangedSubview(removeButton)

            nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
            commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            commandField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            [nameField, commandField].forEach { field in
                NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification,
                    object: field,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.onChange?()
                    }
                }
            }
        }

        func remove() {
            container.removeFromSuperview()
        }

        @objc private func removeRow() {
            onRemove?()
        }
    }
}

@MainActor
private final class StatusCheckEditor {
    let container = NSStackView()
    private let rowsStack = NSStackView()
    private let addButton: NSButton
    private var rows: [StatusCheckRowRefs] = []
    var onDirty: (() -> Void)?
    private let processNamesProvider: () -> [String]

    init(processNamesProvider: @escaping () -> [String]) {
        self.processNamesProvider = processNamesProvider
        container.orientation = .vertical
        container.spacing = 8
        rowsStack.orientation = .vertical
        rowsStack.spacing = 6
        addButton = NSButton(title: "", target: nil, action: nil)
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Status Check")
        addButton.toolTip = "Add status check"
        addButton.target = self
        addButton.action = #selector(addRowFromButton)
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        let nameHeader = makeFieldHeader("Name")
        let processHeader = makeFieldHeader("Process")
        let commandHeader = makeFieldHeader("Command")
        let intervalHeader = makeFieldHeader("Interval")
        let timeoutHeader = makeFieldHeader("Timeout")
        let onExitHeader = makeFieldHeader("On Exit")
        header.addArrangedSubview(nameHeader)
        header.addArrangedSubview(processHeader)
        header.addArrangedSubview(commandHeader)
        header.addArrangedSubview(intervalHeader)
        header.addArrangedSubview(timeoutHeader)
        header.addArrangedSubview(onExitHeader)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(addButton)
        nameHeader.widthAnchor.constraint(equalToConstant: 120).isActive = true
        processHeader.widthAnchor.constraint(equalToConstant: 140).isActive = true
        intervalHeader.widthAnchor.constraint(equalToConstant: 70).isActive = true
        timeoutHeader.widthAnchor.constraint(equalToConstant: 70).isActive = true
        onExitHeader.widthAnchor.constraint(equalToConstant: 90).isActive = true
        commandHeader.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandHeader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(header)
        container.addArrangedSubview(rowsStack)
    }

    func setChecks(_ checks: [StatusCheckDefinition]) {
        rows.forEach { $0.remove() }
        rows = []
        for check in checks {
            addRow(with: check)
        }
        if checks.isEmpty {
            addRow(with: nil)
        }
    }

    func refreshProcessOptions() {
        let names = processNamesProvider()
        for row in rows {
            row.refreshProcessOptions(names: names)
        }
    }

    func currentChecks() -> [StatusCheckDefinition] {
        rows.compactMap { row in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let process = row.processPopup.titleOfSelectedItem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let command = row.commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let interval = Int(row.intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 60
            let timeout = Int(row.timeoutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5
            let onExit = StatusCheckOnExit(rawValue: row.onExitPopup.titleOfSelectedItem ?? "") ?? .none
            guard !process.isEmpty, !command.isEmpty else { return nil }
            return StatusCheckDefinition(
                name: name.isEmpty ? nil : name,
                process: process,
                command: command,
                interval: interval,
                timeout: timeout,
                onExit: onExit
            )
        }
    }

    private func addRow(with check: StatusCheckDefinition?) {
        let row = StatusCheckRowRefs(processNames: processNamesProvider())
        rows.append(row)
        rowsStack.addArrangedSubview(row.container)
        if let check {
            row.nameField.stringValue = check.name ?? ""
            row.commandField.stringValue = check.command
            row.intervalField.stringValue = String(check.interval)
            row.timeoutField.stringValue = String(check.timeout)
            row.onExitPopup.selectItem(withTitle: check.onExit.rawValue)
            if row.processPopup.item(withTitle: check.process) == nil {
                row.processPopup.addItem(withTitle: check.process)
            }
            row.processPopup.selectItem(withTitle: check.process)
        }
        row.onChange = { [weak self] in
            self?.onDirty?()
        }
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            if let idx = self.rows.firstIndex(where: { $0 === row }) {
                self.rows.remove(at: idx)
            }
            row.remove()
            self.onDirty?()
        }
        onDirty?()
    }

    @objc private func addRowFromButton() {
        addRow(with: nil)
    }

    private func processNames() -> [String] {
        let names = processNamesProvider()
        return names.isEmpty ? ["process"] : names
    }

    @MainActor
    private final class StatusCheckRowRefs {
        let container = NSStackView()
        let nameField = NSTextField(string: "")
        let processPopup = NSPopUpButton()
        let commandField = NSTextField(string: "")
        let intervalField = NSTextField(string: "60")
        let timeoutField = NSTextField(string: "5")
        let onExitPopup = NSPopUpButton()
        var onRemove: (() -> Void)?
        var onChange: (() -> Void)?

        init(processNames: [String]) {
            container.orientation = .horizontal
            container.spacing = 6
            container.alignment = .centerY

            nameField.placeholderString = "name"
            commandField.placeholderString = "command"
            intervalField.placeholderString = "interval"
            timeoutField.placeholderString = "timeout"

            processPopup.addItems(withTitles: processNames)
            onExitPopup.addItems(withTitles: StatusCheckOnExit.allCases.map { $0.rawValue })

            let removeButton = NSButton(title: "", target: self, action: #selector(removeRow))
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Status Check")
            removeButton.toolTip = "Remove status check"

            container.addArrangedSubview(nameField)
            container.addArrangedSubview(processPopup)
            container.addArrangedSubview(commandField)
            container.addArrangedSubview(intervalField)
            container.addArrangedSubview(timeoutField)
            container.addArrangedSubview(onExitPopup)
            container.addArrangedSubview(removeButton)

            nameField.widthAnchor.constraint(equalToConstant: 120).isActive = true
            processPopup.widthAnchor.constraint(equalToConstant: 140).isActive = true
            intervalField.widthAnchor.constraint(equalToConstant: 70).isActive = true
            timeoutField.widthAnchor.constraint(equalToConstant: 70).isActive = true
            onExitPopup.widthAnchor.constraint(equalToConstant: 90).isActive = true
            commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            commandField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            [nameField, commandField, intervalField, timeoutField].forEach { field in
                NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification,
                    object: field,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.onChange?()
                    }
                }
            }
            processPopup.target = self
            processPopup.action = #selector(changedPopup)
            onExitPopup.target = self
            onExitPopup.action = #selector(changedPopup)
        }

        func refreshProcessOptions(names: [String]) {
            let current = processPopup.titleOfSelectedItem
            processPopup.removeAllItems()
            processPopup.addItems(withTitles: names.isEmpty ? ["process"] : names)
            if let current, processPopup.item(withTitle: current) != nil {
                processPopup.selectItem(withTitle: current)
            }
        }

        func remove() {
            container.removeFromSuperview()
        }

        @objc private func removeRow() {
            onRemove?()
        }

        @objc private func changedPopup() {
            onChange?()
        }
    }
}
