import AppKit
import Foundation
import streamctl

@MainActor
public final class AppKitController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private final class ProjectEditorContext {
        let projectName: String
        let windowPicker: NSPopUpButton
        let addWindowButton: NSButton

        init(projectName: String, windowPicker: NSPopUpButton, addWindowButton: NSButton) {
            self.projectName = projectName
            self.windowPicker = windowPicker
            self.addWindowButton = addWindowButton
        }
    }

    private var window: NSWindow!

    private let projectTable = NSTableView()
    private let streamTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var projects: [Project] = []
    private var streams: [StreamSummary] = []

    private var selectedProjectName: String?
    private var selectedStreamName: String?
    private var projectEditorContext: ProjectEditorContext?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
        reloadProjects()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == projectTable { return projects.count }
        return streams.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView == projectTable {
            let project = projects[row]
            text = "\(project.name)  (\(project.repoRoot))"
        } else {
            let stream = streams[row]
            let marker = stream.isActive ? "●" : "○"
            text = "\(marker) \(stream.name)  (\(stream.worktreePath))"
        }

        let id = NSUserInterfaceItemIdentifier("Cell")
        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell.textField?.stringValue = text
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: text)
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView == projectTable {
            let idx = projectTable.selectedRow
            if idx >= 0 && idx < projects.count {
                selectedProjectName = projects[idx].name
            } else {
                selectedProjectName = nil
            }
            reloadStreams()
        } else if notification.object as? NSTableView == streamTable {
            let idx = streamTable.selectedRow
            if idx >= 0 && idx < streams.count {
                selectedStreamName = streams[idx].name
            } else {
                selectedStreamName = nil
            }
        }
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "agentmux"

        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin

        let left = makeProjectsPane()
        let right = makeStreamsPane()
        split.addSubview(left)
        split.addSubview(right)
        split.setPosition(480, ofDividerAt: 0)

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        root.addSubview(statusLabel)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            statusLabel.heightAnchor.constraint(equalToConstant: 20)
        ])

        window.contentView = root
        window.makeKeyAndOrderFront(nil)
    }

    private func makeProjectsPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Projects")
        header.font = .boldSystemFont(ofSize: 14)
        header.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [
            makeButton(title: "Add", action: #selector(addProjectClicked)),
            makeButton(title: "Edit", action: #selector(editProjectClicked)),
            makeButton(title: "Delete", action: #selector(deleteProjectClicked)),
            makeButton(title: "Refresh", action: #selector(refreshProjectsClicked))
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project-col"))
        col.title = "Project"
        projectTable.addTableColumn(col)
        projectTable.headerView = nil
        projectTable.delegate = self
        projectTable.dataSource = self

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = projectTable
        scroll.hasVerticalScroller = true

        container.addSubview(header)
        container.addSubview(buttons)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),

            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            buttons.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        return container
    }

    private func makeStreamsPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Streams")
        header.font = .boldSystemFont(ofSize: 14)
        header.translatesAutoresizingMaskIntoConstraints = false

        let row1 = NSStackView(views: [
            makeButton(title: "Add", action: #selector(addStreamClicked)),
            makeButton(title: "Destroy", action: #selector(destroyStreamClicked)),
            makeButton(title: "Refresh", action: #selector(refreshStreamsClicked))
        ])
        row1.orientation = .horizontal
        row1.spacing = 8
        row1.translatesAutoresizingMaskIntoConstraints = false

        let row2 = NSStackView(views: [
            makeButton(title: "Show", action: #selector(showStreamClicked)),
            makeButton(title: "Hide", action: #selector(hideStreamClicked)),
            makeButton(title: "Focus", action: #selector(focusStreamClicked)),
            makeButton(title: "Doctor", action: #selector(doctorStreamClicked))
        ])
        row2.orientation = .horizontal
        row2.spacing = 8
        row2.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("stream-col"))
        col.title = "Stream"
        streamTable.addTableColumn(col)
        streamTable.headerView = nil
        streamTable.delegate = self
        streamTable.dataSource = self

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = streamTable
        scroll.hasVerticalScroller = true

        container.addSubview(header)
        container.addSubview(row1)
        container.addSubview(row2)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),

            row1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            row1.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),

            row2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            row2.topAnchor.constraint(equalTo: row1.bottomAnchor, constant: 8),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: row2.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        return container
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func refreshProjectsClicked() { reloadProjects() }
    @objc private func refreshStreamsClicked() { reloadStreams() }

    @objc private func addProjectClicked() {
        let name = NSTextField(string: "")
        let repo = NSTextField(string: FileManager.default.currentDirectoryPath)
        guard runModalForm(
            title: "Add Project",
            message: "Create a new project",
            fields: [
                ("Name", name),
                ("Repo Root", repo)
            ]
        ) else {
            return
        }

        do {
            _ = try orchestrator().createProject(
                name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                repoRoot: repo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                editor: nil,
                browser: nil,
                terminal: nil,
                editorDisplay: nil,
                editorTile: nil,
                browserDisplay: nil,
                browserTile: nil,
                browserTabs: []
            )
            reloadProjects(selectProject: name.stringValue)
            setStatus("Created project '\(name.stringValue)'.")
        } catch {
            setStatus("Create project failed: \(error.localizedDescription)")
        }
    }

    @objc private func editProjectClicked() {
        guard let project = selectedProject() else {
            setStatus("Select a project first.")
            return
        }

        let repo = NSTextField(string: project.repoRoot)
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        picker.autoenablesItems = false
        populateWindowPicker(picker, projectName: project.name)

        let addWindowButton = NSButton(title: "Add Window…", target: self, action: #selector(projectEditorAddWindowClicked))
        let editWindowButton = NSButton(title: "Edit Selected…", target: self, action: #selector(projectEditorEditWindowClicked))
        let removeWindowButton = NSButton(title: "Remove Selected…", target: self, action: #selector(projectEditorRemoveWindowClicked))
        addWindowButton.bezelStyle = .rounded
        editWindowButton.bezelStyle = .rounded
        removeWindowButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [addWindowButton, editWindowButton, removeWindowButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let rows: [[NSView]] = [
            [NSTextField(labelWithString: "Repo Root"), repo],
            [NSTextField(labelWithString: "Windows"), picker],
            [NSTextField(labelWithString: ""), buttonRow]
        ]

        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 380

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 140))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6)
        ])

        let alert = NSAlert()
        alert.messageText = "Edit Project"
        alert.informativeText = "Update selected project settings"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = container

        projectEditorContext = ProjectEditorContext(projectName: project.name, windowPicker: picker, addWindowButton: addWindowButton)
        defer { projectEditorContext = nil }

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            _ = try orchestrator().updateProject(
                name: project.name,
                repoRoot: repo.stringValue,
                editor: nil,
                browser: nil,
                terminal: nil,
                editorDisplay: nil,
                editorTile: nil,
                browserDisplay: nil,
                browserTile: nil,
                browserTabs: nil
            )
            reloadProjects(selectProject: project.name)
            setStatus("Saved project '\(project.name)'.")
        } catch {
            setStatus("Save project failed: \(error.localizedDescription)")
        }
    }

    @objc private func deleteProjectClicked() {
        guard let project = selectedProjectName else {
            setStatus("Select a project first.")
            return
        }
        guard confirm(title: "Delete Project", message: "Delete '\(project)' and all streams?") else { return }

        do {
            try orchestrator().deleteProject(name: project)
            reloadProjects()
            setStatus("Deleted project '\(project)'.")
        } catch {
            setStatus("Delete project failed: \(error.localizedDescription)")
        }
    }

    @objc private func addEditorWindowClicked() {
        guard let projectName = selectedProjectName else { return }
        let name = NSTextField(string: "")
        let bundleID = NSTextField(string: "com.exafunction.windsurf")
        let display = NSTextField(string: "0")
        let tile = NSTextField(string: "leftHalf")
        let editorKind = NSTextField(string: "windsurf")
        let matchTitle = NSTextField(string: "")
        guard runModalForm(
            title: "Add Editor Window",
            message: "Add editor window spec to '\(projectName)'",
            fields: [
                ("Name", name),
                ("Bundle ID", bundleID),
                ("Display", display),
                ("Tile", tile),
                ("Editor Kind (windsurf|vscode|cursor)", editorKind),
                ("Match Title (optional)", matchTitle)
            ]
        ) else { return }

        do {
            let updated = try orchestrator().addProjectWindow(
                projectName: projectName,
                name: name.stringValue,
                kind: "editor",
                bundleID: bundleID.stringValue,
                displayIndex: Int(display.stringValue) ?? 0,
                tile: tile.stringValue,
                launchCommand: nil,
                command: nil,
                urls: [],
                matchTitle: blankToNil(matchTitle.stringValue),
                editorKind: blankToNil(editorKind.stringValue)
            )
            setStatus("Added editor window. total windows=\(updated.windows.count)")
        } catch {
            setStatus("Add editor window failed: \(error.localizedDescription)")
        }
    }

    @objc private func addBrowserWindowClicked() {
        guard let projectName = selectedProjectName else { return }
        let name = NSTextField(string: "")
        let bundleID = NSTextField(string: "com.google.Chrome")
        let display = NSTextField(string: "0")
        let tile = NSTextField(string: "rightHalf")
        let url = NSTextField(string: "http://localhost:3000")
        let matchTitle = NSTextField(string: "")
        guard runModalForm(
            title: "Add Browser Window",
            message: "Add browser window spec to '\(projectName)'",
            fields: [
                ("Name", name),
                ("Bundle ID", bundleID),
                ("Display", display),
                ("Tile", tile),
                ("URL", url),
                ("Match Title (optional)", matchTitle)
            ]
        ) else { return }

        do {
            let updated = try orchestrator().addProjectWindow(
                projectName: projectName,
                name: name.stringValue,
                kind: "browser",
                bundleID: bundleID.stringValue,
                displayIndex: Int(display.stringValue) ?? 0,
                tile: tile.stringValue,
                launchCommand: nil,
                command: nil,
                urls: [url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty },
                matchTitle: blankToNil(matchTitle.stringValue),
                editorKind: nil
            )
            setStatus("Added browser window. total windows=\(updated.windows.count)")
        } catch {
            setStatus("Add browser window failed: \(error.localizedDescription)")
        }
    }

    @objc private func addTerminalWindowClicked() {
        guard let projectName = selectedProjectName else { return }
        let name = NSTextField(string: "")
        let bundleID = NSTextField(string: "com.apple.Terminal")
        let display = NSTextField(string: "0")
        let tile = NSTextField(string: "bottomLeft")
        let command = NSTextField(string: "")
        let matchTitle = NSTextField(string: "")
        guard runModalForm(
            title: "Add Terminal Window",
            message: "Add terminal window spec to '\(projectName)'",
            fields: [
                ("Name", name),
                ("Bundle ID", bundleID),
                ("Display", display),
                ("Tile", tile),
                ("Shell Command (optional)", command),
                ("Match Title (optional)", matchTitle)
            ]
        ) else { return }

        do {
            let updated = try orchestrator().addProjectWindow(
                projectName: projectName,
                name: name.stringValue,
                kind: "terminal",
                bundleID: bundleID.stringValue,
                displayIndex: Int(display.stringValue) ?? 0,
                tile: tile.stringValue,
                launchCommand: nil,
                command: blankToNil(command.stringValue),
                urls: [],
                matchTitle: blankToNil(matchTitle.stringValue),
                editorKind: nil
            )
            setStatus("Added terminal window. total windows=\(updated.windows.count)")
        } catch {
            setStatus("Add terminal window failed: \(error.localizedDescription)")
        }
    }

    @objc private func addCustomWindowClicked() {
        guard let projectName = selectedProjectName else { return }
        let name = NSTextField(string: "")
        let bundleID = NSTextField(string: "")
        let display = NSTextField(string: "0")
        let tile = NSTextField(string: "bottomRight")
        let launchCommand = NSTextField(string: "")
        let matchTitle = NSTextField(string: "")
        guard runModalForm(
            title: "Add Custom Window",
            message: "Add custom window spec to '\(projectName)'",
            fields: [
                ("Name", name),
                ("Bundle ID", bundleID),
                ("Display", display),
                ("Tile", tile),
                ("Launch Command", launchCommand),
                ("Match Title (optional)", matchTitle)
            ]
        ) else { return }

        do {
            let updated = try orchestrator().addProjectWindow(
                projectName: projectName,
                name: name.stringValue,
                kind: "custom",
                bundleID: bundleID.stringValue,
                displayIndex: Int(display.stringValue) ?? 0,
                tile: tile.stringValue,
                launchCommand: blankToNil(launchCommand.stringValue),
                command: nil,
                urls: [],
                matchTitle: blankToNil(matchTitle.stringValue),
                editorKind: nil
            )
            setStatus("Added custom window. total windows=\(updated.windows.count)")
        } catch {
            setStatus("Add custom window failed: \(error.localizedDescription)")
        }
    }

    @objc private func editWindowClicked() {
        guard let projectName = selectedProjectName else { return }
        do {
            let windows = try orchestrator().listProjectWindows(projectName: projectName)
            guard let idx = chooseWindowIndex(projectName: projectName, windows: windows, title: "Edit Window", message: "Choose a window in '\(projectName)'") else { return }
            try editWindow(projectName: projectName, index: idx)
        } catch {
            setStatus("Edit window failed: \(error.localizedDescription)")
        }
    }

    @objc private func removeWindowClicked() {
        guard let projectName = selectedProjectName else { return }
        do {
            let windows = try orchestrator().listProjectWindows(projectName: projectName)
            guard let idx = chooseWindowIndex(projectName: projectName, windows: windows, title: "Remove Window", message: "Choose a window to remove in '\(projectName)'") else { return }
            try removeWindow(projectName: projectName, index: idx)
        } catch {
            setStatus("Remove window failed: \(error.localizedDescription)")
        }
    }

    @objc private func addStreamClicked() {
        guard let project = selectedProjectName else {
            setStatus("Select a project first.")
            return
        }
        let name = NSTextField(string: "")
        guard runModalForm(title: "Add Stream", message: "Create new stream in '\(project)'", fields: [("Stream Name", name)]) else { return }

        do {
            _ = try orchestrator().create(projectName: project, streamName: name.stringValue, worktreePath: nil)
            reloadStreams(selectStream: name.stringValue)
            setStatus("Created stream '\(name.stringValue)'.")
        } catch {
            setStatus("Create stream failed: \(error.localizedDescription)")
        }
    }

    @objc private func destroyStreamClicked() {
        guard let project = selectedProjectName, let stream = selectedStreamName else {
            setStatus("Select a stream first.")
            return
        }
        guard confirm(title: "Destroy Stream", message: "Destroy '\(stream)' from project '\(project)'?") else { return }

        do {
            try orchestrator().destroy(projectName: project, streamName: stream, removeBranch: false)
            reloadStreams()
            setStatus("Destroyed stream '\(stream)'.")
        } catch {
            setStatus("Destroy stream failed: \(error.localizedDescription)")
        }
    }

    @objc private func showStreamClicked() { runStreamAction("show") { try $0.show(projectName: $1, streamName: $2) } }
    @objc private func hideStreamClicked() { runStreamAction("hide") { try $0.hide(projectName: $1, streamName: $2) } }
    @objc private func focusStreamClicked() { runStreamAction("focus") { try $0.focus(projectName: $1, streamName: $2) } }

    @objc private func doctorStreamClicked() {
        guard let project = selectedProjectName, let stream = selectedStreamName else {
            setStatus("Select a stream first.")
            return
        }
        do {
            let reports = try orchestrator().doctor(projectName: project, streamName: stream)
            guard let report = reports.first else {
                setStatus("No doctor report for \(project)/\(stream).")
                return
            }
            let missing = report.missingWindows.isEmpty ? "-" : report.missingWindows.joined(separator: ",")
            setStatus("doctor \(project)/\(stream): windows=\(report.foundWindowCount)/\(report.expectedWindowCount), missing=\(missing)")
        } catch {
            setStatus("Doctor failed: \(error.localizedDescription)")
        }
    }

    private func runStreamAction(_ action: String, _ body: (StreamOrchestrator, String, String) throws -> Void) {
        guard let project = selectedProjectName, let stream = selectedStreamName else {
            setStatus("Select a stream first.")
            return
        }

        do {
            try body(try orchestrator(), project, stream)
            reloadStreams(selectStream: stream)
            setStatus("\(action) ok: \(project)/\(stream)")
        } catch {
            setStatus("\(action) failed: \(error.localizedDescription)")
        }
    }

    private func reloadProjects(selectProject: String? = nil) {
        do {
            let list = try orchestrator().listProjects().sorted { $0.name < $1.name }
            projects = list
            projectTable.reloadData()

            if let selectProject, let idx = list.firstIndex(where: { $0.name == selectProject }) {
                projectTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                selectedProjectName = list[idx].name
            } else if !list.isEmpty {
                let idx = min(max(projectTable.selectedRow, 0), list.count - 1)
                projectTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                selectedProjectName = list[idx].name
            } else {
                selectedProjectName = nil
            }
            reloadStreams()
        } catch {
            setStatus("Error loading projects: \(error.localizedDescription)")
        }
    }

    private func reloadStreams(selectStream: String? = nil) {
        guard let selectedProjectName else {
            streams = []
            selectedStreamName = nil
            streamTable.reloadData()
            return
        }

        do {
            let list = try orchestrator().list(projectName: selectedProjectName)
            streams = list
            streamTable.reloadData()

            if let selectStream, let idx = list.firstIndex(where: { $0.name == selectStream }) {
                streamTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                selectedStreamName = list[idx].name
            } else if !list.isEmpty {
                let idx = min(max(streamTable.selectedRow, 0), list.count - 1)
                streamTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                selectedStreamName = list[idx].name
            } else {
                selectedStreamName = nil
            }
        } catch {
            setStatus("Error loading streams: \(error.localizedDescription)")
        }
    }

    private func selectedProject() -> Project? {
        guard let selectedProjectName else { return nil }
        return projects.first(where: { $0.name == selectedProjectName })
    }

    private func orchestrator() throws -> StreamOrchestrator {
        StreamOrchestrator(store: try SQLiteStore(path: try databasePath()))
    }

    private func databasePath() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".agentmux", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agentmux.db").path
    }

    private func runModalForm(title: String, message: String, fields: [(String, NSTextField)]) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let containerHeight = max(140, fields.count * 34 + 12)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: containerHeight))
        let rows: [[NSView]] = fields.map { label, field in
            field.isEditable = true
            field.isSelectable = true
            field.isEnabled = true
            field.controlSize = .regular
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 22)

            let labelView = NSTextField(labelWithString: label)
            labelView.alignment = .right
            labelView.frame = NSRect(x: 0, y: 0, width: 150, height: 22)
            return [labelView, field]
        }

        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        if grid.numberOfColumns >= 2 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = 150
            grid.column(at: 1).xPlacement = .fill
            grid.column(at: 1).width = 380
        }
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6)
        ])

        alert.accessoryView = container
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    private func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func setupMenu() {
        let mainMenu = NSMenu(title: "MainMenu")

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit agentmux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        NSApp.mainMenu = mainMenu
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func blankToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseOptionalInt(_ value: String) -> Int? {
        guard let text = blankToNil(value) else { return nil }
        return Int(text)
    }

    @objc private func projectEditorAddWindowClicked() {
        guard let ctx = projectEditorContext else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Add Browser Window", action: #selector(projectEditorAddBrowserWindowClicked(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Add Terminal Window", action: #selector(projectEditorAddTerminalWindowClicked(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Add Editor Window", action: #selector(projectEditorAddEditorWindowClicked(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Add Custom Window", action: #selector(projectEditorAddCustomWindowClicked(_:)), keyEquivalent: "")
        for item in menu.items {
            item.target = self
            item.isEnabled = true
        }
        let event = NSApp.currentEvent ?? NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(
                x: ctx.addWindowButton.window?.frame.midX ?? window.frame.midX,
                y: ctx.addWindowButton.window?.frame.midY ?? window.frame.midY
            ),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: ctx.addWindowButton.window?.windowNumber ?? window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        guard let event else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: ctx.addWindowButton)
    }

    @objc private func projectEditorEditWindowClicked() {
        guard let ctx = projectEditorContext else { return }
        let previous = selectedProjectName
        selectedProjectName = ctx.projectName
        defer { selectedProjectName = previous }
        let idx = ctx.windowPicker.indexOfSelectedItem
        guard idx >= 0 else {
            setStatus("No window selected.")
            return
        }
        do {
            try editWindow(projectName: ctx.projectName, index: idx)
        } catch {
            setStatus("Edit window failed: \(error.localizedDescription)")
        }
        populateWindowPicker(ctx.windowPicker, projectName: ctx.projectName)
    }

    @objc private func projectEditorRemoveWindowClicked() {
        guard let ctx = projectEditorContext else { return }
        let previous = selectedProjectName
        selectedProjectName = ctx.projectName
        defer { selectedProjectName = previous }
        let idx = ctx.windowPicker.indexOfSelectedItem
        guard idx >= 0 else {
            setStatus("No window selected.")
            return
        }
        do {
            try removeWindow(projectName: ctx.projectName, index: idx)
        } catch {
            setStatus("Remove window failed: \(error.localizedDescription)")
        }
        populateWindowPicker(ctx.windowPicker, projectName: ctx.projectName)
    }

    @objc private func projectEditorAddBrowserWindowClicked(_ sender: Any?) {
        runProjectEditorAddAction { addBrowserWindowClicked() }
    }

    @objc private func projectEditorAddTerminalWindowClicked(_ sender: Any?) {
        runProjectEditorAddAction { addTerminalWindowClicked() }
    }

    @objc private func projectEditorAddEditorWindowClicked(_ sender: Any?) {
        runProjectEditorAddAction { addEditorWindowClicked() }
    }

    @objc private func projectEditorAddCustomWindowClicked(_ sender: Any?) {
        runProjectEditorAddAction { addCustomWindowClicked() }
    }

    private func runProjectEditorAddAction(_ action: () -> Void) {
        guard let ctx = projectEditorContext else { return }
        let previous = selectedProjectName
        selectedProjectName = ctx.projectName
        action()
        selectedProjectName = previous
        populateWindowPicker(ctx.windowPicker, projectName: ctx.projectName)
    }

    private func populateWindowPicker(_ picker: NSPopUpButton, projectName: String) {
        picker.removeAllItems()
        let windows = (try? orchestrator().listProjectWindows(projectName: projectName)) ?? []
        for (index, spec) in windows.enumerated() {
            picker.addItem(withTitle: "\(index): \(spec.name) [\(spec.kind.rawValue)]")
        }
        if windows.isEmpty {
            picker.addItem(withTitle: "(no windows)")
            picker.selectItem(at: 0)
            picker.isEnabled = false
        } else {
            picker.isEnabled = true
            picker.selectItem(at: 0)
        }
    }

    private func chooseWindowIndex(projectName: String, windows: [ProjectWindowSpec], title: String, message: String) -> Int? {
        guard !windows.isEmpty else {
            setStatus("No windows configured for '\(projectName)'.")
            return nil
        }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        for (index, spec) in windows.enumerated() {
            picker.addItem(withTitle: "\(index): \(spec.name) [\(spec.kind.rawValue)]")
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let idx = picker.indexOfSelectedItem
        return (idx >= 0 && idx < windows.count) ? idx : nil
    }

    private func editWindow(projectName: String, index idx: Int) throws {
        let windows = try orchestrator().listProjectWindows(projectName: projectName)
        guard idx >= 0, idx < windows.count else {
            setStatus("Invalid window index.")
            return
        }

        let existing = windows[idx]
        let name = NSTextField(string: existing.name)
        let bundleID = NSTextField(string: existing.bundleID)
        let display = NSTextField(string: String(existing.layout.displayIndex))
        let tile = NSTextField(string: existing.layout.tile.rawValue)
        let matchTitle = NSTextField(string: existing.matchTitle ?? "")

        var fields: [(String, NSTextField)] = [
            ("Name", name),
            ("Bundle ID", bundleID),
            ("Display", display),
            ("Tile", tile),
            ("Match Title (optional)", matchTitle)
        ]

        let editorKind = NSTextField(string: existing.editorKind ?? "")
        let url = NSTextField(string: existing.urls.first ?? "")
        let command = NSTextField(string: existing.command ?? "")
        let launchCommand = NSTextField(string: existing.launchCommand ?? "")

        switch existing.kind {
        case .editor:
            fields.append(("Editor Kind (windsurf|vscode|cursor)", editorKind))
        case .browser:
            fields.append(("URL", url))
        case .terminal:
            fields.append(("Shell Command (optional)", command))
        case .custom:
            fields.append(("Launch Command", launchCommand))
        }

        guard runModalForm(
            title: "Edit \(existing.kind.rawValue.capitalized) Window",
            message: "Update window at index \(idx) in '\(projectName)'",
            fields: fields
        ) else { return }

        let updated = try orchestrator().updateProjectWindow(
            projectName: projectName,
            index: idx,
            name: name.stringValue,
            kind: existing.kind.rawValue,
            bundleID: bundleID.stringValue,
            displayIndex: Int(display.stringValue),
            tile: tile.stringValue,
            launchCommand: existing.kind == .custom ? blankToNil(launchCommand.stringValue) : nil,
            command: existing.kind == .terminal ? blankToNil(command.stringValue) : nil,
            urls: existing.kind == .browser
                ? [url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
                : [],
            matchTitle: blankToNil(matchTitle.stringValue),
            editorKind: existing.kind == .editor ? blankToNil(editorKind.stringValue) : nil
        )
        setStatus("Updated \(existing.kind.rawValue) window at index \(idx). total windows=\(updated.windows.count)")
    }

    private func removeWindow(projectName: String, index idx: Int) throws {
        let windows = try orchestrator().listProjectWindows(projectName: projectName)
        guard idx >= 0, idx < windows.count else {
            setStatus("Invalid window index.")
            return
        }
        let spec = windows[idx]
        guard confirm(title: "Remove Window", message: "Remove '\(spec.name)' (\(spec.kind.rawValue))?") else { return }
        let updated = try orchestrator().removeProjectWindow(projectName: projectName, index: idx)
        setStatus("Removed window at index \(idx). total windows=\(updated.windows.count)")
    }
}
