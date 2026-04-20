import Testing

@testable import gui

@Suite struct AppKitControllerActivationSelectionTests {
    @Test func activationPrefersFocusedWorkspace() {
        #expect(
            AppKitController.activationWorkspaceID(
                focusedWorkspaceID: "workspace-focused",
                selectedWorkspaceID: "workspace-previous") == "workspace-focused")
    }

    @Test func activationFallsBackToSelectedWorkspace() {
        #expect(
            AppKitController.activationWorkspaceID(
                focusedWorkspaceID: nil,
                selectedWorkspaceID: "workspace-previous") == "workspace-previous")
    }

    @Test func activationReturnsNilWhenNothingIsSelected() {
        #expect(
            AppKitController.activationWorkspaceID(
                focusedWorkspaceID: nil,
                selectedWorkspaceID: nil) == nil)
    }
}
