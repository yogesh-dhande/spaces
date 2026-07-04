import AppKit
import Testing

@testable import spacesui

/// The main window hosts one shared tab strip (the titlebar accessory) that the
/// visible workspace panel adopts; ownership must move with adoption so a background
/// panel's renders never overwrite the visible panel's tabs.
@MainActor @Suite struct WorkspacePanelExternalTabBarTests {
    private func layout(tabID: String, sessionID: String) -> PanelLayout {
        PanelLayoutEngine.appendTab(
            tabID: tabID, pane: Pane(id: "pane-\(tabID)", content: .terminalSession(deviceID: "device", sessionID: sessionID)),
            to: PanelLayout())
    }

    private func tabIDs(in bar: PanelTabBarView) -> [String] {
        var ids: [String] = []
        func walk(_ view: NSView) {
            let id = view.accessibilityIdentifier()
            if id.hasPrefix("panel-tab-"), !id.hasPrefix("panel-tab-close-"), !id.hasPrefix("panel-tab-rename-") {
                ids.append(String(id.dropFirst("panel-tab-".count)))
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(bar)
        return ids
    }

    @Test func adoptingPanelDrivesSharedBarAndBackgroundPanelsDoNot() {
        let shared = PanelTabBarView()
        let panelA = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "a"))
        let panelB = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "b"))

        panelA.adoptExternalTabBar(shared)
        panelA.apply(layout: layout(tabID: "tab-a", sessionID: "sess-a"), titlesByTabID: ["tab-a": "A"])
        #expect(tabIDs(in: shared) == ["tab-a"])

        // Panel B takes over (workspace switch); panel A's later renders must not
        // touch the shared strip anymore.
        panelB.adoptExternalTabBar(shared)
        panelB.apply(layout: layout(tabID: "tab-b", sessionID: "sess-b"), titlesByTabID: ["tab-b": "B"])
        #expect(tabIDs(in: shared) == ["tab-b"])

        panelA.apply(layout: layout(tabID: "tab-a2", sessionID: "sess-a2"), titlesByTabID: ["tab-a2": "A2"])
        #expect(tabIDs(in: shared) == ["tab-b"])
    }
}
