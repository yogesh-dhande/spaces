import AppKit
import workspacecore

@MainActor final class PortEditor {
    let container = NSStackView()
    private let rowsStack = NSStackView()
    private let addButton: NSButton
    private var rows: [PortRowRefs] = []
    private let accessibilityPrefix: String?
    var onDirty: (() -> Void)?

    init(accessibilityPrefix: String? = nil) {
        self.accessibilityPrefix = accessibilityPrefix
        container.orientation = .vertical
        container.spacing = 8
        if let accessibilityPrefix { container.setAccessibilityIdentifier("\(accessibilityPrefix)-container") }
        rowsStack.orientation = .vertical
        rowsStack.spacing = 6
        addButton = NSButton(title: "", target: nil, action: nil)
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Port")
        addButton.toolTip = "Add port definition"
        if let accessibilityPrefix { addButton.setAccessibilityIdentifier("\(accessibilityPrefix)-add") }
        addButton.target = self
        addButton.action = #selector(addRowFromButton)
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        let nameHeader = makeFieldHeader("Env var name")
        header.addArrangedSubview(nameHeader)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(addButton)
        nameHeader.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameHeader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(header)
        container.addArrangedSubview(rowsStack)
    }

    func setDefinitions(_ definitions: [PortDefinition]) {
        for row in rows { row.remove() }
        rows = []
        for definition in definitions { addRow(with: definition) }
    }

    func currentDefinitions() -> [PortDefinition] {
        rows.compactMap { row in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return PortDefinition(id: row.definitionID, name: name)
        }
    }

    private func addRow(with definition: PortDefinition?) {
        let row = PortRowRefs()
        rows.append(row)
        rowsStack.addArrangedSubview(row.container)
        if let definition {
            row.definitionID = definition.id
            row.nameField.stringValue = definition.name
        }
        row.onChange = { [weak self] in self?.onDirty?() }
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            if let idx = self.rows.firstIndex(where: { $0 === row }) { self.rows.remove(at: idx) }
            row.remove()
            self.onDirty?()
            self.refreshAccessibilityIdentifiers()
        }
        onDirty?()
        refreshAccessibilityIdentifiers()
    }

    @objc private func addRowFromButton() { addRow(with: nil) }

    private func refreshAccessibilityIdentifiers() {
        guard let accessibilityPrefix else { return }
        for (index, row) in rows.enumerated() {
            row.container.setAccessibilityIdentifier("\(accessibilityPrefix)-row-\(index)")
            row.nameField.setAccessibilityIdentifier("\(accessibilityPrefix)-name-\(index)")
            row.removeButton.setAccessibilityIdentifier("\(accessibilityPrefix)-remove-\(index)")
        }
    }

    @MainActor private final class PortRowRefs {
        let container = NSStackView()
        let nameField = NSTextField(string: "")
        let removeButton: NSButton
        var definitionID = UUID().uuidString
        var onRemove: (() -> Void)?
        var onChange: (() -> Void)?

        init() {
            container.orientation = .horizontal
            container.spacing = 6
            container.alignment = .centerY

            nameField.placeholderString = "e.g. FRONTEND_PORT"

            removeButton = NSButton(title: "", target: nil, action: nil)
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Port")
            removeButton.toolTip = "Remove port definition"
            removeButton.target = self
            removeButton.action = #selector(removeRow)

            container.addArrangedSubview(nameField)
            container.addArrangedSubview(removeButton)

            nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nameField, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onChange?() }
            }
        }

        func remove() { container.removeFromSuperview() }

        @objc private func removeRow() { onRemove?() }
    }
}
