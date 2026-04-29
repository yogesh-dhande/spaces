import Testing

@testable import spacesui

@Suite struct AppKitControllerExternalWindowActionTests {
    @Test func successfulFocusActionsHideSpaces() { #expect(AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .focus)) }

    @Test func successfulFocusActionsDelayHideForPulseVisibility() {
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(true, action: .focus) == .milliseconds(400))
    }

    @Test func successfulOpenActionsHideSpaces() { #expect(AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .open)) }

    @Test func successfulOpenActionsDoNotDelayHide() {
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(true, action: .open) == nil)
    }

    @Test func failedActionsDoNotHideSpaces() {
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(false, action: .focus))
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(false, action: .open))
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(false, action: .focus) == nil)
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(false, action: .open) == nil)
    }
}
