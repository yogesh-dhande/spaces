import AppKit
import streamctl

@MainActor final class BrowserSessionsSection {
    // MARK: Public surface

    let view: NSView
    var onCommit: (([BrowserSession]) -> Void)?
    var presentRemoveConfirmation: ((BrowserSession, @escaping (Bool) -> Void) -> Void)?

    // MARK: State

    private var sessions: [BrowserSession]
    private var collapsedDisplayURLs: [String?]
    private let rowsStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [BrowserSessionRowView] = []
    private var pendingDraftIndex: Int?

    /// Map from URL string → shortcut display text (e.g. "⌘1"). When absent
    /// for a session's URL the shortcut chip is hidden on that row.
    var shortcutsByURL: [String: String] = [:] { didSet { refreshRows(animated: false) } }

    /// Called when a collapsed row is clicked. Receives the session so the host
    /// can dispatch the appropriate focus or open action.
    var onFocus: ((BrowserSession) -> Void)?

    // MARK: Init

    init(sessions: [BrowserSession] = [], collapsedDisplayURLs: [String?] = [], subtitle: String? = nil) {
        self.sessions = sessions
        self.collapsedDisplayURLs = collapsedDisplayURLs

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

    func reload(sessions: [BrowserSession], collapsedDisplayURLs: [String?]? = nil) {
        self.sessions = sessions
        if let collapsedDisplayURLs { self.collapsedDisplayURLs = collapsedDisplayURLs }
        refreshRows(animated: true)
    }
    var rowCount: Int { rows.count }
    func isEditing(at index: Int) -> Bool { index >= 0 && index < rows.count ? rows[index].isEditing : false }

    // MARK: Header

    private static func makeHeader(countLabel: NSTextField, subtitle: String? = nil) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: "Browser Sessions")
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
        addButton.setAccessibilityIdentifier("browser-sessions-section-add")

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

    var currentSessions: [BrowserSession] { sessions }

    static func makeDivider() -> NSView {
        let line = ColoredBackgroundView()
        line.fillColor = Theme.border
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    // MARK: Row lifecycle

    private func refreshRows(animated: Bool) {
        let existingEditing: [String: BrowserSession] = Dictionary(
            uniqueKeysWithValues: rows.enumerated().compactMap { index, row -> (String, BrowserSession)? in
                guard row.isEditing else { return nil }
                return (row.identity(from: sessions[safe: index]), row.formSnapshot())
            })
        clearRowsStack()
        rows.removeAll()
        for (index, session) in sessions.enumerated() {
            let collapsedDisplayURL = collapsedDisplayURLs[safe: index] ?? session.url
            let shortcut = (session.url.map { shortcutsByURL[$0] } ?? nil)
            let focusAction: (() -> Void)? = onFocus.map { handler in { handler(session) } }
            let row = BrowserSessionRowView(session: session, displayURL: collapsedDisplayURL, shortcut: shortcut, onFocus: focusAction)
            row.onBeginEdit = { [weak self] in self?.handleBeginEdit(row: row) }
            row.onCancel = { [weak self] in self?.handleCancel(row: row) }
            row.onSave = { [weak self] edited in self?.handleSave(row: row, edited: edited) }
            row.onRemove = { [weak self] in self?.handleRemove(row: row) }
            rows.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if let snapshot = existingEditing[row.identity(from: session)] { row.enterEditing(prefill: snapshot, animated: false) }
        }
        countLabel.stringValue = "\(sessions.count)"
        _ = animated
    }

    private func clearRowsStack() {
        for arrangedSubview in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
    }

    // MARK: Row callbacks

    private func handleBeginEdit(row: BrowserSessionRowView) { row.enterEditing(prefill: nil, animated: true) }

    private func handleCancel(row: BrowserSessionRowView) {
        guard let index = rows.firstIndex(of: row) else { return }
        if pendingDraftIndex == index {
            sessions.remove(at: index)
            pendingDraftIndex = nil
            refreshRows(animated: true)
            return
        }
        row.exitEditing(animated: true)
    }

    private func handleSave(row: BrowserSessionRowView, edited: BrowserSession) {
        guard let index = rows.firstIndex(of: row), index < sessions.count else { return }
        sessions[index] = edited
        if pendingDraftIndex == index { pendingDraftIndex = nil }
        row.exitEditing(animated: true)
        row.rebindCollapsedContent(from: edited, displayURL: row.collapsedDisplayURL)
        onCommit?(sessions)
    }

    private func handleRemove(row: BrowserSessionRowView) {
        guard let index = rows.firstIndex(of: row), index < sessions.count else { return }
        let target = sessions[index]
        let isDraft = (pendingDraftIndex == index)
        let commitAfterRemove = !isDraft
        let confirm = { [weak self] (approved: Bool) in
            guard let self, approved else { return }
            guard let currentIndex = self.rows.firstIndex(of: row), currentIndex < self.sessions.count else { return }
            self.sessions.remove(at: currentIndex)
            if self.pendingDraftIndex == currentIndex { self.pendingDraftIndex = nil }
            self.refreshRows(animated: true)
            if commitAfterRemove { self.onCommit?(self.sessions) }
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
        let displayName = target.name ?? target.url ?? "this session"
        alert.messageText = "Remove \(displayName)?"
        alert.informativeText = "This removes the browser session from the workspace."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
    }

    @objc func handleAdd(_ sender: NSButton) {
        let blank = BrowserSession(name: nil, url: nil)
        sessions.append(blank)
        pendingDraftIndex = sessions.count - 1
        refreshRows(animated: true)
        rows.last?.enterEditing(prefill: blank, animated: false)
    }
}

// MARK: - BrowserSessionRowView

@MainActor final class BrowserSessionRowView: HoverRevealRowView {
    var onBeginEdit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: ((BrowserSession) -> Void)?
    var onRemove: (() -> Void)?

    private let body = NSStackView()
    private var collapsedContainer: NSStackView = NSStackView()
    private var editingContainer: NSStackView?
    private(set) var isEditing: Bool = false

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var currentSession: BrowserSession
    private(set) var collapsedDisplayURL: String?
    private var onFocus: (() -> Void)?

    private var nameField: NSTextField?
    private var urlField: NSTextField?

    init(session: BrowserSession, displayURL: String? = nil, shortcut: String? = nil, onFocus: (() -> Void)? = nil) {
        self.currentSession = session
        self.collapsedDisplayURL = displayURL
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
            shortcut: shortcutView, nameLabel: nameLabel, detailLabel: detailLabel, onEdit: { [weak self] in self?.onBeginEdit?() },
            onRemove: { [weak self] in self?.onRemove?() }, onFocus: onFocus)
        collapsedContainer = collapsedLine.row
        body.addArrangedSubview(collapsedContainer)
        collapsedContainer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureActionButtonsForHover(collapsedLine.actionButtons)
        rebindCollapsedContent(from: session, displayURL: displayURL)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func rebindCollapsedContent(from session: BrowserSession, displayURL: String? = nil) {
        currentSession = session
        collapsedDisplayURL = displayURL ?? session.url
        let visibleURL = collapsedDisplayURL ?? session.url
        let primaryText = session.name ?? visibleURL ?? "(unnamed)"
        nameLabel.stringValue = primaryText
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = Theme.text
        let detailText = session.name != nil ? (visibleURL ?? "") : ""
        detailLabel.stringValue = detailText
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = Theme.muted
        detailLabel.lineBreakMode = .byTruncatingTail
    }

    func enterEditing(prefill: BrowserSession?, animated: Bool) {
        guard !isEditing else { return }
        isEditing = true
        let seed = prefill ?? currentSession
        let (form, fields) = Self.makeEditingForm(
            session: seed, onCancel: { [weak self] in self?.onCancel?() }, onSave: { [weak self] edited in self?.onSave?(edited) })
        nameField = fields.name
        urlField = fields.url
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
        urlField = nil
    }

    func identity(from session: BrowserSession?) -> String {
        let fromState = currentSession.name ?? currentSession.url ?? ""
        return fromState.isEmpty ? (session?.url ?? session?.name ?? "") : fromState
    }

    func formSnapshot() -> BrowserSession {
        let name = nameField?.stringValue.trimmingCharacters(in: .whitespaces)
        let url = urlField?.stringValue.trimmingCharacters(in: .whitespaces)
        return BrowserSession(name: name?.isEmpty == false ? name : nil, url: url?.isEmpty == false ? url : nil)
    }

    private static func makeCollapsedLine(
        shortcut: NSView? = nil, nameLabel: NSTextField, detailLabel: NSTextField, onEdit: @escaping () -> Void, onRemove: @escaping () -> Void,
        onFocus: (() -> Void)?
    ) -> (row: NSStackView, actionButtons: [NSButton]) {
        var contentViews: [NSView] = []
        contentViews.append(RowPrimitives.statusSlot())
        if let shortcut { contentViews.append(shortcut) }
        contentViews.append(RowPrimitives.typeIconTile(.browser, symbol: "globe", accessibilityLabel: "Browser Session"))
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

        let editButton = buildActionButton(symbol: "pencil", tooltip: "Edit") { _ in onEdit() }
        editButton.setAccessibilityIdentifier("browser-session-row-edit")
        let removeButton = buildActionButton(symbol: "trash", tooltip: "Remove") { _ in onRemove() }
        removeButton.setAccessibilityIdentifier("browser-session-row-remove")

        let row = NSStackView(views: [contentArea, editButton, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        return (row, [editButton, removeButton])
    }

    private static func makeEditingForm(session: BrowserSession, onCancel: @escaping () -> Void, onSave: @escaping (BrowserSession) -> Void) -> (
        NSStackView, (name: NSTextField, url: NSTextField)
    ) {
        let nameField = NSTextField(string: session.name ?? "")
        nameField.placeholderString = "Name (optional)"
        nameField.setAccessibilityIdentifier("browser-session-row-edit-name")

        let urlField = NSTextField(string: session.url ?? "")
        urlField.placeholderString = "https://"
        urlField.setAccessibilityIdentifier("browser-session-row-edit-url")

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
        cancelButton.setAccessibilityIdentifier("browser-session-row-edit-cancel")
        Theme.applySecondaryStyle(to: cancelButton)
        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("browser-session-row-edit-save")
        Theme.applyPrimaryStyle(to: saveButton)

        let refreshSaveEnabled: () -> Void = { [weak saveButton, weak urlField] in
            saveButton?.isEnabled = !(urlField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }

        let target = BrowserSessionFormTarget()
        target.onCancel = onCancel
        target.onSave = { [weak nameField, weak urlField] in
            let name = nameField?.stringValue.trimmingCharacters(in: .whitespaces)
            let url = urlField?.stringValue.trimmingCharacters(in: .whitespaces)
            onSave(BrowserSession(name: name?.isEmpty == false ? name : nil, url: url?.isEmpty == false ? url : nil))
        }
        target.onTextChange = refreshSaveEnabled
        nameField.delegate = target
        urlField.delegate = target
        cancelButton.target = target
        cancelButton.action = #selector(BrowserSessionFormTarget.triggerCancel)
        saveButton.target = target
        saveButton.action = #selector(BrowserSessionFormTarget.triggerSave)
        refreshSaveEnabled()

        let trailingButtons = NSStackView(views: [NSView(), cancelButton, saveButton])
        trailingButtons.orientation = .horizontal
        trailingButtons.alignment = .centerY
        trailingButtons.spacing = 6
        trailingButtons.translatesAutoresizingMaskIntoConstraints = false
        let form = NSStackView(views: [labeled("Name", nameField), labeled("URL", urlField), trailingButtons])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        form.translatesAutoresizingMaskIntoConstraints = false
        objc_setAssociatedObject(form, &Self.targetKey, target, .OBJC_ASSOCIATION_RETAIN)
        return (form, (nameField, urlField))
    }

    private static func buildActionButton(symbol: String, tooltip: String, onClick: @escaping (NSButton) -> Void) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = Theme.muted
        let target = BrowserSessionFormTarget()
        target.onCancel = { onClick(button) }
        button.target = target
        button.action = #selector(BrowserSessionFormTarget.triggerCancel)
        objc_setAssociatedObject(button, &targetKey, target, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    private static var targetKey: UInt8 = 0
}

extension BrowserSessionRowView {
    var collapsedPrimaryTextForTesting: String { nameLabel.stringValue }
    var collapsedDetailTextForTesting: String { detailLabel.stringValue }
    var editingURLValueForTesting: String? { urlField?.stringValue }
}

@MainActor private final class BrowserSessionFormTarget: NSObject, NSTextFieldDelegate {
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onTextChange: (() -> Void)?
    @objc func triggerCancel() { onCancel?() }
    @objc func triggerSave() { onSave?() }
    func controlTextDidChange(_ obj: Notification) { onTextChange?() }
}

extension Array { fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
