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
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addButton = NSButton(title: "", target: nil, action: nil)
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Process")
        addButton.toolTip = "Add process"
        addButton.target = self
        addButton.action = #selector(addRowFromButton)

        // Header: fixed widths match data rows; command label stretches via low hugging
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.distribution = .fill

        let nameLabel = makeFieldHeader("Name")
        let commandLabel = makeFieldHeader("Command")
        let onExitLabel = makeFieldHeader("On Exit")

        header.addArrangedSubview(nameLabel)
        header.addArrangedSubview(commandLabel)
        header.addArrangedSubview(onExitLabel)
        header.addArrangedSubview(addButton)

        nameLabel.widthAnchor.constraint(equalToConstant: 160).isActive = true
        onExitLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        commandLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addArrangedSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        container.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        addRow(with: nil, checks: [])
    }

    func setProcesses(_ processes: [ProcessTemplate]) { setProcessesWithChecks(processes, statusChecks: []) }

    func setProcessesWithChecks(_ processes: [ProcessTemplate], statusChecks: [StatusCheckDefinition]) {
        for row in rows { row.remove() }
        rows = []
        for process in processes {
            let processName = process.name ?? ""
            let checks = statusChecks.filter { $0.process == processName }
            addRow(with: process, checks: checks)
        }
        if processes.isEmpty { addRow(with: nil, checks: []) }
    }

    func currentProcesses() -> [ProcessTemplate] {
        rows.compactMap { row in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = row.commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let onExit = ProcessExitAction(rawValue: row.onExitPopup.titleOfSelectedItem ?? "") ?? .none
            guard !command.isEmpty else { return nil }
            return ProcessTemplate(name: name, command: command, onExit: onExit)
        }
    }

    func currentStatusChecks() -> [StatusCheckDefinition] {
        rows.flatMap { row in
            let processName = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !processName.isEmpty else { return [StatusCheckDefinition]() }
            return row.currentChecks(processName: processName)
        }
    }

    func processNames() -> [String] {
        let names = rows.compactMap { row -> String? in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return Array(Set(names)).sorted()
    }

    private func addRow(with process: ProcessTemplate?, checks: [StatusCheckDefinition]) {
        let row = ProcessRowRefs(rowsStack: rowsStack)
        rows.append(row)
        row.processRow.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.addArrangedSubview(row.processRow)
        row.processRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        rowsStack.addArrangedSubview(row.checksSection)
        row.checksSection.translatesAutoresizingMaskIntoConstraints = false
        row.checksSection.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        if let process {
            row.nameField.stringValue = process.name ?? ""
            row.commandField.stringValue = process.command
            row.onExitPopup.selectItem(withTitle: process.onExit.rawValue)
        }
        row.setChecks(checks)
        row.onChange = { [weak self] in self?.onDirty?() }
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            if let idx = self.rows.firstIndex(where: { $0 === row }) { self.rows.remove(at: idx) }
            row.remove()
            self.onDirty?()
        }
        onDirty?()
    }

    @objc private func addRowFromButton() { addRow(with: nil, checks: []) }

    @MainActor private final class ProcessRowRefs {
        let processRow = NSStackView()
        let checksSection = NSStackView()
        let nameField = NSTextField(string: "")
        let commandField = NSTextField(string: "")
        let onExitPopup = NSPopUpButton()
        private let checksStack = NSStackView()
        private let checksFieldHeader = NSStackView()
        private var checkRows: [StatusCheckRowRefs] = []
        private weak var rowsStack: NSStackView?
        var onRemove: (() -> Void)?
        var onChange: (() -> Void)?

        init(rowsStack: NSStackView) {
            self.rowsStack = rowsStack

            processRow.orientation = .horizontal
            processRow.spacing = 6
            processRow.alignment = .centerY

            nameField.placeholderString = "name"
            commandField.placeholderString = "command"
            onExitPopup.addItems(withTitles: ProcessExitAction.allCases.map { $0.rawValue })
            onExitPopup.controlSize = .small
            onExitPopup.font = .systemFont(ofSize: 11)
            onExitPopup.toolTip = "Action on process exit"

            let removeButton = NSButton(title: "", target: self, action: #selector(removeRow))
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Process")
            removeButton.toolTip = "Remove process"

            processRow.addArrangedSubview(nameField)
            processRow.addArrangedSubview(commandField)
            processRow.addArrangedSubview(onExitPopup)
            processRow.addArrangedSubview(removeButton)

            nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
            onExitPopup.widthAnchor.constraint(equalToConstant: 80).isActive = true
            removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
            commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            commandField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            for field in [nameField, commandField] {
                NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: field, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.onChange?() }
                }
            }
            onExitPopup.target = self
            onExitPopup.action = #selector(changedPopup)

            // Status checks sub-section
            checksStack.orientation = .vertical
            checksStack.spacing = 4

            let checksHeader = NSStackView()
            checksHeader.orientation = .horizontal
            checksHeader.spacing = 4
            checksHeader.alignment = .centerY

            let arrow = NSTextField(labelWithString: "↳")
            arrow.font = .systemFont(ofSize: 11)
            arrow.textColor = .tertiaryLabelColor
            let checksLabel = NSTextField(labelWithString: "Status checks:")
            checksLabel.font = .systemFont(ofSize: 11, weight: .medium)
            checksLabel.textColor = .secondaryLabelColor
            let addCheckButton = NSButton(title: "", target: self, action: #selector(addCheckRow))
            addCheckButton.bezelStyle = .texturedRounded
            addCheckButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Status Check")
            addCheckButton.controlSize = .small
            addCheckButton.toolTip = "Add status check"

            checksHeader.addArrangedSubview(arrow)
            checksHeader.addArrangedSubview(checksLabel)
            checksHeader.addArrangedSubview(addCheckButton)
            // Status check field header — uses same fixed widths as StatusCheckRowRefs
            checksFieldHeader.orientation = .horizontal
            checksFieldHeader.spacing = 4
            checksFieldHeader.alignment = .centerY
            checksFieldHeader.distribution = .fill
            let nameLabel = makeFieldHeader("Name")
            let commandLabel = makeFieldHeader("Command")
            let intervalLabel = makeFieldHeader("Interval (s)")
            let timeoutLabel = makeFieldHeader("Timeout (s)")
            let onFailLabel = makeFieldHeader("On Fail")
            checksFieldHeader.addArrangedSubview(nameLabel)
            checksFieldHeader.addArrangedSubview(commandLabel)
            checksFieldHeader.addArrangedSubview(intervalLabel)
            checksFieldHeader.addArrangedSubview(timeoutLabel)
            checksFieldHeader.addArrangedSubview(onFailLabel)
            // Spacer to account for the remove button column
            let btnSpacer = NSView()
            btnSpacer.setContentHuggingPriority(.required, for: .horizontal)
            checksFieldHeader.addArrangedSubview(btnSpacer)
            nameLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
            intervalLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
            timeoutLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
            onFailLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
            btnSpacer.widthAnchor.constraint(equalToConstant: 20).isActive = true
            commandLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            checksFieldHeader.isHidden = true
            checksFieldHeader.translatesAutoresizingMaskIntoConstraints = false

            checksSection.orientation = .horizontal
            checksSection.spacing = 0
            checksSection.alignment = .top
            checksSection.distribution = .fill
            let indent = NSView()
            indent.translatesAutoresizingMaskIntoConstraints = false
            indent.widthAnchor.constraint(equalToConstant: 20).isActive = true
            indent.setContentHuggingPriority(.required, for: .horizontal)
            let innerStack = NSStackView()
            innerStack.orientation = .vertical
            innerStack.spacing = 4
            innerStack.alignment = .leading
            innerStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            innerStack.translatesAutoresizingMaskIntoConstraints = false
            checksStack.translatesAutoresizingMaskIntoConstraints = false
            innerStack.addArrangedSubview(checksHeader)
            innerStack.addArrangedSubview(checksFieldHeader)
            innerStack.addArrangedSubview(checksStack)
            checksSection.addArrangedSubview(indent)
            checksSection.addArrangedSubview(innerStack)
            innerStack.widthAnchor.constraint(equalTo: checksSection.widthAnchor, constant: -20).isActive = true
            checksStack.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
            checksFieldHeader.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        }

        func setChecks(_ checks: [StatusCheckDefinition]) {
            for row in checkRows { row.remove() }
            checkRows = []
            for check in checks { addCheck(with: check) }
            updateChecksFieldHeaderVisibility()
        }

        func currentChecks(processName: String) -> [StatusCheckDefinition] {
            checkRows.compactMap { row in
                let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let command = row.commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let interval =
                    Int(row.intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? PollingConstants.statusCheckDefaultInterval
                let timeout =
                    Int(row.timeoutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? PollingConstants.statusCheckDefaultTimeout
                let onFail = OnFailAction(rawValue: row.onExitPopup.titleOfSelectedItem ?? "") ?? .none
                guard !command.isEmpty else { return nil }
                return StatusCheckDefinition(
                    name: name.isEmpty ? nil : name, process: processName, command: command, interval: interval, timeout: timeout, onFail: onFail)
            }
        }

        func remove() {
            processRow.removeFromSuperview()
            checksSection.removeFromSuperview()
        }

        @objc private func removeRow() { onRemove?() }
        @objc private func changedPopup() { onChange?() }

        @objc private func addCheckRow() {
            addCheck(with: nil)
            updateChecksFieldHeaderVisibility()
            onChange?()
        }

        private func updateChecksFieldHeaderVisibility() { checksFieldHeader.isHidden = checkRows.isEmpty }

        private func addCheck(with check: StatusCheckDefinition?) {
            let row = StatusCheckRowRefs()
            checkRows.append(row)
            checksStack.addArrangedSubview(row.container)
            row.container.translatesAutoresizingMaskIntoConstraints = false
            row.container.widthAnchor.constraint(equalTo: checksStack.widthAnchor).isActive = true
            if let check {
                row.nameField.stringValue = check.name ?? ""
                row.commandField.stringValue = check.command
                row.intervalField.stringValue = String(check.interval)
                row.timeoutField.stringValue = String(check.timeout)
                row.onExitPopup.selectItem(withTitle: check.onFail.rawValue)
            }
            row.onChange = { [weak self] in self?.onChange?() }
            row.onRemove = { [weak self, weak row] in
                guard let self, let row else { return }
                if let idx = self.checkRows.firstIndex(where: { $0 === row }) { self.checkRows.remove(at: idx) }
                row.remove()
                self.updateChecksFieldHeaderVisibility()
                self.onChange?()
            }
        }
    }

    @MainActor private final class StatusCheckRowRefs {
        let container = NSStackView()
        let nameField = NSTextField(string: "")
        let commandField = NSTextField(string: "")
        let intervalField = NSTextField(string: String(PollingConstants.statusCheckDefaultInterval))
        let timeoutField = NSTextField(string: String(PollingConstants.statusCheckDefaultTimeout))
        let onExitPopup = NSPopUpButton()
        var onRemove: (() -> Void)?
        var onChange: (() -> Void)?

        init() {
            container.orientation = .horizontal
            container.spacing = 4
            container.alignment = .centerY

            nameField.placeholderString = "name"
            nameField.font = .systemFont(ofSize: 11)
            nameField.toolTip = "Check name (optional)"
            commandField.placeholderString = "command"
            commandField.font = .systemFont(ofSize: 11)
            commandField.toolTip = "Health check command to run"
            intervalField.placeholderString = "60"
            intervalField.font = .systemFont(ofSize: 11)
            intervalField.toolTip = "Seconds between checks"
            timeoutField.placeholderString = "5"
            timeoutField.font = .systemFont(ofSize: 11)
            timeoutField.toolTip = "Command timeout in seconds"

            onExitPopup.addItems(withTitles: OnFailAction.allCases.map { $0.rawValue })
            onExitPopup.controlSize = .small
            onExitPopup.font = .systemFont(ofSize: 11)
            onExitPopup.toolTip = "Action when check fails"

            let removeButton = NSButton(title: "", target: self, action: #selector(removeRow))
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Status Check")
            removeButton.controlSize = .small
            removeButton.toolTip = "Remove status check"

            container.addArrangedSubview(nameField)
            container.addArrangedSubview(commandField)
            container.addArrangedSubview(intervalField)
            container.addArrangedSubview(timeoutField)
            container.addArrangedSubview(onExitPopup)
            container.addArrangedSubview(removeButton)

            nameField.widthAnchor.constraint(equalToConstant: 80).isActive = true
            intervalField.widthAnchor.constraint(equalToConstant: 70).isActive = true
            timeoutField.widthAnchor.constraint(equalToConstant: 70).isActive = true
            onExitPopup.widthAnchor.constraint(equalToConstant: 80).isActive = true
            removeButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
            commandField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            commandField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            for field in [nameField, commandField, intervalField, timeoutField] {
                NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: field, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.onChange?() }
                }
            }
            onExitPopup.target = self
            onExitPopup.action = #selector(changedPopup)
        }

        func remove() { container.removeFromSuperview() }

        @objc private func removeRow() { onRemove?() }

        @objc private func changedPopup() { onChange?() }
    }
}
