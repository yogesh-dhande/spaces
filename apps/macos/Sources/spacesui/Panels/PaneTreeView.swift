import AppKit

/// Renders one tab's `PaneNode` tree as nested `NSSplitView`s. Structural changes
/// (split, close) rebuild the split-view skeleton, but leaf `PaneView`s are cached by
/// pane id and re-parented rather than recreated — the hosted Ghostty surface must
/// survive splits and closes elsewhere in the tree. Divider drags report back as
/// weight changes for persistence.
@MainActor final class PaneTreeView: NSView {
    /// Configures a (new or re-parented) pane view for its pane: attach content and
    /// wire split/close/focus callbacks.
    var onConfigurePane: ((PaneView, Pane) -> Void)?
    var onSplitWeightsChanged: ((_ splitID: String, _ weights: [Double]) -> Void)?

    private var paneViewsByID: [String: PaneView] = [:]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func paneView(forPaneID paneID: String) -> PaneView? { paneViewsByID[paneID] }

    /// Rebuilds the tree for `root` (nil clears). Cached pane views for ids no longer
    /// present are dropped; their content lifecycle is the coordinator's concern.
    func render(root: PaneNode?) {
        for view in subviews { view.removeFromSuperview() }
        guard let root else {
            paneViewsByID.removeAll()
            return
        }
        let built = build(node: root)
        addSubview(built)
        NSLayoutConstraint.activate([
            built.topAnchor.constraint(equalTo: topAnchor), built.leadingAnchor.constraint(equalTo: leadingAnchor),
            built.trailingAnchor.constraint(equalTo: trailingAnchor), built.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let liveIDs = Set(paneIDs(in: root))
        for staleID in paneViewsByID.keys where !liveIDs.contains(staleID) { paneViewsByID.removeValue(forKey: staleID) }
    }

    private func paneIDs(in node: PaneNode) -> [String] {
        switch node {
        case .leaf(let pane): return [pane.id]
        case .split(let split): return split.children.flatMap { paneIDs(in: $0) }
        }
    }

    private func build(node: PaneNode) -> NSView {
        switch node {
        case .leaf(let pane):
            let view: PaneView
            if let cached = paneViewsByID[pane.id] {
                view = cached
                view.removeFromSuperview()
            } else {
                view = PaneView(paneID: pane.id)
                paneViewsByID[pane.id] = view
            }
            onConfigurePane?(view, pane)
            return view
        case .split(let split):
            let splitView = WeightedSplitView()
            // NSSplitView "vertical" means vertical dividers, i.e. children side by side.
            splitView.isVertical = split.orientation == .horizontal
            splitView.dividerStyle = .thin
            splitView.translatesAutoresizingMaskIntoConstraints = false
            for child in split.children { splitView.addArrangedSubview(build(node: child)) }
            splitView.desiredWeights = split.weights
            let splitID = split.id
            splitView.onWeightsChanged = { [weak self] weights in self?.onSplitWeightsChanged?(splitID, weights) }
            return splitView
        }
    }
}

/// An `NSSplitView` that applies persisted relative weights once it has real bounds and
/// reports user divider drags back as normalized weights.
@MainActor final class WeightedSplitView: NSSplitView, NSSplitViewDelegate {
    var desiredWeights: [Double] = []
    var onWeightsChanged: (([Double]) -> Void)?
    private var hasAppliedDesiredWeights = false
    private var isApplyingWeights = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private var totalExtent: CGFloat {
        let dividers = CGFloat(max(arrangedSubviews.count - 1, 0)) * dividerThickness
        return (isVertical ? bounds.width : bounds.height) - dividers
    }

    override func layout() {
        super.layout()
        applyDesiredWeightsIfNeeded()
    }

    private func applyDesiredWeightsIfNeeded() {
        guard !hasAppliedDesiredWeights, arrangedSubviews.count > 1, desiredWeights.count == arrangedSubviews.count, totalExtent > 1 else { return }
        hasAppliedDesiredWeights = true
        isApplyingWeights = true
        defer { isApplyingWeights = false }
        let total = desiredWeights.reduce(0, +)
        guard total > 0 else { return }
        var offset: CGFloat = 0
        for (index, weight) in desiredWeights.dropLast().enumerated() {
            offset += totalExtent * CGFloat(weight / total)
            setPosition(offset + CGFloat(index) * dividerThickness, ofDividerAt: index)
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard hasAppliedDesiredWeights, !isApplyingWeights, totalExtent > 1, inLiveResize || NSApp.currentEvent?.type == .leftMouseDragged else {
            return
        }
        let extents = arrangedSubviews.map { view in Double(isVertical ? view.frame.width : view.frame.height) }
        let total = extents.reduce(0, +)
        guard total > 0 else { return }
        onWeightsChanged?(extents.map { $0 / total })
    }
}
