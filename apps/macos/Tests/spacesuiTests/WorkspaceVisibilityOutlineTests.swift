import AppKit
import Testing
import workspacecore

@testable import spacesui

/// The Workspaces dialog outline's expand/collapse contract. The dialog is a recovery surface, so no
/// row — device header or project — may ever collapse and put a hidden row behind a closed triangle.
@Suite struct WorkspaceVisibilityOutlineTests {
    @MainActor @Test func noRowMayCollapse() {
        let controller = WorkspaceVisibilityOutlineController()
        controller.devices = WorkspaceVisibilityTree.build(
            devices: [WorkspaceVisibilityTree.Device(deviceID: "device-mac", name: "Local")],
            projects: [
                ProjectSummary(
                    id: "p1", name: "harbor", dir: "/repos/harbor", isGitRepo: true, defaultBranch: "main", isHidden: false, deviceID: "device-mac")
            ],
            workspacesByProject: [
                "p1": [WorkspaceSummary(id: "w1", branch: "main", dir: "/repos/main", isRunning: false, isHidden: false, isDefault: true)]
            ], query: "")

        let outlineView = NSOutlineView()
        let deviceItem = controller.outlineView(outlineView, child: 0, ofItem: nil)
        let projectItem = controller.outlineView(outlineView, child: 0, ofItem: deviceItem)

        #expect(controller.outlineView(outlineView, shouldCollapseItem: deviceItem) == false)
        #expect(controller.outlineView(outlineView, shouldCollapseItem: projectItem) == false)
    }
}
