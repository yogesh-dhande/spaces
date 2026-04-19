import AppKit
import streamctl

@MainActor final class TerminalWindowEditor {
    let container = NSStackView()
    private let rowsStack = NSStackView()
    private let addButton: NSButton
    private var rows: [TerminalWindowRowRefs] = []
    var onDirty: (() -> Void)?

    init() {
        container.orientation = .vertical
        container.spacing = 8
        rowsStack.orientation = .vertical
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addButton = NSButton(title: "", target: nil, action: nil)
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Terminal Window")
        addButton.toolTip = "Add terminal window"
        addButton.target = self
        addButton.action = #selector(addRowFromButton)

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.distribution = .fill

        let nameLabel = makeFieldHeader("Name")
        let commandLabel = makeFieldHeader("Command")
        header.addArrangedSubview(nameLabel)
        header.addArrangedSubview(commandLabel)
        header.addArrangedSubview(addButton)

        nameLabel.widthAnchor.constraint(equalToConstant: 160).isActive = true
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        commandLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addArrangedSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        container.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        addRow(with: nil)
    }

    func setWindows(_ windows: [TerminalWindowTemplate]) {
        for row in rows { row.remove() }
        rows = []
        for window in windows { addRow(with: window) }
        if windows.isEmpty { addRow(with: nil) }
    }

    func currentWindows() throws -> [TerminalWindowTemplate] {
        try rows.compactMap { row in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = row.commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty, command.isEmpty { return nil }
            guard !name.isEmpty else { throw MuxyError.invalidArgument(message: "Terminal window name is required.") }
            return TerminalWindowTemplate(name: name, command: command.isEmpty ? nil : command)
        }
    }

    @objc private func addRowFromButton() { addRow(with: nil) }

    private func addRow(with window: TerminalWindowTemplate?) {
        let row = TerminalWindowRowRefs()
        rows.append(row)
        row.container.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.addArrangedSubview(row.container)
        row.container.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        if let window {
            row.nameField.stringValue = window.name
            row.commandField.stringValue = window.command ?? ""
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

    @MainActor private final class TerminalWindowRowRefs {
        let container = NSStackView()
        let nameField = NSTextField(string: "")
        let commandField = NSTextField(string: "")
        var onRemove: (() -> Void)?
        var onChange: (() -> Void)?

        init() {
            container.orientation = .horizontal
            container.spacing = 6
            container.alignment = .centerY

            nameField.placeholderString = "name"
            commandField.placeholderString = "optional command"

            let removeButton = NSButton(title: "", target: self, action: #selector(removeRow))
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Terminal Window")
            removeButton.toolTip = "Remove terminal window"

            container.addArrangedSubview(nameField)
            container.addArrangedSubview(commandField)
            container.addArrangedSubview(removeButton)

            nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
            removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
            commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            commandField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            for field in [nameField, commandField] {
                NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: field, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.onChange?() }
                }
            }
        }

        func remove() { container.removeFromSuperview() }

        @objc private func removeRow() { onRemove?() }
    }
}
