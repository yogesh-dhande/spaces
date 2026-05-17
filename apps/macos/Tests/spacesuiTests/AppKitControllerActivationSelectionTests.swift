import Testing

@testable import spacesui

@Suite struct AppKitControllerActivationSelectionTests {
    @Test func activationPrefersFocusedWorkspace() {
        #expect(AppKitController.activationSelectionTarget(focusedWorkspaceID: "workspace-focused") == .workspace("workspace-focused"))
    }

    @Test func activationShowsAlertsWhenFocusedWindowIsNotTracked() {
        #expect(AppKitController.activationSelectionTarget(focusedWorkspaceID: nil) == .alerts)
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
}
