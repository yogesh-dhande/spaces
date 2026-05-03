import Testing

@testable import spacesui

@Suite struct AppKitControllerSetupFlowTests {
    @Test func startupSetupFlowShowsStartupSplash() { #expect(AppKitController.shouldShowStartupSplashBeforeSetup(entryContext: .appLaunch)) }

    @Test func deferredSetupFlowSkipsStartupSplash() {
        #expect(!AppKitController.shouldShowStartupSplashBeforeSetup(entryContext: .deferredRequirement))
    }

    @Test func startupSetupFlowDefersChecksUntilSplashCanRender() {
        #expect(AppKitController.shouldDeferSetupChecksUntilAfterSplash(entryContext: .appLaunch))
    }

    @Test func deferredSetupFlowRunsChecksImmediately() {
        #expect(!AppKitController.shouldDeferSetupChecksUntilAfterSplash(entryContext: .deferredRequirement))
    }
}
