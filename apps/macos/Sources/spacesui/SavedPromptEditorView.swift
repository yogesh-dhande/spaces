import AppKit
import spacesterminalcore
import systembridge

/// What the inline editor shows, derived from the draft.
struct SavedPromptEditorState: Equatable {
    struct DeviceChoice: Equatable {
        let id: String
        let name: String
    }

    let title: String
    let text: String
    let isNew: Bool
    let isDirty: Bool
    let error: String?
    /// Non-empty only for a new draft on a table that spans several devices.
    let deviceChoices: [DeviceChoice]
    let selectedDeviceID: String

    /// Save and Discard exist only while there is something to save: a new draft always has, a saved prompt
    /// once it is edited.
    var showsSaveAndDiscard: Bool { isNew || isDirty }
}

struct SavedPromptEditorActions {
    var titleChanged: (String) -> Void
    var textChanged: (String) -> Void
    var deviceChosen: (String) -> Void
    var save: () -> Void
    var discard: () -> Void
    var delete: () -> Void
    /// Escape in either field.
    var escape: () -> Void
}

/// The panel that opens under a prompt's row: the prompt text and the actions on it.
///
/// The prompt's title is edited in the open row's Title cell, so this view owns `titleField` but does not
/// lay it out: the row line hosts it.
///
/// The controller keeps one instance per open draft and calls `apply` as the draft changes, rather than
/// building a new panel per render: replacing the panel would take the focused field away mid-typing.
/// `apply` writes a field only when it differs from the model, so the caret stays put while typing.
@MainActor final class SavedPromptEditorView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    private let actions: SavedPromptEditorActions
    let titleField = NSTextField()
    private let textView = makeEditableTextView()
    private let captionLabel = NSTextField(labelWithString: "Edited \u{00B7} not saved")
    private let errorLabel = helpTextLabel("")
    private let devicePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let deviceLabel = NSTextField(labelWithString: "Save on")
    private let trashButton = NSButton()
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var state: SavedPromptEditorState?

    init(actions: SavedPromptEditorActions) {
        self.actions = actions
        super.init(frame: .zero)
        bindAppearanceReactiveLayer(self) { view in
            view.layer?.backgroundColor = Theme.rowHover.cgColor
            view.layer?.cornerRadius = UIRadius.compact
            // The row line above carries the top corners; together they read as one rounded surface.
            view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("prompts-editor")

        titleField.placeholderString = "Title"
        titleField.font = Typography.rowLabel
        titleField.isBordered = false
        titleField.drawsBackground = true
        titleField.backgroundColor = Theme.surface2
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.delegate = self
        titleField.setAccessibilityIdentifier("prompts-editor-title")

        textView.delegate = self
        textView.setAccessibilityIdentifier("prompts-editor-text")
        textView.onCancel = { [weak self] in self?.actions.escape() }
        let textScroll = scrollableTextView(textView, lines: .growingFormEditor, inputBackgroundColor: Theme.surface2, borderColor: Theme.border)

        captionLabel.font = Typography.metadata
        captionLabel.textColor = Theme.orange
        errorLabel.textColor = Theme.red
        errorLabel.setAccessibilityIdentifier("prompts-editor-error")

        deviceLabel.font = Typography.metadata
        deviceLabel.textColor = .secondaryLabelColor
        devicePopUp.target = self
        devicePopUp.action = #selector(deviceChosen)
        devicePopUp.controlSize = .small
        devicePopUp.font = Typography.metadata

        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete prompt")
        trashButton.imagePosition = .imageOnly
        trashButton.isBordered = false
        trashButton.contentTintColor = Theme.muted
        trashButton.toolTip = "Delete prompt"
        trashButton.target = self
        trashButton.action = #selector(deleteClicked)
        trashButton.setAccessibilityIdentifier("prompts-editor-delete")

        discardButton.target = self
        discardButton.action = #selector(discardClicked)
        Theme.applySecondaryStyle(to: discardButton)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        Theme.applySecondaryStyle(to: saveButton)
        saveButton.setAccessibilityIdentifier("prompts-editor-save")

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let actionRow = NSStackView(views: [deviceLabel, devicePopUp, captionLabel, spacer, trashButton, discardButton, saveButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let stack = NSStackView(views: [textScroll, actionRow, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TableGrid.horizontalInset + 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(TableGrid.horizontalInset + 4)),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        for view in [textScroll, actionRow, errorLabel] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    /// Makes the panel show `state`. Fields that already hold the model's value are left alone.
    func apply(_ state: SavedPromptEditorState) {
        self.state = state
        if titleField.stringValue != state.title { titleField.stringValue = state.title }
        if textView.string != state.text { textView.string = state.text }
        captionLabel.isHidden = !state.isDirty
        trashButton.isHidden = state.isNew
        discardButton.isHidden = !state.showsSaveAndDiscard
        saveButton.isHidden = !state.showsSaveAndDiscard
        let showsPicker = !state.deviceChoices.isEmpty
        deviceLabel.isHidden = !showsPicker
        devicePopUp.isHidden = !showsPicker
        if showsPicker {
            if devicePopUp.itemTitles != state.deviceChoices.map(\.name) {
                devicePopUp.removeAllItems()
                devicePopUp.addItems(withTitles: state.deviceChoices.map(\.name))
            }
            if let index = state.deviceChoices.firstIndex(where: { $0.id == state.selectedDeviceID }) { devicePopUp.selectItem(at: index) }
        }
        errorLabel.stringValue = state.error ?? ""
        errorLabel.isHidden = state.error == nil
    }

    /// Moves the caret into the title when a new draft opens, so the user can start typing.
    func focusTitle() { window?.makeFirstResponder(titleField) }

    // MARK: - Actions

    @objc private func deviceChosen() {
        guard let state, devicePopUp.indexOfSelectedItem >= 0, state.deviceChoices.indices.contains(devicePopUp.indexOfSelectedItem) else { return }
        actions.deviceChosen(state.deviceChoices[devicePopUp.indexOfSelectedItem].id)
    }

    @objc private func deleteClicked() { actions.delete() }
    @objc private func discardClicked() { actions.discard() }
    @objc private func saveClicked() { actions.save() }

    func controlTextDidChange(_ notification: Notification) { actions.titleChanged(titleField.stringValue) }

    func textDidChange(_ notification: Notification) { actions.textChanged(textView.string) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        actions.escape()
        return true
    }

    /// ⌘S saves while the panel is on screen and has something to save.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let editingHere =
            window?.firstResponder === textView || (titleField.currentEditor() != nil && window?.firstResponder === titleField.currentEditor())
        if flags == .command, event.charactersIgnoringModifiers == "s", state?.showsSaveAndDiscard == true, editingHere {
            actions.save()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
