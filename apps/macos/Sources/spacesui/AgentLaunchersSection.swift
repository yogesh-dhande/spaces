import AppKit
import workspacecore

@MainActor final class AgentLaunchersSection {
    // MARK: Public surface

    let view: NSView
    var onCommit: (([AgentLauncher]) -> Void)?
    var presentRemoveConfirmation: ((AgentLauncher, @escaping (Bool) -> Void) -> Void)?

    // MARK: State

    private var launchers: [AgentLauncher]
    private let rowsStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [AgentLauncherRowView] = []
    private var pendingDraftIndex: Int?
    private var agentWindows: [AgentWindowRecord] = []
    private var runtimeWindowTitleByAgentID: [String: String] = [:]

    /// Map from launcher name → shortcut display text (e.g. "⌘5").
    var shortcutsByName: [String: String] = [:] { didSet { refreshRows(animated: false) } }

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

    /// Called when a collapsed row is clicked. Receives the launcher so the
    /// host can dispatch the appropriate focus or launch action.
    var onFocus: ((AgentLauncher) -> Void)?

    // MARK: Init

    init(launchers: [AgentLauncher] = [], subtitle: String? = nil) {
        self.launchers = launchers

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = Self.makeHeader(countLabel: countLabel, subtitle: subtitle)
        container.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let card = ColoredBackgroundView()
        card.fillColor = .clear
        card.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: card.leadingAnchor), container.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            container.topAnchor.constraint(equalTo: card.topAnchor), container.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        self.view = card

        if let addButton = header.arrangedSubviews.compactMap({ $0 as? NSButton }).first {
            addButton.target = self
            addButton.action = #selector(handleAdd(_:))
        }
        objc_setAssociatedObject(card, &Self.anchorKey, self, .OBJC_ASSOCIATION_RETAIN)

        refreshRows(animated: false)
    }

    private static var anchorKey: UInt8 = 0

    // MARK: Public API

    func reload(launchers: [AgentLauncher]) {
        self.launchers = launchers
        refreshRows(animated: true)
    }

    var rowCount: Int { rows.count }
    func isEditing(at index: Int) -> Bool { index >= 0 && index < rows.count ? rows[index].isEditing : false }

    private struct DisplayEntry {
        let launcher: AgentLauncher?
        let agentWindow: AgentWindowRecord?
        let runtimeWindowTitle: String?

        var displayLauncher: AgentLauncher {
            if let launcher { return launcher }
            let label = agentWindow?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (label?.isEmpty == false ? label : nil) ?? "Coding Agent"
            let detail = runtimeWindowTitle ?? ""
            return AgentLauncher(name: name, command: detail)
        }

        var shortcutName: String? {
            let value = launcher?.name ?? agentWindow?.label
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }

        var status: AgentWindowStatus? { agentWindow?.status }
        var isEditable: Bool { launcher != nil }
    }

    private func displayEntries() -> [DisplayEntry] {
        AppKitController.resolvedCodingAgentRunEntries(configuredAgentLaunchers: launchers, agentWindows: agentWindows).map {
            DisplayEntry(
                launcher: $0.launcher, agentWindow: $0.agentWindow, runtimeWindowTitle: $0.agentWindow.flatMap { runtimeWindowTitleByAgentID[$0.id] })
        }
    }

    // MARK: Header

    var currentLaunchers: [AgentLauncher] { launchers }

    private static func makeHeader(countLabel: NSTextField, subtitle: String? = nil) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: "Coding Agents")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text

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
        addButton.setAccessibilityIdentifier("agent-launchers-section-add")

        if let subtitle {
            let titleRow = NSStackView(views: [titleLabel, countLabel])
            titleRow.orientation = .horizontal
            titleRow.alignment = .firstBaseline
            titleRow.spacing = 6
            titleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            subtitleLabel.textColor = Theme.muted
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let titleStack = NSStackView(views: [titleRow, subtitleLabel])
            titleStack.orientation = .vertical
            titleStack.alignment = .leading
            titleStack.spacing = 2
            titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let header = NSStackView(views: [titleStack, spacer, addButton])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 8
            header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            header.translatesAutoresizingMaskIntoConstraints = false
            return header
        }

        let header = NSStackView(views: [titleLabel, countLabel, spacer, addButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    static func makeDivider() -> NSView {
        let line = ColoredBackgroundView()
        line.fillColor = Theme.border
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    // MARK: Row lifecycle

    private func refreshRows(animated: Bool) {
        let existingEditing: [String: AgentLauncher] = Dictionary(
            uniqueKeysWithValues: rows.enumerated().compactMap { index, row -> (String, AgentLauncher)? in
                guard row.isEditing else { return nil }
                return (row.identity(from: launchers[safe: index]), row.formSnapshot())
            })

        clearRowsStack()
        rows.removeAll()

        let entries = displayEntries()
        for (_, entry) in entries.enumerated() {
            let launcher = entry.displayLauncher
            let shortcut = entry.shortcutName.flatMap { shortcutsByName[$0] }
            let focusAction: (() -> Void)? = onFocus.map { handler in { handler(launcher) } }
            let row = AgentLauncherRowView(
                launcher: launcher, shortcut: shortcut, status: entry.status, isEditable: entry.isEditable, onFocus: focusAction)
            row.onBeginEdit = { [weak self] in self?.handleBeginEdit(row: row) }
            row.onCancel = { [weak self] in self?.handleCancel(row: row) }
            row.onSave = { [weak self] edited in self?.handleSave(row: row, edited: edited) }
            row.onRemove = { [weak self] in self?.handleRemove(row: row) }
            rows.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if let snapshot = existingEditing[row.identity(from: launcher)] { row.enterEditing(prefill: snapshot, animated: false) }
        }
        countLabel.stringValue = "\(entries.count)"
        _ = animated
    }

    private func clearRowsStack() {
        for arrangedSubview in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
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
        if isDraft {
            confirm(true)
            return
        }
        if let presenter = presentRemoveConfirmation {
            presenter(target, confirm)
            return
        }
        let alert = NSAlert()
        let displayName = target.name.isEmpty ? "this agent" : target.name
        alert.messageText = "Remove \(displayName)?"
        alert.informativeText = "This removes the coding agent from the workspace."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
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

    private let body = NSStackView()
    private var collapsedContainer: NSStackView = NSStackView()
    private var editingContainer: NSStackView?
    private(set) var isEditing: Bool = false
    private let isEditable: Bool

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var currentLauncher: AgentLauncher
    private var onFocus: (() -> Void)?

    private var nameField: NSTextField?
    private var commandField: NSTextField?

    init(launcher: AgentLauncher, shortcut: String? = nil, status: AgentWindowStatus? = nil, isEditable: Bool = true, onFocus: (() -> Void)? = nil) {
        self.currentLauncher = launcher
        self.isEditable = isEditable
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
            onEdit: { [weak self] in self?.onBeginEdit?() }, onRemove: { [weak self] in self?.onRemove?() }, onFocus: onFocus)
        collapsedContainer = collapsedLine.row
        body.addArrangedSubview(collapsedContainer)
        collapsedContainer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureActionButtonsForHover(collapsedLine.actionButtons)
        rebindCollapsedContent(from: launcher)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func rebindCollapsedContent(from launcher: AgentLauncher) {
        currentLauncher = launcher
        nameLabel.stringValue = launcher.name.isEmpty ? "(unnamed)" : launcher.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = Theme.text
        detailLabel.stringValue = launcher.command
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = Theme.muted
        detailLabel.lineBreakMode = .byTruncatingTail
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

    func formSnapshot() -> AgentLauncher { AgentLauncher(name: nameField?.stringValue ?? "", command: commandField?.stringValue ?? "") }

    private static func makeCollapsedLine(
        shortcut: NSView? = nil, status: AgentWindowStatus?, isEditable: Bool, nameLabel: NSTextField, detailLabel: NSTextField,
        onEdit: @escaping () -> Void, onRemove: @escaping () -> Void, onFocus: (() -> Void)?
    ) -> (row: NSStackView, actionButtons: [NSButton]) {
        var contentViews: [NSView] = []
        contentViews.append(RowPrimitives.statusSlot(status.flatMap(makeStatusIndicator)))
        if let shortcut { contentViews.append(shortcut) }
        contentViews.append(RowPrimitives.typeIconTile(.agent, symbol: "cpu.fill", accessibilityLabel: "Coding Agent"))
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

        if !isEditable {
            let row = NSStackView(views: [contentArea])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
            row.translatesAutoresizingMaskIntoConstraints = false
            return (row, [])
        }

        let editButton = buildActionButton(symbol: "pencil", tooltip: "Edit") { _ in onEdit() }
        editButton.setAccessibilityIdentifier("agent-launcher-row-edit")
        let removeButton = buildActionButton(symbol: "trash", tooltip: "Remove") { _ in onRemove() }
        removeButton.setAccessibilityIdentifier("agent-launcher-row-remove")

        let row = NSStackView(views: [contentArea, editButton, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        return (row, [editButton, removeButton])
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
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("agent-launcher-row-edit-save")
        Theme.applyPrimaryStyle(to: saveButton)

        let refreshSaveEnabled = { [weak saveButton, weak nameField, weak commandField] in
            let hasName = !(nameField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            let hasCommand = !(commandField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            saveButton?.isEnabled = hasName && hasCommand
        }

        let target = AgentLauncherFormTarget()
        target.onCancel = onCancel
        target.onSave = { [weak nameField, weak commandField] in
            onSave(AgentLauncher(name: nameField?.stringValue ?? "", command: commandField?.stringValue ?? ""))
        }
        target.onTextChange = refreshSaveEnabled
        nameField.delegate = target
        commandField.delegate = target

        cancelButton.target = target
        cancelButton.action = #selector(AgentLauncherFormTarget.triggerCancel)
        saveButton.target = target
        saveButton.action = #selector(AgentLauncherFormTarget.triggerSave)
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
        form.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        form.translatesAutoresizingMaskIntoConstraints = false
        objc_setAssociatedObject(form, &Self.targetKey, target, .OBJC_ASSOCIATION_RETAIN)
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
        objc_setAssociatedObject(button, &targetKey, target, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    private static var targetKey: UInt8 = 0
}

@MainActor private final class AgentLauncherFormTarget: NSObject, NSTextFieldDelegate {
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onTextChange: (() -> Void)?
    @objc func triggerCancel() { onCancel?() }
    @objc func triggerSave() { onSave?() }
    func controlTextDidChange(_ obj: Notification) { onTextChange?() }
}

extension Array { fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
