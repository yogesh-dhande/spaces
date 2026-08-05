import Testing
import spacesdevicecore

@testable import spacesui

@Suite struct AppKitControllerActivationSelectionTests {
    @Test func activationPrefersFocusedWorkspace() {
        #expect(AppKitController.activationSelectionTarget(focusedWorkspaceID: "workspace-focused") == .workspace("workspace-focused"))
    }

    @Test func activationKeepsCurrentViewWhenFocusedWindowIsNotTracked() {
        #expect(AppKitController.activationSelectionTarget(focusedWorkspaceID: nil) == nil)
    }

    @Test func appTogglePrefersFocusedBuiltInTerminalWorkspace() {
        #expect(
            AppKitController.preferredWorkspaceIDForAppToggle(
                focusedTerminalSessionWorkspaceID: "workspace-terminal", focusedWindowWorkspaceID: "workspace-window") == "workspace-terminal")
    }

    @Test func appToggleFallsBackToFocusedWindowWorkspaceWhenNoBuiltInTerminalWorkspaceExists() {
        #expect(
            AppKitController.preferredWorkspaceIDForAppToggle(focusedTerminalSessionWorkspaceID: nil, focusedWindowWorkspaceID: "workspace-window")
                == "workspace-window")
    }

    @Test func observedRemoteRoutedBrowserURLResolvesWorkspace() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project", name: "Project", dir: "/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace", projectID: "project", projectName: "Project", branch: "feature-123", baseBranch: "main", dir: "/project-feature",
                    isRunning: true, isHidden: false, isDefault: false, sessionCount: 0,
                    assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:9000")],
                    config: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [
                        SpacesDeviceBrowserSession(name: "docs", url: "http://localhost:32001/docs")
                    ]))
            ], sessions: [])

        let workspaceID = AppKitController.workspaceIDForObservedBrowserURL("http://web.feature-123.localhost:7391/docs", in: [overview])

        #expect(workspaceID == "workspace")
    }
}
