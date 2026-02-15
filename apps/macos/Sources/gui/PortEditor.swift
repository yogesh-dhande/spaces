import AppKit
import streamctl

@MainActor final class PortEditor {
    let container = NSStackView()
    private let rowsStack = NSStackView()
    private let addButton: NSButton
    private var rows: [PortRowRefs] = []
    var onDirty: (() -> Void)?

    init() {
        container.orientation = .vertical
        container.spacing = 8
        rowsStack.orientation = .vertical
        rowsStack.spacing = 6
        addButton = NSButton(title: "", target: nil, action: nil)
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Port")
        addButton.toolTip = "Add port definition"
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
            return PortDefinition(name: name)
        }
    }

    private func addRow(with definition: PortDefinition?) {
        let row = PortRowRefs()
        rows.append(row)
        rowsStack.addArrangedSubview(row.container)
        if let definition {
            row.nameField.stringValue = definition.name
        }
        row.onChange = { [weak self] in self?.onDirty?() }
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            if let idx = self.rows.firstIndex(where: { $0 === row }) { self.rows.remove(at: idx) }
            row.remove()
            self.onDirty?()
        }
        onDirty?()
    }

    @objc private func addRowFromButton() { addRow(with: nil) }

    @MainActor private final class PortRowRefs {
        let container = NSStackView()
        let nameField = NSTextField(string: "")
        var onRemove: (() -> Void)?
        var onChange: (() -> Void)?

        init() {
            container.orientation = .horizontal
            container.spacing = 6
            container.alignment = .centerY

            nameField.placeholderString = "e.g. FRONTEND_PORT"

            let removeButton = NSButton(title: "", target: self, action: #selector(removeRow))
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Port")
            removeButton.toolTip = "Remove port definition"

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
