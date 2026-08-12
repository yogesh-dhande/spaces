import Testing

@testable import spacesui

@Suite struct AppKitControllerSidebarNavigationTests {
    @Test func downArrowFromAlertsSelectsAutomations() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"]), ("project-b", ["workspace-c"])], hiddenWorkspaceIDs: [],
            selectedProjectID: nil, selectedWorkspaceID: nil, showingAlerts: true, showingAutomations: false, direction: 1)

        #expect(target == .automations)
    }

    @Test func downArrowFromAlertsSelectsAutomationsWhenNoWorkspaces() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [], hiddenWorkspaceIDs: [], selectedProjectID: nil, selectedWorkspaceID: nil, showingAlerts: true,
            showingAutomations: false, direction: 1)

        #expect(target == .automations)
    }

    @Test func upArrowFromAlertsStops() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a"])], hiddenWorkspaceIDs: [], selectedProjectID: nil, selectedWorkspaceID: nil,
            showingAlerts: true, showingAutomations: false, direction: -1)

        #expect(target == nil)
    }

    @Test func upArrowFromAutomationsSelectsAlerts() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a"])], hiddenWorkspaceIDs: [], selectedProjectID: nil, selectedWorkspaceID: nil,
            showingAlerts: false, showingAutomations: true, direction: -1)

        #expect(target == .alerts)
    }

    @Test func downArrowFromAutomationsSelectsFirstVisibleWorkspace() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"]), ("project-b", ["workspace-c"])], hiddenWorkspaceIDs: [],
            selectedProjectID: nil, selectedWorkspaceID: nil, showingAlerts: false, showingAutomations: true, direction: 1)

        #expect(target == .workspace("workspace-a"))
    }

    @Test func downArrowFromAutomationsStopsWhenNoWorkspaces() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [], hiddenWorkspaceIDs: [], selectedProjectID: nil, selectedWorkspaceID: nil, showingAlerts: false,
            showingAutomations: true, direction: 1)

        #expect(target == nil)
    }

    @Test func upArrowFromFirstWorkspaceReturnsToAutomations() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"]), ("project-b", ["workspace-c"])], hiddenWorkspaceIDs: [],
            selectedProjectID: "project-a", selectedWorkspaceID: "workspace-a", showingAlerts: false, showingAutomations: false, direction: -1)

        #expect(target == .automations)
    }

    @Test func upArrowFromFirstWorkspaceReturnsToAutomationsViaProjectFallback() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", []), ("project-b", [])], hiddenWorkspaceIDs: [], selectedProjectID: "project-a",
            selectedWorkspaceID: nil, showingAlerts: false, showingAutomations: false, direction: -1)

        #expect(target == .automations)
    }

    @Test func arrowNavigationMovesAcrossProjectBoundariesUsingFlatVisibleOrder() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-1", ["project-1-a", "project-1-b"]), ("project-2", ["project-2-a"])], hiddenWorkspaceIDs: [],
            selectedProjectID: "project-1", selectedWorkspaceID: "project-1-b", showingAlerts: false, showingAutomations: false, direction: 1)

        #expect(target == .workspace("project-2-a"))
    }

    @Test func downArrowFromLastWorkspaceStopsAtEndOfList() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", ["workspace-a", "workspace-b"])], hiddenWorkspaceIDs: [], selectedProjectID: "project-a",
            selectedWorkspaceID: "workspace-b", showingAlerts: false, showingAutomations: false, direction: 1)

        #expect(target == nil)
    }

    @Test func keyboardNavigationExpandsAutomationsAsATransientPreview() {
        let state = AppKitController.sidebarAutomationExpansionAfterSelection(
            isExpanded: false, wasExpandedByKeyboard: false, selectingAutomations: true, canExpand: true)

        #expect(state.isExpanded)
        #expect(state.wasExpandedByKeyboard)
    }

    @Test func keyboardNavigationAwayCollapsesOnlyItsTransientAutomationPreview() {
        let transient = AppKitController.sidebarAutomationExpansionAfterSelection(
            isExpanded: true, wasExpandedByKeyboard: true, selectingAutomations: false, canExpand: true)
        let pinned = AppKitController.sidebarAutomationExpansionAfterSelection(
            isExpanded: true, wasExpandedByKeyboard: false, selectingAutomations: false, canExpand: true)

        #expect(!transient.isExpanded)
        #expect(!transient.wasExpandedByKeyboard)
        #expect(pinned.isExpanded)
        #expect(!pinned.wasExpandedByKeyboard)
    }

    @Test func keyboardNavigationDoesNotExpandAutomationsWithoutRunningChildren() {
        let state = AppKitController.sidebarAutomationExpansionAfterSelection(
            isExpanded: false, wasExpandedByKeyboard: false, selectingAutomations: true, canExpand: false)

        #expect(!state.isExpanded)
        #expect(!state.wasExpandedByKeyboard)
    }

    @Test func collapsedProjectSelectionSkipsToNextVisibleWorkspace() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", []), ("project-b", ["workspace-b1"]), ("project-c", ["workspace-c1"])],
            hiddenWorkspaceIDs: [], selectedProjectID: "project-a", selectedWorkspaceID: "workspace-a1", showingAlerts: false,
            showingAutomations: false, direction: 1)

        #expect(target == .workspace("workspace-b1"))
    }

    @Test func projectSelectionFallsThroughToFirstHiddenWorkspaceWhenVisibleProjectsEnd() {
        let target = AppKitController.sidebarArrowSelectionTarget(
            visibleWorkspaceIDsByProject: [("project-a", []), ("project-b", [])], hiddenWorkspaceIDs: ["hidden-1", "hidden-2"],
            selectedProjectID: "project-b", selectedWorkspaceID: nil, showingAlerts: false, showingAutomations: false, direction: 1)

        #expect(target == .workspace("hidden-1"))
    }
}
