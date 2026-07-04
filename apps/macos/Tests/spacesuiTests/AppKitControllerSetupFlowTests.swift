import Foundation
import Testing
import systembridge

@testable import spacesui

@Suite struct AppKitControllerSetupFlowTests {
    @MainActor @Test func chromeAutomationSetupBlocksWhenDeniedOrUndetermined() {
        #expect(AppKitController.requiresChromeAutomationSetup(.denied))
        #expect(AppKitController.requiresChromeAutomationSetup(.notDetermined))
    }

    @MainActor @Test func chromeAutomationSetupDoesNotBlockWhenGrantedOrUnavailable() {
        // Granted needs no setup; `unavailable` (Chrome absent or permission unverifiable) must not
        // lock a user out of the app over a permission that cannot be granted.
        #expect(!AppKitController.requiresChromeAutomationSetup(.granted))
        #expect(!AppKitController.requiresChromeAutomationSetup(.unavailable))
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

    @MainActor @Test func backgroundRefreshFailuresAreLoggedOnly() {
        let connectionError = NSError(domain: "spaces.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to connect to socket"])
        let decodeError = NSError(domain: "spaces.tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "remote state could not be decoded"])

        #expect(AppKitController.backgroundRefreshFailureAction(for: connectionError) == .logOnly)
        #expect(AppKitController.backgroundRefreshFailureAction(for: decodeError) == .logOnly)
    }

    @MainActor @Test func schedulesWorkAfterRunLoopTurn() async {
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
