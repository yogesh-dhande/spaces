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
    private var streamStatuses: [String: [WindowStatus]] = [:]
    private var streamWindows: [String: [CapturedWindow]] = [:]
    private var statusRefreshTimer: Timer?

    private var selectedProjectName: String?
    private var selectedStreamName: String?

    private final class SpacePickerView: NSView {
        private var buttons: [NSButton] = []
        private let optionsByDisplay: [(display: Int, spaces: [Int])]
        private let displayField: NSTextField
        private let spaceField: NSTextField

        init(options: [SpaceOption], displayField: NSTextField, spaceField: NSTextField) {
            let grouped = Dictionary(grouping: options, by: { $0.displayIndex })
            self.optionsByDisplay = grouped.keys.sorted().map { key in
                let spaces = grouped[key]?.map { $0.spaceIndex }.sorted() ?? []
                return (display: key, spaces: spaces)
            }
            self.displayField = displayField
            self.spaceField = spaceField
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            buildView()
        }

        required init?(coder: NSCoder) {
            return nil
        }

        private func buildView() {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false

            for entry in optionsByDisplay {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 6
                row.alignment = .centerY

                let label = NSTextField(labelWithString: "Display \(entry.display)")
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                label.textColor = .secondaryLabelColor
                row.addArrangedSubview(label)

                for space in entry.spaces {
                    let button = NSButton(title: "\(space)", target: self, action: #selector(spaceClicked(_:)))
                    button.setButtonType(.toggle)
                    button.bezelStyle = .texturedRounded
                    button.tag = (entry.display * 10_000) + space
                    buttons.append(button)
                    row.addArrangedSubview(button)
                }

                stack.addArrangedSubview(row)
            }

            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        @objc private func spaceClicked(_ sender: NSButton) {
            for btn in buttons where btn != sender {
                btn.state = .off
            }
            sender.state = .on
            let display = sender.tag / 10_000
            let space = sender.tag % 10_000
            displayField.stringValue = String(display)
            spaceField.stringValue = String(space)
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
        reloadProjects()
        startStatusRefresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == projectTable { return projects.count }
        return streams.count
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView == streamTable, row >= 0, row < streams.count {
            let stream = streams[row]
            let windowCount = streamWindows[stream.name]?.count ?? 0
            let lines = 1 + max(windowCount, 1)
            return CGFloat(lines) * 20.0 + 8.0
        }
        return tableView.rowHeight
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == projectTable {
            let project = projects[row]
            let text = "\(project.name)  (\(project.repoRoot))"
            return makeTextCell(tableView: tableView, text: text)
        } else {
            let stream = streams[row]
            let marker = stream.isActive ? "●" : "○"
            let header = "\(marker) \(stream.name)  (\(stream.worktreePath))  |  display=\(stream.displayIndex) space=\(stream.spaceIndex)"
            let lines = formatWindowLines(for: stream.name)
            return makeStreamCell(tableView: tableView, header: header, lines: lines)
        }
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
            makeButton(title: "Edit", action: #selector(editStreamClicked)),
            makeButton(title: "Destroy", action: #selector(destroyStreamClicked)),
            makeButton(title: "Refresh", action: #selector(refreshStreamsClicked))
        ])
        row1.orientation = .horizontal
        row1.spacing = 8
        row1.translatesAutoresizingMaskIntoConstraints = false

        let row2 = NSStackView(views: [
            makeButton(title: "Show", action: #selector(showStreamClicked)),
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
                repoRoot: repo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard runModalForm(
            title: "Edit Project",
            message: "Update selected project settings",
            fields: [("Repo Root", repo)]
        ) else {
            return
        }

        do {
            _ = try orchestrator().updateProject(
                name: project.name,
                repoRoot: repo.stringValue
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
        let display = NSTextField(string: "1")
        let space = NSTextField(string: "1")
        let picker = makeSpacePicker(displayField: display, spaceField: space)
        guard runStreamModal(
            title: "Add Stream",
            message: "Create new stream in '\(project)'",
            nameField: name,
            displayField: display,
            spaceField: space,
            picker: picker
        ) else { return }

        do {
            _ = try orchestrator().create(
                projectName: project,
                streamName: name.stringValue,
                worktreePath: nil,
                displayIndex: Int(display.stringValue) ?? 1,
                spaceIndex: Int(space.stringValue) ?? 1
            )
            reloadStreams(selectStream: name.stringValue)
            setStatus("Created stream '\(name.stringValue)'.")
        } catch {
            setStatus("Create stream failed: \(error.localizedDescription)")
        }
    }

    @objc private func editStreamClicked() {
        guard let project = selectedProjectName, let stream = selectedStreamName else {
            setStatus("Select a stream first.")
            return
        }
        guard let existing = streams.first(where: { $0.name == stream }) else { return }

        let display = NSTextField(string: String(existing.displayIndex))
        let space = NSTextField(string: String(existing.spaceIndex))
        let picker = makeSpacePicker(displayField: display, spaceField: space)
        guard runStreamModal(
            title: "Edit Stream",
            message: "Update display/space for '\(stream)'",
            nameField: nil,
            displayField: display,
            spaceField: space,
            picker: picker
        ) else { return }

        do {
            _ = try orchestrator().updateStream(
                projectName: project,
                streamName: stream,
                displayIndex: Int(display.stringValue),
                spaceIndex: Int(space.stringValue)
            )
            reloadStreams(selectStream: stream)
            setStatus("Updated stream '\(stream)'.")
        } catch {
            setStatus("Update stream failed: \(error.localizedDescription)")
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
            let missing = report.missingWindowIDs.isEmpty ? "-" : report.missingWindowIDs.map(String.init).joined(separator: ",")
            setStatus("doctor \(project)/\(stream): windows=\(report.windowsFound)/\(report.windowsExpected), missing=\(missing)")
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
            streamStatuses = [:]
            streamWindows = [:]
            selectedStreamName = nil
            streamTable.reloadData()
            return
        }

        do {
            let list = try orchestrator().list(projectName: selectedProjectName)
            streams = list
            let (statuses, windows) = loadStreamStatusesAndWindows(projectName: selectedProjectName, streams: list)
            streamStatuses = statuses
            streamWindows = windows
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

    private func loadStreamStatusesAndWindows(projectName: String, streams: [StreamSummary]) -> ([String: [WindowStatus]], [String: [CapturedWindow]]) {
        var result: [String: [WindowStatus]] = [:]
        var windowsResult: [String: [CapturedWindow]] = [:]
        let fm = FileManager.default
        var allWindowIDs: [Int] = []
        var streamFiles: [String: [URL]] = [:]
        var capturedByStream: [String: [WindowIdentity]] = [:]
        for stream in streams {
            let statusDir = URL(fileURLWithPath: stream.worktreePath)
                .appendingPathComponent(".agentmux", isDirectory: true)
                .appendingPathComponent("status", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: statusDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]),
                  !files.isEmpty else {
                continue
            }

            let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
            guard !jsonFiles.isEmpty else { continue }
            streamFiles[stream.name] = jsonFiles

            if let windows = try? orchestrator().capturedWindows(projectName: projectName, streamName: stream.name) {
                capturedByStream[stream.name] = windows
                allWindowIDs.append(contentsOf: windows.map { $0.id })
            }
        }

        let titleLookup = (try? orchestrator().windowTitles(ids: allWindowIDs)) ?? [:]
        for (streamName, files) in streamFiles {
            var statuses: [WindowStatus] = []
            for file in files {
                guard let id = windowID(from: file) else { continue }
                guard let data = try? Data(contentsOf: file),
                      let status = try? JSONDecoder().decode(TerminalStatus.self, from: data) else {
                    continue
                }
                let title = titleLookup[id]
                statuses.append(WindowStatus(id: id, title: title, status: status))
            }
            statuses.sort { $0.id < $1.id }
            if !statuses.isEmpty {
                result[streamName] = statuses
            }
        }

        for (streamName, windows) in capturedByStream {
            let mapped = windows.map { win in
                let title = titleLookup[win.id] ?? win.title ?? win.app
                return CapturedWindow(id: win.id, app: win.app, title: title)
            }.sorted { $0.id < $1.id }
            windowsResult[streamName] = mapped
        }

        return (result, windowsResult)
    }

    private func windowID(from url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("window-") else { return nil }
        let raw = String(name.dropFirst("window-".count))
        return Int(raw)
    }

    private func formatStatusText(for streamName: String) -> String {
        guard let windows = streamWindows[streamName], !windows.isEmpty else {
            return ""
        }
        let statusLookup = Dictionary(uniqueKeysWithValues: (streamStatuses[streamName] ?? []).map { ($0.id, $0) })
        let summary = windows.map { win in
            var label = win.title ?? win.app
            if label.isEmpty { label = win.app }
            var text = label
            if let status = statusLookup[win.id] {
                text += " status=\(status.status.displayState)"
                if let exitCode = status.status.exitCode, status.status.state == "done" || status.status.state == "error" {
                    text += " exit=\(exitCode)"
                }
            } else {
                text += " status=unknown"
            }
            return text
        }.joined(separator: "; ")
        return "  |  windows=\(windows.count) [\(summary)]"
    }

    private func formatWindowLines(for streamName: String) -> [String] {
        guard let windows = streamWindows[streamName], !windows.isEmpty else {
            return ["windows=0"]
        }
        let statusLookup = Dictionary(uniqueKeysWithValues: (streamStatuses[streamName] ?? []).map { ($0.id, $0) })
        return windows.map { win in
            var label = win.title ?? win.app
            if label.isEmpty { label = win.app }
            var text = "[\(win.id)] \(label)"
            if let status = statusLookup[win.id] {
                text += "  status=\(status.status.displayState)"
                if let exitCode = status.status.exitCode, status.status.state == "done" || status.status.state == "error" {
                    text += " exit=\(exitCode)"
                }
            } else {
                text += "  status=missing"
            }
            return text
        }
    }

    private func makeTextCell(tableView: NSTableView, text: String) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("Cell")
        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell.textField?.stringValue = text
            cell.textField?.toolTip = text
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: text)
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(tf)
        cell.textField = tf
        cell.textField?.toolTip = text
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeStreamCell(tableView: NSTableView, header: String, lines: [String]) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("StreamCell")
        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView,
           let stack = cell.subviews.first(where: { $0.identifier?.rawValue == "StreamStack" }) as? NSStackView {
            updateStreamStack(stack, header: header, lines: lines)
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = id
        let stack = NSStackView()
        stack.identifier = NSUserInterfaceItemIdentifier("StreamStack")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -4)
        ])

        updateStreamStack(stack, header: header, lines: lines)
        return cell
    }

    private func updateStreamStack(_ stack: NSStackView, header: String, lines: [String]) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.toolTip = header
        stack.addArrangedSubview(headerLabel)

        for line in lines {
            let label = NSTextField(labelWithString: line)
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.toolTip = line
            stack.addArrangedSubview(label)
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

    private func runStreamModal(
        title: String,
        message: String,
        nameField: NSTextField?,
        displayField: NSTextField,
        spaceField: NSTextField,
        picker: NSView?
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        var rows: [[NSView]] = []
        if let nameField {
            rows.append([NSTextField(labelWithString: "Stream Name"), nameField])
        }
        rows.append([NSTextField(labelWithString: "Display Index"), displayField])
        rows.append([NSTextField(labelWithString: "Space Index"), spaceField])

        if let picker {
            let label = NSTextField(labelWithString: "Spaces")
            label.alignment = .right
            label.textColor = .secondaryLabelColor
            rows.append([label, picker])
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

        let containerHeight = max(180, rows.count * 34 + 80)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: containerHeight))
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

    private func makeSpacePicker(displayField: NSTextField, spaceField: NSTextField) -> NSView? {
        guard let options = try? orchestrator().listSpaceOptions(), !options.isEmpty else {
            return nil
        }
        let picker = SpacePickerView(options: options, displayField: displayField, spaceField: spaceField)
        return picker
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

    private func startStatusRefresh() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.selectedProjectName != nil else { return }
                self.reloadStreams(selectStream: self.selectedStreamName)
            }
        }
        RunLoop.main.add(statusRefreshTimer!, forMode: .common)
    }
}

private struct TerminalStatus: Decodable {
    let state: String
    let timestamp: String
    let exitCode: Int?

    var displayState: String {
        switch state {
        case "starting":
            return "starting"
        case "working":
            return "working"
        case "waiting_for_input":
            return "waiting"
        case "done":
            return "done"
        case "error":
            return "error"
        default:
            return state
        }
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case timestamp
        case exitCode = "exit_code"
    }
}

private struct WindowStatus {
    let id: Int
    let title: String?
    let status: TerminalStatus
}

private struct CapturedWindow {
    let id: Int
    let app: String
    let title: String?
}
