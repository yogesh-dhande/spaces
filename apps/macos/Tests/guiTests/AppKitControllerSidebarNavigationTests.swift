import Testing

@testable import gui

@Suite struct AppKitControllerSidebarNavigationTests {
    @Test func downArrowFromDashboardSelectsFirstVisibleWorkspace() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"]), ("project-b", ["workspace-c"])],
            selectedProjectID: nil,
            selectedWorkspaceID: nil,
            showingDashboard: true,
            direction: 1)

        #expect(target == .workspace("workspace-a"))
    }

    @Test func upArrowFromFirstWorkspaceReturnsToDashboard() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"]), ("project-b", ["workspace-c"])],
            selectedProjectID: "project-a",
            selectedWorkspaceID: "workspace-a",
            showingDashboard: false,
            direction: -1)

        #expect(target == .dashboard)
    }

    @Test func arrowNavigationMovesAcrossProjectBoundariesUsingFlatVisibleOrder() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-1", ["project-1-a", "project-1-b"]), ("project-2", ["project-2-a"])],
            selectedProjectID: "project-1",
            selectedWorkspaceID: "project-1-b",
            showingDashboard: false,
            direction: 1)

        #expect(target == .workspace("project-2-a"))
    }

    @Test func downArrowFromLastWorkspaceStopsAtEndOfList() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"])],
            selectedProjectID: "project-a",
            selectedWorkspaceID: "workspace-b",
            showingDashboard: false,
            direction: 1)

        #expect(target == nil)
    }

    @Test func collapsedProjectSelectionSkipsToNextVisibleWorkspace() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", []), ("project-b", ["workspace-b1"]), ("project-c", ["workspace-c1"])],
            selectedProjectID: "project-a",
            selectedWorkspaceID: "workspace-a1",
            showingDashboard: false,
            direction: 1)

        #expect(target == .workspace("workspace-b1"))
    }
}
