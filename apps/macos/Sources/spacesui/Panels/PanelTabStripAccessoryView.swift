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
    /// The clip/self spanning constraints currently installed, and the titlebar they
    /// pin to. Kept so a titlebar rebuild (see `installClipSpanningConstraintsIfNeeded`)
    /// can be detected and the constraints re-established rather than left orphaned.
    private var spanningConstraints: [NSLayoutConstraint] = []
    private weak var constrainedTitlebar: NSView?

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

    /// Drops the visible workspace's ownership of the shared titlebar strip. Detail panes
    /// without a visible workspace panel call this so a later background render from the
    /// previously selected workspace cannot re-show stale tabs over that pane.
    func releaseTabBar() {
        tabBar.hostingOwner = nil
        tabBar.onSelectTab = nil
        tabBar.onCloseTab = nil
        tabBar.onNewTab = nil
        tabBar.onRenameTab = nil
        tabBar.onSplitFocusedPane = nil
        tabBar.clear()
        tabBar.isHidden = true
    }

    override func layout() {
        installClipSpanningConstraintsIfNeeded()
        super.layout()
        syncStripLeading()
    }

    /// AppKit's accessory clip view sizes a `.left` accessory to its fitting size,
    /// which collapses a plain container to zero width. Once the clip view has its
    /// natural origin (just right of the traffic lights), pin it to span to the
    /// titlebar's trailing edge and fill it — the same technique Ghostty's titlebar
    /// tabs use to occupy the full row.
    ///
    /// Re-runnable rather than one-shot: the clip→titlebar constraints live on the
    /// titlebar, and AppKit rebuilds the titlebar container on an `NSApp.appearance`
    /// change (light/dark switch), discarding them and collapsing the strip back to
    /// its fitting width — the tab list then loses all its width and only the action
    /// buttons remain visible. Detecting that the titlebar changed (or any spanning
    /// constraint went inactive) re-establishes the span so the strip self-heals on
    /// the next layout pass.
    private func installClipSpanningConstraintsIfNeeded() {
        guard let clip = superview, let titlebar = clip.superview,
            NSStringFromClass(type(of: clip)).contains("NSTitlebarAccessoryClipView"), clip.frame.origin.x > 0
        else { return }
        guard constrainedTitlebar !== titlebar || !spanningConstraints.allSatisfy(\.isActive) else { return }
        NSLayoutConstraint.deactivate(spanningConstraints)
        let leadingConstant = clip.frame.origin.x
        clip.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        spanningConstraints = [
            clip.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: leadingConstant),
            clip.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            clip.topAnchor.constraint(equalTo: titlebar.topAnchor),
            clip.heightAnchor.constraint(equalTo: titlebar.heightAnchor),
            leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            topAnchor.constraint(equalTo: clip.topAnchor),
            bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ]
        NSLayoutConstraint.activate(spanningConstraints)
        constrainedTitlebar = titlebar
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
