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

    private func tabIDs(in root: NSView) -> [String] {
        var ids: [String] = []
        func walk(_ view: NSView) {
            let id = view.accessibilityIdentifier()
            if id.hasPrefix("panel-tab-"), !id.hasPrefix("panel-tab-close-"), !id.hasPrefix("panel-tab-rename-") {
                ids.append(String(id.dropFirst("panel-tab-".count)))
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return ids
    }

    private func view(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for subview in root.subviews {
            if let match = view(identifier: identifier, in: subview) { return match }
        }
        return nil
    }

    private func beginRename(tabID: String, in bar: PanelTabBarView) {
        let tabView = view(identifier: "panel-tab-\(tabID)", in: bar)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 0)
        let renameItem = event.flatMap { tabView?.menu(for: $0)?.items.first { $0.title == "Rename Tab" } }
        #expect(renameItem != nil)
        if let renameItem, let action = renameItem.action {
            NSApp.sendAction(action, to: renameItem.target, from: renameItem)
        }
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

    @Test func releasingSharedBarHidesTabsAndStopsBackgroundRedraws() {
        let accessory = PanelTabStripAccessoryView()
        let shared = accessory.tabBar
        let panel = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "a"))

        panel.adoptExternalTabBar(shared)
        panel.apply(layout: layout(tabID: "tab-a", sessionID: "sess-a"), titlesByTabID: ["tab-a": "A"])
        #expect(tabIDs(in: shared) == ["tab-a"])
        #expect(!shared.isHidden)

        accessory.releaseTabBar()
        #expect(shared.hostingOwner == nil)
        #expect(shared.isHidden)
        #expect(tabIDs(in: shared).isEmpty)

        panel.apply(layout: layout(tabID: "tab-a2", sessionID: "sess-a2"), titlesByTabID: ["tab-a2": "A2"])
        #expect(shared.isHidden)
        #expect(tabIDs(in: shared).isEmpty)
    }

    @Test func releasingSharedBarDuringRenameClearsDeferredTabViews() {
        let accessory = PanelTabStripAccessoryView()
        let shared = accessory.tabBar
        let panel = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "a"))

        panel.adoptExternalTabBar(shared)
        panel.apply(layout: layout(tabID: "tab-a", sessionID: "sess-a"), titlesByTabID: ["tab-a": "A"])
        beginRename(tabID: "tab-a", in: shared)
        #expect(view(identifier: "panel-tab-rename-input", in: shared) != nil)

        accessory.releaseTabBar()
        #expect(shared.isHidden)
        #expect(tabIDs(in: shared).isEmpty)
        #expect(view(identifier: "panel-tab-rename-input", in: shared) == nil)
    }

    @Test func panelCanMoveTabsIntoContentAndBackToTitlebar() {
        let accessory = PanelTabStripAccessoryView()
        let shared = accessory.tabBar
        let panel = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "a"))

        panel.adoptExternalTabBar(shared)
        panel.apply(layout: layout(tabID: "tab-a", sessionID: "sess-a"), titlesByTabID: ["tab-a": "A"])
        #expect(tabIDs(in: shared) == ["tab-a"])
        #expect(tabIDs(in: panel).isEmpty)

        accessory.releaseTabBar()
        panel.useBuiltInTabBar()
        #expect(tabIDs(in: shared).isEmpty)
        #expect(tabIDs(in: panel) == ["tab-a"])

        panel.apply(layout: layout(tabID: "tab-a2", sessionID: "sess-a2"), titlesByTabID: ["tab-a2": "A2"])
        #expect(tabIDs(in: shared).isEmpty)
        #expect(tabIDs(in: panel) == ["tab-a2"])

        panel.adoptExternalTabBar(shared)
        #expect(tabIDs(in: shared) == ["tab-a2"])
    }

    @Test func titlebarAccessoryUsesLeftTitlebarSlot() {
        let controller = NSTitlebarAccessoryViewController()
        AppKitController.configureWorkspacePanelTabStripAccessory(controller)

        #expect(controller.layoutAttribute == .left)
    }
}
