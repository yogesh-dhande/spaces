import AppKit
import Carbon
import Foundation
import streamctl

@MainActor
public final class AppKitController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!

    private let projectTable = NSTableView()
    private let streamTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hotkeyHintLabel = NSTextField(labelWithString: "")

    private var projects: [Project] = []
    private var streams: [StreamSummary] = []
    private var streamStatuses: [String: [WindowStatus]] = [:]
    private var streamWindows: [String: [CapturedWindow]] = [:]
    private var statusRefreshTimer: Timer?
    private var hotkeyRefreshTimer: Timer?

    private var hotkeyRef: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var registeredHotkey: HotkeySpec?
    private var lastHotkeyRaw: String?
    private var nextShortcut: HotkeySpec?
    private var previousShortcut: HotkeySpec?
    private var showShortcut: HotkeySpec?
    private var lastNextShortcutRaw: String?
    private var lastPreviousShortcutRaw: String?
    private var lastShowShortcutRaw: String?
    private var shortcutMonitor: Any?
    private var suppressShortcuts = false
    private var nextStreamMenuItem: NSMenuItem?
    private var previousStreamMenuItem: NSMenuItem?
    private var showStreamMenuItem: NSMenuItem?
    private lazy var hotkeyHandlerProc: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<AppKitController>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
            controller.toggleWindowFromHotkey()
        }
        return noErr
    }

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

    private final class HotkeyCaptureField: NSControl {
        private final class WeakBox {
            weak var value: HotkeyCaptureField?
            init(_ value: HotkeyCaptureField) { self.value = value }
        }

        private let valueField = NSTextField(string: "")
        private let placeholder: String
        private let specFromEvent: (NSEvent) -> HotkeySpec?
        private static weak var currentFocusedField: HotkeyCaptureField?
        private static var allFields: [WeakBox] = []
        private var isFocused = false
        var capturedSpec: HotkeySpec? {
            didSet { updateDisplay() }
        }

        init(placeholder: String, initial: HotkeySpec?, specFromEvent: @escaping (NSEvent) -> HotkeySpec?) {
            self.placeholder = placeholder
            self.specFromEvent = specFromEvent
            self.capturedSpec = initial
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            setup()
            updateDisplay()
            HotkeyCaptureField.allFields.append(WeakBox(self))
        }

        required init?(coder: NSCoder) { nil }

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            setFocused(true)
        }

        override func becomeFirstResponder() -> Bool {
            needsDisplay = true
            if HotkeyCaptureField.currentFocusedField !== self {
                HotkeyCaptureField.currentFocusedField?.setFocused(false)
                HotkeyCaptureField.currentFocusedField = self
            }
            setFocused(true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            needsDisplay = true
            setFocused(false)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard let spec = specFromEvent(event) else {
                NSSound.beep()
                return
            }
            capturedSpec = spec
        }

        @objc private func handleClick(_ sender: Any?) {
            window?.makeFirstResponder(self)
            setFocused(true)
        }

        private func setup() {
            wantsLayer = true
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.cornerRadius = 7
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.shadowColor = NSColor.black.withAlphaComponent(0.15).cgColor
            layer?.shadowOpacity = 0.6
            layer?.shadowRadius = 2
            layer?.shadowOffset = CGSize(width: 0, height: -1)

            valueField.isEditable = false
            valueField.isSelectable = false
            valueField.refusesFirstResponder = true
            valueField.isBordered = false
            valueField.drawsBackground = false
            valueField.backgroundColor = .clear
            valueField.alignment = .center
            valueField.font = .systemFont(ofSize: 12, weight: .medium)
            valueField.translatesAutoresizingMaskIntoConstraints = false
            addSubview(valueField)
            NSLayoutConstraint.activate([
                valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                valueField.topAnchor.constraint(equalTo: topAnchor, constant: 3),
                valueField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
                heightAnchor.constraint(equalToConstant: 24)
            ])

            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            addGestureRecognizer(click)
            let valueClick = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            valueField.addGestureRecognizer(valueClick)
        }

        private func updateDisplay() {
            if let capturedSpec {
                valueField.stringValue = capturedSpec.normalized
                valueField.textColor = .labelColor
            } else {
                valueField.stringValue = placeholder
                valueField.textColor = .secondaryLabelColor
            }
        }

        private func updateFocusAppearance() {
            if isFocused {
                layer?.borderColor = NSColor.controlAccentColor.cgColor
            } else {
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }

        private func setFocused(_ focused: Bool) {
            if focused {
                HotkeyCaptureField.clearAllFocus(except: self)
                HotkeyCaptureField.currentFocusedField = self
            } else if HotkeyCaptureField.currentFocusedField === self {
                HotkeyCaptureField.currentFocusedField = nil
            }
            isFocused = focused
            updateFocusAppearance()
        }

        private static func clearAllFocus(except field: HotkeyCaptureField?) {
            allFields = allFields.filter { $0.value != nil }
            for box in allFields {
                if let target = box.value, target !== field {
                    target.setFocused(false)
                }
            }
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
        setupHotkey()
        setupShortcuts()
        setupShortcutMonitor()
        startHotkeyRefresh()
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
        window.collectionBehavior.insert(.moveToActiveSpace)

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
        let footerStack = NSStackView(views: [statusLabel, hotkeyHintLabel])
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 12
        footerStack.distribution = .fill

        root.addSubview(footerStack)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hotkeyHintLabel.textColor = .tertiaryLabelColor
        hotkeyHintLabel.font = .systemFont(ofSize: 11)
        hotkeyHintLabel.alignment = .right
        hotkeyHintLabel.lineBreakMode = .byTruncatingTail
        hotkeyHintLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -8),

            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footerStack.heightAnchor.constraint(equalToConstant: 20)
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
        try DatabaseLocator.defaultPath()
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

    private enum KeyCaptureResult {
        case save
        case cancel
        case resetDefaults
    }

    private func runHotkeyCaptureForm(title: String, message: String, fields: [(String, HotkeyCaptureField)]) -> KeyCaptureResult {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset Defaults")

        let containerHeight = max(190, fields.count * 42 + 30)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: containerHeight))
        let rows: [[NSView]] = fields.map { label, field in
            field.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
            let labelView = NSTextField(labelWithString: label)
            labelView.alignment = .left
            labelView.lineBreakMode = .byTruncatingTail
            labelView.font = .systemFont(ofSize: 13)
            labelView.frame = NSRect(x: 0, y: 0, width: 250, height: 22)
            return [labelView, field]
        }

        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        if grid.numberOfColumns >= 2 {
            grid.column(at: 0).xPlacement = .leading
            grid.column(at: 0).width = 250
            grid.column(at: 1).xPlacement = .trailing
            grid.column(at: 1).width = 180
        }
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6)
        ])

        alert.accessoryView = container
        if let first = fields.first?.1 {
            alert.window.initialFirstResponder = first
        }
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .save
        case .alertThirdButtonReturn:
            return .resetDefaults
        default:
            return .cancel
        }
    }

    private func makeHotkeyCaptureField(initial: HotkeySpec) -> HotkeyCaptureField {
        HotkeyCaptureField(
            placeholder: "Click then press keys",
            initial: initial,
            specFromEvent: { [weak self] event in
                self?.hotkeySpec(from: event)
            }
        )
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
        appMenu.addItem(withTitle: "Keyboard Shortcuts...", action: #selector(editKeysClicked), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit agentmux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let streamItem = NSMenuItem()
        let streamMenu = NSMenu(title: "Stream")
        let nextItem = NSMenuItem(title: "Next Stream", action: #selector(selectNextStream), keyEquivalent: "")
        nextItem.target = self
        streamMenu.addItem(nextItem)
        nextStreamMenuItem = nextItem

        let prevItem = NSMenuItem(title: "Previous Stream", action: #selector(selectPreviousStream), keyEquivalent: "")
        prevItem.target = self
        streamMenu.addItem(prevItem)
        previousStreamMenuItem = prevItem

        streamMenu.addItem(NSMenuItem.separator())
        let showItem = NSMenuItem(title: "Show Selected Stream", action: #selector(showSelectedStreamShortcut), keyEquivalent: "")
        showItem.target = self
        streamMenu.addItem(showItem)
        showStreamMenuItem = showItem

        streamItem.submenu = streamMenu
        mainMenu.addItem(streamItem)

        NSApp.mainMenu = mainMenu
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    @objc private func editKeysClicked() {
        do {
            let currentHotkey = try HotkeySpec.parse(try orchestrator().guiHotkey())
            let currentNext = try HotkeySpec.parse(try orchestrator().guiNextShortcut())
            let currentPrev = try HotkeySpec.parse(try orchestrator().guiPreviousShortcut())
            let currentShow = try HotkeySpec.parse(try orchestrator().guiShowShortcut())

            let hotkeyField = makeHotkeyCaptureField(initial: currentHotkey)
            let nextField = makeHotkeyCaptureField(initial: currentNext)
            let prevField = makeHotkeyCaptureField(initial: currentPrev)
            let showField = makeHotkeyCaptureField(initial: currentShow)

            suppressShortcuts = true
            unregisterHotkey()
            let result = runHotkeyCaptureForm(
                title: "Keyboard Shortcuts",
                message: "Click a field and press the key combination you want.",
                fields: [
                    ("Toggle agentmux window", hotkeyField),
                    ("Next stream", nextField),
                    ("Previous stream", prevField),
                    ("Show selected stream", showField)
                ]
            )

            var didRegisterHotkey = false
            switch result {
            case .save:
                guard
                    let hotkeySpec = hotkeyField.capturedSpec,
                    let nextSpec = nextField.capturedSpec,
                    let prevSpec = prevField.capturedSpec,
                    let showSpec = showField.capturedSpec
                else {
                    showErrorAlert(title: "Invalid shortcuts", message: "Missing one or more shortcuts.")
                    return
                }
                try orchestrator().setGUIHotkey(hotkeySpec.normalized)
                try orchestrator().setGUINextShortcut(nextSpec.normalized)
                try orchestrator().setGUIPreviousShortcut(prevSpec.normalized)
                try orchestrator().setGUIShowShortcut(showSpec.normalized)
                registerHotkey(hotkeySpec)
                didRegisterHotkey = true
                lastHotkeyRaw = hotkeySpec.normalized
                nextShortcut = nextSpec
                previousShortcut = prevSpec
                showShortcut = showSpec
                lastNextShortcutRaw = nextSpec.normalized
                lastPreviousShortcutRaw = prevSpec.normalized
                lastShowShortcutRaw = showSpec.normalized
                updateShortcutMenuItems()
                updateHotkeyHint()
                setStatus("Shortcuts updated.")
            case .resetDefaults:
                try orchestrator().setGUIHotkey(nil)
                try orchestrator().setGUINextShortcut(nil)
                try orchestrator().setGUIPreviousShortcut(nil)
                try orchestrator().setGUIShowShortcut(nil)
                let hotkeySpec = try HotkeySpec.parse(SettingsKey.defaultGUIHotkey)
                let nextSpec = try HotkeySpec.parse(SettingsKey.defaultGUINextShortcut)
                let prevSpec = try HotkeySpec.parse(SettingsKey.defaultGUIPreviousShortcut)
                let showSpec = try HotkeySpec.parse(SettingsKey.defaultGUIShowShortcut)
                registerHotkey(hotkeySpec)
                didRegisterHotkey = true
                lastHotkeyRaw = hotkeySpec.normalized
                nextShortcut = nextSpec
                previousShortcut = prevSpec
                showShortcut = showSpec
                lastNextShortcutRaw = nextSpec.normalized
                lastPreviousShortcutRaw = prevSpec.normalized
                lastShowShortcutRaw = showSpec.normalized
                updateShortcutMenuItems()
                updateHotkeyHint()
                setStatus("Shortcuts reset.")
            case .cancel:
                break
            }
            suppressShortcuts = false
            if !didRegisterHotkey {
                registerHotkey(currentHotkey)
                lastHotkeyRaw = currentHotkey.normalized
                updateHotkeyHint()
            }
        } catch {
            suppressShortcuts = false
            showErrorAlert(title: "Invalid shortcuts", message: error.localizedDescription)
        }
    }

    private func setupHotkey() {
        do {
            let raw = try orchestrator().guiHotkey()
            let spec = try HotkeySpec.parse(raw)
            registerHotkey(spec)
            lastHotkeyRaw = raw
            updateHotkeyHint()
        } catch {
            setStatus("Hotkey error: \(error.localizedDescription)")
            updateHotkeyHint()
        }
    }

    private func setupShortcuts() {
        do {
            let nextRaw = try orchestrator().guiNextShortcut()
            let prevRaw = try orchestrator().guiPreviousShortcut()
            let showRaw = try orchestrator().guiShowShortcut()
            let nextSpec = try HotkeySpec.parse(nextRaw)
            let prevSpec = try HotkeySpec.parse(prevRaw)
            let showSpec = try HotkeySpec.parse(showRaw)
            nextShortcut = nextSpec
            previousShortcut = prevSpec
            showShortcut = showSpec
            lastNextShortcutRaw = nextRaw
            lastPreviousShortcutRaw = prevRaw
            lastShowShortcutRaw = showRaw
            updateShortcutMenuItems()
            updateHotkeyHint()
        } catch {
            setStatus("Shortcut error: \(error.localizedDescription)")
            updateHotkeyHint()
        }
    }

    private func setupShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.shouldHandleShortcuts() else { return event }
            guard !event.isARepeat else { return event }
            guard let spec = self.hotkeySpec(from: event) else { return event }

            if spec == self.nextShortcut {
                self.selectNextStream()
                return nil
            }
            if spec == self.previousShortcut {
                self.selectPreviousStream()
                return nil
            }
            if spec == self.showShortcut {
                self.showSelectedStreamShortcut()
                return nil
            }

            return event
        }
    }

    private func shouldHandleShortcuts() -> Bool {
        if suppressShortcuts { return false }
        guard window.isKeyWindow else { return false }
        if let responder = window.firstResponder as? NSTextView, responder.isEditable {
            return false
        }
        if let responder = window.firstResponder as? NSTextField, responder.isEditable {
            return false
        }
        return true
    }

    private func registerHotkey(_ spec: HotkeySpec) {
        unregisterHotkey()
        guard let keyCode = keyCode(for: spec.key) else {
            setStatus("Unsupported hotkey key: \(spec.key)")
            return
        }

        let modifiers = carbonModifiers(from: spec.modifiers)
        let hotkeyID = EventHotKeyID(signature: fourCharCode("AMUX"), id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotkeyID, GetEventDispatcherTarget(), 0, &hotkeyRef)
        if status != noErr {
            setStatus("Failed to register hotkey (\(status))")
            return
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyHandlerProc,
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotkeyHandler
        )
        registeredHotkey = spec
        updateHotkeyHint()
    }

    private func unregisterHotkey() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let hotkeyHandler {
            RemoveEventHandler(hotkeyHandler)
            self.hotkeyHandler = nil
        }
        registeredHotkey = nil
        updateHotkeyHint()
    }

    fileprivate func toggleWindowFromHotkey() {
        if window.isVisible {
            if shouldMoveToActiveSpace() {
                showWindowOnActiveSpace()
            } else {
                window.orderOut(nil)
            }
        } else {
            showWindowOnActiveSpace()
        }
    }

    private func shouldMoveToActiveSpace() -> Bool {
        if let targetScreen = screenForActiveDisplay(), window.screen != targetScreen {
            return true
        }
        if !window.isOnActiveSpace {
            return true
        }
        return false
    }

    private func showWindowOnActiveSpace() {
        if let screen = screenForActiveDisplay() {
            centerWindow(on: screen)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func screenForActiveDisplay() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    private func centerWindow(on screen: NSScreen) {
        let frame = window.frame
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.origin.x + (visible.size.width - frame.size.width) / 2,
            y: visible.origin.y + (visible.size.height - frame.size.height) / 2
        )
        window.setFrameOrigin(origin)
    }

    private func hotkeySpec(from event: NSEvent) -> HotkeySpec? {
        guard let key = keyName(for: event.keyCode) else { return nil }
        let modifiers = hotkeyModifiers(from: event.modifierFlags)
        return HotkeySpec(key: key, modifiers: modifiers)
    }

    private func hotkeyModifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Set<HotkeyModifier>()
        if masked.contains(.command) { modifiers.insert(.cmd) }
        if masked.contains(.shift) { modifiers.insert(.shift) }
        if masked.contains(.option) { modifiers.insert(.alt) }
        if masked.contains(.control) { modifiers.insert(.ctrl) }
        return modifiers
    }

    private func keyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case UInt16(kVK_ANSI_A): return "a"
        case UInt16(kVK_ANSI_B): return "b"
        case UInt16(kVK_ANSI_C): return "c"
        case UInt16(kVK_ANSI_D): return "d"
        case UInt16(kVK_ANSI_E): return "e"
        case UInt16(kVK_ANSI_F): return "f"
        case UInt16(kVK_ANSI_G): return "g"
        case UInt16(kVK_ANSI_H): return "h"
        case UInt16(kVK_ANSI_I): return "i"
        case UInt16(kVK_ANSI_J): return "j"
        case UInt16(kVK_ANSI_K): return "k"
        case UInt16(kVK_ANSI_L): return "l"
        case UInt16(kVK_ANSI_M): return "m"
        case UInt16(kVK_ANSI_N): return "n"
        case UInt16(kVK_ANSI_O): return "o"
        case UInt16(kVK_ANSI_P): return "p"
        case UInt16(kVK_ANSI_Q): return "q"
        case UInt16(kVK_ANSI_R): return "r"
        case UInt16(kVK_ANSI_S): return "s"
        case UInt16(kVK_ANSI_T): return "t"
        case UInt16(kVK_ANSI_U): return "u"
        case UInt16(kVK_ANSI_V): return "v"
        case UInt16(kVK_ANSI_W): return "w"
        case UInt16(kVK_ANSI_X): return "x"
        case UInt16(kVK_ANSI_Y): return "y"
        case UInt16(kVK_ANSI_Z): return "z"
        case UInt16(kVK_ANSI_0): return "0"
        case UInt16(kVK_ANSI_1): return "1"
        case UInt16(kVK_ANSI_2): return "2"
        case UInt16(kVK_ANSI_3): return "3"
        case UInt16(kVK_ANSI_4): return "4"
        case UInt16(kVK_ANSI_5): return "5"
        case UInt16(kVK_ANSI_6): return "6"
        case UInt16(kVK_ANSI_7): return "7"
        case UInt16(kVK_ANSI_8): return "8"
        case UInt16(kVK_ANSI_9): return "9"
        case UInt16(kVK_ANSI_LeftBracket): return "["
        case UInt16(kVK_ANSI_RightBracket): return "]"
        case UInt16(kVK_ANSI_Semicolon): return ";"
        case UInt16(kVK_ANSI_Quote): return "'"
        case UInt16(kVK_ANSI_Comma): return ","
        case UInt16(kVK_ANSI_Period): return "."
        case UInt16(kVK_ANSI_Slash): return "/"
        case UInt16(kVK_ANSI_Backslash): return "\\"
        case UInt16(kVK_ANSI_Minus): return "minus"
        case UInt16(kVK_ANSI_Equal): return "="
        case UInt16(kVK_ANSI_Grave): return "`"
        case UInt16(kVK_Space): return "space"
        case UInt16(kVK_Tab): return "tab"
        case UInt16(kVK_Return): return "return"
        case UInt16(kVK_ANSI_KeypadEnter): return "enter"
        case UInt16(kVK_Escape): return "escape"
        case UInt16(kVK_Delete): return "delete"
        case UInt16(kVK_ForwardDelete): return "forwarddelete"
        case UInt16(kVK_LeftArrow): return "left"
        case UInt16(kVK_RightArrow): return "right"
        case UInt16(kVK_UpArrow): return "up"
        case UInt16(kVK_DownArrow): return "down"
        case UInt16(kVK_F1): return "f1"
        case UInt16(kVK_F2): return "f2"
        case UInt16(kVK_F3): return "f3"
        case UInt16(kVK_F4): return "f4"
        case UInt16(kVK_F5): return "f5"
        case UInt16(kVK_F6): return "f6"
        case UInt16(kVK_F7): return "f7"
        case UInt16(kVK_F8): return "f8"
        case UInt16(kVK_F9): return "f9"
        case UInt16(kVK_F10): return "f10"
        case UInt16(kVK_F11): return "f11"
        case UInt16(kVK_F12): return "f12"
        case UInt16(kVK_F13): return "f13"
        case UInt16(kVK_F14): return "f14"
        case UInt16(kVK_F15): return "f15"
        case UInt16(kVK_F16): return "f16"
        case UInt16(kVK_F17): return "f17"
        case UInt16(kVK_F18): return "f18"
        case UInt16(kVK_F19): return "f19"
        case UInt16(kVK_F20): return "f20"
        default: return nil
        }
    }

    private func keyCode(for key: String) -> UInt32? {
        let lower = key.lowercased()
        if lower.count == 1, let scalar = lower.unicodeScalars.first {
            if CharacterSet.letters.contains(scalar) {
                switch lower {
                case "a": return UInt32(kVK_ANSI_A)
                case "b": return UInt32(kVK_ANSI_B)
                case "c": return UInt32(kVK_ANSI_C)
                case "d": return UInt32(kVK_ANSI_D)
                case "e": return UInt32(kVK_ANSI_E)
                case "f": return UInt32(kVK_ANSI_F)
                case "g": return UInt32(kVK_ANSI_G)
                case "h": return UInt32(kVK_ANSI_H)
                case "i": return UInt32(kVK_ANSI_I)
                case "j": return UInt32(kVK_ANSI_J)
                case "k": return UInt32(kVK_ANSI_K)
                case "l": return UInt32(kVK_ANSI_L)
                case "m": return UInt32(kVK_ANSI_M)
                case "n": return UInt32(kVK_ANSI_N)
                case "o": return UInt32(kVK_ANSI_O)
                case "p": return UInt32(kVK_ANSI_P)
                case "q": return UInt32(kVK_ANSI_Q)
                case "r": return UInt32(kVK_ANSI_R)
                case "s": return UInt32(kVK_ANSI_S)
                case "t": return UInt32(kVK_ANSI_T)
                case "u": return UInt32(kVK_ANSI_U)
                case "v": return UInt32(kVK_ANSI_V)
                case "w": return UInt32(kVK_ANSI_W)
                case "x": return UInt32(kVK_ANSI_X)
                case "y": return UInt32(kVK_ANSI_Y)
                case "z": return UInt32(kVK_ANSI_Z)
                default: break
                }
            }
            if CharacterSet.decimalDigits.contains(scalar) {
                switch lower {
                case "0": return UInt32(kVK_ANSI_0)
                case "1": return UInt32(kVK_ANSI_1)
                case "2": return UInt32(kVK_ANSI_2)
                case "3": return UInt32(kVK_ANSI_3)
                case "4": return UInt32(kVK_ANSI_4)
                case "5": return UInt32(kVK_ANSI_5)
                case "6": return UInt32(kVK_ANSI_6)
                case "7": return UInt32(kVK_ANSI_7)
                case "8": return UInt32(kVK_ANSI_8)
                case "9": return UInt32(kVK_ANSI_9)
                default: break
                }
            }
        }

        switch lower {
        case "[": return UInt32(kVK_ANSI_LeftBracket)
        case "]": return UInt32(kVK_ANSI_RightBracket)
        case ";": return UInt32(kVK_ANSI_Semicolon)
        case "'": return UInt32(kVK_ANSI_Quote)
        case ",": return UInt32(kVK_ANSI_Comma)
        case ".": return UInt32(kVK_ANSI_Period)
        case "/": return UInt32(kVK_ANSI_Slash)
        case "\\": return UInt32(kVK_ANSI_Backslash)
        case "minus", "dash": return UInt32(kVK_ANSI_Minus)
        case "=": return UInt32(kVK_ANSI_Equal)
        case "`": return UInt32(kVK_ANSI_Grave)
        case "space": return UInt32(kVK_Space)
        case "tab": return UInt32(kVK_Tab)
        case "return": return UInt32(kVK_Return)
        case "enter": return UInt32(kVK_Return)
        case "escape": return UInt32(kVK_Escape)
        case "delete", "backspace": return UInt32(kVK_Delete)
        case "forwarddelete": return UInt32(kVK_ForwardDelete)
        case "left": return UInt32(kVK_LeftArrow)
        case "right": return UInt32(kVK_RightArrow)
        case "up": return UInt32(kVK_UpArrow)
        case "down": return UInt32(kVK_DownArrow)
        default: break
        }

        if lower.hasPrefix("f"), let value = Int(lower.dropFirst()) {
            switch value {
            case 1: return UInt32(kVK_F1)
            case 2: return UInt32(kVK_F2)
            case 3: return UInt32(kVK_F3)
            case 4: return UInt32(kVK_F4)
            case 5: return UInt32(kVK_F5)
            case 6: return UInt32(kVK_F6)
            case 7: return UInt32(kVK_F7)
            case 8: return UInt32(kVK_F8)
            case 9: return UInt32(kVK_F9)
            case 10: return UInt32(kVK_F10)
            case 11: return UInt32(kVK_F11)
            case 12: return UInt32(kVK_F12)
            case 13: return UInt32(kVK_F13)
            case 14: return UInt32(kVK_F14)
            case 15: return UInt32(kVK_F15)
            case 16: return UInt32(kVK_F16)
            case 17: return UInt32(kVK_F17)
            case 18: return UInt32(kVK_F18)
            case 19: return UInt32(kVK_F19)
            case 20: return UInt32(kVK_F20)
            default: break
            }
        }

        return nil
    }

    private func carbonModifiers(from modifiers: Set<HotkeyModifier>) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.cmd) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.alt) { flags |= UInt32(optionKey) }
        if modifiers.contains(.ctrl) { flags |= UInt32(controlKey) }
        return flags
    }

    private func updateShortcutMenuItems() {
        if let nextShortcut {
            applyMenuShortcutDisplay(nextShortcut, to: nextStreamMenuItem)
        }
        if let previousShortcut {
            applyMenuShortcutDisplay(previousShortcut, to: previousStreamMenuItem)
        }
        if let showShortcut {
            applyMenuShortcutDisplay(showShortcut, to: showStreamMenuItem)
        }
    }

    private func applyMenuShortcutDisplay(_ spec: HotkeySpec, to item: NSMenuItem?) {
        guard let item else { return }
        if let (key, mask) = menuKeyEquivalent(for: spec) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mask
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    private func menuKeyEquivalent(for spec: HotkeySpec) -> (String, NSEvent.ModifierFlags)? {
        let key = spec.key.lowercased()
        let equivalent: String
        switch key {
        case "space": equivalent = " "
        case "tab": equivalent = "\t"
        case "return", "enter": equivalent = "\r"
        case "escape": equivalent = "\u{1b}"
        case "minus": equivalent = "-"
        default:
            guard key.count == 1 else { return nil }
            equivalent = key
        }

        var mask: NSEvent.ModifierFlags = []
        if spec.modifiers.contains(.cmd) { mask.insert(.command) }
        if spec.modifiers.contains(.shift) { mask.insert(.shift) }
        if spec.modifiers.contains(.alt) { mask.insert(.option) }
        if spec.modifiers.contains(.ctrl) { mask.insert(.control) }
        return (equivalent, mask)
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startHotkeyRefresh() {
        hotkeyRefreshTimer?.invalidate()
        hotkeyRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.refreshBindingsIfNeeded()
            }
        }
        RunLoop.main.add(hotkeyRefreshTimer!, forMode: .common)
    }

    private func refreshBindingsIfNeeded() {
        do {
            let hotkeyRaw = try orchestrator().guiHotkey()
            if hotkeyRaw != lastHotkeyRaw {
                let spec = try HotkeySpec.parse(hotkeyRaw)
                registerHotkey(spec)
                lastHotkeyRaw = hotkeyRaw
                setStatus("Hotkey updated to \(spec.normalized)")
            }

            let nextRaw = try orchestrator().guiNextShortcut()
            let prevRaw = try orchestrator().guiPreviousShortcut()
            let showRaw = try orchestrator().guiShowShortcut()
            var shortcutsChanged = false
            if nextRaw != lastNextShortcutRaw {
                nextShortcut = try HotkeySpec.parse(nextRaw)
                lastNextShortcutRaw = nextRaw
                shortcutsChanged = true
            }
            if prevRaw != lastPreviousShortcutRaw {
                previousShortcut = try HotkeySpec.parse(prevRaw)
                lastPreviousShortcutRaw = prevRaw
                shortcutsChanged = true
            }
            if showRaw != lastShowShortcutRaw {
                showShortcut = try HotkeySpec.parse(showRaw)
                lastShowShortcutRaw = showRaw
                shortcutsChanged = true
            }
            if shortcutsChanged {
                updateShortcutMenuItems()
                setStatus("Shortcuts updated.")
            }
            updateHotkeyHint()
        } catch {
            setStatus("Bindings reload failed: \(error.localizedDescription)")
            updateHotkeyHint()
        }
    }

    private func updateHotkeyHint() {
        let hotkey = registeredHotkey?.normalized ?? SettingsKey.defaultGUIHotkey
        let next = nextShortcut?.normalized ?? SettingsKey.defaultGUINextShortcut
        let prev = previousShortcut?.normalized ?? SettingsKey.defaultGUIPreviousShortcut
        let show = showShortcut?.normalized ?? SettingsKey.defaultGUIShowShortcut
        let hint = "Hotkey: \(hotkey)  |  Next: \(next)  Prev: \(prev)  Show: \(show)"
        hotkeyHintLabel.stringValue = hint
        hotkeyHintLabel.toolTip = hint
    }

    @objc private func selectNextStream() {
        selectAdjacentStream(offset: 1)
    }

    @objc private func selectPreviousStream() {
        selectAdjacentStream(offset: -1)
    }

    private func selectAdjacentStream(offset: Int) {
        guard !streams.isEmpty else {
            setStatus("No streams to select.")
            return
        }

        var current = streamTable.selectedRow
        if current < 0 || current >= streams.count {
            current = 0
        } else {
            current = (current + offset) % streams.count
            if current < 0 {
                current += streams.count
            }
        }

        streamTable.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
        streamTable.scrollRowToVisible(current)
        selectedStreamName = streams[current].name
        setStatus("Selected stream '\(streams[current].name)'.")
    }

    @objc private func showSelectedStreamShortcut() {
        showStreamClicked()
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

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.utf8.prefix(4) {
        result = (result << 8) + OSType(scalar)
    }
    return result
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
