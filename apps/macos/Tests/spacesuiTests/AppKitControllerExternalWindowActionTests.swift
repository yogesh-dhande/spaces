import Testing

@testable import spacesui

@Suite struct AppKitControllerExternalWindowActionTests {
    @Test func successfulExternalFocusActionsHideSpaces() {
        #expect(AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .focus(hidesApp: true)))
    }

    @Test func successfulFocusActionsDelayHideForPulseVisibility() {
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(true, action: .focus(hidesApp: true)) == .milliseconds(400))
    }

    @Test func successfulBuiltInFocusActionsDoNotHideSpaces() {
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .focus(hidesApp: false)))
    }

    @Test func successfulExternalOpenActionsHideSpaces() {
        #expect(AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .open(hidesApp: true)))
    }

    @Test func successfulOpenActionsDoNotDelayHide() {
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(true, action: .open(hidesApp: true)) == nil)
    }

    @Test func successfulBuiltInOpenActionsDoNotHideSpaces() {
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .open(hidesApp: false)))
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(true, action: .open(hidesApp: false)) == nil)
    }

    @Test func failedActionsDoNotHideSpaces() {
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(false, action: .focus(hidesApp: true)))
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(false, action: .open(hidesApp: true)))
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(false, action: .focus(hidesApp: true)) == nil)
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(false, action: .open(hidesApp: true)) == nil)
    }
}
