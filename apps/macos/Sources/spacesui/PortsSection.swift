import AppKit
import spacesterminalcore
import workspacecore

@MainActor final class PortsSection {
    // MARK: Public surface

    let view: NSView
    var onCommit: (([ServiceDefinition]) -> Void)?
    var presentRemoveConfirmation: ((ServiceDefinition, @escaping (Bool) -> Void) -> Void)?

    // MARK: State

    private var ports: [ServiceDefinition]
    private var collapsedDisplayPortTexts: [String?]
    private var collapsedDisplayURLs: [String?]
    private let showsEnvironmentVariableHints: Bool
    private let rowsStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [PortRowView] = []
    private var pendingDraftIndex: Int?

    // MARK: Init

    init(
        ports: [ServiceDefinition] = [], collapsedDisplayPortTexts: [String?] = [], collapsedDisplayURLs: [String?] = [], subtitle: String? = nil,
        showsEnvironmentVariableHints: Bool = false
    ) {
        self.ports = ports
        self.collapsedDisplayPortTexts = collapsedDisplayPortTexts
        self.collapsedDisplayURLs = collapsedDisplayURLs
        self.showsEnvironmentVariableHints = showsEnvironmentVariableHints

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = RowSectionHeader.make(
            title: "Services", addButtonAccessibilityIdentifier: "services-section-add", countLabel: countLabel, subtitle: subtitle)
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

    func reload(ports: [ServiceDefinition], collapsedDisplayPortTexts: [String?]? = nil, collapsedDisplayURLs: [String?]? = nil) {
        update(
            ports: ports, collapsedDisplayPortTexts: collapsedDisplayPortTexts, collapsedDisplayURLs: collapsedDisplayURLs, preservingEditing: true)
    }

    func replace(ports: [ServiceDefinition], collapsedDisplayPortTexts: [String?]? = nil, collapsedDisplayURLs: [String?]? = nil) {
        pendingDraftIndex = nil
        update(
            ports: ports, collapsedDisplayPortTexts: collapsedDisplayPortTexts, collapsedDisplayURLs: collapsedDisplayURLs, preservingEditing: false)
    }

    private func update(ports: [ServiceDefinition], collapsedDisplayPortTexts: [String?]?, collapsedDisplayURLs: [String?]?, preservingEditing: Bool)
    {
        self.ports = ports
        if let collapsedDisplayPortTexts { self.collapsedDisplayPortTexts = collapsedDisplayPortTexts }
        if let collapsedDisplayURLs { self.collapsedDisplayURLs = collapsedDisplayURLs }
        refreshRows(animated: true, preservingEditing: preservingEditing)
    }
    var rowCount: Int { rows.count }
    var currentPorts: [ServiceDefinition] { ports }
    var hasOpenEditor: Bool { rows.contains { $0.isEditing } }
    func row(at index: Int) -> PortRowView? { index >= 0 && index < rows.count ? rows[index] : nil }
    func isEditing(at index: Int) -> Bool { index >= 0 && index < rows.count ? rows[index].isEditing : false }

    // MARK: Row lifecycle

    private func refreshRows(animated: Bool, preservingEditing: Bool = true) {
        let existingEditing: [String: ServiceDefinition] =
            preservingEditing
            ? Dictionary(
                uniqueKeysWithValues: rows.enumerated().compactMap { index, row -> (String, ServiceDefinition)? in
                    guard row.isEditing else { return nil }
                    return (row.identity(from: ports[safe: index]), row.formSnapshot())
                }) : [:]
        // Row rebuilds can end AppKit field editing; preserve/cancel that draft instead of committing it.
        for row in rows where row.isEditing { row.suppressNextEditingEndedCommit() }
        rowsStack.removeAllArrangedSubviews()
        rows.removeAll()
        for (index, port) in ports.enumerated() {
            let row = PortRowView(
                port: port, portText: collapsedDisplayPortTexts[safe: index] ?? nil, displayURL: collapsedDetailText(for: port, at: index))
            row.onBeginEdit = { [weak self] in self?.handleBeginEdit(row: row) }
            row.onCancel = { [weak self] in self?.handleCancel(row: row) }
            row.onSave = { [weak self] edited in self?.handleSave(row: row, edited: edited) }
            row.onRemove = { [weak self] in self?.handleRemove(row: row) }
            rows.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if let snapshot = existingEditing[row.identity(from: port)] { row.enterEditing(prefill: snapshot, animated: false) }
        }
        countLabel.stringValue = "\(ports.count)"
        _ = animated
    }

    private func collapsedDetailText(for port: ServiceDefinition, at index: Int) -> String? {
        let displayURL = collapsedDisplayURLs[safe: index] ?? nil
        let trimmedDisplayURL = displayURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedDisplayURL.isEmpty else { return trimmedDisplayURL }
        guard showsEnvironmentVariableHints, ServiceName.isValidLabel(port.name) else { return displayURL }
        return "\(ServiceName.portEnvVar(for: port.name)), \(ServiceName.urlEnvVar(for: port.name))"
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

    private func handleSave(row: PortRowView, edited: ServiceDefinition) {
        guard let index = rows.firstIndex(of: row), index < ports.count else { return }
        ports[index] = edited
        if pendingDraftIndex == index { pendingDraftIndex = nil }
        row.exitEditing(animated: true)
        row.rebindCollapsedContent(
            from: edited, portText: collapsedDisplayPortTexts[safe: index] ?? nil, displayURL: collapsedDetailText(for: edited, at: index))
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
        RowSectionRemoveConfirmation.confirm(
            messageText: "Remove service \"\(target.name)\"?", informativeText: "This removes the service from the workspace.", isDraft: isDraft,
            presenter: presentRemoveConfirmation.map { presenter in { presenter(target, $0) } }, onDecision: confirm)
    }

    @objc func handleAdd(_ sender: NSButton) {
        let blank = ServiceDefinition(name: "")
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
    var onSave: ((ServiceDefinition) -> Void)?
    var onRemove: (() -> Void)?

    private let body = NSStackView()
    private var collapsedContainer: NSStackView = NSStackView()
    private var editingContainer: NSStackView?
    private(set) var isEditing: Bool = false

    private let nameLabel = NSTextField(labelWithString: "")
    private let portLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var currentPort: ServiceDefinition
    private var nameField: NSTextField?
    private var formTarget: PortFormTarget?

    init(port: ServiceDefinition, portText: String? = nil, displayURL: String? = nil) {
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
            nameLabel: nameLabel, portLabel: portLabel, detailLabel: detailLabel, onEdit: { [weak self] in self?.onBeginEdit?() },
            onRemove: { [weak self] in self?.onRemove?() })
        collapsedContainer = collapsedLine.row
        body.addArrangedSubview(collapsedContainer)
        collapsedContainer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureActionButtonsForHover(collapsedLine.actionButtons)
        rebindCollapsedContent(from: port, portText: portText, displayURL: displayURL)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func rebindCollapsedContent(from port: ServiceDefinition, portText: String? = nil, displayURL: String? = nil) {
        currentPort = port
        nameLabel.stringValue = port.name.isEmpty ? "(unnamed)" : port.name
        nameLabel.font = Typography.rowLabel
        nameLabel.textColor = Theme.text
        nameLabel.isSelectable = true
        let trimmedPortText = portText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        portLabel.stringValue = trimmedPortText
        portLabel.isHidden = trimmedPortText.isEmpty
        portLabel.font = Typography.monoBody
        portLabel.textColor = Theme.muted
        portLabel.isSelectable = true
        detailLabel.stringValue = displayURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        detailLabel.font = Typography.rowDetail
        detailLabel.textColor = Theme.muted
        detailLabel.lineBreakMode = .byTruncatingTail
    }

    func enterEditing(prefill: ServiceDefinition?, animated: Bool) {
        guard !isEditing else { return }
        isEditing = true
        let seed = prefill ?? currentPort
        let (form, field, target) = Self.makeEditingForm(
            port: seed, onCancel: { [weak self] in self?.onCancel?() }, onSave: { [weak self] edited in self?.onSave?(edited) })
        nameField = field
        formTarget = target
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
        formTarget = nil
    }

    func identity(from port: ServiceDefinition?) -> String {
        let fromState = currentPort.id
        let fromArg = port?.id ?? ""
        return fromState.isEmpty ? fromArg : fromState
    }

    func formSnapshot() -> ServiceDefinition { ServiceDefinition(id: currentPort.id, name: nameField?.stringValue ?? "") }
    func suppressNextEditingEndedCommit() { formTarget?.suppressNextEditingEndedCommit() }

    var collapsedPrimaryTextForTesting: String { nameLabel.stringValue }
    var collapsedPrimaryTextIsSelectableForTesting: Bool { nameLabel.isSelectable }
    var collapsedPortTextForTesting: String { portLabel.isHidden ? "" : portLabel.stringValue }
    var collapsedDetailTextForTesting: String { detailLabel.stringValue }
    func setEditingNameForTesting(_ name: String) { nameField?.stringValue = name }
    func endEditingForTesting() {
        guard let nameField else { return }
        nameField.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: nameField))
    }

    private static func makeCollapsedLine(
        nameLabel: NSTextField, portLabel: NSTextField, detailLabel: NSTextField, onEdit: @escaping () -> Void, onRemove: @escaping () -> Void
    ) -> (row: NSStackView, actionButtons: [NSButton]) {
        let leading: [NSView] = [RowPrimitives.typeIconTile(.port, symbol: "network", accessibilityLabel: "Port")]
        let editButton = buildActionButton(symbol: "pencil", tooltip: "Edit") { _ in onEdit() }
        editButton.setAccessibilityIdentifier("service-row-edit")
        let removeButton = buildActionButton(symbol: "trash", tooltip: "Remove") { _ in onRemove() }
        removeButton.setAccessibilityIdentifier("service-row-remove")
        let textStack = NSStackView(views: [nameLabel, portLabel, detailLabel])
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

    private static func makeEditingForm(port: ServiceDefinition, onCancel: @escaping () -> Void, onSave: @escaping (ServiceDefinition) -> Void) -> (
        NSStackView, NSTextField, PortFormTarget
    ) {
        let nameField = NSTextField(string: port.name)
        nameField.placeholderString = "Service name (e.g. web)"
        nameField.font = Typography.rowLabel
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setAccessibilityIdentifier("service-row-edit-name")

        let target = PortFormTarget()

        let cancel = { [weak target] in
            target?.beginCancelling()
            onCancel()
        }
        let cancelButton = buildActionButton(symbol: "xmark", tooltip: "Cancel") { _ in cancel() }
        // NSButton can end field editing before its action fires, so mark cancel on mouse down.
        cancelButton.onMouseDown = { [weak target] in target?.suppressNextEditingEndedCommit() }
        cancelButton.onMouseTrackingEnded = { [weak target] in target?.clearUnusedEditingEndedSuppression() }
        cancelButton.setAccessibilityIdentifier("service-row-edit-cancel")

        // A service name is a DNS label (it becomes a hostname), so only commit valid labels.
        let doSave = { [weak nameField, weak target] in
            guard let target, !target.didFinish, !target.isCancelling else { return }
            let name = (nameField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ServiceName.isValidLabel(name) else { return }
            target.didFinish = true
            onSave(ServiceDefinition(id: port.id, name: name))
        }
        let saveButton = buildActionButton(symbol: "checkmark", tooltip: "Save") { _ in doSave() }
        saveButton.setAccessibilityIdentifier("service-row-edit-save")

        let refreshSaveEnabled: () -> Void = { [weak saveButton, weak nameField] in
            let name = (nameField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            saveButton?.isEnabled = ServiceName.isValidLabel(name)
        }

        target.onCancel = cancel
        target.onSave = doSave
        target.onEditingEnded = doSave
        target.onTextChange = refreshSaveEnabled
        nameField.delegate = target
        refreshSaveEnabled()

        let icon = RowPrimitives.typeIconTile(.port, symbol: "network", accessibilityLabel: "Port")
        let form = NSStackView(views: [icon, nameField, cancelButton, saveButton])
        form.orientation = .horizontal
        form.alignment = .centerY
        form.spacing = 10
        form.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        form.translatesAutoresizingMaskIntoConstraints = false
        retainAssociatedObject(target, on: form)
        return (form, nameField, target)
    }

    private static func buildActionButton(symbol: String, tooltip: String, onClick: @escaping (NSButton) -> Void) -> PortActionButton {
        let button = PortActionButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = Theme.muted
        let target = PortFormTarget()
        target.onCancel = { onClick(button) }
        button.target = target
        button.action = #selector(PortFormTarget.triggerCancel)
        retainAssociatedObject(target, on: button)
        return button
    }

}

@MainActor private final class PortActionButton: NSButton {
    var onMouseDown: (() -> Void)?
    var onMouseTrackingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
        onMouseTrackingEnded?()
    }
}

@MainActor private final class PortFormTarget: NSObject, NSTextFieldDelegate {
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onEditingEnded: (() -> Void)?
    var onTextChange: (() -> Void)?
    var didFinish = false
    var isCancelling = false
    private var suppressesNextEditingEndedCommit = false
    func beginCancelling() { isCancelling = true }
    func suppressNextEditingEndedCommit() { suppressesNextEditingEndedCommit = true }
    func clearUnusedEditingEndedSuppression() { suppressesNextEditingEndedCommit = false }
    @objc func triggerCancel() { onCancel?() }
    @objc func triggerSave() { onSave?() }
    func controlTextDidChange(_ obj: Notification) { onTextChange?() }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !suppressesNextEditingEndedCommit else {
            suppressesNextEditingEndedCommit = false
            return
        }
        guard !isCancelling else { return }
        onEditingEnded?()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSave?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
