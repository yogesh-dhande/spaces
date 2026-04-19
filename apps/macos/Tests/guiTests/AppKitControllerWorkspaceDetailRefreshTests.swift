import Testing

@testable import gui

@Suite struct AppKitControllerWorkspaceDetailRefreshTests {
    @Test func terminalFallbackRowTextUsesTerminalNameAndShellDetail() {
        let row = AppKitController.terminalFallbackRowText(title: "* zsh", app: "iTerm2")
        #expect(row.label == "Terminal")
        #expect(row.detail == "zsh")
    }

    @Test func terminalFallbackRowTextOmitsDetailWhenTitleMissing() {
        let row = AppKitController.terminalFallbackRowText(title: nil, app: "iTerm2")
        #expect(row.label == "Terminal")
        #expect(row.detail == nil)
    }

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
