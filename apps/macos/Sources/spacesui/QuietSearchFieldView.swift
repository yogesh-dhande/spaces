import AppKit
import spacesterminalcore

/// A search field in the quiet control style: no border, the control fill, the system magnifier glyph.
/// `field` is the live `NSSearchField`; callers wire its target, action, and accessibility identifier.
///
/// The fill lives on a wrapper because the field's own bezel is what draws a border. Clicks on the
/// wrapper's padding focus the field.
@MainActor final class QuietSearchFieldView: NSView {
    static let height: CGFloat = 28

    let field = QuietSearchField()

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = PaneLayout.controlRadius
        bindAppearanceReactiveLayer(self) { view in view.layer?.backgroundColor = Theme.controlFill.cgColor }

        field.placeholderString = placeholder
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.body
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false

        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

/// `NSSearchField` whose cell insets the field editor for the magnifier and cancel button.
final class QuietSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { QuietSearchFieldCell.self }
        set {}
    }
}

/// With the bezel off, `NSSearchFieldCell` hands the whole bounds to the field editor when editing starts
/// (`select` for `makeFirstResponder`/`selectText`, `edit` for a click), so typed text begins under the
/// magnifier. Both entry points are routed through `searchTextRect(forBounds:)`, which the cell's own drawing
/// already uses for the placeholder and the committed text.
private final class QuietSearchFieldCell: NSSearchFieldCell {
    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int
    ) {
        super.select(
            withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart,
            length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}
