import AppKit
import streamctl

@MainActor final class PortsSection {
    // MARK: Public surface

    let view: NSView
    var onCommit: (([PortDefinition]) -> Void)?
    var presentRemoveConfirmation: ((PortDefinition, @escaping (Bool) -> Void) -> Void)?

    // MARK: State

    private var ports: [PortDefinition]
    private var collapsedDisplayPorts: [Int?]
    private let rowsStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [PortRowView] = []
    private var pendingDraftIndex: Int?

    // MARK: Init

    init(ports: [PortDefinition] = [], collapsedDisplayPorts: [Int?] = []) {
        self.ports = ports
        self.collapsedDisplayPorts = collapsedDisplayPorts

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

        if let addButton = header.arrangedSubviews.compactMap({ $0 as? NSButton }).first {
            addButton.target = self
            addButton.action = #selector(handleAdd(_:))
        }
        objc_setAssociatedObject(card, &Self.anchorKey, self, .OBJC_ASSOCIATION_RETAIN)

        refreshRows(animated: false)
    }

    private static var anchorKey: UInt8 = 0

    // MARK: Public API

    func reload(ports: [PortDefinition], collapsedDisplayPorts: [Int?]? = nil) {
        self.ports = ports
        if let collapsedDisplayPorts { self.collapsedDisplayPorts = collapsedDisplayPorts }
        refreshRows(animated: true)
    }
    var rowCount: Int { rows.count }
    func row(at index: Int) -> PortRowView? { index >= 0 && index < rows.count ? rows[index] : nil }
    func isEditing(at index: Int) -> Bool { index >= 0 && index < rows.count ? rows[index].isEditing : false }

    // MARK: Header

    private static func makeHeader(countLabel: NSTextField) -> NSStackView {
        let title = NSTextField(labelWithString: "Ports")
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
        addButton.setAccessibilityIdentifier("ports-section-add")
        let header = NSStackView(views: [title, countLabel, spacer, addButton])
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
        let existingEditing: [String: PortDefinition] = Dictionary(
            uniqueKeysWithValues: rows.enumerated().compactMap { index, row -> (String, PortDefinition)? in
                guard row.isEditing else { return nil }
                return (row.identity(from: ports[safe: index]), row.formSnapshot())
            })
        clearRowsStack()
        rows.removeAll()
        for (index, port) in ports.enumerated() {
            let row = PortRowView(port: port, reservedPort: collapsedDisplayPorts[safe: index] ?? nil)
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
            if let snapshot = existingEditing[row.identity(from: port)] { row.enterEditing(prefill: snapshot, animated: false) }
        }
        countLabel.stringValue = "\(ports.count)"
        _ = animated
    }

    private func clearRowsStack() {
        for arrangedSubview in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
    }

    // MARK: Row callbacks

    private func handleBeginEdit(row: PortRowView) { row.enterEditing(prefill: nil, animated: true) }

    private func handleCancel(row: PortRowView) {
        guard let index = rows.firstIndex(of: row) else { return }
        if pendingDraftIndex == index {
            ports.remove(at: index)
            pendingDraftIndex = nil
            refreshRows(animated: true)
            return
        }
        row.exitEditing(animated: true)
    }

    private func handleSave(row: PortRowView, edited: PortDefinition) {
        guard let index = rows.firstIndex(of: row), index < ports.count else { return }
        ports[index] = edited
        if pendingDraftIndex == index { pendingDraftIndex = nil }
        row.exitEditing(animated: true)
        row.rebindCollapsedContent(from: edited, reservedPort: collapsedDisplayPorts[safe: index] ?? nil)
        onCommit?(ports)
    }

    private func handleRemove(row: PortRowView) {
        guard let index = rows.firstIndex(of: row), index < ports.count else { return }
        let target = ports[index]
        let isDraft = (pendingDraftIndex == index)
        let commitAfterRemove = !isDraft
        let confirm = { [weak self] (approved: Bool) in
            guard let self, approved else { return }
            guard let currentIndex = self.rows.firstIndex(of: row), currentIndex < self.ports.count else { return }
            self.ports.remove(at: currentIndex)
            if self.pendingDraftIndex == currentIndex { self.pendingDraftIndex = nil }
            self.refreshRows(animated: true)
            if commitAfterRemove { self.onCommit?(self.ports) }
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
        alert.messageText = "Remove port \"\(target.name)\"?"
        alert.informativeText = "This removes the port definition from the workspace."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
    }

    @objc func handleAdd(_ sender: NSButton) {
        let blank = PortDefinition(name: "")
        ports.append(blank)
        pendingDraftIndex = ports.count - 1
        refreshRows(animated: true)
        rows.last?.enterEditing(prefill: blank, animated: false)
    }
}

// MARK: - PortRowView

@MainActor final class PortRowView: HoverRevealRowView {
    var onBeginEdit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: ((PortDefinition) -> Void)?
    var onRemove: (() -> Void)?

    private let body = NSStackView()
    private var collapsedContainer: NSStackView = NSStackView()
    private var editingContainer: NSStackView?
    private(set) var isEditing: Bool = false

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var currentPort: PortDefinition
    private var nameField: NSTextField?

    init(port: PortDefinition, reservedPort: Int? = nil) {
        self.currentPort = port
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
            nameLabel: nameLabel, detailLabel: detailLabel, onEdit: { [weak self] in self?.onBeginEdit?() },
            onRemove: { [weak self] in self?.onRemove?() })
        collapsedContainer = collapsedLine.row
        body.addArrangedSubview(collapsedContainer)
        collapsedContainer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureActionButtonsForHover(collapsedLine.actionButtons)
        rebindCollapsedContent(from: port, reservedPort: reservedPort)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func rebindCollapsedContent(from port: PortDefinition, reservedPort: Int? = nil) {
        currentPort = port
        nameLabel.stringValue = port.name.isEmpty ? "(unnamed)" : port.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = Theme.text
        detailLabel.stringValue = reservedPort.map(String.init) ?? ""
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = Theme.muted
        detailLabel.lineBreakMode = .byTruncatingTail
    }

    func enterEditing(prefill: PortDefinition?, animated: Bool) {
        guard !isEditing else { return }
        isEditing = true
        let seed = prefill ?? currentPort
        let (form, field) = Self.makeEditingForm(
            port: seed, onCancel: { [weak self] in self?.onCancel?() }, onSave: { [weak self] edited in self?.onSave?(edited) })
        nameField = field
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
    }

    func identity(from port: PortDefinition?) -> String {
        let fromState = currentPort.id
        let fromArg = port?.id ?? ""
        return fromState.isEmpty ? fromArg : fromState
    }

    func formSnapshot() -> PortDefinition { PortDefinition(id: currentPort.id, name: nameField?.stringValue ?? "") }

    var collapsedPrimaryTextForTesting: String { nameLabel.stringValue }
    var collapsedDetailTextForTesting: String { detailLabel.stringValue }

    private static func makeCollapsedLine(
        nameLabel: NSTextField, detailLabel: NSTextField, onEdit: @escaping () -> Void, onRemove: @escaping () -> Void
    ) -> (row: NSStackView, actionButtons: [NSButton]) {
        let leading: [NSView] = [RowPrimitives.typeIconTile(.port, symbol: "network", accessibilityLabel: "Port")]
        let editButton = buildActionButton(symbol: "pencil", tooltip: "Edit") { _ in onEdit() }
        editButton.setAccessibilityIdentifier("port-row-edit")
        let removeButton = buildActionButton(symbol: "trash", tooltip: "Remove") { _ in onRemove() }
        removeButton.setAccessibilityIdentifier("port-row-remove")
        let textStack = NSStackView(views: [nameLabel, detailLabel])
        textStack.orientation = .horizontal
        textStack.alignment = .firstBaseline
        textStack.spacing = 6
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)

        let row = NSStackView(views: leading + [textStack, spacer, editButton, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        return (row, [editButton, removeButton])
    }

    private static func makeEditingForm(port: PortDefinition, onCancel: @escaping () -> Void, onSave: @escaping (PortDefinition) -> Void) -> (
        NSStackView, NSTextField
    ) {
        let nameField = NSTextField(string: port.name)
        nameField.placeholderString = "Env var name (e.g. PORT)"
        nameField.setAccessibilityIdentifier("port-row-edit-name")

        let label = NSTextField(labelWithString: "Name")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.muted
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        let nameRow = NSStackView(views: [label, nameField])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 10
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.setAccessibilityIdentifier("port-row-edit-cancel")
        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("port-row-edit-save")

        let refreshSaveEnabled: () -> Void = { [weak saveButton, weak nameField] in
            saveButton?.isEnabled = !(nameField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }

        let target = PortFormTarget()
        target.onCancel = onCancel
        target.onSave = { [weak nameField] in onSave(PortDefinition(id: port.id, name: nameField?.stringValue ?? "")) }
        target.onTextChange = refreshSaveEnabled
        nameField.delegate = target
        cancelButton.target = target
        cancelButton.action = #selector(PortFormTarget.triggerCancel)
        saveButton.target = target
        saveButton.action = #selector(PortFormTarget.triggerSave)
        refreshSaveEnabled()

        let trailingButtons = NSStackView(views: [NSView(), cancelButton, saveButton])
        trailingButtons.orientation = .horizontal
        trailingButtons.alignment = .centerY
        trailingButtons.spacing = 6
        trailingButtons.translatesAutoresizingMaskIntoConstraints = false
        let form = NSStackView(views: [nameRow, trailingButtons])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        form.translatesAutoresizingMaskIntoConstraints = false
        objc_setAssociatedObject(form, &Self.targetKey, target, .OBJC_ASSOCIATION_RETAIN)
        return (form, nameField)
    }

    private static func buildActionButton(symbol: String, tooltip: String, onClick: @escaping (NSButton) -> Void) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = Theme.muted
        let target = PortFormTarget()
        target.onCancel = { onClick(button) }
        button.target = target
        button.action = #selector(PortFormTarget.triggerCancel)
        objc_setAssociatedObject(button, &targetKey, target, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    private static var targetKey: UInt8 = 0
}

@MainActor private final class PortFormTarget: NSObject, NSTextFieldDelegate {
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onTextChange: (() -> Void)?
    @objc func triggerCancel() { onCancel?() }
    @objc func triggerSave() { onSave?() }
    func controlTextDidChange(_ obj: Notification) { onTextChange?() }
}

extension Array { fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
