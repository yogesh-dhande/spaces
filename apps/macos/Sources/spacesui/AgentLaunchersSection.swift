import AppKit
import workspacecore

@MainActor final class AgentLaunchersSection {
    // MARK: Public surface

    let view: NSView
    var onCommit: (([AgentLauncher]) -> Void)?
    var presentRemoveConfirmation: ((AgentLauncher, @escaping (Bool) -> Void) -> Void)?

    // MARK: State

    private var launchers: [AgentLauncher]
    private let showsRuntimeControls: Bool
    private let rowsStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [AgentLauncherRowView] = []
    private var pendingDraftIndex: Int?
    private var agentWindows: [AgentWindowRecord] = []
    private var runtimeWindowTitleByAgentID: [String: String] = [:]

    /// Map from entry identity → shortcut display text (e.g. "⌘5").
    var shortcutsByIdentity: [String: String] = [:] { didSet { refreshRows(animated: false) } }

    /// Live coding-agent windows currently associated with the workspace.
    var runtimeAgentWindows: [AgentWindowRecord] = [] {
        didSet {
            agentWindows = runtimeAgentWindows
            refreshRows(animated: false)
        }
    }

    /// Best-effort terminal window titles for live coding-agent rows, keyed by
    /// `AgentWindowRecord.id`.
    var runtimeWindowTitleByAgentWindowID: [String: String] = [:] {
        didSet {
            runtimeWindowTitleByAgentID = runtimeWindowTitleByAgentWindowID
            refreshRows(animated: false)
        }
    }

    /// Called when a configured launcher row is clicked.
    var onFocusLauncher: ((AgentLauncher) -> Void)?

    /// Called when a live runtime agent row is clicked.
    var onFocusAgentWindow: ((AgentWindowRecord) -> Void)?
    var onRunLauncher: ((AgentLauncher) -> Void)?
    var onStopAgentWindow: ((AgentWindowRecord) -> Void)?
    var onRestartAgentWindow: ((AgentWindowRecord) -> Void)?

    // MARK: Init

    init(launchers: [AgentLauncher] = [], subtitle: String? = nil, showsRuntimeControls: Bool = true) {
        self.launchers = launchers
        self.showsRuntimeControls = showsRuntimeControls

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = RowSectionHeader.make(
            title: "Coding Agents", addButtonAccessibilityIdentifier: "agent-launchers-section-add", countLabel: countLabel, subtitle: subtitle)
        container.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        self.view = RowSectionCard.wrap(container)

        if let addButton = header.arrangedSubviews.compactMap({ $0 as? NSButton }).first {
            addButton.target = self
            addButton.action = #selector(handleAdd(_:))
        }
        RowSectionCard.retain(self, in: view)

        refreshRows(animated: false)
    }

    // MARK: Public API

    func reload(launchers: [AgentLauncher]) { update(launchers: launchers, preservingEditing: true) }

    func replace(launchers: [AgentLauncher]) {
        pendingDraftIndex = nil
        update(launchers: launchers, preservingEditing: false)
    }

    private func update(launchers: [AgentLauncher], preservingEditing: Bool) {
        self.launchers = launchers
        refreshRows(animated: true, preservingEditing: preservingEditing)
    }

    var rowCount: Int { rows.count }
    var hasOpenEditor: Bool { rows.contains { $0.isEditing } }
    func isEditing(at index: Int) -> Bool { index >= 0 && index < rows.count ? rows[index].isEditing : false }

    private struct DisplayEntry {
        let launcher: AgentLauncher?
        let agentWindow: AgentWindowRecord?
        let runtimeWindowTitle: String?

        var displayLauncher: AgentLauncher {
            if let launcher { return launcher }
            let name = AppKitController.codingAgentDisplayName(label: agentWindow?.label, runtimeWindowTitle: runtimeWindowTitle)
            let detail = runtimeWindowTitle ?? ""
            return AgentLauncher(name: name, command: detail)
        }

        var identity: String? {
            if let agentWindow { return AppKitController.codingAgentShortcutIdentity(agentWindowID: agentWindow.id) }
            if let launcher, !launcher.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AppKitController.codingAgentShortcutIdentity(launcherName: launcher.name)
            }
            return nil
        }

        var status: AgentWindowStatus? { agentWindow?.status }
        var isEditable: Bool { launcher != nil }
        var isRunning: Bool { agentWindow != nil }
        var canRestart: Bool {
            guard let agentWindow else { return false }
            if launcher != nil { return true }
            if agentWindow.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return false }
            return agentWindow.claimedLauncherName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private func displayEntries() -> [DisplayEntry] {
        let configuredAgentNames = Set(launchers.map(\.name).map(AppKitController.normalizedRunRowName).filter { !$0.isEmpty })
        let configuredAgentIDs = Set(launchers.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        var entries: [DisplayEntry] = []

        for launcher in launchers {
            let normalizedName = AppKitController.normalizedRunRowName(launcher.name)
            let matchedAgent = agentWindows.first(where: { agentWindow in
                if agentWindow.claimedLauncherID == launcher.id { return true }
                guard agentWindow.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return false }
                return !normalizedName.isEmpty && AppKitController.normalizedRunRowName(agentWindow.label ?? "") == normalizedName
            })
            entries.append(
                DisplayEntry(
                    launcher: launcher, agentWindow: matchedAgent, runtimeWindowTitle: matchedAgent.flatMap { runtimeWindowTitleByAgentID[$0.id] }))
        }

        for agentWindow in agentWindows {
            if let claimedLauncherID = agentWindow.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines), !claimedLauncherID.isEmpty {
                if configuredAgentIDs.contains(claimedLauncherID) { continue }
            } else {
                guard !configuredAgentNames.contains(AppKitController.normalizedRunRowName(agentWindow.label ?? "")) else { continue }
            }
            entries.append(DisplayEntry(launcher: nil, agentWindow: agentWindow, runtimeWindowTitle: runtimeWindowTitleByAgentID[agentWindow.id]))
        }

        return entries
    }

    var currentLaunchers: [AgentLauncher] { launchers }

    // MARK: Row lifecycle

    private func refreshRows(animated: Bool, preservingEditing: Bool = true) {
        let existingEditing: [String: AgentLauncher] =
            preservingEditing
            ? Dictionary(
                uniqueKeysWithValues: rows.enumerated().compactMap { index, row -> (String, AgentLauncher)? in
                    guard row.isEditing else { return nil }
                    return (row.identity(from: launchers[safe: index]), row.formSnapshot())
                }) : [:]

        rowsStack.removeAllArrangedSubviews()
        rows.removeAll()

        let entries = displayEntries()
        for (_, entry) in entries.enumerated() {
            let launcher = entry.displayLauncher
            let shortcut = entry.identity.flatMap { shortcutsByIdentity[$0] }
            let focusAction: (() -> Void)?
            if let agentWindow = entry.agentWindow {
                focusAction = onFocusAgentWindow.map { handler in { handler(agentWindow) } }
            } else {
                focusAction = onFocusLauncher.map { handler in { handler(launcher) } }
            }
            let row = AgentLauncherRowView(
                launcher: launcher, shortcut: shortcut, status: entry.status, isEditable: entry.isEditable,
                showsRuntimeControls: showsRuntimeControls, isRunning: entry.isRunning, canRestart: entry.canRestart, onFocus: focusAction)
            row.onBeginEdit = { [weak self] in self?.handleBeginEdit(row: row) }
            row.onCancel = { [weak self] in self?.handleCancel(row: row) }
            row.onSave = { [weak self] edited in self?.handleSave(row: row, edited: edited) }
            row.onRemove = { [weak self] in self?.handleRemove(row: row) }
            row.onRun = { [weak self, launcher = entry.launcher] in
                guard let launcher else { return }
                self?.onRunLauncher?(launcher)
            }
            row.onStop = { [weak self, agentWindow = entry.agentWindow] in
                guard let agentWindow else { return }
                self?.onStopAgentWindow?(agentWindow)
            }
            row.onRestart = { [weak self, agentWindow = entry.agentWindow] in
                guard let agentWindow else { return }
                self?.onRestartAgentWindow?(agentWindow)
            }
            rows.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if let snapshot = existingEditing[row.identity(from: launcher)] { row.enterEditing(prefill: snapshot, animated: false) }
        }
        countLabel.stringValue = "\(entries.count)"
        _ = animated
    }
    // MARK: Row callbacks

    private func handleBeginEdit(row: AgentLauncherRowView) { row.enterEditing(prefill: nil, animated: true) }

    private func handleCancel(row: AgentLauncherRowView) {
        guard let index = rows.firstIndex(of: row) else { return }
        if pendingDraftIndex == index {
            launchers.remove(at: index)
            pendingDraftIndex = nil
            refreshRows(animated: true)
            return
        }
        row.exitEditing(animated: true)
    }

    private func handleSave(row: AgentLauncherRowView, edited: AgentLauncher) {
        guard let index = rows.firstIndex(of: row), index < launchers.count else { return }
        launchers[index] = edited
        if pendingDraftIndex == index { pendingDraftIndex = nil }
        row.exitEditing(animated: true)
        row.rebindCollapsedContent(from: edited)
        onCommit?(launchers)
    }

    private func handleRemove(row: AgentLauncherRowView) {
        guard let index = rows.firstIndex(of: row), index < launchers.count else { return }
        let target = launchers[index]
        let isDraft = (pendingDraftIndex == index)
        let commitAfterRemove = !isDraft
        let confirm = { [weak self] (approved: Bool) in
            guard let self, approved else { return }
            guard let currentIndex = self.rows.firstIndex(of: row), currentIndex < self.launchers.count else { return }
            self.launchers.remove(at: currentIndex)
            if self.pendingDraftIndex == currentIndex { self.pendingDraftIndex = nil }
            self.refreshRows(animated: true)
            if commitAfterRemove { self.onCommit?(self.launchers) }
        }
        let displayName = target.name.isEmpty ? "this agent" : target.name
        RowSectionRemoveConfirmation.confirm(
            messageText: "Remove \(displayName)?", informativeText: "This removes the coding agent from the workspace.", isDraft: isDraft,
            presenter: presentRemoveConfirmation.map { presenter in { presenter(target, $0) } }, onDecision: confirm)
    }

    @objc func handleAdd(_ sender: NSButton) {
        let blank = AgentLauncher(name: "", command: "")
        launchers.append(blank)
        pendingDraftIndex = launchers.count - 1
        refreshRows(animated: true)
        rows.last?.enterEditing(prefill: blank, animated: false)
    }
}

// MARK: - AgentLauncherRowView

@MainActor final class AgentLauncherRowView: HoverRevealRowView {
    var onBeginEdit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: ((AgentLauncher) -> Void)?
    var onRemove: (() -> Void)?
    var onRun: (() -> Void)?
    var onStop: (() -> Void)?
    var onRestart: (() -> Void)?

    private let body = NSStackView()
    private var collapsedContainer: NSStackView = NSStackView()
    private var editingContainer: NSStackView?
    private(set) var isEditing: Bool = false
    private let isEditable: Bool
    private let showsRuntimeControls: Bool
    private var isRunning: Bool
    private let canRestart: Bool

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var runButton: NSButton?
    private var stopButton: NSButton?
    private var restartButton: NSButton?
    private var editButton: NSButton?
    private var removeButton: NSButton?
    private var agentTileTextLabel: NSTextField?
    private var currentLauncher: AgentLauncher
    private var onFocus: (() -> Void)?

    private var nameField: NSTextField?
    private var commandField: NSTextField?

    init(
        launcher: AgentLauncher, shortcut: String? = nil, status: AgentWindowStatus? = nil, isEditable: Bool = true,
        showsRuntimeControls: Bool = true, isRunning: Bool = false, canRestart: Bool = false, onFocus: (() -> Void)? = nil
    ) {
        self.currentLauncher = launcher
        self.isEditable = isEditable
        self.showsRuntimeControls = showsRuntimeControls
        self.isRunning = isRunning
        self.canRestart = canRestart
        self.onFocus = onFocus
        super.init(frame: .zero)

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let shortcutView = shortcut.map { RowPrimitives.shortcutChip($0) }
        let collapsedLine = Self.makeCollapsedLine(
            shortcut: shortcutView, status: status, isEditable: isEditable, nameLabel: nameLabel, detailLabel: detailLabel,
            tileText: Self.agentTileText(for: launcher), onRun: { [weak self] in self?.onRun?() }, onStop: { [weak self] in self?.onStop?() },
            onRestart: { [weak self] in self?.onRestart?() }, onEdit: { [weak self] in self?.onBeginEdit?() },
            onRemove: { [weak self] in self?.onRemove?() }, onFocus: onFocus)
        collapsedContainer = collapsedLine.row
        agentTileTextLabel = collapsedLine.agentTileTextLabel
        body.addArrangedSubview(collapsedContainer)
        collapsedContainer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureActionButtonsForHover(collapsedLine.actionButtons)
        runButton = collapsedLine.runButton
        stopButton = collapsedLine.stopButton
        restartButton = collapsedLine.restartButton
        editButton = collapsedLine.editButton
        removeButton = collapsedLine.removeButton
        rebindCollapsedContent(from: launcher)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func rebindCollapsedContent(from launcher: AgentLauncher) {
        currentLauncher = launcher
        agentTileTextLabel?.stringValue = Self.agentTileText(for: launcher)
        nameLabel.stringValue = launcher.name.isEmpty ? "(unnamed)" : launcher.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = Theme.text
        nameLabel.setAccessibilityIdentifier("agent-launcher-row-name")
        detailLabel.stringValue = launcher.command
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = Theme.muted
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setAccessibilityIdentifier("agent-launcher-row-detail")
        updateRuntimeActionVisibility()
    }

    func enterEditing(prefill: AgentLauncher?, animated: Bool) {
        guard isEditable else { return }
        guard !isEditing else { return }
        isEditing = true
        let seed = prefill ?? currentLauncher
        let (form, fields) = Self.makeEditingForm(
            launcher: seed, onCancel: { [weak self] in self?.onCancel?() }, onSave: { [weak self] edited in self?.onSave?(edited) })
        nameField = fields.name
        commandField = fields.command
        editingContainer = form
        let run = { [self] in
            body.removeArrangedSubview(collapsedContainer)
            collapsedContainer.isHidden = true
            body.addArrangedSubview(form)
            form.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                run()
            }
        } else {
            run()
        }
        window?.makeFirstResponder(fields.name)
    }

    func exitEditing(animated: Bool) {
        guard isEditable else { return }
        guard isEditing, let form = editingContainer else { return }
        isEditing = false
        let run = { [self] in
            body.removeArrangedSubview(form)
            form.removeFromSuperview()
            collapsedContainer.isHidden = false
            body.addArrangedSubview(collapsedContainer)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                run()
            }
        } else {
            run()
        }
        editingContainer = nil
        nameField = nil
        commandField = nil
    }

    func identity(from launcher: AgentLauncher?) -> String {
        let fromState = currentLauncher.name.isEmpty ? currentLauncher.command : currentLauncher.name
        return fromState.isEmpty ? (launcher?.name ?? "") : fromState
    }

    func formSnapshot() -> AgentLauncher {
        AgentLauncher(id: currentLauncher.id, name: nameField?.stringValue ?? "", command: commandField?.stringValue ?? "")
    }

    private static func makeCollapsedLine(
        shortcut: NSView? = nil, status: AgentWindowStatus?, isEditable: Bool, nameLabel: NSTextField, detailLabel: NSTextField, tileText: String,
        onRun: @escaping () -> Void, onStop: @escaping () -> Void, onRestart: @escaping () -> Void, onEdit: @escaping () -> Void,
        onRemove: @escaping () -> Void, onFocus: (() -> Void)?
    ) -> (
        row: NSStackView, actionButtons: [NSButton], runButton: NSButton, stopButton: NSButton, restartButton: NSButton, editButton: NSButton?,
        removeButton: NSButton?, agentTileTextLabel: NSTextField?
    ) {
        var contentViews: [NSView] = []
        contentViews.append(RowPrimitives.statusSlot(status.flatMap(makeStatusIndicator)))
        if let shortcut { contentViews.append(shortcut) }
        let agentTile = RowPrimitives.typeTextTile(.agent, text: tileText, accessibilityLabel: "Coding Agent")
        let agentTileTextLabel = agentTile.subviews.compactMap { $0 as? NSTextField }.first
        agentTileTextLabel?.setAccessibilityIdentifier("agent-launcher-row-tile")
        contentViews.append(agentTile)
        let textStack = NSStackView(views: [nameLabel, detailLabel])
        textStack.orientation = .horizontal
        textStack.alignment = .firstBaseline
        textStack.spacing = 6
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentViews.append(textStack)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        contentViews.append(spacer)

        let contentArea = NSStackView(views: contentViews)
        contentArea.orientation = .horizontal
        contentArea.alignment = .centerY
        contentArea.spacing = 10
        contentArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        if let onFocus { attachRowClickAction(to: contentArea, action: onFocus) }

        let runButton = buildActionButton(symbol: "play.fill", tooltip: "Run") { _ in onRun() }
        runButton.setAccessibilityIdentifier("agent-launcher-row-run")
        let stopButton = buildActionButton(symbol: "stop.fill", tooltip: "Stop") { _ in onStop() }
        stopButton.setAccessibilityIdentifier("agent-launcher-row-stop")
        let restartButton = buildActionButton(symbol: "arrow.clockwise", tooltip: "Restart") { _ in onRestart() }
        restartButton.setAccessibilityIdentifier("agent-launcher-row-restart")

        var rowViews: [NSView] = [contentArea, runButton, stopButton, restartButton]
        var actionButtons = [runButton, stopButton, restartButton]

        let editButton: NSButton?
        let removeButton: NSButton?
        if isEditable {
            let builtEditButton = buildActionButton(symbol: "pencil", tooltip: "Edit") { _ in onEdit() }
            builtEditButton.setAccessibilityIdentifier("agent-launcher-row-edit")
            let builtRemoveButton = buildActionButton(symbol: "trash", tooltip: "Remove") { _ in onRemove() }
            builtRemoveButton.setAccessibilityIdentifier("agent-launcher-row-remove")
            editButton = builtEditButton
            removeButton = builtRemoveButton
            rowViews.append(contentsOf: [builtEditButton, builtRemoveButton])
            actionButtons.append(contentsOf: [builtEditButton, builtRemoveButton])
        } else {
            editButton = nil
            removeButton = nil
        }

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        return (row, actionButtons, runButton, stopButton, restartButton, editButton, removeButton, agentTileTextLabel)
    }

    static func agentTileText(for launcher: AgentLauncher) -> String { agentTileText(name: launcher.name, command: launcher.command) }

    static func agentTileText(name: String, command: String) -> String {
        for candidate in [name, command] { if let tileText = knownAgentTileText(in: candidate) { return tileText } }

        let letters = name.uppercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let text = letters.prefix(2).map { String($0) }.joined()
        return text.isEmpty ? "AI" : text
    }

    private static func knownAgentTileText(in text: String) -> String? {
        let tokens = Set(usefulTokens(in: text))
        if tokens.contains("codex") || tokens.contains("codexcli") { return "CX" }
        if tokens.contains("claude") || tokens.contains("claudecode") || tokens.contains("claudecodecli") { return "CL" }
        if tokens.contains("opencode") || tokens.contains("opencodecli") { return "OC" }
        return nil
    }

    private static func usefulTokens(in text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private func updateRuntimeActionVisibility() {
        runButton?.isHidden = !showsRuntimeControls || isRunning
        stopButton?.isHidden = !showsRuntimeControls || !isRunning
        restartButton?.isHidden = !showsRuntimeControls || !isRunning || !canRestart
        editButton?.isHidden = !isEditable
        removeButton?.isHidden = !isEditable
    }

    private static func makeStatusIndicator(_ status: AgentWindowStatus) -> NSView {
        switch status {
        case .spinning:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .mini
            spinner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([spinner.widthAnchor.constraint(equalToConstant: 10), spinner.heightAnchor.constraint(equalToConstant: 10)])
            spinner.startAnimation(nil)
            return spinner
        case .waiting: return makeStatusImage(symbol: "exclamationmark.triangle.fill", color: .systemOrange, accessibilityLabel: status.rawValue)
        case .done: return makeStatusImage(symbol: "circle.fill", color: .systemGreen, accessibilityLabel: status.rawValue)
        case .idle: return makeStatusImage(symbol: "circle.fill", color: .tertiaryLabelColor, accessibilityLabel: status.rawValue)
        }
    }

    private static func makeStatusImage(symbol: String, color: NSColor, accessibilityLabel: String) -> NSView {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        imageView.contentTintColor = color
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([imageView.widthAnchor.constraint(equalToConstant: 10), imageView.heightAnchor.constraint(equalToConstant: 10)])
        return imageView
    }

    private static func makeEditingForm(launcher: AgentLauncher, onCancel: @escaping () -> Void, onSave: @escaping (AgentLauncher) -> Void) -> (
        NSStackView, (name: NSTextField, command: NSTextField)
    ) {
        let nameField = NSTextField(string: launcher.name)
        nameField.placeholderString = "Name"
        nameField.setAccessibilityIdentifier("agent-launcher-row-edit-name")

        let commandField = NSTextField(string: launcher.command)
        commandField.placeholderString = "Command"
        commandField.setAccessibilityIdentifier("agent-launcher-row-edit-command")

        func labeled(_ title: String, _ field: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = Theme.muted
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
            let row = NSStackView(views: [label, field])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return row
        }

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.setAccessibilityIdentifier("agent-launcher-row-edit-cancel")
        Theme.applySecondaryStyle(to: cancelButton)

        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.setAccessibilityIdentifier("agent-launcher-row-edit-save")
        Theme.applyPrimaryStyle(to: saveButton)

        let refreshSaveEnabled = { [weak saveButton, weak nameField, weak commandField] in
            let hasName = !(nameField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            let hasCommand = !(commandField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            saveButton?.isEnabled = hasName && hasCommand
        }

        let target = AgentLauncherFormTarget()
        target.onCancel = onCancel
        target.onSave = { [weak nameField, weak commandField, launcherID = launcher.id] in
            onSave(AgentLauncher(id: launcherID, name: nameField?.stringValue ?? "", command: commandField?.stringValue ?? ""))
        }
        target.onTextChange = refreshSaveEnabled
        nameField.delegate = target
        commandField.delegate = target

        cancelButton.target = target
        cancelButton.action = #selector(AgentLauncherFormTarget.triggerCancel)
        saveButton.target = target
        saveButton.action = #selector(AgentLauncherFormTarget.triggerSave)
        nameField.nextKeyView = commandField
        commandField.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = nameField
        refreshSaveEnabled()

        let trailingButtons = NSStackView(views: [NSView(), cancelButton, saveButton])
        trailingButtons.orientation = .horizontal
        trailingButtons.alignment = .centerY
        trailingButtons.spacing = 6
        trailingButtons.translatesAutoresizingMaskIntoConstraints = false

        let form = NSStackView(views: [labeled("Name", nameField), labeled("Command", commandField), trailingButtons])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.edgeInsets = Theme.cardContentInsets
        form.translatesAutoresizingMaskIntoConstraints = false
        retainAssociatedObject(target, on: form)
        return (form, (nameField, commandField))
    }

    private static func buildActionButton(symbol: String, tooltip: String, onClick: @escaping (NSButton) -> Void) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = Theme.muted
        let target = AgentLauncherFormTarget()
        target.onCancel = { onClick(button) }
        button.target = target
        button.action = #selector(AgentLauncherFormTarget.triggerCancel)
        retainAssociatedObject(target, on: button)
        return button
    }

}

@MainActor private final class AgentLauncherFormTarget: NSObject, NSTextFieldDelegate {
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onTextChange: (() -> Void)?
    @objc func triggerCancel() { onCancel?() }
    @objc func triggerSave() { onSave?() }
    func controlTextDidChange(_ obj: Notification) { onTextChange?() }
}
