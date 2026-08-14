import Foundation
import Testing

@testable import spacesui

@Suite struct PanelLayoutEngineTests {
    private func pane(_ id: String) -> Pane { Pane(id: id, content: .terminalSession(deviceID: "device", sessionID: "sess-\(id)")) }

    private func layoutWithTab(_ tabID: String = "tab-1", paneID: String = "a") -> PanelLayout {
        PanelLayoutEngine.appendTab(tabID: tabID, pane: pane(paneID), to: PanelLayout())
    }

    @Test func appendTabSelectsAndFocuses() {
        var layout = layoutWithTab()
        #expect(layout.selectedTabID == "tab-1")
        #expect(layout.focusedPaneID == "a")
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b"), to: layout)
        #expect(layout.tabs.map(\.id) == ["tab-1", "tab-2"])
        #expect(layout.selectedTabID == "tab-2")
        #expect(layout.focusedPaneID == "b")
    }

    /// A pane installed for a programmatically launched process lands behind whatever the user is looking
    /// at: the panel keeps its selected tab and its focused pane, and the new tab waits in the tab bar.
    @Test func appendUnselectedTabKeepsTheCurrentSelectionAndFocus() {
        var layout = layoutWithTab()

        layout = PanelLayoutEngine.appendUnselectedTab(tabID: "tab-2", pane: pane("b"), to: layout)

        #expect(layout.tabs.map(\.id) == ["tab-1", "tab-2"])
        #expect(layout.selectedTabID == "tab-1")
        #expect(layout.focusedPaneID == "a")
    }

    /// A panel with no tabs has no selection to preserve, and a panel that has tabs must show one, so the
    /// first pane installed this way is selected. Nothing is brought forward or focused by the install
    /// itself, so this still moves nothing the user was using.
    @Test func appendUnselectedTabSelectsTheFirstTabOfAnEmptyPanel() {
        let layout = PanelLayoutEngine.appendUnselectedTab(tabID: "tab-1", pane: pane("a"), to: PanelLayout())

        #expect(layout.selectedTabID == "tab-1")
        #expect(layout.focusedPaneID == "a")
    }

    /// A restart's replacement takes over its predecessor's pane: same tab, same position, and the
    /// panel's selection and focus untouched, because those name pane ids rather than sessions.
    @Test func retargetPaneKeepsThePanesPlaceSelectionAndFocus() {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b"), to: layout)
        let before = layout

        layout = PanelLayoutEngine.retargetPane(paneID: "a", to: .terminalSession(deviceID: "device", sessionID: "sess-replacement"), in: layout)

        #expect(layout.tabs.map(\.id) == before.tabs.map(\.id))
        #expect(layout.selectedTabID == before.selectedTabID)
        #expect(layout.focusedPaneID == before.focusedPaneID)
        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: layout) == ["sess-replacement", "sess-b"])
        #expect(PanelLayoutEngine.pane(withID: "a", in: layout)?.id == "a")
    }

    /// Retargeting inside a split leaves the split's shape and weights alone: the replacement appears
    /// where the user put the pane, not as a new tab.
    @Test func retargetPaneInsideASplitLeavesTheSplitIntact() throws {
        let layout = try #require(
            PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layoutWithTab()))

        let retargeted = PanelLayoutEngine.retargetPane(
            paneID: "b", to: .terminalSession(deviceID: "device", sessionID: "sess-replacement"), in: layout)

        guard case .split(let split) = retargeted.tabs[0].root else {
            Issue.record("expected split root")
            return
        }
        #expect(split.weights == [0.5, 0.5])
        #expect(PanelLayoutEngine.panes(in: retargeted.tabs[0]).map(\.id) == ["a", "b"])
        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: retargeted) == ["sess-a", "sess-replacement"])
        #expect(retargeted.focusedPaneID == layout.focusedPaneID)
    }

    /// A pane id the layout does not hold changes nothing, so a replacement whose predecessor's pane is
    /// already gone cannot corrupt the layout on its way to the ordinary install path.
    @Test func retargetPaneIgnoresAnUnknownPane() {
        let layout = layoutWithTab()

        let retargeted = PanelLayoutEngine.retargetPane(paneID: "missing", to: .terminalSession(deviceID: "device", sessionID: "x"), in: layout)

        #expect(retargeted == layout)
    }

    @Test func splitLeafWrapsIntoSplitAndFocusesNewPane() throws {
        let layout = try #require(
            PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layoutWithTab()))
        guard case .split(let split) = layout.tabs[0].root else {
            Issue.record("expected split root")
            return
        }
        #expect(split.orientation == .horizontal)
        #expect(split.weights == [0.5, 0.5])
        #expect(PanelLayoutEngine.panes(in: layout.tabs[0]).map(\.id) == ["a", "b"])
        #expect(layout.focusedPaneID == "b")
    }

    @Test func splitAlongParentOrientationJoinsAsSiblingSharingWeight() throws {
        var layout = try #require(
            PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layoutWithTab()))
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("c"), newSplitID: "s2", in: layout))
        guard case .split(let split) = layout.tabs[0].root else {
            Issue.record("expected split root")
            return
        }
        #expect(split.children.count == 3)
        #expect(split.weights == [0.25, 0.25, 0.5])
        #expect(PanelLayoutEngine.panes(in: layout.tabs[0]).map(\.id) == ["a", "c", "b"])
    }

    @Test func splitAcrossOrientationNestsASplit() throws {
        var layout = try #require(
            PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layoutWithTab()))
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "b", direction: .down, newPane: pane("c"), newSplitID: "s2", in: layout))
        guard case .split(let outer) = layout.tabs[0].root, case .split(let nested) = outer.children[1] else {
            Issue.record("expected nested split")
            return
        }
        #expect(outer.orientation == .horizontal)
        #expect(nested.orientation == .vertical)
        #expect(PanelLayoutEngine.panes(in: layout.tabs[0]).map(\.id) == ["a", "b", "c"])
    }

    @Test func removePaneCollapsesSingleChildSplitAndRefocuses() throws {
        var layout = try #require(
            PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layoutWithTab()))
        layout = PanelLayoutEngine.removePane(paneID: "b", from: layout)
        guard case .leaf(let remaining) = layout.tabs[0].root else {
            Issue.record("expected collapsed leaf root")
            return
        }
        #expect(remaining.id == "a")
        #expect(layout.focusedPaneID == "a")
    }

    @Test func removeMiddlePaneFocusFallsToPreviousInOrder() throws {
        var layout = try #require(
            PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layoutWithTab()))
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "b", direction: .right, newPane: pane("c"), newSplitID: "s2", in: layout))
        layout = PanelLayoutEngine.focusPane(paneID: "b", in: layout)
        layout = PanelLayoutEngine.removePane(paneID: "b", from: layout)
        #expect(PanelLayoutEngine.panes(in: layout.tabs[0]).map(\.id) == ["a", "c"])
        #expect(layout.focusedPaneID == "a")
    }

    @Test func removingLastPaneRemovesTabAndSelectsNeighbor() {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b"), to: layout)
        layout = PanelLayoutEngine.appendTab(tabID: "tab-3", pane: pane("c"), to: layout)
        layout = PanelLayoutEngine.selectTab(tabID: "tab-2", in: layout)
        layout = PanelLayoutEngine.removePane(paneID: "b", from: layout)
        #expect(layout.tabs.map(\.id) == ["tab-1", "tab-3"])
        #expect(layout.selectedTabID == "tab-3")
        #expect(layout.focusedPaneID == "c")
    }

    @Test func prunedLayoutDropsDeadSessionsAndEmptyTabs() throws {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "a", direction: .down, newPane: pane("b"), newSplitID: "s1", in: layout))
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("c"), to: layout)
        let pruned = PanelLayoutEngine.prunedLayout(layout, keepingSessionIDs: ["sess-a"])
        #expect(pruned.tabs.map(\.id) == ["tab-1"])
        guard case .leaf(let remaining) = pruned.tabs[0].root else {
            Issue.record("expected collapsed leaf root")
            return
        }
        #expect(remaining.id == "a")
        #expect(pruned.selectedTabID == "tab-1")
        #expect(pruned.focusedPaneID == "a")
    }

    @Test func orderedSessionIDsWalkTabsDepthFirst() throws {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layout))
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "b", direction: .down, newPane: pane("c"), newSplitID: "s2", in: layout))
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("d"), to: layout)
        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: layout) == ["sess-a", "sess-b", "sess-c", "sess-d"])
    }

    @Test func locationFindsContentAcrossTabs() {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b"), to: layout)
        let location = PanelLayoutEngine.location(of: .terminalSession(deviceID: "device", sessionID: "sess-b"), in: layout)
        #expect(location?.tabID == "tab-2")
        #expect(location?.paneID == "b")
        #expect(PanelLayoutEngine.location(of: .terminalSession(deviceID: "device", sessionID: "missing"), in: layout) == nil)
    }

    @Test func selectTabRestoresItsMostRecentlyFocusedPane() throws {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layout))
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("c"), to: layout)
        layout = PanelLayoutEngine.selectTab(tabID: "tab-1", in: layout)
        #expect(layout.focusedPaneID == "b")
        layout = PanelLayoutEngine.focusPane(paneID: "b", in: layout)
        layout = PanelLayoutEngine.selectTab(tabID: "tab-2", in: layout)
        #expect(layout.focusedPaneID == "c")
        // Reselecting tab-1 restores the pane that last held focus there, not the
        // first pane.
        layout = PanelLayoutEngine.selectTab(tabID: "tab-1", in: layout)
        #expect(layout.focusedPaneID == "b")
        // A remembered pane that has since closed falls back to the first pane.
        layout = PanelLayoutEngine.selectTab(tabID: "tab-2", in: layout)
        layout = PanelLayoutEngine.removePane(paneID: "b", from: layout)
        layout = PanelLayoutEngine.selectTab(tabID: "tab-1", in: layout)
        #expect(layout.focusedPaneID == "a")
    }

    /// The open-in-new-window move: removing the pane from the source layout and
    /// appending it to a fresh one keeps the session in exactly one layout, and a
    /// source that held only that pane empties (which is what closes an emptied
    /// global panel window).
    @Test func movingPaneBetweenLayoutsKeepsSingleInstance() throws {
        var source = layoutWithTab("tab-1", paneID: "a")
        source = try #require(PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: source))
        source = PanelLayoutEngine.removePane(paneID: "b", from: source)
        let destination = PanelLayoutEngine.appendTab(tabID: "tab-new", pane: pane("b"), to: PanelLayout())
        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: source) == ["sess-a"])
        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: destination) == ["sess-b"])

        let emptiedSource = PanelLayoutEngine.removePane(paneID: "a", from: source)
        #expect(emptiedSource.isEmpty)
    }

    @Test func renameTabSetsCustomTitleAndEmptyClearsIt() {
        var layout = layoutWithTab()
        layout = PanelLayoutEngine.renameTab(tabID: "tab-1", title: "  build watch  ", in: layout)
        #expect(layout.tabs[0].title == "build watch")
        layout = PanelLayoutEngine.renameTab(tabID: "tab-1", title: "   ", in: layout)
        #expect(layout.tabs[0].title == nil)
        #expect(PanelLayoutEngine.renameTab(tabID: "missing", title: "x", in: layout) == layout)
    }

    @Test func movingTabToAnInsertionIndexPreservesSelectionAndFocus() {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b"), to: layout)
        layout = PanelLayoutEngine.appendTab(tabID: "tab-3", pane: pane("c"), to: layout)
        layout = PanelLayoutEngine.selectTab(tabID: "tab-2", in: layout)

        layout = PanelLayoutEngine.moveTab(tabID: "tab-1", toInsertionIndex: 3, in: layout)

        #expect(layout.tabs.map(\.id) == ["tab-2", "tab-3", "tab-1"])
        #expect(layout.selectedTabID == "tab-2")
        #expect(layout.focusedPaneID == "b")
    }

    @Test func movingTabBackwardUsesThePreMoveInsertionIndex() {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b"), to: layout)
        layout = PanelLayoutEngine.appendTab(tabID: "tab-3", pane: pane("c"), to: layout)

        layout = PanelLayoutEngine.moveTab(tabID: "tab-3", toInsertionIndex: 1, in: layout)

        #expect(layout.tabs.map(\.id) == ["tab-1", "tab-3", "tab-2"])
    }

    @Test func movingTabIgnoresUnknownTabsAndClampsInsertionIndex() {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b"), to: layout)
        let before = layout

        #expect(PanelLayoutEngine.moveTab(tabID: "missing", toInsertionIndex: 0, in: layout) == before)
        layout = PanelLayoutEngine.moveTab(tabID: "tab-2", toInsertionIndex: -10, in: layout)
        #expect(layout.tabs.map(\.id) == ["tab-2", "tab-1"])
    }

    /// A tab is named after the pane the user is looking at, so splitting and then moving focus
    /// re-titles the tab (and with it the panel window) instead of leaving it on the pane that
    /// happens to sit first in the tree.
    @Test func selectedPaneFollowsFocusWithinTheTab() throws {
        var layout = layoutWithTab()
        var tab = try #require(layout.tabs.first)
        #expect(PanelLayoutEngine.selectedPane(in: tab)?.id == "a")

        layout = try #require(PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layout))
        tab = try #require(layout.tabs.first)
        #expect(PanelLayoutEngine.selectedPane(in: tab)?.id == "b")

        layout = PanelLayoutEngine.focusPane(paneID: "a", in: layout)
        tab = try #require(layout.tabs.first)
        #expect(PanelLayoutEngine.selectedPane(in: tab)?.id == "a")
    }

    /// A restored tab that has not been focused since launch still has a name to show.
    @Test func selectedPaneFallsBackToTheFirstPaneWithoutFocusMemory() {
        let tab = PanelTab(id: "tab-1", title: nil, lastFocusedPaneID: nil, root: .leaf(pane("a")))
        #expect(PanelLayoutEngine.selectedPane(in: tab)?.id == "a")
    }

    @Test func layoutRoundTripsThroughJSON() throws {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layout))
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "b", direction: .down, newPane: pane("c"), newSplitID: "s2", in: layout))
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(PanelLayout.self, from: data)
        #expect(decoded == layout)
        #expect(decoded.version == PanelLayout.currentVersion)
    }
}
