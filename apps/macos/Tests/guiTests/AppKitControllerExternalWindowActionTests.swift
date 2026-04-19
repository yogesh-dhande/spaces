import Testing

@testable import gui

@Suite struct AppKitControllerExternalWindowActionTests {
    @Test func successfulFocusActionsHideMuxy() {
        #expect(AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .focus))
    }

    @Test func successfulOpenActionsHideMuxy() {
        #expect(AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .open))
    }

    @Test func failedActionsDoNotHideMuxy() {
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(false, action: .focus))
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(false, action: .open))
    }
}
