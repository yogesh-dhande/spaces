import AppKit

/// How tall a form's text editor may be, expressed in lines of the editor's own font.
///
/// Equal bounds pin the editor to that many lines. A range lets it grow with what the user types and
/// scroll inside itself once the text passes the upper bound.
struct TextEditorLineBounds: Equatable {
    let minimum: Int
    let maximum: Int

    /// The automation form's prompt and script editors: four lines at rest, growing with the text up
    /// to fourteen, then scrolling. Long prompts and scripts are the common case, and a four-line
    /// window forced the user to scroll a field they were still writing.
    static let growingFormEditor = TextEditorLineBounds(minimum: 4, maximum: 14)

    /// An editor that always shows `lines` lines, and scrolls for anything longer.
    static func fixed(_ lines: Int) -> TextEditorLineBounds { TextEditorLineBounds(minimum: lines, maximum: lines) }

    var growsWithContent: Bool { maximum > minimum }
}

/// Maps laid-out text to the height its scroll view takes: never shorter than the minimum line
/// count, never taller than the maximum, with the text container's inset added on both sides.
///
/// Pure arithmetic so the rule can be tested without a view: the caller measures the text and hands
/// the result here.
struct TextEditorHeightRule: Equatable {
    let bounds: TextEditorLineBounds
    /// The font's line height as the layout manager measures it.
    let lineHeight: CGFloat
    /// `NSTextView.textContainerInset.height`, which pads the text above and below.
    let verticalInset: CGFloat

    init(bounds: TextEditorLineBounds, lineHeight: CGFloat, verticalInset: CGFloat) {
        self.bounds = bounds
        self.lineHeight = lineHeight
        self.verticalInset = verticalInset
    }

    init(bounds: TextEditorLineBounds, font: NSFont, verticalInset: CGFloat) {
        self.init(bounds: bounds, lineHeight: NSLayoutManager().defaultLineHeight(for: font), verticalInset: verticalInset)
    }

    var minimumHeight: CGFloat { height(forLines: bounds.minimum) }
    var maximumHeight: CGFloat { height(forLines: bounds.maximum) }

    /// `usedHeight` is the height the layout manager reports for the text laid out at the editor's
    /// current width, so a wrapped line counts exactly like a typed one.
    func height(forUsedTextHeight usedHeight: CGFloat) -> CGFloat { min(max(ceil(usedHeight) + verticalInset * 2, minimumHeight), maximumHeight) }

    private func height(forLines lines: Int) -> CGFloat { ceil(lineHeight * CGFloat(max(lines, 1))) + verticalInset * 2 }
}

/// The scroll view `scrollableTextView` returns: it keeps its own height constraint in step with the
/// text it holds.
///
/// The height comes from the layout manager's used rect rather than a line count of the string,
/// because that is the only measurement that accounts for wrapping, and wrapping depends on the
/// editor's width. So the height is recomputed on every text change and on every layout pass, the
/// latter being where a width change (the form window resizing) shows up.
@MainActor final class AutoGrowingTextScrollView: NSScrollView {
    private let rule: TextEditorHeightRule
    private let editor: NSTextView

    /// The constraint the view drives. Held so tests and layout share one source of truth for the
    /// editor's height.
    private(set) lazy var heightConstraint: NSLayoutConstraint = {
        let constraint = heightAnchor.constraint(equalToConstant: rule.minimumHeight)
        constraint.isActive = true
        return constraint
    }()

    init(editor: NSTextView, rule: TextEditorHeightRule) {
        self.editor = editor
        self.rule = rule
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        documentView = editor
        // Installs the constraint (a pinned editor never revisits it) and then measures the seed text.
        heightConstraint.isActive = true
        applyContentHeight()
        // Target-action observation rather than a block: the notification centre holds the observer
        // weakly, so the view needs no deinit teardown, and the callback runs synchronously on the
        // posting (main) thread, so the editor resizes within the keystroke that grew it.
        NotificationCenter.default.addObserver(self, selector: #selector(editorTextDidChange), name: NSText.didChangeNotification, object: editor)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func editorTextDidChange(_ notification: Notification) { applyContentHeight() }

    override func layout() {
        super.layout()
        applyContentHeight()
    }

    /// Sizes the view to its text. Assigning only on a real change keeps the layout pass from
    /// re-triggering itself: the second pass measures the same text and stops here.
    func applyContentHeight() {
        // An editor pinned to a line count needs no measurement, and measuring would force a full
        // layout of text that can be long (the setup log tail) for a height that cannot move.
        guard rule.bounds.growsWithContent else { return }
        let target = rule.height(forUsedTextHeight: usedTextHeight())
        guard abs(heightConstraint.constant - target) > 0.5 else { return }
        heightConstraint.constant = target
    }

    private func usedTextHeight() -> CGFloat {
        guard let layoutManager = editor.layoutManager, let container = editor.textContainer else { return 0 }
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height
    }
}
