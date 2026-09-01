import Testing
import spacesclientcore
import spacesterminalcore

@testable import spacesui

/// Table-driven coverage of the pure decisions behind `maybeRequestSilentDaemonHandoff`: which staged
/// build a status refresh should ask a device to apply in place, and how the watchdog later reads back
/// from the device whether that apply happened. The once-only rule that sits alongside them is a set
/// membership check on the requested attempt at the call site.
@Suite struct AppKitControllerSilentDaemonHandoffTests {
    private struct Case: Sendable {
        let name: String
        let status: TerminalServiceDaemonStatus?
        let expectedStagedVersion: String?
    }

    private static func status(version: String, installedVersion: String?, protocolVersion: Int) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: version, installedVersion: installedVersion, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: protocolVersion
        )
    }

    private static let cases: [Case] = [
        Case(
            name: "a compatible daemon with a newer build staged is asked to apply it",
            status: status(version: "0.8.7", installedVersion: "0.9.2", protocolVersion: SpacesWireProtocol.version), expectedStagedVersion: "0.9.2"),
        Case(
            name: "a wire-incompatible daemon with a newer build staged is asked to apply it too — the restart RPC rides the frozen wire core",
            status: status(version: "0.8.7", installedVersion: "0.9.2", protocolVersion: SpacesWireProtocol.version - 1),
            expectedStagedVersion: "0.9.2"),
        Case(
            name: "a too-old daemon with nothing staged has nothing to apply",
            status: status(version: "0.8.7", installedVersion: nil, protocolVersion: SpacesWireProtocol.version - 1), expectedStagedVersion: nil),
        Case(
            name: "a compatible, up-to-date daemon has nothing to apply",
            status: status(version: "0.9.2", installedVersion: nil, protocolVersion: SpacesWireProtocol.version), expectedStagedVersion: nil),
        Case(
            name: "a daemon ahead of this app is never restarted — this app must update first",
            status: status(version: "0.9.2", installedVersion: "0.9.3", protocolVersion: SpacesWireProtocol.version + 1), expectedStagedVersion: nil),
        Case(
            name: "an installed build that is not newer than the running one is not a staged update",
            status: status(version: "0.9.2", installedVersion: "0.9.2", protocolVersion: SpacesWireProtocol.version), expectedStagedVersion: nil),
        Case(name: "a device that reported no status is asked for nothing", status: nil, expectedStagedVersion: nil),
    ]

    @Test(arguments: cases) private func picksTheStagedBuildToApply(testCase: Case) {
        #expect(DaemonUpdateController.silentDaemonHandoffStagedVersion(status: testCase.status) == testCase.expectedStagedVersion, "\(testCase.name)")
    }

    @Test func theApplyIsStillPendingOnlyWhileTheDeviceReportsTheSameBuildStaged() {
        let stillStaged = Self.status(version: "0.8.7", installedVersion: "0.9.2", protocolVersion: SpacesWireProtocol.version - 1)
        #expect(DaemonUpdateController.stagedApplyIsStillPending(status: stillStaged, stagedVersion: "0.9.2"))
        // The device came back on the staged build: nothing is staged any more, so the apply landed.
        let applied = Self.status(version: "0.9.2", installedVersion: "0.9.2", protocolVersion: SpacesWireProtocol.version)
        #expect(!DaemonUpdateController.stagedApplyIsStillPending(status: applied, stagedVersion: "0.9.2"))
        // A newer build was staged while the app was waiting on the previous one — a different attempt,
        // so the watchdog watching the old one must not report on it.
        let supersededByANewerStage = Self.status(version: "0.8.7", installedVersion: "0.9.3", protocolVersion: SpacesWireProtocol.version - 1)
        #expect(!DaemonUpdateController.stagedApplyIsStillPending(status: supersededByANewerStage, stagedVersion: "0.9.2"))
        // An unreachable device reports nothing, which is also what a daemon mid-handoff looks like.
        #expect(!DaemonUpdateController.stagedApplyIsStillPending(status: nil, stagedVersion: "0.9.2"))
    }

    /// The other half of the watchdog's decision: what a wait that decided nothing does about the
    /// once-per-build rule the request spent. Only the device's own report that the build is still
    /// staged and not running spends it; anything else hands it back, so a device that comes back still
    /// waiting on that same build is asked again instead of being deduped into a state with no automatic
    /// apply and no block to act on.
    @Test func aWaitThatDecidedNothingReArmsTheAutomaticRequest() {
        let stillStaged = Self.status(version: "0.8.7", installedVersion: "0.9.2", protocolVersion: SpacesWireProtocol.version - 1)
        #expect(DaemonUpdateController.stagedApplyWatchdogResolution(status: stillStaged, stagedVersion: "0.9.2") == .reportDidNotLand)
        // The device went quiet for the whole wait — a daemon still replaying its sessions and an
        // unreachable device look the same — so nothing was decided and the request is un-made.
        #expect(DaemonUpdateController.stagedApplyWatchdogResolution(status: nil, stagedVersion: "0.9.2") == .rearmAutomaticRequest)
        // The apply landed: the device is on the staged build and has nothing staged any more. Re-arming
        // here costs nothing — there is no staged build left for a report to re-request.
        let applied = Self.status(version: "0.9.2", installedVersion: "0.9.2", protocolVersion: SpacesWireProtocol.version)
        #expect(DaemonUpdateController.stagedApplyWatchdogResolution(status: applied, stagedVersion: "0.9.2") == .rearmAutomaticRequest)
        // A newer build was staged while this one was waited on. This attempt is not the one to judge,
        // and the newer build is a different attempt with its own once-only.
        let supersededByANewerStage = Self.status(version: "0.8.7", installedVersion: "0.9.3", protocolVersion: SpacesWireProtocol.version - 1)
        #expect(DaemonUpdateController.stagedApplyWatchdogResolution(status: supersededByANewerStage, stagedVersion: "0.9.2") == .rearmAutomaticRequest)
    }
}
