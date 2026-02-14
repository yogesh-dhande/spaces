import AppKit
import streamctl

@MainActor final class ProcessEditor {
    let container = NSStackView()
    private let rowsStack = NSStackView()
    private let addButton: NSButton
    private var rows: [ProcessRowRefs] = []
    var onDirty: (() -> Void)?

    init() {
        container.orientation = .vertical
        container.spacing = 8
        rowsStack.orientation = .vertical
        rowsStack.spacing = 6
        addButton = NSButton(title: "", target: nil, action: nil)
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Process")
        addButton.toolTip = "Add process"
        addButton.target = self
        addButton.action = #selector(addRowFromButton)
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        let nameHeader = makeFieldHeader("Name")
        let commandHeader = makeFieldHeader("Command")
        header.addArrangedSubview(nameHeader)
        header.addArrangedSubview(commandHeader)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(addButton)
        nameHeader.widthAnchor.constraint(equalToConstant: 160).isActive = true
        commandHeader.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandHeader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(header)
        container.addArrangedSubview(rowsStack)
        addRow(with: nil)
    }

    func setProcesses(_ processes: [ProcessTemplate]) {
        for row in rows { row.remove() }
        rows = []
        for process in processes { addRow(with: process) }
        if processes.isEmpty { addRow(with: nil) }
    }

    func currentProcesses() -> [ProcessTemplate] {
        rows.compactMap { row in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = row.commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return nil }
            return ProcessTemplate(name: name.isEmpty ? nil : name, command: command)
        }
    }

    func processNames() -> [String] {
        let names = rows.compactMap { row -> String? in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return Array(Set(names)).sorted()
    }

    private func addRow(with process: ProcessTemplate?) {
        let row = ProcessRowRefs()
        rows.append(row)
        rowsStack.addArrangedSubview(row.container)
        if let process {
            row.nameField.stringValue = process.name ?? ""
            row.commandField.stringValue = process.command
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

    @MainActor private final class ProcessRowRefs {
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
            commandField.placeholderString = "command"

            let removeButton = NSButton(title: "", target: self, action: #selector(removeRow))
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Process")
            removeButton.toolTip = "Remove process"

            container.addArrangedSubview(nameField)
            container.addArrangedSubview(commandField)
            container.addArrangedSubview(removeButton)

            nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
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
