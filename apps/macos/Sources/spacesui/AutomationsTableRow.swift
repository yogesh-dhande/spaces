import AppKit
import spacesterminalcore

/// The shared column grid the Automations pane's table lays its header and every row out on. The columns
/// after the name are fixed width so the lines align without an `NSTableView`; the name column absorbs the
/// remaining width and truncates last.
@MainActor enum AutomationTableColumns {
    static let schedule: CGFloat = 180
    static let nextRun: CGFloat = 88
    static let lastResult: CGFloat = 104
    static let device: CGFloat = 96
    static let toggle: CGFloat = 36
    static let action: CGFloat = 88
    static let nameMinimum: CGFloat = 110
    static let spacing: CGFloat = 10
    /// Compact enough to scan a long list, tall enough for the enable switch and a 13 pt name.
    static let rowHeight: CGFloat = 30
    /// Horizontal breathing room between the table's card edge and its first and last columns.
    static let horizontalInset: CGFloat = 6

    /// Lays one table line out on the grid. `device` is nil when the table shows a single device and the
    /// column is dropped from every line at once.
    static func layOut(
        status: NSView, name: NSView, schedule: NSView, nextRun: NSView, lastResult: NSView, device: NSView?, toggle: NSView, action: NSView
    ) -> NSStackView {
        // The three widest data columns yield before the name column does: each holds its preferred width
        // only while the name keeps its floor, and they give way in a fixed order (schedule first, then
        // last-result, then device) so every line compresses identically and the grid stays aligned. With
        // the device column shown, the preferred widths alone exceed a default-width window's row, so
        // without this give the flexible name column would be the one to collapse.
        flexWidth(schedule, preferred: self.schedule, minimum: 120, yieldOrder: 0)
        fixWidth(nextRun, self.nextRun)
        flexWidth(lastResult, preferred: self.lastResult, minimum: 88, yieldOrder: 1)
        if let device { flexWidth(device, preferred: self.device, minimum: 78, yieldOrder: 2) }
        fixWidth(toggle, self.toggle)
        fixWidth(action, self.action)

        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Outranks the flexible columns' preferred widths (so they shrink first) while staying below
        // required (so an impossibly narrow pane degrades without unsatisfiable-constraint breakage).
        let minimumName = name.widthAnchor.constraint(greaterThanOrEqualToConstant: nameMinimum)
        minimumName.priority = NSLayoutConstraint.Priority(900)
        minimumName.isActive = true

        var views: [NSView] = [status, name, schedule, nextRun, lastResult]
        if let device { views.append(device) }
        views.append(contentsOf: [toggle, action])

        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = spacing
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    private static func fixWidth(_ view: NSView, _ width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    /// A column that prefers `preferred` but shrinks toward `minimum` when the row runs out of room.
    /// A lower `yieldOrder` gives way first; the priorities all sit below the name column's floor (900),
    /// which is what makes these columns yield before the name does. Identical constraints on every line
    /// mean identical solutions, so the columns stay aligned across the whole table.
    private static func flexWidth(_ view: NSView, preferred: CGFloat, minimum: CGFloat, yieldOrder: Int) {
        view.translatesAutoresizingMaskIntoConstraints = false
        // The explicit constraints own this column's width outright: intrinsic-size priorities are pushed
        // below every width constraint so a short label cannot hug the column narrower than the shared
        // grid, and a long one cannot resist compression past the floor (it truncates instead).
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        let preferredWidth = view.widthAnchor.constraint(equalToConstant: preferred)
        preferredWidth.priority = NSLayoutConstraint.Priority(Float(700 + yieldOrder * 10))
        let floor = view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum)
        floor.priority = NSLayoutConstraint.Priority(950)
        let cap = view.widthAnchor.constraint(lessThanOrEqualToConstant: preferred)
        NSLayoutConstraint.activate([preferredWidth, floor, cap])
    }
}

/// One dense row in the Automations pane's table.
///
/// Hand-rolled rather than an `NSTableView` row: the pane rebuilds wholesale on every overview refresh, so
/// there is no diffing to gain, and the row's two gestures read straight off an `NSView` — right-click
/// opens the context menu through the standard `menu` property, and double-click opens the editor — while
/// the enable switch and the contextual action keep their own click handling as ordinary subviews.
@MainActor final class AutomationsTableRowView: NSView, NSGestureRecognizerDelegate {
    private let onDoubleClick: () -> Void

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
        // happens to bubble up. Clicks that land on a control (the enable switch, the action button) are
        // refused below so a double-click there stays the control's own interaction.
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(rowDoubleClicked))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        doubleClick.delegate = self
        addGestureRecognizer(doubleClick)
        updateBackground()
    }

    @objc private func rowDoubleClicked() { onDoubleClick() }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let location = convert(event.locationInWindow, from: nil)
        var hit = hitTest(location)
        while let view = hit, view !== self {
            if view is NSControl { return false }
            hit = view.superview
        }
        return true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
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
