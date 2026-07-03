import AppKit

/// The main window's titlebar accessory hosting the selected workspace panel's tab
/// strip, so tabs share the titlebar row with the traffic lights instead of costing
/// a second chrome row. The strip is offset to start at the right pane's leading
/// edge and spans to the window's right edge; the area left of the strip (over the
/// sidebar) stays empty so native titlebar dragging keeps working there.
@MainActor final class PanelTabStripAccessoryView: NSView {
    let tabBar = PanelTabBarView()

    /// The sidebar's current width; the strip starts just right of the divider.
    var sidebarWidth: CGFloat = 360 {
        didSet { needsLayout = true }
    }

    private var stripLeadingConstraint: NSLayoutConstraint!
    private var clipConstraintsInstalled = false

    init() {
        super.init(frame: .zero)
        addSubview(tabBar)
        stripLeadingConstraint = tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 280)
        NSLayoutConstraint.activate([
            stripLeadingConstraint,
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        installClipConstraintsIfNeeded()
        super.layout()
        syncStripLeading()
    }

    /// AppKit's accessory clip view sizes a `.left` accessory to its fitting size,
    /// which collapses a plain container to zero width. Once the clip view has its
    /// natural origin (just right of the traffic lights), pin it to span to the
    /// titlebar's trailing edge and fill it — the same technique Ghostty's titlebar
    /// tabs use to occupy the full row.
    private func installClipConstraintsIfNeeded() {
        guard !clipConstraintsInstalled, let clip = superview, let titlebar = clip.superview,
            NSStringFromClass(type(of: clip)).contains("NSTitlebarAccessoryClipView"), clip.frame.origin.x > 0
        else { return }
        clipConstraintsInstalled = true
        let leadingConstant = clip.frame.origin.x
        clip.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: leadingConstant),
            clip.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            clip.topAnchor.constraint(equalTo: titlebar.topAnchor),
            clip.heightAnchor.constraint(equalTo: titlebar.heightAnchor),
            leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            topAnchor.constraint(equalTo: clip.topAnchor),
            bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
    }

    /// The accessory's window origin is owned by AppKit, so the strip's leading
    /// offset is derived from where the view actually landed: the strip starts at
    /// the sidebar/right-pane divider.
    private func syncStripLeading() {
        guard window != nil else { return }
        let originX = convert(NSPoint.zero, to: nil).x
        let target = max(0, sidebarWidth + 1 - originX)
        if abs(stripLeadingConstraint.constant - target) > 0.5 { stripLeadingConstraint.constant = target }
    }
}
