import AppKit
import Testing
import spacesdevicecore

@testable import spacesui

/// The Workspaces dialog outline's expand/collapse contract. The dialog is a recovery surface, so no
/// row — device header or project — may ever collapse and put a hidden row behind a closed triangle.
@Suite struct WorkspaceVisibilityOutlineTests {
    @MainActor @Test func noRowMayCollapse() {
        let controller = WorkspaceVisibilityOutlineController()
        controller.devices = WorkspaceVisibilityTree.build(
            devices: [WorkspaceVisibilityTree.Device(deviceID: "device-mac", name: "Local")],
            projectsByDevice: ["device-mac": [WorkspaceVisibilityTree.Project(id: "p1", name: "harbor", isGitRepo: true, isHidden: false)]],
            workspacesByProject: ["p1": [WorkspaceVisibilityTree.Workspace(id: "w1", name: "main", isDefault: true, isHidden: false)]], query: "")

        let outlineView = NSOutlineView()
        let deviceItem = controller.outlineView(outlineView, child: 0, ofItem: nil)
        let projectItem = controller.outlineView(outlineView, child: 0, ofItem: deviceItem)

        #expect(controller.outlineView(outlineView, shouldCollapseItem: deviceItem) == false)
        #expect(controller.outlineView(outlineView, shouldCollapseItem: projectItem) == false)
    }
}
