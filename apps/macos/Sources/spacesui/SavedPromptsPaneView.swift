import AppKit
import spacesterminalcore

/// The Prompts pane's views: the header (title, search, New Prompt) and the table.
///
/// A render whose layout matches the last one only updates the lines' contents. Otherwise it rebuilds the
/// header line, divider, and row lines, but never the header controls or the open prompt's editor. The search
/// field and the editor hold the keyboard focus while the user types, and a view that is removed from its
/// window drops it; a rebuild therefore only ever inserts and removes the table lines around the editor. The
/// one exception is the editor's title field, which the open row's line hosts: it moves into each rebuilt
/// line, and `render` restores its caret.
@MainActor final class SavedPromptsPaneView: NSObject {
    /// The pane's content, shown through `showScrollableDetailStack`.
    let stack = NSStackView()

    var onSearchChange: (String) -> Void = { _ in }
    var onNewPrompt: () -> Void = {}
    var onRowClick: (String) -> Void = { _ in }
    var onRowCopy: (String) -> Void = { _ in }

    private let editorActions: SavedPromptEditorActions
    private let searchField = NSSearchField()
    private let newPromptButton = NSButton(title: "New Prompt", target: nil, action: nil)
    private let table = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var editor: (key: String, view: SavedPromptEditorView)?
    /// What the table's lines were last built or updated from, to tell whether a render needs a rebuild.
    private var applied: (rows: [SavedPromptsPaneModel.Row], showsDeviceColumn: Bool)?
    private var rowViews: [String: SavedPromptRowView] = [:]

    private enum Layout {
        static let title = TableGrid.ColumnWidth.name(minimum: 120, maximum: 240)
        static let preview = TableGrid.ColumnWidth.growable(preferred: 340, minimum: 160)
        static let device = TableGrid.ColumnWidth.capped(preferred: 120, minimum: 72)
        static let used = TableGrid.ColumnWidth.fixed(48)
        // Wide enough for "Copy edited" in the secondary button style (its label plus 36pt of padding).
        static let copy = TableGrid.ColumnWidth.fixed(116)
        static let sideInset: CGFloat = 4
    }

    init(query: String, editorActions: SavedPromptEditorActions) {
        self.editorActions = editorActions
        super.init()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Prompts")
        titleLabel.font = Typography.pageTitle
        titleLabel.textColor = Theme.text

        searchField.placeholderString = "Search titles and text"
        searchField.sendsSearchStringImmediately = true
        searchField.stringValue = query
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityIdentifier("prompts-search")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        searchField.setContentHuggingPriority(NSLayoutConstraint.Priority(250), for: .horizontal)

        newPromptButton.target = self
        newPromptButton.action = #selector(newPromptClicked)
        newPromptButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New prompt")
        newPromptButton.imagePosition = .imageLeading
        newPromptButton.setAccessibilityIdentifier("prompts-new")
        Theme.applySecondaryStyle(to: newPromptButton)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let headerRow = NSStackView(views: [titleLabel, searchField, spacer, newPromptButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        stack.addArrangedSubview(headerRow)
        constrainFormFieldToFillWidth(headerRow, in: stack)

        table.orientation = .vertical
        table.alignment = .leading
        table.spacing = 0
        table.edgeInsets = NSEdgeInsets(top: 6, left: Layout.sideInset, bottom: 6, right: Layout.sideInset)
        table.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(table)
        constrainFormFieldToFillWidth(table, in: stack)

        emptyLabel.font = Typography.rowDetail
        emptyLabel.textColor = Theme.muted
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityIdentifier("prompts-empty")
        stack.addArrangedSubview(emptyLabel)
        constrainFormFieldToFillWidth(emptyLabel, in: stack)
    }

    @objc private func searchChanged() { onSearchChange(searchField.stringValue) }
    @objc private func newPromptClicked() { onNewPrompt() }

    /// Redraws the table. `editorState` is the open draft's row key and what its editor shows, or nil when
    /// no editor is open.
    func render(
        rows: [SavedPromptsPaneModel.Row], showsDeviceColumn: Bool, canCreate: Bool, emptyMessage: String?,
        editorState: (key: String, state: SavedPromptEditorState)?
    ) {
        newPromptButton.isHidden = !canCreate
        emptyLabel.stringValue = emptyMessage ?? ""
        emptyLabel.isHidden = emptyMessage == nil

        let (editorView, isNewEditor) = resolveEditor(for: editorState)
        let previous = applied
        let current = (rows: rows, showsDeviceColumn: showsDeviceColumn)
        applied = current
        if !isNewEditor, let previous, SavedPromptsPaneModel.canApplyInPlace(from: previous, to: current) {
            for row in rows {
                rowViews[row.key]?.updateUsed(row.usedText)
                rowViews[row.key]?.updateCopyButton(title: row.copyTitle, showsCopied: row.showsCopied)
            }
            return
        }
        // A real layout change while the user types, such as another device changing the library's visible
        // rows, rebuilds the open row's line. The title field lives in that line, so it is detached from its
        // window and loses first responder; remember the caret to put it back. Its undo history does not
        // survive the detach. That is accepted: the layout rarely changes mid-edit.
        let titleEditing =
            isNewEditor
            ? nil
            : editorView.flatMap { editor in
                (editor.titleField.currentEditor() as? NSTextView).map { (window: editor.titleField.window, selection: $0.selectedRange) }
            }
        // Everything but a reused editor goes; that one stays in the table so it keeps its focus.
        for line in table.arrangedSubviews where line !== editorView || isNewEditor {
            table.removeArrangedSubview(line)
            line.removeFromSuperview()
        }
        guard !rows.isEmpty else { return }

        let grid = TableGrid()
        var lines: [NSView] = [makeHeaderLine(grid: grid, showsDeviceColumn: showsDeviceColumn), makeDivider()]
        rowViews = [:]
        for row in rows {
            let line = SavedPromptRowView(
                row: row, grid: grid, titleField: row.isExpanded ? editorView?.titleField : nil,
                onClick: { [weak self] in self?.onRowClick(row.key) }, onCopy: { [weak self] in self?.onRowCopy(row.key) })
            rowViews[row.key] = line
            lines.append(line)
            if row.isExpanded, let editorView { lines.append(editorView) }
        }
        // The reused editor, if it is not wanted after all (its row left the table), goes too.
        if let editorView, !lines.contains(where: { $0 === editorView }), editorView.superview != nil {
            table.removeArrangedSubview(editorView)
            editorView.removeFromSuperview()
        }
        for (index, line) in lines.enumerated() {
            let isReusedEditor = line === editorView && !isNewEditor && line.superview != nil
            guard !isReusedEditor else { continue }
            table.insertArrangedSubview(line, at: index)
            // Leading alignment gives lines their intrinsic width, so each is pinned to the table's full width.
            line.widthAnchor.constraint(equalTo: table.widthAnchor, constant: -Layout.sideInset * 2).isActive = true
        }
        table.setCustomSpacing(4, after: lines[0])
        table.setCustomSpacing(4, after: lines[1])
        grid.activateColumnAlignment()
        if isNewEditor, editorState?.state.isNew == true {
            editorView?.focusTitle()
        } else if let titleEditing, let titleField = editorView?.titleField, titleEditing.window?.makeFirstResponder(titleField) == true {
            (titleField.currentEditor() as? NSTextView)?.selectedRange = titleEditing.selection
        }
    }

    /// The editor for the open draft: the one already built while the same draft stays open, a new one when
    /// a different draft opens, none when no draft is open.
    private func resolveEditor(for editorState: (key: String, state: SavedPromptEditorState)?) -> (SavedPromptEditorView?, isNew: Bool) {
        guard let editorState else {
            editor?.view.removeFromSuperview()
            editor = nil
            return (nil, false)
        }
        if let editor, editor.key == editorState.key {
            editor.view.apply(editorState.state)
            return (editor.view, false)
        }
        editor?.view.removeFromSuperview()
        let view = SavedPromptEditorView(actions: editorActions)
        view.apply(editorState.state)
        editor = (key: editorState.key, view: view)
        return (view, true)
    }

    private func makeHeaderLine(grid: TableGrid, showsDeviceColumn: Bool) -> NSView {
        func header(_ text: String, alignment: NSTextAlignment = .left) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = Typography.metadataTitle
            label.textColor = Theme.mutedSecondary
            label.alignment = alignment
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        var columns: [(view: NSView, width: TableGrid.ColumnWidth)] = [(header("Title"), Layout.title), (header("Prompt"), Layout.preview)]
        if showsDeviceColumn { columns.append((header("Device"), Layout.device)) }
        columns.append((header("Used", alignment: .right), Layout.used))
        columns.append((NSView(), Layout.copy))
        return grid.makeHeaderLine(columns)
    }

    private func makeDivider() -> NSView {
        let divider = ColoredBackgroundView()
        divider.fillColor = Theme.border
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }
}
