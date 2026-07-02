import Foundation

/// Which edge a pane split adds the new pane on.
enum PaneSplitDirection: Sendable {
    case right
    case down

    var orientation: PaneSplitOrientation {
        switch self {
        case .right: return .horizontal
        case .down: return .vertical
        }
    }
}

/// Pure mutations over `PanelLayout`, in the style of `WorkspaceWindowCycle`: every
/// operation takes a layout and returns a new one, so the whole tab/pane lifecycle is
/// unit-testable without AppKit. Callers supply new IDs (the engine never generates
/// randomness). Every mutation returns a normalized layout — `selectedTabID` and
/// `focusedPaneID` always reference live nodes or are nil.
enum PanelLayoutEngine {
    // MARK: - Queries

    /// Depth-first panes of one tab, in visual order (left-to-right, top-to-bottom).
    static func panes(in tab: PanelTab) -> [Pane] { panes(in: tab.root) }

    private static func panes(in node: PaneNode) -> [Pane] {
        switch node {
        case .leaf(let pane): return [pane]
        case .split(let split): return split.children.flatMap { panes(in: $0) }
        }
    }

    /// All panes across all tabs, tab order then depth-first — the panel's canonical
    /// target order for cycling.
    static func allPanes(in layout: PanelLayout) -> [Pane] { layout.tabs.flatMap { panes(in: $0) } }

    static func orderedTerminalSessionIDs(in layout: PanelLayout) -> [String] {
        allPanes(in: layout).compactMap { $0.content.terminalSessionID }
    }

    static func pane(withID paneID: String, in layout: PanelLayout) -> Pane? {
        allPanes(in: layout).first { $0.id == paneID }
    }

    /// The tab and pane holding a given content descriptor, if any.
    static func location(of content: PaneContentDescriptor, in layout: PanelLayout) -> (tabID: String, paneID: String)? {
        for tab in layout.tabs {
            if let pane = panes(in: tab).first(where: { $0.content == content }) { return (tab.id, pane.id) }
        }
        return nil
    }

    static func location(ofPaneID paneID: String, in layout: PanelLayout) -> (tabID: String, paneID: String)? {
        for tab in layout.tabs {
            if panes(in: tab).contains(where: { $0.id == paneID }) { return (tab.id, paneID) }
        }
        return nil
    }

    // MARK: - Mutations

    /// Appends a tab holding a single pane, selecting and focusing it.
    static func appendTab(tabID: String, pane: Pane, to layout: PanelLayout) -> PanelLayout {
        var layout = layout
        layout.tabs.append(PanelTab(id: tabID, title: nil, root: .leaf(pane)))
        layout.selectedTabID = tabID
        layout.focusedPaneID = pane.id
        return normalized(layout)
    }

    /// Sets a tab's user-chosen name; nil (or an empty trim) returns the tab to its
    /// derived title.
    static func renameTab(tabID: String, title: String?, in layout: PanelLayout) -> PanelLayout {
        var layout = layout
        guard let index = layout.tabs.firstIndex(where: { $0.id == tabID }) else { return layout }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        layout.tabs[index].title = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return layout
    }

    /// Splits `paneID` in the given direction, placing `newPane` after it. When the
    /// pane's parent split already has the target orientation the new pane joins as a
    /// sibling (sharing the split pane's weight); otherwise the leaf is wrapped in a new
    /// split (`newSplitID`) with equal weights. The new pane becomes focused.
    static func splitPane(paneID: String, direction: PaneSplitDirection, newPane: Pane, newSplitID: String, in layout: PanelLayout) -> PanelLayout? {
        guard let tabIndex = layout.tabs.firstIndex(where: { panes(in: $0).contains { $0.id == paneID } }) else { return nil }
        var layout = layout
        guard let root = inserting(newPane: newPane, near: paneID, direction: direction, newSplitID: newSplitID, in: layout.tabs[tabIndex].root)
        else { return nil }
        layout.tabs[tabIndex].root = root
        layout.selectedTabID = layout.tabs[tabIndex].id
        layout.focusedPaneID = newPane.id
        return normalized(layout)
    }

    private static func inserting(
        newPane: Pane, near paneID: String, direction: PaneSplitDirection, newSplitID: String, in node: PaneNode
    ) -> PaneNode? {
        switch node {
        case .leaf(let pane):
            guard pane.id == paneID else { return nil }
            return .split(
                PaneSplit(id: newSplitID, orientation: direction.orientation, weights: [0.5, 0.5], children: [.leaf(pane), .leaf(newPane)]))
        case .split(var split):
            for (index, child) in split.children.enumerated() {
                // A direct leaf child splitting along the parent's orientation joins the
                // parent as a sibling instead of nesting a redundant single-axis split.
                if case .leaf(let pane) = child, pane.id == paneID, split.orientation == direction.orientation {
                    let sharedWeight = split.weights.indices.contains(index) ? split.weights[index] / 2 : 0.5
                    if split.weights.indices.contains(index) { split.weights[index] = sharedWeight }
                    split.children.insert(.leaf(newPane), at: index + 1)
                    split.weights.insert(sharedWeight, at: min(index + 1, split.weights.count))
                    return .split(split)
                }
                if let replaced = inserting(newPane: newPane, near: paneID, direction: direction, newSplitID: newSplitID, in: child) {
                    split.children[index] = replaced
                    return .split(split)
                }
            }
            return nil
        }
    }

    /// Removes a pane. Splits collapse when they drop to one child; a tab whose last
    /// pane closes is removed. Focus moves to the neighboring pane in the same tab
    /// (previous in depth-first order, else next), and selection falls back to the
    /// adjacent tab when the tab itself closed.
    static func removePane(paneID: String, from layout: PanelLayout) -> PanelLayout {
        guard let tabIndex = layout.tabs.firstIndex(where: { panes(in: $0).contains { $0.id == paneID } }) else { return layout }
        var layout = layout
        let tab = layout.tabs[tabIndex]
        let orderedBefore = panes(in: tab)
        let removedOrderIndex = orderedBefore.firstIndex { $0.id == paneID } ?? 0

        if let newRoot = removing(paneID: paneID, from: tab.root) {
            layout.tabs[tabIndex].root = newRoot
            if layout.focusedPaneID == paneID {
                let remaining = panes(in: layout.tabs[tabIndex])
                let fallbackIndex = max(0, min(removedOrderIndex - 1, remaining.count - 1))
                layout.focusedPaneID = remaining.indices.contains(fallbackIndex) ? remaining[fallbackIndex].id : remaining.first?.id
                layout.selectedTabID = tab.id
            }
        } else {
            layout.tabs.remove(at: tabIndex)
            if layout.selectedTabID == tab.id {
                let fallbackIndex = max(0, min(tabIndex, layout.tabs.count - 1))
                layout.selectedTabID = layout.tabs.indices.contains(fallbackIndex) ? layout.tabs[fallbackIndex].id : nil
                layout.focusedPaneID = layout.selectedTabID.flatMap { id in layout.tabs.first { $0.id == id } }.map { panes(in: $0) }?.first?.id
            }
        }
        return normalized(layout)
    }

    /// Returns the node with the pane removed, nil when the node becomes empty.
    private static func removing(paneID: String, from node: PaneNode) -> PaneNode? {
        switch node {
        case .leaf(let pane):
            return pane.id == paneID ? nil : node
        case .split(var split):
            for (index, child) in split.children.enumerated() {
                guard panes(in: child).contains(where: { $0.id == paneID }) else { continue }
                if let replaced = removing(paneID: paneID, from: child) {
                    split.children[index] = replaced
                } else {
                    split.children.remove(at: index)
                    if split.weights.indices.contains(index) { split.weights.remove(at: index) }
                }
                if split.children.isEmpty { return nil }
                if split.children.count == 1 { return split.children[0] }
                return .split(split)
            }
            return node
        }
    }

    static func selectTab(tabID: String, in layout: PanelLayout) -> PanelLayout {
        guard let tab = layout.tabs.first(where: { $0.id == tabID }) else { return layout }
        var layout = layout
        layout.selectedTabID = tabID
        // Keep the focused pane when it lives in this tab; otherwise focus its first pane.
        if !(layout.focusedPaneID.map { id in panes(in: tab).contains { $0.id == id } } ?? false) {
            layout.focusedPaneID = panes(in: tab).first?.id
        }
        return layout
    }

    static func focusPane(paneID: String, in layout: PanelLayout) -> PanelLayout {
        guard let location = location(ofPaneID: paneID, in: layout) else { return layout }
        var layout = layout
        layout.selectedTabID = location.tabID
        layout.focusedPaneID = paneID
        return layout
    }

    /// Drops panes whose terminal session no longer exists (used at launch against the
    /// overview's session catalog). Non-terminal content is untouched. Splits collapse
    /// and empty tabs disappear exactly as explicit closes do.
    static func prunedLayout(_ layout: PanelLayout, keepingSessionIDs: Set<String>) -> PanelLayout {
        var layout = layout
        let deadPaneIDs = allPanes(in: layout).filter { pane in
            guard let sessionID = pane.content.terminalSessionID else { return false }
            return !keepingSessionIDs.contains(sessionID)
        }.map(\.id)
        for paneID in deadPaneIDs { layout = removePane(paneID: paneID, from: layout) }
        return layout
    }

    /// Repairs selection references so they always point at live nodes.
    static func normalized(_ layout: PanelLayout) -> PanelLayout {
        var layout = layout
        if layout.selectedTabID == nil || !layout.tabs.contains(where: { $0.id == layout.selectedTabID }) {
            layout.selectedTabID = layout.tabs.first?.id
        }
        let selectedTab = layout.tabs.first { $0.id == layout.selectedTabID }
        let selectedPanes = selectedTab.map { panes(in: $0) } ?? []
        if layout.focusedPaneID == nil || !selectedPanes.contains(where: { $0.id == layout.focusedPaneID }) {
            layout.focusedPaneID = selectedPanes.first?.id
        }
        return layout
    }
}
