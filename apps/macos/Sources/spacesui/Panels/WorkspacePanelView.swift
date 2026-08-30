import AppKit
import spacesterminalcore

/// One panel: a tab bar over the selected tab's pane tree. Instantiated per
/// `PanelScope` and kept alive (detached) while its workspace is not selected, so
/// hosted Ghostty surfaces survive workspace switching. All state mutations flow up to
/// the coordinator through closures; `apply(layout:)` is the single render entry.
@MainActor final class WorkspacePanelView: NSView {
    let scope: PanelScope

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onMoveTab: ((_ tabID: String, _ insertionIndex: Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onRenameTab: ((_ tabID: String, _ title: String?) -> Void)?
    var onSplitPane: ((_ paneID: String, _ direction: PaneSplitDirection) -> Void)?
    /// Tab-header context menu's "Open Tab in New Window".
    var onOpenTabInNewWindow: ((_ tabID: String) -> Void)?
    /// Tab-header context menu's "Open Selected Pane in New Window".
    var onOpenSelectedPaneInNewWindow: ((_ tabID: String) -> Void)?
    var onFocusPane: ((String) -> Void)?
    var onSplitWeightsChanged: ((_ splitID: String, _ weights: [Double]) -> Void)?
    /// Resolves a pane's live content controller; nil renders the pane empty (e.g. a
    /// persisted pane whose session is still reattaching).
    var paneContentProvider: ((Pane) -> (any PaneContentHosting)?)?
    /// Fires whenever this view joins or leaves a window — including a workspace switch, which
    /// detaches the panel from the main window's detail container while keeping it alive (see the
    /// class docstring). A terminal pane's Ghostty surface is meant to survive that detachment
    /// untouched; a code pane's `WKWebView` is not, so `PanelCoordinator` uses this to hibernate
    /// only code-pane content while the panel has no window and rebuild it when the panel rejoins one.
    var onWindowMembershipChanged: ((_ isInWindow: Bool) -> Void)?

    /// The workspace panel's own tab strip; non-nil only for a `.workspace` scope (a main-window
    /// panel). A `.globalWindow` panel carries no tabs (see this type's docstring) and shows
    /// `identityStrip` in its place instead.
    private let tabBar: PanelTabBarView?
    /// A global window's chrome row: workspace/pane identity plus the two split buttons, standing
    /// in for `tabBar`. Non-nil only for a `.globalWindow` scope.
    private let identityStrip: PanelWindowIdentityStripView?
    private let paneTree = PaneTreeView()
    private let emptyStateLabel = NSTextField(labelWithString: "No open terminals")
    private var renderedLayout = PanelLayout()
    private var renderedTitles: [String: String] = [:]
    /// A titlebar-hosted tab strip driven by this panel instead of the built-in one (main-window
    /// presentation). Only a `.workspace` panel adopts one — a `.globalWindow` panel's chrome
    /// lives in its own window, never the main window's titlebar.
    private weak var externalTabBar: PanelTabBarView?
    private var paneTreeTopToTabBar: NSLayoutConstraint!
    private var paneTreeTopToView: NSLayoutConstraint!

    init(scope: PanelScope) {
        self.scope = scope
        switch scope {
        case .workspace:
            tabBar = PanelTabBarView()
            identityStrip = nil
        case .globalWindow:
            tabBar = nil
            identityStrip = PanelWindowIdentityStripView()
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let chromeView: NSView
        if let tabBar {
            wire(tabBar)
            chromeView = tabBar
        } else {
            // `identityStrip` is the only other case constructed above.
            identityStrip!.onSplitFocusedPane = { [weak self] direction in
                guard let self, let paneID = self.splitTargetPaneID() else { return }
                self.onSplitPane?(paneID, direction)
            }
            identityStrip!.onOpenSelectedPaneInNewWindow = { [weak self] in
                guard let self, let tabID = self.renderedLayout.tabs.first?.id else { return }
                self.onOpenSelectedPaneInNewWindow?(tabID)
            }
            chromeView = identityStrip!
        }
        paneTree.onSplitWeightsChanged = { [weak self] splitID, weights in self?.onSplitWeightsChanged?(splitID, weights) }
        paneTree.onConfigurePane = { [weak self] paneView, pane in self?.configure(paneView: paneView, pane: pane) }

        emptyStateLabel.font = Typography.rowDetail
        emptyStateLabel.textColor = Theme.mutedSecondary
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(chromeView)
        addSubview(paneTree)
        addSubview(emptyStateLabel)
        paneTreeTopToTabBar = paneTree.topAnchor.constraint(equalTo: chromeView.bottomAnchor)
        paneTreeTopToView = paneTree.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            chromeView.topAnchor.constraint(equalTo: topAnchor), chromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: trailingAnchor), paneTreeTopToTabBar,
            paneTree.leadingAnchor.constraint(equalTo: leadingAnchor), paneTree.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneTree.bottomAnchor.constraint(equalTo: bottomAnchor), emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() { onWindowMembershipChanged?(window != nil) }

    private func wire(_ bar: PanelTabBarView) {
        bar.onSelectTab = { [weak self] tabID in self?.onSelectTab?(tabID) }
        bar.onCloseTab = { [weak self] tabID in self?.onCloseTab?(tabID) }
        bar.onMoveTab = { [weak self] tabID, insertionIndex in self?.onMoveTab?(tabID, insertionIndex) }
        bar.onNewTab = { [weak self] in self?.onNewTab?() }
        bar.onRenameTab = { [weak self] tabID, title in self?.onRenameTab?(tabID, title) }
        bar.onSplitFocusedPane = { [weak self] direction in
            guard let self, let paneID = self.splitTargetPaneID() else { return }
            self.onSplitPane?(paneID, direction)
        }
        bar.onOpenTabInNewWindow = { [weak self] tabID in self?.onOpenTabInNewWindow?(tabID) }
        bar.onOpenSelectedPaneInNewWindow = { [weak self] tabID in self?.onOpenSelectedPaneInNewWindow?(tabID) }
    }

    /// Adopts a shared, externally hosted tab strip (the main window's titlebar
    /// accessory): this panel takes over the strip's callbacks and content, and its
    /// built-in strip collapses. Only the adopting panel updates the shared strip —
    /// background panels fall back to their own (hidden) one. Only ever called on a
    /// `.workspace` panel (the main window's own detail views) — a global window's chrome lives
    /// in its own window, never the main window's titlebar.
    func adoptExternalTabBar(_ bar: PanelTabBarView) {
        guard tabBar != nil else { return }
        if externalTabBar === bar, bar.hostingOwner === self { return }
        externalTabBar = bar
        bar.hostingOwner = self
        wire(bar)
        paneTreeTopToTabBar.isActive = false
        paneTreeTopToView.isActive = true
        applyToActiveChrome()
    }

    /// Returns the panel to its built-in content tab strip. The main window uses this
    /// while fullscreen because AppKit hides titlebar accessories there.
    func useBuiltInTabBar() {
        guard tabBar != nil else { return }
        if let externalTabBar, externalTabBar.hostingOwner === self { externalTabBar.hostingOwner = nil }
        externalTabBar = nil
        paneTreeTopToView.isActive = false
        paneTreeTopToTabBar.isActive = true
        applyToActiveChrome()
    }

    private var drivesExternalTabBar: Bool {
        guard let externalTabBar else { return false }
        return externalTabBar.hostingOwner === self
    }

    /// Renders the layout: chrome (tab strip or identity strip), selected tab's pane tree,
    /// focused-pane chrome, and the empty state when no tabs exist. `newTabShortcutHint` labels
    /// the empty state with the New-terminal shortcut when known. `identity` is the current
    /// identity-strip content for a `.globalWindow` panel; unused (and always nil) for a
    /// `.workspace` panel, which has no identity strip.
    func apply(layout: PanelLayout, titlesByTabID: [String: String], identity: PanelWindowIdentity? = nil, newTabShortcutHint: String? = nil) {
        renderedLayout = layout
        renderedTitles = titlesByTabID
        applyToActiveChrome(identity: identity)
        let selectedTab = layout.tabs.first { $0.id == layout.selectedTabID }
        paneTree.render(root: selectedTab?.root)
        emptyStateLabel.isHidden = !layout.isEmpty
        if layout.isEmpty { emptyStateLabel.stringValue = newTabShortcutHint.map { "No open terminals — \($0) opens one" } ?? "No open terminals" }
    }

    private func applyToActiveChrome(identity: PanelWindowIdentity? = nil) {
        if let identityStrip {
            let canMoveFocusedPane = renderedLayout.tabs.first.map(PanelLayoutEngine.canMoveFocusedPaneOutOfPanelWindow) ?? false
            identityStrip.update(identity: identity, canMoveFocusedPane: canMoveFocusedPane)
            return
        }
        guard let tabBar else { return }
        let hasMultiplePanesByTabID = Dictionary(uniqueKeysWithValues: renderedLayout.tabs.map { ($0.id, PanelLayoutEngine.panes(in: $0).count > 1) })
        if drivesExternalTabBar, let externalTabBar {
            tabBar.isHidden = true
            externalTabBar.isHidden = renderedLayout.isEmpty
            externalTabBar.update(
                tabIDs: renderedLayout.tabs.map(\.id), titlesByTabID: renderedTitles, selectedTabID: renderedLayout.selectedTabID,
                hasMultiplePanesByTabID: hasMultiplePanesByTabID)
        } else {
            tabBar.isHidden = renderedLayout.isEmpty
            tabBar.update(
                tabIDs: renderedLayout.tabs.map(\.id), titlesByTabID: renderedTitles, selectedTabID: renderedLayout.selectedTabID,
                hasMultiplePanesByTabID: hasMultiplePanesByTabID)
        }
    }

    /// The pane a tab-bar split targets: the focused pane when it lives in the
    /// selected tab, else the selected tab's first pane.
    private func splitTargetPaneID() -> String? {
        guard let selectedTab = renderedLayout.tabs.first(where: { $0.id == renderedLayout.selectedTabID }) else { return nil }
        let panes = PanelLayoutEngine.panes(in: selectedTab)
        if let focusedPaneID = renderedLayout.focusedPaneID, panes.contains(where: { $0.id == focusedPaneID }) { return focusedPaneID }
        return panes.first?.id
    }

    func updateTabTitle(_ title: String, forTabID tabID: String) {
        renderedTitles[tabID] = title
        if identityStrip != nil {
            // A global window's identity strip shows its pane title alongside the workspace
            // label, and the label can go stale (a git branch rename, say) independently of any
            // pane-title change. Patching just the title into the last-rendered identity would
            // carry that stale label forward, so the strip case is refreshed instead through
            // `updateIdentity(_:)`, which the coordinator drives with a freshly computed identity
            // (see `PanelCoordinator.refreshTabTitles`). This still records the title in
            // `renderedTitles` for callers that read it (e.g. `apply(layout:...)` diffing).
            return
        }
        if drivesExternalTabBar, let externalTabBar {
            externalTabBar.updateTitle(title, forTabID: tabID)
        } else {
            tabBar?.updateTitle(title, forTabID: tabID)
        }
    }

    /// Refreshes the identity strip in place with a freshly computed `PanelWindowIdentity`
    /// (current workspace label included) for the lightweight title-refresh path that skips a
    /// full `apply(layout:...)` re-render — see `PanelCoordinator.refreshTabTitles`. No-op for a
    /// `.workspace` panel, which has no identity strip.
    func updateIdentity(_ identity: PanelWindowIdentity?) {
        guard identityStrip != nil else { return }
        let canMoveFocusedPane = renderedLayout.tabs.first.map(PanelLayoutEngine.canMoveFocusedPaneOutOfPanelWindow) ?? false
        identityStrip?.update(identity: identity, canMoveFocusedPane: canMoveFocusedPane)
    }

    private func configure(paneView: PaneView, pane: Pane) {
        let paneID = pane.id
        paneView.onFocusRequest = { [weak self] in self?.onFocusPane?(paneID) }
        if let content = paneContentProvider?(pane) { paneView.attachContent(content) }
        // Only mark focus when the selected tab is split — a lone pane needs no disambiguation.
        let selectedTab = renderedLayout.tabs.first { $0.id == renderedLayout.selectedTabID }
        let paneCount = selectedTab.map { PanelLayoutEngine.panes(in: $0).count } ?? 0
        paneView.setPaneFocused(paneCount > 1 && renderedLayout.focusedPaneID == paneID)
    }
}
