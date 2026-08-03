import Testing
import workspacecore

@testable import spacesui

/// Deleting a workspace runs for seconds on the owning daemon (it stops the workspace, then removes the
/// git worktree), and every overview that lands in that window still reports the workspace. These cover
/// the contract that makes that window readable: the row stays listed and renders marked as deleting —
/// dimmed, spinning, children hidden, inert — and it leaves the sidebar exactly once, when the
/// post-delete overview stops carrying it.
@Suite struct AppKitControllerPendingWorkspaceDeletionTests {
    @Test func aWorkspacePendingDeletionKeepsItsRowAndRendersMarked() {
        // The daemon still reports the workspace mid-delete, so a refresh landing during the mutation
        // rebuilds from a section that contains it — and it keeps its row rather than disappearing and
        // coming back on the next refresh. The row carries the delete instead: dimmed, with a progress
        // indicator, its runtime targets hidden whatever the user had expanded, and refusing selection,
        // its context menu, and expansion.
        let merged = AppKitController.mergedSidebarData(sections: [deviceSection()])
        #expect(merged.workspacesByProject["proj"]?.map(\.id) == ["ws-deleting", "ws-keep"])
        #expect(merged.workspaceRuntimeStatusByID["ws-deleting"] != nil)
        #expect(merged.alertsGroups.map(\.workspaceID) == ["ws-deleting", "ws-keep"])

        let marked = AppKitController.sidebarWorkspaceRowState(isPendingDeletion: true)
        #expect(marked.alpha == AppKitController.unreachableDeviceAlpha)
        #expect(marked.showsDeletingProgress)
        #expect(!marked.listsRuntimeTargetChildren)
        #expect(!marked.isInteractive)
    }

    @Test func aWorkspaceThatIsNotBeingDeletedRendersNormally() {
        // Every other row is untouched by the marking: full opacity, no spinner, its runtime targets
        // listed as children, and fully interactive.
        let normal = AppKitController.sidebarWorkspaceRowState(isPendingDeletion: false)
        #expect(normal.alpha == 1)
        #expect(!normal.showsDeletingProgress)
        #expect(normal.listsRuntimeTargetChildren)
        #expect(normal.isInteractive)
    }

    @Test func aFailedDeleteRestoresTheNormalRow() {
        // Walk the marking the way the delete does: marked on confirm, cleared when the mutation comes
        // back. A failure leaves the workspace exactly where it was in the sidebar data, and its row
        // returns to the normal treatment — children listed again, since the marking never touched the
        // user's expansion state.
        var pendingDeletion: Set<String> = ["ws-deleting"]
        #expect(!AppKitController.sidebarWorkspaceRowState(isPendingDeletion: pendingDeletion.contains("ws-deleting")).isInteractive)

        pendingDeletion.remove("ws-deleting")
        let restored = AppKitController.sidebarWorkspaceRowState(isPendingDeletion: pendingDeletion.contains("ws-deleting"))
        #expect(restored == AppKitController.sidebarWorkspaceRowState(isPendingDeletion: false))

        let merged = AppKitController.mergedSidebarData(sections: [deviceSection()])
        #expect(merged.workspacesByProject["proj"]?.map(\.id) == ["ws-deleting", "ws-keep"])
        #expect(merged.workspaceRuntimeStatusByID["ws-deleting"] != nil)
    }

    @Test func aCompletedDeleteDropsTheRowOnce() {
        // The post-delete overview no longer carries the workspace, so once the marking is cleared the
        // row is simply gone — it does not come back, and nothing else under the project moves.
        var section = deviceSection()
        section.workspacesByProject["proj"]?.removeAll { $0.id == "ws-deleting" }
        section.workspaceRuntimeStatusByID["ws-deleting"] = nil
        section.alertsGroups.removeAll { $0.workspaceID == "ws-deleting" }

        let merged = AppKitController.mergedSidebarData(sections: [section])

        #expect(merged.workspacesByProject["proj"]?.map(\.id) == ["ws-keep"])
        #expect(merged.workspaceRuntimeStatusByID["ws-deleting"] == nil)
        #expect(merged.alertsGroups.map(\.workspaceID) == ["ws-keep"])
        #expect(merged.projects.map(\.id) == ["proj"])
    }

    /// One project with the workspace being deleted and a sibling that must survive, plus the runtime
    /// state and alerts group each of them owns.
    private func deviceSection() -> AppKitController.DeviceSection {
        AppKitController.DeviceSection(
            deviceID: "local", deviceName: "local", isLocal: true, loadState: .loaded, device: nil,
            projects: [ProjectSummary(id: "proj", name: "Project", dir: "/project", isGitRepo: true, defaultBranch: "main", deviceID: "local")],
            workspacesByProject: [
                "proj": [
                    WorkspaceSummary(
                        id: "ws-deleting", branch: "doomed", dir: "/project-doomed", isRunning: true, isDefault: false, deviceID: "local"),
                    WorkspaceSummary(id: "ws-keep", branch: "keep", dir: "/project-keep", isRunning: true, isDefault: false, deviceID: "local"),
                ]
            ],
            workspaceRuntimeStatusByID: ["ws-deleting": runtimeStatus(workspaceID: "ws-deleting"), "ws-keep": runtimeStatus(workspaceID: "ws-keep")],
            alertsGroups: [
                AppKitController.AlertsGroup(
                    projectName: "Project", workspaceID: "ws-deleting", workspaceName: "doomed", workspaceBranch: "doomed", items: []),
                AppKitController.AlertsGroup(
                    projectName: "Project", workspaceID: "ws-keep", workspaceName: "keep", workspaceBranch: "keep", items: []),
            ])
    }

    private func runtimeStatus(workspaceID: String) -> WorkspaceRuntimeStatus {
        WorkspaceRuntimeStatus(
            workspaceID: workspaceID, lifecycleState: .running, runtimeHealth: .healthy, hasTrackedRuntimeIndicators: false, runningProcessCount: 1,
            exitedProcessCount: 0, waitingAgentWindowCount: 0, missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
    }
}
