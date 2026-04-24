import Testing

@testable import gui

@Suite struct AppKitControllerActivationSelectionTests {
    @Test func activationPrefersFocusedWorkspace() {
        #expect(AppKitController.activationSelectionTarget(focusedWorkspaceID: "workspace-focused") == .workspace("workspace-focused"))
    }

    @Test func activationShowsDashboardWhenFocusedWindowIsNotTracked() {
        #expect(AppKitController.activationSelectionTarget(focusedWorkspaceID: nil) == .dashboard)
    }
}
