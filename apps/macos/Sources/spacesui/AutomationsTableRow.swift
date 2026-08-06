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
        fixWidth(schedule, self.schedule)
        fixWidth(nextRun, self.nextRun)
        fixWidth(lastResult, self.lastResult)
        if let device { fixWidth(device, self.device) }
        fixWidth(toggle, self.toggle)
        fixWidth(action, self.action)

        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A low priority so a narrow pane squeezes the name column rather than breaking the grid.
        let minimumName = name.widthAnchor.constraint(greaterThanOrEqualToConstant: nameMinimum)
        minimumName.priority = .defaultLow
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
}

/// One dense row in the Automations pane's table.
///
/// Hand-rolled rather than an `NSTableView` row: the pane rebuilds wholesale on every overview refresh, so
/// there is no diffing to gain, and the row's two gestures read straight off an `NSView` — right-click
/// opens the context menu through the standard `menu` property, and double-click opens the editor — while
/// the enable switch and the contextual action keep their own click handling as ordinary subviews.
@MainActor final class AutomationsTableRowView: NSView {
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
        updateBackground()
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

    /// The table has no selection, so a single click deliberately does nothing rather than acting as a
    /// weaker Edit; the row's own gesture is the double-click that opens the editor.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        onDoubleClick()
    }

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
