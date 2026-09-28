import AppKit
import spacesterminalcore

/// The shared column grid a hand-rolled pane table (Automations, Alerts) lays its header and every row
/// out on.
///
/// The header owns the grid. It is built first and is the only line whose columns are sized by their own
/// constraints; every row line then pins each of its columns to the width of the matching header column, so
/// there is exactly one width solution in the table and the lines cannot drift apart. Sizing a line
/// independently does not work here: a line is an `NSStackView`, whose nested flexible columns leave the
/// solver free ties to break, and it breaks them differently per line (visibly so after a window resize).
///
/// `distribution` is `.fill` on every line for the same reason. The default `.gravityAreas` lays views out
/// in gravity areas without forcing them to tile the line's pinned width, which leaves the leftover width
/// unattributed and the columns free to slide.
///
/// Column count and sizing are supplied per table by its caller (`AutomationsController`'s
/// `AutomationsTableLayout`, `AlertsController`'s `AlertsTableLayout`); this type owns only the shared
/// alignment mechanics and the width policies a hand-rolled row grid needs.
@MainActor final class TableGrid {
    enum ColumnWidth {
        /// Never shrinks or grows past `width` (a status dot, a shortcut badge, a toggle).
        case fixed(CGFloat)
        /// Prefers `preferred`, shrinks toward `minimum` under pressure, never grows past `preferred`.
        case capped(preferred: CGFloat, minimum: CGFloat)
        /// Prefers `preferred`, shrinks toward `minimum` under pressure, and absorbs surplus width beyond
        /// `preferred`: the column that takes up the table's leftover space.
        case growable(preferred: CGFloat, minimum: CGFloat)
        /// Claims the first share of available width up to `maximum`, floors at `minimum`, and truncates
        /// rather than push the rest of the grid past either bound.
        case name(minimum: CGFloat, maximum: CGFloat)
        /// The view already carries its own fixed-width constraints (e.g. `RowPrimitives.statusSlot()`),
        /// so the grid leaves its sizing alone and only ties its width to the matching header column.
        case asIs
    }

    static let spacing: CGFloat = 10
    /// Horizontal breathing room between the table's card edge and its first and last columns.
    static let horizontalInset: CGFloat = 6

    /// The header's column views in line order, which every row's columns are matched against.
    private var headerColumns: [NSView] = []
    /// Row-to-header width equalities, held until `activateColumnAlignment()`. A constraint between two
    /// views needs a common ancestor to install on, and a line has none until it joins the table stack.
    private var pendingAlignment: [NSLayoutConstraint] = []

    /// Builds the header line and fixes the grid to it and its column widths. Call once, before any row
    /// line, with every column the table has in this render (a caller drops an optional column, such as
    /// Device with one paired device, from this list rather than passing a placeholder).
    func makeHeaderLine(_ columns: [(view: NSView, width: ColumnWidth)]) -> NSStackView {
        for (view, width) in columns { size(view, width) }
        headerColumns = columns.map(\.view)
        return Self.makeLine(headerColumns)
    }

    /// Builds one row line on the grid the header established. `columns` must match the header's column
    /// count and order.
    func makeRowLine(_ columns: [NSView]) -> NSStackView {
        precondition(columns.count == headerColumns.count, "row line must have the same columns as the header line")
        for (column, headerColumn) in zip(columns, headerColumns) {
            column.translatesAutoresizingMaskIntoConstraints = false
            // The header equality owns this column's width outright: intrinsic-size priorities are pushed
            // below it so a short label cannot hug the column narrower than the grid, and a long one
            // truncates instead of widening it.
            column.setContentHuggingPriority(NSLayoutConstraint.Priority(100), for: .horizontal)
            column.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
            pendingAlignment.append(column.widthAnchor.constraint(equalTo: headerColumn.widthAnchor))
        }
        return Self.makeLine(columns)
    }

    /// Ties the rows to the header. Call once every line built here is installed in the pane's table stack.
    func activateColumnAlignment() {
        NSLayoutConstraint.activate(pendingAlignment)
        pendingAlignment = []
    }

    private static func makeLine(_ columns: [NSView]) -> NSStackView {
        let line = NSStackView(views: columns)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = spacing
        line.edgeInsets = NSEdgeInsets(top: 0, left: horizontalInset, bottom: 0, right: horizontalInset)
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    private func size(_ view: NSView, _ width: ColumnWidth) {
        switch width {
        case .fixed(let width): fixWidth(view, width)
        case .capped(let preferred, let minimum): sizeFlexibleColumn(view, preferred: preferred, minimum: minimum, capsAtPreferredWidth: true)
        case .growable(let preferred, let minimum): sizeFlexibleColumn(view, preferred: preferred, minimum: minimum, capsAtPreferredWidth: false)
        case .name(let minimum, let maximum): sizeNameColumn(view, minimum: minimum, maximum: maximum)
        case .asIs: break
        }
    }

    private func fixWidth(_ view: NSView, _ width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func sizeFlexibleColumn(_ view: NSView, preferred: CGFloat, minimum: CGFloat, capsAtPreferredWidth: Bool) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        let preferredWidth = view.widthAnchor.constraint(equalToConstant: preferred)
        preferredWidth.priority = NSLayoutConstraint.Priority(700)
        let floor = view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum)
        // Below the name column's floor (900): when even the floors cannot all hold, these give way and
        // the name is the last column standing, not the first to collapse.
        floor.priority = NSLayoutConstraint.Priority(850)
        NSLayoutConstraint.activate([preferredWidth, floor])
        if capsAtPreferredWidth { view.widthAnchor.constraint(lessThanOrEqualToConstant: preferred).isActive = true }
    }

    private func sizeNameColumn(_ view: NSView, minimum: CGFloat, maximum: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        // Name gets the first claim on available width, up to a readable cap, and truncates rather than
        // pushing the rest of the grid after that.
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        // Outranks the flexible columns' preferred widths (so they shrink first) while staying below
        // required (so an impossibly narrow pane degrades without unsatisfiable-constraint breakage).
        let minimumWidth = view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum)
        minimumWidth.priority = NSLayoutConstraint.Priority(900)
        let maximumWidth = view.widthAnchor.constraint(lessThanOrEqualToConstant: maximum)
        NSLayoutConstraint.activate([minimumWidth, maximumWidth])
    }
}

/// One dense row in the Automations pane's table.
///
/// Hand-rolled rather than an `NSTableView` row: the pane rebuilds wholesale on every overview refresh, so
/// there is no diffing to gain, and the row's two gestures read straight off an `NSView` — right-click
/// opens the context menu through the standard `menu` property, and double-click opens the editor — while
/// the enable switch and the next-run chip keep their own click handling as ordinary subviews.
@MainActor final class AutomationsTableRowView: NSView, NSGestureRecognizerDelegate {
    private let onDoubleClick: () -> Void
    private var hoverTrackingArea: NSTrackingArea?

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            updateBackground()
        }
    }

    init(onDoubleClick: @escaping () -> Void) {
        self.onDoubleClick = onDoubleClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        // A recognizer rather than a `mouseDown` override so the double-click is genuinely row-wide: it
        // observes events for the whole subtree, where a raw override only sees what the responder chain
        // happens to bubble up. Clicks that land on a control (the enable switch, the next-run chip) are
        // refused below so a double-click there stays the control's own interaction.
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(rowDoubleClicked))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        doubleClick.delegate = self
        addGestureRecognizer(doubleClick)
        updateBackground()
    }

    @objc private func rowDoubleClicked() { onDoubleClick() }

    /// Refuses the double-click only where an actionable control owns the click (the enable switch, the
    /// next-run chip). A plain `NSControl` test would be wrong here: the row's labels are `NSTextField`s,
    /// which are controls too, and they cover most of the row the gesture is meant to serve.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let location = convert(event.locationInWindow, from: nil)
        var hit = hitTest(location)
        while let view = hit, view !== self {
            if view is NSButton || view is NSSwitch { return false }
            hit = view.superview
        }
        return true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    // Replaces only this view's own hover area: AppKit's tooltip manager keeps its own tracking area on
    // this view (installed by setting `toolTip`), and removing every area would silently kill the tooltip.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    // Resolve under this view's effective appearance so a live light/dark switch re-resolves the fill;
    // a bare `.cgColor` snapshot would keep the old variant.
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = (isHovered ? Theme.rowHover : .clear).cgColor }
    }
}
