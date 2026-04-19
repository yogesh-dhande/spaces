import Testing

@testable import gui

@Suite struct AppKitControllerWorkspaceDetailRefreshTests {
    @Test func visibleWorkspaceDetailRefreshRequiresSelectedExistingWorkspace() {
        #expect(
            AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1",
                showingDashboard: false,
                showingSettings: false,
                workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: nil,
                showingDashboard: false,
                showingSettings: false,
                workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1",
                showingDashboard: false,
                showingSettings: false,
                workspaceExists: false))
    }

    @Test func visibleWorkspaceDetailRefreshSkipsDashboardAndSettings() {
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1",
                showingDashboard: true,
                showingSettings: false,
                workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1",
                showingDashboard: false,
                showingSettings: true,
                workspaceExists: true))
    }
}
