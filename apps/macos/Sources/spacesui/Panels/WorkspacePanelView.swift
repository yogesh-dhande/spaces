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

    private let tabBar = PanelTabBarView()
    private let paneTree = PaneTreeView()
    private let emptyStateLabel = NSTextField(labelWithString: "No open terminals")
    private var renderedLayout = PanelLayout()
    private var renderedTitles: [String: String] = [:]
    /// A titlebar-hosted tab strip driven by this panel instead of the built-in one
    /// (main-window presentation). The built-in strip stays for panel windows.
    private weak var externalTabBar: PanelTabBarView?
    private var paneTreeTopToTabBar: NSLayoutConstraint!
    private var paneTreeTopToView: NSLayoutConstraint!

    init(scope: PanelScope) {
        self.scope = scope
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wire(tabBar)
        paneTree.onSplitWeightsChanged = { [weak self] splitID, weights in self?.onSplitWeightsChanged?(splitID, weights) }
        paneTree.onConfigurePane = { [weak self] paneView, pane in self?.configure(paneView: paneView, pane: pane) }

        emptyStateLabel.font = Typography.rowDetail
        emptyStateLabel.textColor = Theme.mutedSecondary
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tabBar)
        addSubview(paneTree)
        addSubview(emptyStateLabel)
        paneTreeTopToTabBar = paneTree.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        paneTreeTopToView = paneTree.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor), tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor), paneTreeTopToTabBar, paneTree.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneTree.trailingAnchor.constraint(equalTo: trailingAnchor), paneTree.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor), emptyStateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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
    }

    /// Adopts a shared, externally hosted tab strip (the main window's titlebar
    /// accessory): this panel takes over the strip's callbacks and content, and its
    /// built-in strip collapses. Only the adopting panel updates the shared strip —
    /// background panels fall back to their own (hidden) one.
    func adoptExternalTabBar(_ bar: PanelTabBarView) {
        if externalTabBar === bar, bar.hostingOwner === self { return }
        externalTabBar = bar
        bar.hostingOwner = self
        wire(bar)
        paneTreeTopToTabBar.isActive = false
        paneTreeTopToView.isActive = true
        applyToActiveTabBar()
    }

    /// Returns the panel to its built-in content tab strip. The main window uses this
    /// while fullscreen because AppKit hides titlebar accessories there.
    func useBuiltInTabBar() {
        if let externalTabBar, externalTabBar.hostingOwner === self { externalTabBar.hostingOwner = nil }
        externalTabBar = nil
        paneTreeTopToView.isActive = false
        paneTreeTopToTabBar.isActive = true
        applyToActiveTabBar()
    }

    private var drivesExternalTabBar: Bool {
        guard let externalTabBar else { return false }
        return externalTabBar.hostingOwner === self
    }

    /// Renders the layout: tab strip, selected tab's pane tree, focused-pane chrome,
    /// and the empty state when no tabs exist. `newTabShortcutHint` labels the empty
    /// state with the New-terminal shortcut when known.
    func apply(layout: PanelLayout, titlesByTabID: [String: String], newTabShortcutHint: String? = nil) {
        renderedLayout = layout
        renderedTitles = titlesByTabID
        applyToActiveTabBar()
        let selectedTab = layout.tabs.first { $0.id == layout.selectedTabID }
        paneTree.render(root: selectedTab?.root)
        emptyStateLabel.isHidden = !layout.isEmpty
        if layout.isEmpty { emptyStateLabel.stringValue = newTabShortcutHint.map { "No open terminals — \($0) opens one" } ?? "No open terminals" }
    }

    private func applyToActiveTabBar() {
        if drivesExternalTabBar, let externalTabBar {
            tabBar.isHidden = true
            externalTabBar.isHidden = renderedLayout.isEmpty
            externalTabBar.update(tabIDs: renderedLayout.tabs.map(\.id), titlesByTabID: renderedTitles, selectedTabID: renderedLayout.selectedTabID)
        } else {
            tabBar.isHidden = renderedLayout.isEmpty
            tabBar.update(tabIDs: renderedLayout.tabs.map(\.id), titlesByTabID: renderedTitles, selectedTabID: renderedLayout.selectedTabID)
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
        if drivesExternalTabBar, let externalTabBar {
            externalTabBar.updateTitle(title, forTabID: tabID)
        } else {
            tabBar.updateTitle(title, forTabID: tabID)
        }
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
