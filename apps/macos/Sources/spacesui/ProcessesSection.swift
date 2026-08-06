import AppKit
import spacesterminalcore
import workspacecore

/// Phase 2b.1 prototype. Replaces the table-style `ProcessEditor` for processes
/// with the live-and-config row pattern from the workspace-detail mocks
/// (`design-mocks/workspace-detail/variant-d.html`): each row shows status +
/// shortcut + name/command, expanding inline into a Name/Command/On-exit form
/// when the pencil icon is clicked.
///
/// This section owns transient form state (what's typed while editing) and
/// publishes committed edits through `onCommit`. The host view is responsible
/// for persisting that array back through the orchestrator — the section
/// itself is pure UI + local state.
@MainActor final class ProcessesSection {
    struct SupplementalRuntimeRow {
        let id: String
        let label: String
        let detail: String?
        let shortcut: String?
        let status: RowPrimitives.StatusKind
        let onFocus: (() -> Void)?
    }

    // MARK: Public surface

    let view: NSView

    /// Fires with the section's current processes after Save, Add, or Remove.
    var onCommit: (([ProcessTemplate]) -> Void)?

    /// Optional map from process name → current status. When absent, rows fall
    /// back to `.idle`. The host updates this separately from edits.
    var statusByName: [String: RowPrimitives.StatusKind] = [:] { didSet { for row in rows { row.refreshStatus(from: statusByName) } } }

    /// Optional map from process name → keyboard shortcut text like "⌘3".
    /// When absent, the shortcut chip is hidden.
    var shortcutsByName: [String: String] = [:] { didSet { refreshRows(animated: false) } }

    /// Called when a collapsed row is clicked. Receives the process template so
    /// the host can dispatch the appropriate focus or launch action.
    var onFocus: ((ProcessTemplate) -> Void)?
    var onRunProcess: ((ProcessTemplate) -> Void)?
    var onStopProcess: ((ProcessTemplate) -> Void)?
    var onRestartProcess: ((ProcessTemplate) -> Void)?
    var validateProcess: ((ProcessTemplate) throws -> Void)?
    var presentValidationError: ((Error) -> Void)?

    /// Override the remove-confirmation flow. When set, called instead of
    /// `NSAlert`. Tests use this to bypass the modal. Default presents an
    /// NSAlert and delivers the user's choice.
    var presentRemoveConfirmation: ((ProcessTemplate, @escaping (Bool) -> Void) -> Void)?

    // MARK: State

    private var processes: [ProcessTemplate]
    private let showsRuntimeControls: Bool
    private let rowsStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [ProcessRowView] = []
    /// Index of a row that was created via `+add` and has not yet been Saved.
    /// Used to drop the draft on Cancel and skip the remove-confirmation modal.
    private var pendingDraftIndex: Int?

    // MARK: Init

    init(processes: [ProcessTemplate] = [], subtitle: String? = nil, showsRuntimeControls: Bool = true) {
        self.processes = processes
        self.showsRuntimeControls = showsRuntimeControls

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = RowSectionHeader.make(
            title: "Processes", addButtonAccessibilityIdentifier: "processes-section-add", countLabel: countLabel, subtitle: subtitle)
        container.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        self.view = RowSectionCard.wrap(container)

        // Wire up the header add button now that `self` is fully initialized.
        if let addButton = header.arrangedSubviews.compactMap({ $0 as? NSButton }).first {
            addButton.target = self
            addButton.action = #selector(handleAdd(_:))
        }
        RowSectionCard.retain(self, in: view)

        refreshRows(animated: false)
    }

    // MARK: Public API

    func reload(processes: [ProcessTemplate]) { update(processes: processes, preservingEditing: true) }

    func replace(processes: [ProcessTemplate]) {
        pendingDraftIndex = nil
        update(processes: processes, preservingEditing: false)
    }

    private func update(processes: [ProcessTemplate], preservingEditing: Bool) {
        self.processes = processes
        refreshRows(animated: true, preservingEditing: preservingEditing)
    }

    /// Exposed for tests — current in-memory process list.
    var currentProcesses: [ProcessTemplate] { processes }

    var hasOpenEditor: Bool { rows.contains { $0.isEditing } }

    /// Exposed for tests — current row count.
    var rowCount: Int { rows.count }

    var supplementalRows: [SupplementalRuntimeRow] = [] { didSet { refreshRows(animated: false) } }

    /// Exposed for tests — whether row at index is in its editing state.
    func isEditing(at index: Int) -> Bool {
        guard index >= 0, index < rows.count else { return false }
        return rows[index].isEditing
    }

    // MARK: Row lifecycle

    private func refreshRows(animated: Bool, preservingEditing: Bool = true) {
        // Snapshot editing states so we don't lose in-flight edits on re-render
        // of the *same* underlying process list (e.g. when the host passes a
        // refreshed statusByName in).
        let existingEditing: [String: ProcessTemplate] =
            preservingEditing
            ? Dictionary(
                uniqueKeysWithValues: rows.enumerated().compactMap { index, row -> (String, ProcessTemplate)? in
                    guard row.isEditing else { return nil }
                    return (row.identity(from: processes[safe: index]), row.formSnapshot())
                }) : [:]

        rowsStack.removeAllArrangedSubviews()
        rows.removeAll()

        for (_, process) in processes.enumerated() {
            let focusAction: (() -> Void)? = onFocus.map { handler in { handler(process) } }
            let row = ProcessRowView(
                process: process, shortcut: shortcutsByName[process.name ?? ""], status: statusByName[process.name ?? ""] ?? .idle,
                onFocus: focusAction, showsRuntimeControls: showsRuntimeControls)
            row.onBeginEdit = { [weak self] in self?.handleBeginEdit(row: row) }
            row.onCancel = { [weak self] in self?.handleCancel(row: row) }
            row.onSave = { [weak self] edited in self?.handleSave(row: row, edited: edited) }
            row.onRemove = { [weak self] in self?.handleRemove(row: row) }
            row.onRun = { [weak self] in self?.handleRun(row: row) }
            row.onStop = { [weak self] in self?.handleStop(row: row) }
            row.onRestart = { [weak self] in self?.handleRestart(row: row) }

            rows.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            // Restore editing state if this row was mid-edit pre-refresh.
            if let snapshot = existingEditing[row.identity(from: process)] { row.enterEditing(prefill: snapshot, animated: false) }
        }

        for supplemental in supplementalRows {
            let row = ProcessRowView(
                displayName: supplemental.label, detailText: supplemental.detail, shortcut: supplemental.shortcut, status: supplemental.status,
                onFocus: supplemental.onFocus, showsRuntimeControls: false, allowsEditing: false, allowsRemoval: false)
            rows.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        countLabel.stringValue = "\(processes.count + supplementalRows.count)"
        _ = animated  // animation polish deferred to 2b.2 — see prototype notes
    }
    // MARK: Row callbacks

    private func handleBeginEdit(row: ProcessRowView) { row.enterEditing(prefill: nil, animated: true) }

    private func handleCancel(row: ProcessRowView) {
        guard let index = rows.firstIndex(of: row) else { return }
        if pendingDraftIndex == index {
            // Cancelling a never-saved draft: drop the row entirely.
            processes.remove(at: index)
            pendingDraftIndex = nil
            refreshRows(animated: true)
            return
        }
        row.exitEditing(animated: true)
    }

    private func handleSave(row: ProcessRowView, edited: ProcessTemplate) {
        guard let index = rows.firstIndex(of: row), index < processes.count else { return }
        do { try validateProcess?(edited) } catch {
            presentValidationError?(error)
            return
        }
        processes[index] = edited
        if pendingDraftIndex == index { pendingDraftIndex = nil }
        row.exitEditing(animated: true)
        row.rebindCollapsedContent(from: edited, shortcut: shortcutsByName[edited.name ?? ""], status: statusByName[edited.name ?? ""] ?? .idle)
        onCommit?(processes)
    }

    private func handleStop(row: ProcessRowView) {
        guard let index = rows.firstIndex(of: row), index < processes.count else { return }
        onStopProcess?(processes[index])
    }

    private func handleRun(row: ProcessRowView) {
        guard let index = rows.firstIndex(of: row), index < processes.count else { return }
        onRunProcess?(processes[index])
    }

    private func handleRestart(row: ProcessRowView) {
        guard let index = rows.firstIndex(of: row), index < processes.count else { return }
        onRestartProcess?(processes[index])
    }

    private func handleRemove(row: ProcessRowView) {
        guard let index = rows.firstIndex(of: row), index < processes.count else { return }
        let target = processes[index]
        let isDraft = (pendingDraftIndex == index)
        let commitAfterRemove = !isDraft  // drafts have never been persisted, so nothing to commit
        let confirm = { [weak self] (approved: Bool) in
            guard let self, approved else { return }
            guard let currentIndex = self.rows.firstIndex(of: row), currentIndex < self.processes.count else { return }
            self.processes.remove(at: currentIndex)
            if self.pendingDraftIndex == currentIndex { self.pendingDraftIndex = nil }
            self.refreshRows(animated: true)
            if commitAfterRemove { self.onCommit?(self.processes) }
        }
        let displayName = target.name?.isEmpty == false ? (target.name ?? "") : "this process"
        RowSectionRemoveConfirmation.confirm(
            messageText: "Remove \(displayName)?", informativeText: "This removes the process from the workspace. You can add it again later.",
            isDraft: isDraft, presenter: presentRemoveConfirmation.map { presenter in { presenter(target, $0) } }, onDecision: confirm)
    }

    @objc func handleAdd(_ sender: NSButton) {
        let blank = ProcessTemplate(name: nil, command: "", onExit: .none)
        processes.append(blank)
        pendingDraftIndex = processes.count - 1
        refreshRows(animated: true)
        // Put the newly-appended row directly into editing so the user can type.
        // Don't call onCommit here — wait for Save so the orchestrator's
        // validators don't reject the empty placeholder.
        rows.last?.enterEditing(prefill: blank, animated: false)
    }
}

// MARK: - ProcessRowView

@MainActor final class ProcessRowView: HoverRevealRowView {
    // Callbacks
    var onBeginEdit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: ((ProcessTemplate) -> Void)?
    var onRemove: (() -> Void)?
    var onRun: (() -> Void)?
    var onStop: (() -> Void)?
    var onRestart: (() -> Void)?

    private let body = NSStackView()
    private var collapsedContainer: NSStackView = NSStackView()
    private var editingContainer: NSStackView?
    private(set) var isEditing: Bool = false

    private let shortcutChip: NSView?
    private let statusDot: StatusDotView
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var runButton: NSButton?
    private var stopButton: NSButton?
    private var restartButton: NSButton?
    private var editButton: NSButton?
    private var removeButton: NSButton?
    private var onFocus: (() -> Void)?

    private var currentProcess: ProcessTemplate
    private var currentStatus: RowPrimitives.StatusKind
    private let showsRuntimeControls: Bool
    private let allowsEditing: Bool
    private let allowsRemoval: Bool

    // Fields that appear in the editing subtree.
    private var nameField: NSTextField?
    private var commandField: NSTextField?
    private var onExitSegmented: NSSegmentedControl?

    init(
        process: ProcessTemplate, shortcut: String?, status: RowPrimitives.StatusKind, onFocus: (() -> Void)? = nil, showsRuntimeControls: Bool = true
    ) {
        self.currentProcess = process
        self.onFocus = onFocus
        self.shortcutChip = shortcut.map { RowPrimitives.shortcutChip($0) }
        self.statusDot = RowPrimitives.statusDot(status)
        self.currentStatus = status
        self.showsRuntimeControls = showsRuntimeControls
        self.allowsEditing = true
        self.allowsRemoval = true
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

        let collapsedLine = Self.makeCollapsedLine(
            shortcut: shortcutChip, statusDot: statusDot, nameLabel: nameLabel, detailLabel: detailLabel, onRun: { [weak self] in self?.onRun?() },
            onStop: { [weak self] in self?.onStop?() }, onRestart: { [weak self] in self?.onRestart?() },
            onEdit: { [weak self] in self?.onBeginEdit?() }, onRemove: { [weak self] in self?.onRemove?() }, onFocus: onFocus)
        collapsedContainer = collapsedLine.row
        body.addArrangedSubview(collapsedContainer)
        collapsedContainer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureActionButtonsForHover(collapsedLine.actionButtons)
        runButton = collapsedLine.runButton
        stopButton = collapsedLine.stopButton
        restartButton = collapsedLine.restartButton
        editButton = collapsedLine.editButton
        removeButton = collapsedLine.removeButton

        rebindCollapsedContent(from: process, shortcut: shortcut, status: status)
    }

    init(
        displayName: String, detailText: String?, shortcut: String?, status: RowPrimitives.StatusKind, onFocus: (() -> Void)? = nil,
        showsRuntimeControls: Bool = false, allowsEditing: Bool = false, allowsRemoval: Bool = false
    ) {
        self.currentProcess = ProcessTemplate(name: displayName, command: detailText ?? "")
        self.onFocus = onFocus
        self.shortcutChip = shortcut.map { RowPrimitives.shortcutChip($0) }
        self.statusDot = RowPrimitives.statusDot(status)
        self.currentStatus = status
        self.showsRuntimeControls = showsRuntimeControls
        self.allowsEditing = allowsEditing
        self.allowsRemoval = allowsRemoval
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

        let collapsedLine = Self.makeCollapsedLine(
            shortcut: shortcutChip, statusDot: statusDot, nameLabel: nameLabel, detailLabel: detailLabel, onRun: { [weak self] in self?.onRun?() },
            onStop: { [weak self] in self?.onStop?() }, onRestart: { [weak self] in self?.onRestart?() },
            onEdit: { [weak self] in self?.onBeginEdit?() }, onRemove: { [weak self] in self?.onRemove?() }, onFocus: onFocus)
        collapsedContainer = collapsedLine.row
        body.addArrangedSubview(collapsedContainer)
        collapsedContainer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureActionButtonsForHover(collapsedLine.actionButtons)
        runButton = collapsedLine.runButton
        stopButton = collapsedLine.stopButton
        restartButton = collapsedLine.restartButton
        editButton = collapsedLine.editButton
        removeButton = collapsedLine.removeButton

        rebindDisplayContent(name: displayName, detail: detailText, status: status)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    // MARK: Collapsed line

    func rebindCollapsedContent(from process: ProcessTemplate, shortcut: String?, status: RowPrimitives.StatusKind) {
        currentProcess = process
        currentStatus = status
        rebindDisplayContent(name: process.name?.isEmpty == false ? (process.name ?? "") : "(unnamed)", detail: process.command, status: status)
        _ = shortcut
    }

    private func rebindDisplayContent(name: String, detail: String?, status: RowPrimitives.StatusKind) {
        nameLabel.stringValue = name
        nameLabel.font = Typography.rowLabel
        nameLabel.textColor = Theme.text
        detailLabel.stringValue = detail ?? ""
        detailLabel.font = Typography.rowDetail
        detailLabel.textColor = Theme.muted
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isHidden = (detail ?? "").isEmpty
        statusDot.kind = status
        updateRuntimeActionVisibility()
    }

    func refreshStatus(from statusByName: [String: RowPrimitives.StatusKind]) {
        let status = statusByName[currentProcess.name ?? ""] ?? .idle
        currentStatus = status
        statusDot.kind = status
        updateRuntimeActionVisibility()
    }

    // MARK: Editing subtree

    func enterEditing(prefill: ProcessTemplate?, animated: Bool) {
        guard !isEditing else { return }
        isEditing = true

        let seed = prefill ?? currentProcess
        let (form, fields) = Self.makeEditingForm(
            process: seed, onCancel: { [weak self] in self?.onCancel?() }, onSave: { [weak self] edited in self?.onSave?(edited) })
        nameField = fields.name
        commandField = fields.command
        onExitSegmented = fields.onExit
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
        onExitSegmented = nil
    }

    // MARK: Identity + snapshot helpers (for refresh reconciliation)

    func identity(from process: ProcessTemplate?) -> String {
        let fromState = currentProcess.id
        let fromArg = process?.id ?? ""
        return fromState.isEmpty ? fromArg : fromState
    }

    func formSnapshot() -> ProcessTemplate {
        ProcessTemplate(
            id: currentProcess.id, name: (nameField?.stringValue).flatMap { $0.isEmpty ? nil : $0 }, command: commandField?.stringValue ?? "",
            onExit: ProcessExitAction.allCases[safe: onExitSegmented?.selectedSegment ?? 0] ?? .none)
    }

    // MARK: Builders

    private static func makeCollapsedLine(
        shortcut: NSView?, statusDot: NSView, nameLabel: NSTextField, detailLabel: NSTextField, onRun: @escaping () -> Void,
        onStop: @escaping () -> Void, onRestart: @escaping () -> Void, onEdit: @escaping () -> Void, onRemove: @escaping () -> Void,
        onFocus: (() -> Void)?
    ) -> (
        row: NSStackView, actionButtons: [NSButton], runButton: NSButton, stopButton: NSButton, restartButton: NSButton, editButton: NSButton,
        removeButton: NSButton
    ) {
        var contentViews: [NSView] = []
        contentViews.append(RowPrimitives.statusSlot(statusDot))
        if let shortcut { contentViews.append(shortcut) }
        contentViews.append(RowPrimitives.typeIconTile(.process, symbol: "terminal", accessibilityLabel: "Process"))

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

        // Content area receives the focus gesture. Buttons are siblings in the
        // outer row so clicks on edit/remove don't also trigger focus.
        let contentArea = NSStackView(views: contentViews)
        contentArea.orientation = .horizontal
        contentArea.alignment = .centerY
        contentArea.spacing = 10
        contentArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        if let onFocus { attachRowClickAction(to: contentArea, action: onFocus) }

        let runButton = buildActionButton(symbol: "play.fill", tooltip: "Run") { _ in onRun() }
        runButton.setAccessibilityIdentifier("process-row-run")
        let stopButton = buildActionButton(symbol: "stop.fill", tooltip: "Stop") { _ in onStop() }
        stopButton.setAccessibilityIdentifier("process-row-stop")
        let restartButton = buildActionButton(symbol: "arrow.clockwise", tooltip: "Restart") { _ in onRestart() }
        restartButton.setAccessibilityIdentifier("process-row-restart")
        let editButton = buildActionButton(symbol: "pencil", tooltip: "Edit") { _ in onEdit() }
        editButton.setAccessibilityIdentifier("process-row-edit")
        let removeButton = buildActionButton(symbol: "trash", tooltip: "Remove") { _ in onRemove() }
        removeButton.setAccessibilityIdentifier("process-row-remove")

        let row = NSStackView(views: [contentArea, runButton, stopButton, restartButton, editButton, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        return (
            row, [runButton, stopButton, restartButton, editButton, removeButton], runButton, stopButton, restartButton, editButton, removeButton
        )
    }

    private func updateRuntimeActionVisibility() {
        if !showsRuntimeControls {
            runButton?.isHidden = true
            stopButton?.isHidden = true
            restartButton?.isHidden = true
        }
        editButton?.isHidden = !allowsEditing
        removeButton?.isHidden = !allowsRemoval
        guard showsRuntimeControls else { return }
        let showsRuntimeButtons = currentStatus == .running
        runButton?.isHidden = showsRuntimeButtons
        stopButton?.isHidden = !showsRuntimeButtons
        restartButton?.isHidden = !showsRuntimeButtons
    }

    private static func makeEditingForm(process: ProcessTemplate, onCancel: @escaping () -> Void, onSave: @escaping (ProcessTemplate) -> Void) -> (
        NSStackView, (name: NSTextField, command: NSTextField, onExit: NSSegmentedControl)
    ) {
        let nameField = NSTextField(string: process.name ?? "")
        nameField.placeholderString = "Name"
        nameField.setAccessibilityIdentifier("process-row-edit-name")

        let commandField = NSTextField(string: process.command)
        commandField.placeholderString = "Command"
        commandField.setAccessibilityIdentifier("process-row-edit-command")

        let onExitSegmented = NSSegmentedControl(
            labels: ProcessExitAction.allCases.map { $0.rawValue.capitalized }, trackingMode: .selectOne, target: nil, action: nil)
        onExitSegmented.selectedSegment = ProcessExitAction.allCases.firstIndex(of: process.onExit) ?? 0
        onExitSegmented.setAccessibilityIdentifier("process-row-edit-on-exit")

        func labeled(_ title: String, _ field: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.font = Typography.metadataTitle
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

        let onExitRow = labeled("On exit", onExitSegmented)
        onExitRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.setAccessibilityIdentifier("process-row-edit-cancel")
        Theme.applySecondaryStyle(to: cancelButton)

        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.setAccessibilityIdentifier("process-row-edit-save")
        Theme.applyPrimaryStyle(to: saveButton)

        // Target/action closures stored on NSButton require a Cocoa selector; use
        // a lightweight target helper tied to the form's lifetime.
        let target = ClosureTarget()
        target.onCancel = onCancel
        target.onSave = { [weak nameField, weak commandField, weak onExitSegmented] in
            let edited = ProcessTemplate(
                id: process.id, name: nameField?.stringValue.isEmpty == false ? nameField?.stringValue : nil,
                command: commandField?.stringValue ?? "", onExit: ProcessExitAction.allCases[safe: onExitSegmented?.selectedSegment ?? 0] ?? .none)
            onSave(edited)
        }
        let refreshSaveEnabled = { [weak saveButton, weak nameField, weak commandField] in
            let hasName = !(nameField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            let hasCommand = !(commandField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            saveButton?.isEnabled = hasName && hasCommand
        }
        target.onTextChange = refreshSaveEnabled
        nameField.delegate = target
        commandField.delegate = target

        cancelButton.target = target
        cancelButton.action = #selector(ClosureTarget.triggerCancel)
        saveButton.target = target
        saveButton.action = #selector(ClosureTarget.triggerSave)
        nameField.nextKeyView = commandField
        commandField.nextKeyView = onExitSegmented
        onExitSegmented.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = nameField
        refreshSaveEnabled()  // set initial state before user types

        let trailingButtons = NSStackView(views: [NSView(), cancelButton, saveButton])
        trailingButtons.orientation = .horizontal
        trailingButtons.alignment = .centerY
        trailingButtons.spacing = 6
        trailingButtons.translatesAutoresizingMaskIntoConstraints = false

        let form = NSStackView(views: [labeled("Name", nameField), labeled("Command", commandField), onExitRow, trailingButtons])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.edgeInsets = Theme.cardContentInsets
        form.translatesAutoresizingMaskIntoConstraints = false

        // Anchor the target to the form so it lives as long as the form does.
        retainAssociatedObject(target, on: form)

        return (form, (nameField, commandField, onExitSegmented))
    }

    private static func buildActionButton(symbol: String, tooltip: String, onClick: @escaping (NSButton) -> Void) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = Theme.muted
        let target = ClosureTarget()
        target.onCancel = { onClick(button) }
        button.target = target
        button.action = #selector(ClosureTarget.triggerCancel)
        retainAssociatedObject(target, on: button)
        return button
    }

}

// MARK: - ClosureTarget

@MainActor private final class ClosureTarget: NSObject, NSTextFieldDelegate {
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onTextChange: (() -> Void)?

    @objc func triggerCancel() { onCancel?() }
    @objc func triggerSave() { onSave?() }
    func controlTextDidChange(_ obj: Notification) { onTextChange?() }
}

// MARK: - Convenience
