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

    @Test func selectTabKeepsFocusedPaneOnlyWhenItLivesThere() throws {
        var layout = layoutWithTab("tab-1", paneID: "a")
        layout = try #require(PanelLayoutEngine.splitPane(paneID: "a", direction: .right, newPane: pane("b"), newSplitID: "s1", in: layout))
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("c"), to: layout)
        layout = PanelLayoutEngine.selectTab(tabID: "tab-1", in: layout)
        #expect(layout.focusedPaneID == "a")
        layout = PanelLayoutEngine.focusPane(paneID: "b", in: layout)
        layout = PanelLayoutEngine.selectTab(tabID: "tab-2", in: layout)
        #expect(layout.focusedPaneID == "c")
        layout = PanelLayoutEngine.selectTab(tabID: "tab-1", in: layout)
        #expect(layout.focusedPaneID == "a")
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
