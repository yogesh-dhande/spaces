import AppKit
import streamctl

@MainActor final class BrowserSessionEditor {
    let container = NSStackView()
    private let rowsStack = NSStackView()
    private let addButton: NSButton
    private var rows: [BrowserSessionRowRefs] = []
    private let accessibilityPrefix: String?
    var onDirty: (() -> Void)?

    init(accessibilityPrefix: String? = nil) {
        self.accessibilityPrefix = accessibilityPrefix
        container.orientation = .vertical
        container.spacing = 8
        if let accessibilityPrefix { container.setAccessibilityIdentifier("\(accessibilityPrefix)-container") }
        rowsStack.orientation = .vertical
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addButton = NSButton(title: "", target: nil, action: nil)
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Browser Session")
        addButton.toolTip = "Add browser session"
        if let accessibilityPrefix { addButton.setAccessibilityIdentifier("\(accessibilityPrefix)-add") }
        addButton.target = self
        addButton.action = #selector(addRowFromButton)

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.distribution = .fill

        let nameLabel = makeFieldHeader("Name")
        let urlLabel = makeFieldHeader("URL")
        header.addArrangedSubview(nameLabel)
        header.addArrangedSubview(urlLabel)
        header.addArrangedSubview(addButton)

        nameLabel.widthAnchor.constraint(equalToConstant: 160).isActive = true
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        urlLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addArrangedSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        container.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        addRow(with: nil)
    }

    func setSessions(_ sessions: [BrowserSession]) {
        for row in rows { row.remove() }
        rows = []
        for session in sessions { addRow(with: session) }
        if sessions.isEmpty { addRow(with: nil) }
    }

    func currentSessions() -> [BrowserSession] {
        rows.compactMap { row in
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = row.urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return nil }
            return BrowserSession(name: name, url: url)
        }
    }

    private func addRow(with session: BrowserSession?) {
        let row = BrowserSessionRowRefs()
        rows.append(row)
        row.container.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.addArrangedSubview(row.container)
        row.container.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        if let session {
            row.nameField.stringValue = session.name ?? ""
            row.urlField.stringValue = session.url ?? ""
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
            row.urlField.setAccessibilityIdentifier("\(accessibilityPrefix)-url-\(index)")
            row.removeButton.setAccessibilityIdentifier("\(accessibilityPrefix)-remove-\(index)")
        }
    }

    @MainActor private final class BrowserSessionRowRefs {
        let container = NSStackView()
        let nameField = NSTextField(string: "")
        let urlField = NSTextField(string: "")
        let removeButton: NSButton
        var onRemove: (() -> Void)?
        var onChange: (() -> Void)?

        init() {
            container.orientation = .horizontal
            container.spacing = 6
            container.alignment = .centerY

            nameField.placeholderString = "name"
            urlField.placeholderString = "https://example.com"

            removeButton = NSButton(title: "", target: nil, action: nil)
            removeButton.bezelStyle = .texturedRounded
            removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Browser Session")
            removeButton.toolTip = "Remove browser session"
            removeButton.target = self
            removeButton.action = #selector(removeRow)

            container.addArrangedSubview(nameField)
            container.addArrangedSubview(urlField)
            container.addArrangedSubview(removeButton)

            nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
            removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
            urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            for field in [nameField, urlField] {
                NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: field, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.onChange?() }
                }
            }
        }

        func remove() { container.removeFromSuperview() }

        @objc private func removeRow() { onRemove?() }
    }
}
