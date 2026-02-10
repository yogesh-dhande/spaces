import AppKit
import streamctl

@MainActor
final class StatusCheckEditor {
    let container = NSStackView()
    private let rowsStack = NSStackView()
    private let addButton: NSButton
    private var rows: [StatusCheckRowRefs] = []
    var onDirty: (() -> Void)?
    private let processNamesProvider: () -> [String]

    init(processNamesProvider: @escaping () -> [String]) {
        self.processNamesProvider = processNamesProvider
        container.orientation = .vertical
        container.spacing = 8
        rowsStack.orientation = .vertical
        rowsStack.spacing = 6
        addButton = NSButton(title: "", target: nil, action: nil)
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Status Check")
        addButton.toolTip = "Add status check"
        addButton.target = self
        addButton.action = #selector(addRowFromButton)
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        let nameHeader = makeFieldHeader("Name")
        let processHeader = makeFieldHeader("Process")
        let commandHeader = makeFieldHeader("Command")
        let intervalHeader = makeFieldHeader("Interval")
        let timeoutHeader = makeFieldHeader("Timeout")
        let onExitHeader = makeFieldHeader("On Exit")
        header.addArrangedSubview(nameHeader)
        header.addArrangedSubview(processHeader)
        header.addArrangedSubview(commandHeader)
        header.addArrangedSubview(intervalHeader)
        header.addArrangedSubview(timeoutHeader)
        header.addArrangedSubview(onExitHeader)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(addButton)
        nameHeader.widthAnchor.constraint(equalToConstant: 120).isActive = true
        processHeader.widthAnchor.constraint(equalToConstant: 140).isActive = true
        intervalHeader.widthAnchor.constraint(equalToConstant: 70).isActive = true
        timeoutHeader.widthAnchor.constraint(equalToConstant: 70).isActive = true
        onExitHeader.widthAnchor.constraint(equalToConstant: 90).isActive = true
        commandHeader.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandHeader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(header)
        container.addArrangedSubview(rowsStack)
    }

    func setChecks(_ checks: [StatusCheckDefinition]) {
        rows.forEach { $0.remove() }
        rows = []
        for check in checks {
            addRow(with: check)
        }
        if checks.isEmpty {
            addRow(with: nil)
        }
    }

    func refreshProcessOptions() {
        let names = processNamesProvider()
        for row in rows {
            row.refreshProcessOptions(names: names)
        }
    }

    func currentChecks() -> [StatusCheckDefinition] {
        rows.compactMap { row in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let process = row.processPopup.titleOfSelectedItem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let command = row.commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let interval = Int(row.intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 60
            let timeout = Int(row.timeoutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5
            let onExit = StatusCheckOnExit(rawValue: row.onExitPopup.titleOfSelectedItem ?? "") ?? .none
            guard !process.isEmpty, !command.isEmpty else { return nil }
            return StatusCheckDefinition(
                name: name.isEmpty ? nil : name,
                process: process,
                command: command,
                interval: interval,
                timeout: timeout,
                onExit: onExit
            )
        }
    }

    private func addRow(with check: StatusCheckDefinition?) {
        let row = StatusCheckRowRefs(processNames: processNamesProvider())
        rows.append(row)
        rowsStack.addArrangedSubview(row.container)
        if let check {
            row.nameField.stringValue = check.name ?? ""
            row.commandField.stringValue = check.command
            row.intervalField.stringValue = String(check.interval)
            row.timeoutField.stringValue = String(check.timeout)
            row.onExitPopup.selectItem(withTitle: check.onExit.rawValue)
            if row.processPopup.item(withTitle: check.process) == nil {
                row.processPopup.addItem(withTitle: check.process)
            }
            row.processPopup.selectItem(withTitle: check.process)
        }
        row.onChange = { [weak self] in
            self?.onDirty?()
        }
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            if let idx = self.rows.firstIndex(where: { $0 === row }) {
                self.rows.remove(at: idx)
            }
            row.remove()
            self.onDirty?()
        }
        onDirty?()
    }

    @objc private func addRowFromButton() {
        addRow(with: nil)
    }

    private func processNames() -> [String] {
        let names = processNamesProvider()
        return names.isEmpty ? ["process"] : names
    }

    @MainActor
    private final class StatusCheckRowRefs {
        let container = NSStackView()
        let nameField = NSTextField(string: "")
        let processPopup = NSPopUpButton()
        let commandField = NSTextField(string: "")
        let intervalField = NSTextField(string: "60")
        let timeoutField = NSTextField(string: "5")
        let onExitPopup = NSPopUpButton()
        var onRemove: (() -> Void)?
        var onChange: (() -> Void)?

        init(processNames: [String]) {
            container.orientation = .horizontal
            container.spacing = 6
            container.alignment = .centerY

            nameField.placeholderString = "name"
            commandField.placeholderString = "command"
            intervalField.placeholderString = "interval"
            timeoutField.placeholderString = "timeout"

            processPopup.addItems(withTitles: processNames)
            onExitPopup.addItems(withTitles: StatusCheckOnExit.allCases.map { $0.rawValue })

            let removeButton = NSButton(title: "", target: self, action: #selector(removeRow))
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Status Check")
            removeButton.toolTip = "Remove status check"

            container.addArrangedSubview(nameField)
            container.addArrangedSubview(processPopup)
            container.addArrangedSubview(commandField)
            container.addArrangedSubview(intervalField)
            container.addArrangedSubview(timeoutField)
            container.addArrangedSubview(onExitPopup)
            container.addArrangedSubview(removeButton)

            nameField.widthAnchor.constraint(equalToConstant: 120).isActive = true
            processPopup.widthAnchor.constraint(equalToConstant: 140).isActive = true
            intervalField.widthAnchor.constraint(equalToConstant: 70).isActive = true
            timeoutField.widthAnchor.constraint(equalToConstant: 70).isActive = true
            onExitPopup.widthAnchor.constraint(equalToConstant: 90).isActive = true
            commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            commandField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            [nameField, commandField, intervalField, timeoutField].forEach { field in
                NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification,
                    object: field,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.onChange?()
                    }
                }
            }
            processPopup.target = self
            processPopup.action = #selector(changedPopup)
            onExitPopup.target = self
            onExitPopup.action = #selector(changedPopup)
        }

        func refreshProcessOptions(names: [String]) {
            let current = processPopup.titleOfSelectedItem
            processPopup.removeAllItems()
            processPopup.addItems(withTitles: names.isEmpty ? ["process"] : names)
            if let current, processPopup.item(withTitle: current) != nil {
                processPopup.selectItem(withTitle: current)
            }
        }

        func remove() {
            container.removeFromSuperview()
        }

        @objc private func removeRow() {
            onRemove?()
        }

        @objc private func changedPopup() {
            onChange?()
        }
    }
}
