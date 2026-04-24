import AppKit

@MainActor final class StopScriptSection {
    // MARK: Public surface

    let view: NSView
    var onCommit: ((String) -> Void)?

    // MARK: State

    private var currentValue: String
    private let container: NSStackView
    private let editButton: NSButton
    private(set) var isEditing = false

    // MARK: Init

    init(value: String) {
        self.currentValue = value

        let title = NSTextField(labelWithString: "Stop Script")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text

        editButton = NSButton()
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")
        editButton.bezelStyle = .inline
        editButton.isBordered = false
        editButton.toolTip = "Edit"
        editButton.contentTintColor = Theme.muted
        editButton.alphaValue = 0.6
        editButton.setAccessibilityIdentifier("stop-script-edit")

        let headerSpacer = NSView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)

        let header = NSStackView(views: [title, headerSpacer, editButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false

        let divider = ColoredBackgroundView()
        divider.fillColor = Theme.border
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        self.container = stack

        let card = ColoredBackgroundView()
        card.fillColor = Theme.surface
        card.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        self.view = card

        let editTarget = StopScriptSectionTarget()
        editTarget.onAction = { [weak self] in self?.enterEditing() }
        editButton.target = editTarget
        editButton.action = #selector(StopScriptSectionTarget.triggerAction)
        objc_setAssociatedObject(editButton, &Self.editButtonTargetKey, editTarget, .OBJC_ASSOCIATION_RETAIN)

        objc_setAssociatedObject(card, &Self.anchorKey, self, .OBJC_ASSOCIATION_RETAIN)
        showCollapsed()
    }

    private static var anchorKey: UInt8 = 0
    private static var editButtonTargetKey: UInt8 = 0
    private static var formTargetKey: UInt8 = 0

    // MARK: Public API

    func reload(value: String) {
        guard !isEditing else { return }
        currentValue = value
        showCollapsed()
    }

    // MARK: Collapsed

    private func showCollapsed() {
        removeContentViews()
        editButton.isHidden = false

        let preview = NSTextField(labelWithString: currentValue.isEmpty ? "(none)" : currentValue)
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textColor = currentValue.isEmpty ? Theme.mutedSecondary : Theme.muted
        preview.lineBreakMode = .byTruncatingTail
        preview.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [preview])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 10, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)

        container.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    // MARK: Editing

    private func enterEditing() {
        guard !isEditing else { return }
        isEditing = true
        removeContentViews()
        editButton.isHidden = true

        let (form, textView) = Self.makeEditingForm(
            value: currentValue,
            onCancel: { [weak self] in
                guard let self else { return }
                isEditing = false
                showCollapsed()
            },
            onSave: { [weak self] value in
                guard let self else { return }
                isEditing = false
                currentValue = value
                onCommit?(value)
                showCollapsed()
            })
        container.addArrangedSubview(form)
        form.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        textView.window?.makeFirstResponder(textView)
    }

    private func removeContentViews() {
        for v in container.arrangedSubviews.dropFirst(2) {
            container.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    // MARK: Editing form builder

    private static func makeEditingForm(value: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) -> (
        NSStackView, NSTextView
    ) {
        let textView = NSTextView()
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = Theme.text
        textView.backgroundColor = Theme.surface2
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = value
        textView.setAccessibilityIdentifier("workspace-stop-script-field")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let inputBg = ColoredBackgroundView()
        inputBg.fillColor = Theme.surface2
        inputBg.cornerRadius = 8
        inputBg.translatesAutoresizingMaskIntoConstraints = false
        inputBg.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: inputBg.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: inputBg.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: inputBg.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: inputBg.bottomAnchor, constant: -4),
        ])
        inputBg.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.setAccessibilityIdentifier("workspace-stop-script-cancel")

        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("workspace-stop-script-save")

        let target = StopScriptSectionTarget()
        target.onCancel = onCancel
        target.onSave = { [weak textView] in onSave(textView?.string ?? "") }
        cancelButton.target = target
        cancelButton.action = #selector(StopScriptSectionTarget.triggerCancel)
        saveButton.target = target
        saveButton.action = #selector(StopScriptSectionTarget.triggerSave)

        let buttonRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let form = NSStackView(views: [inputBg, buttonRow])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)
        form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inputBg.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
            buttonRow.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
        ])

        objc_setAssociatedObject(form, &formTargetKey, target, .OBJC_ASSOCIATION_RETAIN)
        return (form, textView)
    }
}

// MARK: - Target

@MainActor private final class StopScriptSectionTarget: NSObject {
    var onAction: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    @objc func triggerAction() { onAction?() }
    @objc func triggerCancel() { onCancel?() }
    @objc func triggerSave() { onSave?() }
}
