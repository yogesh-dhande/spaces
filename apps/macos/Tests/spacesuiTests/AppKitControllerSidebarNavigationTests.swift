import Testing

@testable import spacesui

@Suite struct AppKitControllerSidebarNavigationTests {
    @Test func downArrowFromAlertsSelectsFirstVisibleWorkspace() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"]), ("project-b", ["workspace-c"])], hiddenWorkspaceIDs: [],
            selectedProjectID: nil, selectedWorkspaceID: nil, showingAlerts: true, direction: 1)

        #expect(target == .workspace("workspace-a"))
    }

    @Test func upArrowFromFirstWorkspaceReturnsToAlerts() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"]), ("project-b", ["workspace-c"])], hiddenWorkspaceIDs: [],
            selectedProjectID: "project-a", selectedWorkspaceID: "workspace-a", showingAlerts: false, direction: -1)

        #expect(target == .alerts)
    }

    @Test func arrowNavigationMovesAcrossProjectBoundariesUsingFlatVisibleOrder() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-1", ["project-1-a", "project-1-b"]), ("project-2", ["project-2-a"])], hiddenWorkspaceIDs: [],
            selectedProjectID: "project-1", selectedWorkspaceID: "project-1-b", showingAlerts: false, direction: 1)

        #expect(target == .workspace("project-2-a"))
    }

    @Test func downArrowFromLastWorkspaceStopsAtEndOfList() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"])], hiddenWorkspaceIDs: [], selectedProjectID: "project-a",
            selectedWorkspaceID: "workspace-b", showingAlerts: false, direction: 1)

        #expect(target == nil)
    }

    @Test func collapsedProjectSelectionSkipsToNextVisibleWorkspace() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", []), ("project-b", ["workspace-b1"]), ("project-c", ["workspace-c1"])],
            hiddenWorkspaceIDs: [], selectedProjectID: "project-a", selectedWorkspaceID: "workspace-a1", showingAlerts: false, direction: 1)

        #expect(target == .workspace("workspace-b1"))
    }

    @Test func projectSelectionFallsThroughToFirstHiddenWorkspaceWhenVisibleProjectsEnd() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", []), ("project-b", [])], hiddenWorkspaceIDs: ["hidden-1", "hidden-2"],
            selectedProjectID: "project-b", selectedWorkspaceID: nil, showingAlerts: false, direction: 1)

        #expect(target == .workspace("hidden-1"))
    }
}
