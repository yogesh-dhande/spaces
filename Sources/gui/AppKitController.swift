import AppKit
import Foundation
import streamctl

@MainActor
public final class AppKitController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!

    private let projectTable = NSTableView()
    private let streamTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var projects: [Project] = []
    private var streams: [StreamSummary] = []

    private var selectedProjectName: String?
    private var selectedStreamName: String?

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
        let editor = NSTextField(string: "windsurf")
        let eDisplay = NSTextField(string: "0")
        let eTile = NSTextField(string: "leftHalf")
        let bDisplay = NSTextField(string: "0")
        let bTile = NSTextField(string: "rightHalf")
        let tabs = NSTextField(string: "")
        guard runModalForm(
            title: "Add Project",
            message: "Create a new project",
            fields: [
                ("Name", name),
                ("Repo Root", repo),
                ("Editor", editor),
                ("Editor Display", eDisplay),
                ("Editor Tile", eTile),
                ("Browser Display", bDisplay),
                ("Browser Tile", bTile),
                ("Browser Tabs CSV", tabs)
            ]
        ) else {
            return
        }

        do {
            _ = try orchestrator().createProject(
                name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                repoRoot: repo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                editor: editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                browser: "chrome",
                terminal: "terminal",
                editorDisplay: Int(eDisplay.stringValue),
                editorTile: eTile.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                browserDisplay: Int(bDisplay.stringValue),
                browserTile: bTile.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                browserTabs: tabs.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
        let editor = NSTextField(string: project.defaultEditor.rawValue)
        let eDisplay = NSTextField(string: String(project.editorLayout.displayIndex))
        let eTile = NSTextField(string: project.editorLayout.tile.rawValue)
        let bDisplay = NSTextField(string: String(project.browserLayout.displayIndex))
        let bTile = NSTextField(string: project.browserLayout.tile.rawValue)
        let tabs = NSTextField(string: project.browserTabs.joined(separator: ","))

        guard runModalForm(
            title: "Edit Project",
            message: "Update selected project settings",
            fields: [
                ("Repo Root", repo),
                ("Editor", editor),
                ("Editor Display", eDisplay),
                ("Editor Tile", eTile),
                ("Browser Display", bDisplay),
                ("Browser Tile", bTile),
                ("Browser Tabs CSV", tabs)
            ]
        ) else {
            return
        }

        do {
            _ = try orchestrator().updateProject(
                name: project.name,
                repoRoot: repo.stringValue,
                editor: editor.stringValue,
                browser: "chrome",
                terminal: "terminal",
                editorDisplay: Int(eDisplay.stringValue),
                editorTile: eTile.stringValue,
                browserDisplay: Int(bDisplay.stringValue),
                browserTile: bTile.stringValue,
                browserTabs: tabs.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
            let editor = report.editorWindowFound ? "ok" : "missing"
            let chrome = report.chromeWindowFound ? "ok" : "missing"
            setStatus("doctor \(project)/\(stream): editor=\(editor), chrome=\(chrome), terminal=\(report.terminalWindowCount)/\(report.expectedTerminalWindowCount)")
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
}
