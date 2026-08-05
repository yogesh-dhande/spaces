import AppKit

/// Renders one tab's `PaneNode` tree as nested `NSSplitView`s. Leaf `PaneView`s are
/// cached by pane id, and the split skeleton is rebuilt only when the tree structure
/// (which panes exist, how they're split) actually changes — rebuilding tears down and
/// re-parents the view hierarchy, which detaches the window's first responder if a pane
/// inside it currently holds keyboard focus. A focus-only, title-only, or weight-only
/// re-render must not cost the user their focused pane. Divider drags report back as
/// weight changes for persistence.
@MainActor final class PaneTreeView: NSView {
    /// Configures a (new or re-parented) pane view for its pane: attach content and
    /// wire split/close/focus callbacks.
    var onConfigurePane: ((PaneView, Pane) -> Void)?
    var onSplitWeightsChanged: ((_ splitID: String, _ weights: [Double]) -> Void)?

    private var paneViewsByID: [String: PaneView] = [:]
    /// Structural signature of the tree currently materialized in the view hierarchy;
    /// nil when nothing is built. See `structureSignature(of:)`.
    private var renderedStructure: String?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Renders `root` (nil clears). If the tree's structure is unchanged from what's
    /// already materialized, the view hierarchy is left completely untouched — only
    /// `onConfigurePane` is re-invoked per leaf — so an in-place focus/title/weight
    /// update never detaches a first responder living inside the tree. Otherwise the
    /// skeleton is rebuilt: cached pane views for ids no longer present are dropped;
    /// their content lifecycle is the coordinator's concern.
    func render(root: PaneNode?) {
        guard let root else {
            for view in subviews { view.removeFromSuperview() }
            paneViewsByID.removeAll()
            renderedStructure = nil
            return
        }
        let signature = Self.structureSignature(of: root)
        if signature == renderedStructure, !subviews.isEmpty {
            reconfigure(node: root)
            return
        }
        for view in subviews { view.removeFromSuperview() }
        let built = build(node: root)
        addSubview(built)
        NSLayoutConstraint.activate([
            built.topAnchor.constraint(equalTo: topAnchor), built.leadingAnchor.constraint(equalTo: leadingAnchor),
            built.trailingAnchor.constraint(equalTo: trailingAnchor), built.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let liveIDs = Set(paneIDs(in: root))
        for staleID in paneViewsByID.keys where !liveIDs.contains(staleID) { paneViewsByID.removeValue(forKey: staleID) }
        renderedStructure = signature
    }

    /// A signature of the tree's shape: leaf pane ids and their order, split ids,
    /// orientations, and nesting. Deliberately excludes:
    /// - `split.weights`: only a user divider drag changes weights, and it reports the
    ///   result back through `onSplitWeightsChanged`; the split view already shows the
    ///   dragged position, so rebuilding to re-apply the weight the user just produced
    ///   is pure churn.
    /// - each pane's `content`: a pane whose id survives keeps its `PaneView`, and
    ///   `onConfigurePane` swaps the hosted content view in place via
    ///   `PaneView.attachContent`, so a content change needs no structural rebuild.
    private static func structureSignature(of node: PaneNode) -> String {
        switch node {
        case .leaf(let pane): return "leaf(\(pane.id))"
        case .split(let split):
            let children = split.children.map(structureSignature).joined(separator: ",")
            return "split(\(split.id),\(split.orientation.rawValue),[\(children)])"
        }
    }

    /// Reconfigures each leaf's cached pane view without touching the hierarchy. Called
    /// only when the structure signature matched, so by construction `paneViewsByID`
    /// holds a view for every pane id in `node` — the cache is written in the rebuild
    /// path and pruned to exactly the live ids.
    private func reconfigure(node: PaneNode) {
        switch node {
        case .leaf(let pane):
            guard let view = paneViewsByID[pane.id] else { return }
            onConfigurePane?(view, pane)
        case .split(let split): for child in split.children { reconfigure(node: child) }
        }
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
