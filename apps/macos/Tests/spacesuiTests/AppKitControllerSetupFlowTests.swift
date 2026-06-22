import Foundation
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

    @Test func passiveDesktopControlRecoveryIgnoresUnrelatedTermination() {
        #expect(!AppKitController.shouldAttemptDesktopControlRecovery(passiveOwnerPID: 101, terminatedApplicationPID: 202))
    }

    @Test func passiveDesktopControlRecoveryRequiresKnownOwnerAndTerminationPID() {
        #expect(!AppKitController.shouldAttemptDesktopControlRecovery(passiveOwnerPID: nil, terminatedApplicationPID: 202))
        #expect(!AppKitController.shouldAttemptDesktopControlRecovery(passiveOwnerPID: 101, terminatedApplicationPID: nil))
    }

    @Test func passiveDesktopControlRecoveryRetriesWhenCurrentOwnerTerminates() {
        #expect(AppKitController.shouldAttemptDesktopControlRecovery(passiveOwnerPID: 101, terminatedApplicationPID: 101))
    }

    @MainActor @Test func backgroundRefreshRoutesOnlyYabaiSocketFailuresToSetup() {
        let yabaiSocketError = NSError(
            domain: "spaces.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "yabai-msg: failed to connect to socket"])
        let decodeError = NSError(domain: "spaces.tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "remote state could not be decoded"])

        #expect(AppKitController.backgroundRefreshFailureAction(for: yabaiSocketError) == .deferredSetup)
        #expect(AppKitController.backgroundRefreshFailureAction(for: decodeError) == .logOnly)
    }

    @MainActor @Test func startupSetupFlowSchedulesChecksAfterRunLoopTurn() async {
        var didRun = false
        await withCheckedContinuation { continuation in
            AppKitController.scheduleAfterNextRunLoopTurn {
                didRun = true
                continuation.resume()
            }
            #expect(!didRun)
        }
        #expect(didRun)
    }
}
