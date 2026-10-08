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
/// The height comes from a layout manager's used rect rather than a line count of the string,
/// because that is the only measurement that accounts for wrapping, and wrapping depends on the
/// editor's width. So the height is recomputed on every text change and on every layout pass, the
/// latter being where a width change (the form window resizing) shows up.
///
/// Both the height and the scroller are functions of the text and the view's width alone. Legacy
/// scrollers take width from the text, so a scroller whose visibility followed the document and clip
/// heights fed back into the measurement: the editor measured one height with the scroller hidden,
/// shrank, the stale taller document showed the scroller, the narrower text measured taller, and the
/// two states alternated until AppKit aborted the window's layout passes.
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
        // An NSTextView starts on TextKit 2, and reading `layoutManager` is Apple's switch into TextKit 1
        // for good. The measuring layout manager is TextKit 1, and the two engines lay out some text
        // differently (wrapped CJK text measured 16 pt in TextKit 1 against 128 pt drawn by TextKit 2),
        // so measuring against a TextKit 2 editor gives a height that disagrees with what the editor
        // draws. Pinning the editor to TextKit 1 makes both use the same engine.
        _ = editor.layoutManager
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        documentView = editor
        hasHorizontalScroller = false
        // A growing editor's scroller is shown by `applyContentHeight`; AppKit's autohide would decide
        // from the document height at an intermediate layout and reintroduce the feedback loop.
        hasVerticalScroller = !rule.bounds.growsWithContent
        autohidesScrollers = !rule.bounds.growsWithContent
        // A pinned editor never revisits this constraint.
        heightConstraint.isActive = true
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

    /// Sizes the view to its text and shows the scroller exactly when the text outgrows the cap.
    /// Assigning only on a real change keeps the layout pass from re-triggering itself: the second
    /// pass measures the same text at the same width and stops here.
    func applyContentHeight() {
        // An editor pinned to a line count needs no measurement, and measuring would force a full
        // layout of text that can be long (the setup log tail) for a height that cannot move.
        guard rule.bounds.growsWithContent else { return }
        // Before the first layout pass the view has no width to wrap against.
        guard frame.width > 0 else { return }
        let used = usedTextHeightWithoutScroller()
        let target = rule.height(forUsedTextHeight: used)
        if abs(heightConstraint.constant - target) > 0.5 { heightConstraint.constant = target }
        let needsScroller = ceil(used) + editor.textContainerInset.height * 2 > rule.maximumHeight
        if hasVerticalScroller != needsScroller { hasVerticalScroller = needsScroller }
    }

    /// A second layout manager on the editor's own text storage, used only to measure. The storage
    /// feeds every edit to each of its layout managers incrementally, so a keystroke in a long prompt
    /// relays out the touched paragraph rather than the whole text, as the editor's own layout does.
    /// It has no text view, so it never draws, and it lives and dies with the editor's storage.
    private lazy var measuringLayout: (manager: NSLayoutManager, container: NSTextContainer)? = {
        guard let storage = editor.textStorage, let editorContainer = editor.textContainer else { return nil }
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = editorContainer.lineFragmentPadding
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return (manager, container)
    }()

    /// The text's height wrapped at the full width, as if no scroller were shown. Measured on the
    /// private layout so the answer does not depend on the editor's current container width, which
    /// narrows while a legacy scroller is visible. Text that fits at the full width needs no scroller,
    /// and text that overflows the cap at the full width overflows it at any narrower width too, so
    /// the scroller decision never changes the height it was decided from.
    private func usedTextHeightWithoutScroller() -> CGFloat {
        guard let (manager, container) = measuringLayout else { return 0 }
        let width = max(frame.width - editor.textContainerInset.width * 2, 0)
        // Assigning an unchanged size would still invalidate the layout, so only resize on a real change.
        if container.size.width != width { container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height
    }
}
