import AppKit
import streamctl

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

    /// Override the remove-confirmation flow. When set, called instead of
    /// `NSAlert`. Tests use this to bypass the modal. Default presents an
    /// NSAlert and delivers the user's choice.
    var presentRemoveConfirmation: ((ProcessTemplate, @escaping (Bool) -> Void) -> Void)?

    // MARK: State

    private var processes: [ProcessTemplate]
    private let rowsStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [ProcessRowView] = []
    /// Index of a row that was created via `+add` and has not yet been Saved.
    /// Used to drop the draft on Cancel and skip the remove-confirmation modal.
    private var pendingDraftIndex: Int?

    // MARK: Init

    init(processes: [ProcessTemplate] = []) {
        self.processes = processes

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = Self.makeHeader(countLabel: countLabel)
        container.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let divider = Self.makeDivider()
        container.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        // Wrap in a section card so it reads as one unit.
        let card = ColoredBackgroundView()
        card.fillColor = Theme.surface
        card.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: card.leadingAnchor), container.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            container.topAnchor.constraint(equalTo: card.topAnchor), container.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        self.view = card

        // Wire up the header add button now that `self` is fully initialized.
        if let addButton = header.arrangedSubviews.compactMap({ $0 as? NSButton }).first {
            addButton.target = self
            addButton.action = #selector(handleAdd(_:))
        }
        objc_setAssociatedObject(card, &Self.anchorKey, self, .OBJC_ASSOCIATION_RETAIN)

        refreshRows(animated: false)
    }

    private static var anchorKey: UInt8 = 0

    // MARK: Public API

    func reload(processes: [ProcessTemplate]) {
        self.processes = processes
        refreshRows(animated: true)
    }

    /// Exposed for tests — current in-memory process list.
    var currentProcesses: [ProcessTemplate] { processes }

    /// Exposed for tests — current row count.
    var rowCount: Int { rows.count }

    /// Exposed for tests — whether row at index is in its editing state.
    func isEditing(at index: Int) -> Bool {
        guard index >= 0, index < rows.count else { return false }
        return rows[index].isEditing
    }

    // MARK: Header

    private static func makeHeader(countLabel: NSTextField) -> NSStackView {
        let title = NSTextField(labelWithString: "Processes")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text

        countLabel.font = .systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = Theme.muted

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let addButton = NSButton(title: "+ add", target: nil, action: nil)
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.contentTintColor = Theme.muted
        addButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        addButton.setAccessibilityIdentifier("processes-section-add")

        let header = NSStackView(views: [title, countLabel, spacer, addButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    private static func makeDivider() -> NSView {
        let line = ColoredBackgroundView()
        line.fillColor = Theme.border
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    // MARK: Row lifecycle

    private func refreshRows(animated: Bool) {
        // Snapshot editing states so we don't lose in-flight edits on re-render
        // of the *same* underlying process list (e.g. when the host passes a
        // refreshed statusByName in).
        let existingEditing: [String: ProcessTemplate] = Dictionary(
            uniqueKeysWithValues: rows.enumerated().compactMap { index, row -> (String, ProcessTemplate)? in
                guard row.isEditing else { return nil }
                return (row.identity(from: processes[safe: index]), row.formSnapshot())
            })

        clearRowsStack()
        rows.removeAll()

        for (index, process) in processes.enumerated() {
            let focusAction: (() -> Void)? = onFocus.map { handler in { handler(process) } }
            let row = ProcessRowView(
                process: process, shortcut: shortcutsByName[process.name ?? ""], status: statusByName[process.name ?? ""] ?? .idle,
                onFocus: focusAction)
            row.onBeginEdit = { [weak self] in self?.handleBeginEdit(row: row) }
            row.onCancel = { [weak self] in self?.handleCancel(row: row) }
            row.onSave = { [weak self] edited in self?.handleSave(row: row, edited: edited) }
            row.onRemove = { [weak self] in self?.handleRemove(row: row) }

            rows.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index > 0 {
                let sep = Self.makeDivider()
                rowsStack.insertArrangedSubview(sep, at: rowsStack.arrangedSubviews.count - 1)
                sep.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }

            // Restore editing state if this row was mid-edit pre-refresh.
            if let snapshot = existingEditing[row.identity(from: process)] { row.enterEditing(prefill: snapshot, animated: false) }
        }

        countLabel.stringValue = "\(processes.count)"
        _ = animated  // animation polish deferred to 2b.2 — see prototype notes
    }

    private func clearRowsStack() {
        for arrangedSubview in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
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
        processes[index] = edited
        if pendingDraftIndex == index { pendingDraftIndex = nil }
        row.exitEditing(animated: true)
        row.rebindCollapsedContent(from: edited, shortcut: shortcutsByName[edited.name ?? ""], status: statusByName[edited.name ?? ""] ?? .idle)
        onCommit?(processes)
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
        // Drafts have nothing committed; delete silently.
        if isDraft {
            confirm(true)
            return
        }
        if let presenter = presentRemoveConfirmation {
            presenter(target, confirm)
            return
        }
        let alert = NSAlert()
        let displayName = target.name?.isEmpty == false ? (target.name ?? "") : "this process"
        alert.messageText = "Remove \(displayName)?"
        alert.informativeText = "This removes the process from the workspace. You can add it again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
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

    private let body = NSStackView()
    private var collapsedContainer: NSStackView = NSStackView()
    private var editingContainer: NSStackView?
    private(set) var isEditing: Bool = false

    private let shortcutChip: NSView?
    private let statusDot: StatusDotView
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var onFocus: (() -> Void)?

    private var currentProcess: ProcessTemplate

    // Fields that appear in the editing subtree.
    private var nameField: NSTextField?
    private var commandField: NSTextField?
    private var onExitPopup: NSPopUpButton?

    init(process: ProcessTemplate, shortcut: String?, status: RowPrimitives.StatusKind, onFocus: (() -> Void)? = nil) {
        self.currentProcess = process
        self.onFocus = onFocus
        self.shortcutChip = shortcut.map { RowPrimitives.shortcutChip($0) }
        self.statusDot = RowPrimitives.statusDot(status)
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
            shortcut: shortcutChip, statusDot: statusDot, nameLabel: nameLabel, detailLabel: detailLabel,
            onEdit: { [weak self] in self?.onBeginEdit?() }, onRemove: { [weak self] in self?.onRemove?() }, onFocus: onFocus)
        collapsedContainer = collapsedLine.row
        body.addArrangedSubview(collapsedContainer)
        collapsedContainer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureActionButtonsForHover(collapsedLine.actionButtons)

        rebindCollapsedContent(from: process, shortcut: shortcut, status: status)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    // MARK: Collapsed line

    func rebindCollapsedContent(from process: ProcessTemplate, shortcut: String?, status: RowPrimitives.StatusKind) {
        currentProcess = process
        nameLabel.stringValue = process.name?.isEmpty == false ? (process.name ?? "") : "(unnamed)"
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = Theme.text
        detailLabel.stringValue = process.command
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = Theme.muted
        detailLabel.lineBreakMode = .byTruncatingTail
        statusDot.kind = status
        _ = shortcut
    }

    func refreshStatus(from statusByName: [String: RowPrimitives.StatusKind]) { statusDot.kind = statusByName[currentProcess.name ?? ""] ?? .idle }

    // MARK: Editing subtree

    func enterEditing(prefill: ProcessTemplate?, animated: Bool) {
        guard !isEditing else { return }
        isEditing = true

        let seed = prefill ?? currentProcess
        let (form, fields) = Self.makeEditingForm(
            process: seed, onCancel: { [weak self] in self?.onCancel?() }, onSave: { [weak self] edited in self?.onSave?(edited) })
        nameField = fields.name
        commandField = fields.command
        onExitPopup = fields.onExit
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
        onExitPopup = nil
    }

    // MARK: Identity + snapshot helpers (for refresh reconciliation)

    func identity(from process: ProcessTemplate?) -> String {
        // Prefer name; fall back to command so a process under edit remains
        // distinguishable even if its name was blanked mid-edit.
        let fromState = currentProcess.name ?? currentProcess.command
        let fromArg = process?.name ?? process?.command ?? ""
        return fromState.isEmpty ? fromArg : fromState
    }

    func formSnapshot() -> ProcessTemplate {
        ProcessTemplate(
            name: (nameField?.stringValue).flatMap { $0.isEmpty ? nil : $0 }, command: commandField?.stringValue ?? "",
            onExit: ProcessExitAction(rawValue: onExitPopup?.selectedItem?.representedObject as? String ?? "") ?? .none)
    }

    // MARK: Builders

    private static func makeCollapsedLine(
        shortcut: NSView?, statusDot: NSView, nameLabel: NSTextField, detailLabel: NSTextField, onEdit: @escaping () -> Void,
        onRemove: @escaping () -> Void, onFocus: (() -> Void)?
    ) -> (row: NSStackView, actionButtons: [NSButton]) {
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

        let editButton = buildActionButton(symbol: "pencil", tooltip: "Edit") { _ in onEdit() }
        editButton.setAccessibilityIdentifier("process-row-edit")
        let removeButton = buildActionButton(symbol: "trash", tooltip: "Remove") { _ in onRemove() }
        removeButton.setAccessibilityIdentifier("process-row-remove")

        let row = NSStackView(views: [contentArea, editButton, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        return (row, [editButton, removeButton])
    }

    private static func makeEditingForm(process: ProcessTemplate, onCancel: @escaping () -> Void, onSave: @escaping (ProcessTemplate) -> Void) -> (
        NSStackView, (name: NSTextField, command: NSTextField, onExit: NSPopUpButton)
    ) {
        let nameField = NSTextField(string: process.name ?? "")
        nameField.placeholderString = "Name"
        nameField.setAccessibilityIdentifier("process-row-edit-name")

        let commandField = NSTextField(string: process.command)
        commandField.placeholderString = "Command"
        commandField.setAccessibilityIdentifier("process-row-edit-command")

        let onExitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for action in ProcessExitAction.allCases {
            onExitPopup.addItem(withTitle: action.rawValue)
            onExitPopup.lastItem?.representedObject = action.rawValue
        }
        onExitPopup.selectItem(withTitle: process.onExit.rawValue)
        onExitPopup.setAccessibilityIdentifier("process-row-edit-on-exit")

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
        cancelButton.bezelStyle = .rounded
        cancelButton.setAccessibilityIdentifier("process-row-edit-cancel")

        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("process-row-edit-save")

        // Target/action closures stored on NSButton require a Cocoa selector; use
        // a lightweight target helper tied to the form's lifetime.
        let target = ClosureTarget()
        target.onCancel = onCancel
        target.onSave = { [weak nameField, weak commandField, weak onExitPopup] in
            let edited = ProcessTemplate(
                name: nameField?.stringValue.isEmpty == false ? nameField?.stringValue : nil, command: commandField?.stringValue ?? "",
                onExit: ProcessExitAction(rawValue: onExitPopup?.selectedItem?.representedObject as? String ?? "") ?? .none)
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
        refreshSaveEnabled()  // set initial state before user types

        let trailingButtons = NSStackView(views: [NSView(), cancelButton, saveButton])
        trailingButtons.orientation = .horizontal
        trailingButtons.alignment = .centerY
        trailingButtons.spacing = 6
        trailingButtons.translatesAutoresizingMaskIntoConstraints = false

        let form = NSStackView(views: [
            labeled("Name", nameField), labeled("Command", commandField), labeled("On exit", onExitPopup), trailingButtons,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        form.translatesAutoresizingMaskIntoConstraints = false

        // Anchor the target to the form so it lives as long as the form does.
        objc_setAssociatedObject(form, &Self.targetKey, target, .OBJC_ASSOCIATION_RETAIN)

        return (form, (nameField, commandField, onExitPopup))
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
        objc_setAssociatedObject(button, &targetKey, target, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    private static var targetKey: UInt8 = 0
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

extension Array { fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
