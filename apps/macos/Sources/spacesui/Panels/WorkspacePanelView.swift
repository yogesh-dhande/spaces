import AppKit

/// One panel: a tab bar over the selected tab's pane tree. Instantiated per
/// `PanelScope` and kept alive (detached) while its workspace is not selected, so
/// hosted Ghostty surfaces survive workspace switching. All state mutations flow up to
/// the coordinator through closures; `apply(layout:)` is the single render entry.
@MainActor final class WorkspacePanelView: NSView {
    let scope: PanelScope

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onRenameTab: ((_ tabID: String, _ title: String?) -> Void)?
    var onSplitPane: ((_ paneID: String, _ direction: PaneSplitDirection) -> Void)?
    var onFocusPane: ((String) -> Void)?
    var onSplitWeightsChanged: ((_ splitID: String, _ weights: [Double]) -> Void)?
    /// Resolves a pane's live content controller; nil renders the pane empty (e.g. a
    /// persisted pane whose session is still reattaching).
    var paneContentProvider: ((Pane) -> (any PaneContentHosting)?)?

    private let tabBar = PanelTabBarView()
    private let paneTree = PaneTreeView()
    private let emptyStateLabel = NSTextField(labelWithString: "No open terminals")
    private var renderedLayout = PanelLayout()

    init(scope: PanelScope) {
        self.scope = scope
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        tabBar.onSelectTab = { [weak self] tabID in self?.onSelectTab?(tabID) }
        tabBar.onCloseTab = { [weak self] tabID in self?.onCloseTab?(tabID) }
        tabBar.onNewTab = { [weak self] in self?.onNewTab?() }
        tabBar.onRenameTab = { [weak self] tabID, title in self?.onRenameTab?(tabID, title) }
        tabBar.onSplitFocusedPane = { [weak self] direction in
            guard let self, let paneID = self.splitTargetPaneID() else { return }
            self.onSplitPane?(paneID, direction)
        }
        paneTree.onSplitWeightsChanged = { [weak self] splitID, weights in self?.onSplitWeightsChanged?(splitID, weights) }
        paneTree.onConfigurePane = { [weak self] paneView, pane in self?.configure(paneView: paneView, pane: pane) }

        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.textColor = Theme.mutedSecondary
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tabBar)
        addSubview(paneTree)
        addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor), tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneTree.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            paneTree.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneTree.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneTree.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor), emptyStateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }


    /// Renders the layout: tab strip, selected tab's pane tree, focused-pane chrome,
    /// and the empty state when no tabs exist. `newTabShortcutHint` labels the empty
    /// state with the New-terminal shortcut when known.
    func apply(layout: PanelLayout, titlesByTabID: [String: String], newTabShortcutHint: String? = nil) {
        renderedLayout = layout
        tabBar.update(tabIDs: layout.tabs.map(\.id), titlesByTabID: titlesByTabID, selectedTabID: layout.selectedTabID)
        let selectedTab = layout.tabs.first { $0.id == layout.selectedTabID }
        paneTree.render(root: selectedTab?.root)
        emptyStateLabel.isHidden = !layout.isEmpty
        tabBar.isHidden = layout.isEmpty
        if layout.isEmpty {
            emptyStateLabel.stringValue = newTabShortcutHint.map { "No open terminals — \($0) opens one" } ?? "No open terminals"
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

    func updateTabTitle(_ title: String, forTabID tabID: String) { tabBar.updateTitle(title, forTabID: tabID) }

    private func configure(paneView: PaneView, pane: Pane) {
        let paneID = pane.id
        paneView.onFocusRequest = { [weak self] in self?.onFocusPane?(paneID) }
        if let content = paneContentProvider?(pane) { paneView.attachContent(content) }
    }
}
