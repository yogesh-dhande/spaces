import AppKit
import spacesterminalcore

/// The shared column grid the Automations pane's table lays its header and every row out on.
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
@MainActor final class AutomationTableGrid {
    static let schedule: CGFloat = 224
    /// Wide enough for the next-run chip, which carries the value plus its disclosure chevron.
    static let nextRun: CGFloat = 132
    static let device: CGFloat = 96
    static let toggle: CGFloat = 36
    static let nameMinimum: CGFloat = 110
    static let nameMaximum: CGFloat = 320
    static let spacing: CGFloat = 10
    /// Compact enough to scan a long list, tall enough for the enable switch and a 13 pt name.
    static let rowHeight: CGFloat = 30
    /// Horizontal breathing room between the table's card edge and its first and last columns.
    static let horizontalInset: CGFloat = 6

    /// The header's column views in line order, which every row's columns are matched against.
    private var headerColumns: [NSView] = []
    /// Row-to-header width equalities, held until `activateColumnAlignment()`. A constraint between two
    /// views needs a common ancestor to install on, and a line has none until it joins the table stack.
    private var pendingAlignment: [NSLayoutConstraint] = []

    /// Builds the header line and fixes the grid to it. `device` is nil when the table shows a single
    /// device and the column is dropped from every line at once. Call once, before any row line.
    func makeHeaderLine(status: NSView, name: NSView, schedule: NSView, nextRun: NSView, device: NSView?, toggle: NSView) -> NSStackView {
        // Schedule holds its preferred width while space is tight, then absorbs the surplus after Name
        // reaches its readable cap. This keeps the trailing status and toggle columns from bunching at
        // the table's right edge in a wide pane.
        growableWidth(schedule, preferred: Self.schedule, minimum: 120)
        fixWidth(nextRun, Self.nextRun)
        if let device { flexWidth(device, preferred: Self.device, minimum: 78) }
        fixWidth(toggle, Self.toggle)

        name.translatesAutoresizingMaskIntoConstraints = false
        // Name gets the first claim on available width, up to a readable cap, and truncates rather than
        // pushing the rest of the grid after that.
        name.setContentHuggingPriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        name.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        // Outranks the flexible columns' preferred widths (so they shrink first) while staying below
        // required (so an impossibly narrow pane degrades without unsatisfiable-constraint breakage).
        let minimumName = name.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.nameMinimum)
        minimumName.priority = NSLayoutConstraint.Priority(900)
        let maximumName = name.widthAnchor.constraint(lessThanOrEqualToConstant: Self.nameMaximum)
        NSLayoutConstraint.activate([minimumName, maximumName])

        headerColumns = Self.columnOrder(status: status, name: name, schedule: schedule, nextRun: nextRun, device: device, toggle: toggle)
        return Self.makeLine(headerColumns)
    }

    /// Builds one row line on the grid the header established.
    func makeRowLine(status: NSView, name: NSView, schedule: NSView, nextRun: NSView, device: NSView?, toggle: NSView) -> NSStackView {
        let columns = Self.columnOrder(status: status, name: name, schedule: schedule, nextRun: nextRun, device: device, toggle: toggle)
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

    private static func columnOrder(status: NSView, name: NSView, schedule: NSView, nextRun: NSView, device: NSView?, toggle: NSView) -> [NSView] {
        var columns: [NSView] = [status, name, schedule, nextRun]
        if let device { columns.append(device) }
        columns.append(toggle)
        return columns
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

    private func fixWidth(_ view: NSView, _ width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    /// A column that prefers `preferred` but shrinks toward `minimum` when the line runs out of room.
    private func flexWidth(_ view: NSView, preferred: CGFloat, minimum: CGFloat) {
        sizeFlexibleColumn(view, preferred: preferred, minimum: minimum, capsAtPreferredWidth: true)
    }

    /// A column that prefers `preferred`, shrinks toward `minimum`, and absorbs wider-window surplus.
    private func growableWidth(_ view: NSView, preferred: CGFloat, minimum: CGFloat) {
        sizeFlexibleColumn(view, preferred: preferred, minimum: minimum, capsAtPreferredWidth: false)
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
