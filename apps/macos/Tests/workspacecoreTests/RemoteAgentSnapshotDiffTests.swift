import XCTest
import spacesdevicecore

@testable import workspacecore

/// Behavior coverage for the pure remote watch diff and the cross-device subscribe validation. The diff
/// recovers blocked/done/exited transitions from successive `listAgentSessions` snapshots; the validation
/// gates a subscribe on a paired device and an existing remote child, both with injected closures.
final class RemoteAgentSnapshotDiffTests: XCTestCase {
    // MARK: - Snapshot diff

    func testFirstSnapshotSeedsBaselineWithoutEmitting() throws {
        let watched: Set<String> = ["term-1", "term-2"]
        let rows = [row(terminal: "term-1", status: "waiting"), row(terminal: "term-2", status: "spinning")]

        let result = RemoteAgentSnapshotDiff.diff(previous: [:], newRows: rows, watchedTerminalSessionIDs: watched)

        // No prior observation for either agent: baseline seeds, nothing fires (no reconnect replay storm).
        XCTAssertTrue(result.transitions.isEmpty)
        XCTAssertEqual(Set(result.snapshot.keys), watched)
    }

    func testTransitionToWaitingIsBlockedAndToDoneIsDone() throws {
        let baseline = RemoteAgentSnapshotDiff.diff(
            previous: [:], newRows: [row(terminal: "term-1", status: "spinning"), row(terminal: "term-2", status: "spinning")],
            watchedTerminalSessionIDs: ["term-1", "term-2"])

        let result = RemoteAgentSnapshotDiff.diff(
            previous: baseline.snapshot, newRows: [row(terminal: "term-1", status: "waiting"), row(terminal: "term-2", status: "done")],
            watchedTerminalSessionIDs: ["term-1", "term-2"])

        // Deterministic sorted order: term-1 (blocked) before term-2 (done).
        XCTAssertEqual(result.transitions.map(\.terminalSessionID), ["term-1", "term-2"])
        XCTAssertEqual(result.transitions.map(\.kind), [.blocked, .done])
    }

    /// waiting → spinning is the child resuming after an approval: a non-notifying `resumedWorking`
    /// transition (it maps to no ChildTransition) whose only effect is withdrawing the held blocked
    /// line. Any other path into `spinning` stays silent — there is nothing to withdraw.
    func testWaitingToSpinningEmitsNonNotifyingResumedWorking() throws {
        let baseline = RemoteAgentSnapshotDiff.diff(
            previous: [:], newRows: [row(terminal: "term-1", status: "waiting"), row(terminal: "term-2", status: "idle")],
            watchedTerminalSessionIDs: ["term-1", "term-2"])

        let result = RemoteAgentSnapshotDiff.diff(
            previous: baseline.snapshot, newRows: [row(terminal: "term-1", status: "spinning"), row(terminal: "term-2", status: "spinning")],
            watchedTerminalSessionIDs: ["term-1", "term-2"])

        XCTAssertEqual(result.transitions.map(\.terminalSessionID), ["term-1"])
        XCTAssertEqual(result.transitions.map(\.kind), [.resumedWorking])
        XCTAssertNil(result.transitions.first?.kind.childTransition)
    }

    func testUnchangedStatusDoesNotReEmit() throws {
        let baseline = RemoteAgentSnapshotDiff.diff(
            previous: [:], newRows: [row(terminal: "term-1", status: "waiting")], watchedTerminalSessionIDs: ["term-1"])
        // Still waiting across a second push: no repeat blocked line.
        let result = RemoteAgentSnapshotDiff.diff(
            previous: baseline.snapshot, newRows: [row(terminal: "term-1", status: "waiting")], watchedTerminalSessionIDs: ["term-1"])
        XCTAssertTrue(result.transitions.isEmpty)
    }

    /// A status change to `exited` (the child process ended but its terminal survived, so the row stays
    /// in the listing) delivers a single `.exited` transition carrying the fresh row, from every prior
    /// live state.
    func testTransitionToExitedStatusEmitsExitedCarryingNewRow() throws {
        for previousStatus in ["spinning", "waiting", "done"] {
            let baseline = RemoteAgentSnapshotDiff.diff(
                previous: [:], newRows: [row(terminal: "term-1", status: previousStatus)], watchedTerminalSessionIDs: ["term-1"])

            let result = RemoteAgentSnapshotDiff.diff(
                previous: baseline.snapshot, newRows: [row(terminal: "term-1", status: "exited")], watchedTerminalSessionIDs: ["term-1"])

            XCTAssertEqual(result.transitions.map(\.kind), [.exited], "\(previousStatus) → exited must emit one exited transition")
            // Unlike the row-disappearance case, the status-transition exit renders from the fresh row and
            // the agent stays in the snapshot (its terminal is still watched).
            XCTAssertEqual(result.transitions.first?.row.status, "exited")
            XCTAssertEqual(Set(result.snapshot.keys), ["term-1"])
        }
    }

    /// A newly-watched agent already observed as `exited` on its first snapshot seeds silently: the first
    /// observation never emits, so subscribing to an already-exited agent replays nothing.
    func testFirstObservationOfExitedRowSeedsSilently() throws {
        let result = RemoteAgentSnapshotDiff.diff(
            previous: [:], newRows: [row(terminal: "term-1", status: "exited")], watchedTerminalSessionIDs: ["term-1"])

        XCTAssertTrue(result.transitions.isEmpty)
        XCTAssertEqual(Set(result.snapshot.keys), ["term-1"])
    }

    /// idle → spinning is an ordinary start with nothing held to withdraw, so it stays silent — only
    /// waiting → spinning (a post-approval resume) emits the non-notifying `resumedWorking`.
    func testIdleToSpinningEmitsNothing() throws {
        let baseline = RemoteAgentSnapshotDiff.diff(
            previous: [:], newRows: [row(terminal: "term-1", status: "idle")], watchedTerminalSessionIDs: ["term-1"])

        let result = RemoteAgentSnapshotDiff.diff(
            previous: baseline.snapshot, newRows: [row(terminal: "term-1", status: "spinning")], watchedTerminalSessionIDs: ["term-1"])

        XCTAssertTrue(result.transitions.isEmpty)
    }

    func testWatchedAgentAbsentFromListingIsExitedAndLeavesSnapshot() throws {
        let baseline = RemoteAgentSnapshotDiff.diff(
            previous: [:], newRows: [row(terminal: "term-1", status: "done")], watchedTerminalSessionIDs: ["term-1"])

        let result = RemoteAgentSnapshotDiff.diff(previous: baseline.snapshot, newRows: [], watchedTerminalSessionIDs: ["term-1"])

        XCTAssertEqual(result.transitions.map(\.kind), [.exited])
        // The exit renders from the last-seen row and the agent leaves the next snapshot.
        XCTAssertEqual(result.transitions.first?.row.status, "done")
        XCTAssertTrue(result.snapshot.isEmpty)
    }

    func testNewlyWatchedAgentSeedsSilentlyEvenWithPopulatedBaseline() throws {
        // term-1 already has a baseline; term-2 is watched for the first time this push.
        let baseline = RemoteAgentSnapshotDiff.diff(
            previous: [:], newRows: [row(terminal: "term-1", status: "spinning")], watchedTerminalSessionIDs: ["term-1"])

        let result = RemoteAgentSnapshotDiff.diff(
            previous: baseline.snapshot, newRows: [row(terminal: "term-1", status: "spinning"), row(terminal: "term-2", status: "waiting")],
            watchedTerminalSessionIDs: ["term-1", "term-2"])

        // term-2's first observation seeds silently — subscribing never replays its current state.
        XCTAssertTrue(result.transitions.isEmpty)
        XCTAssertEqual(Set(result.snapshot.keys), ["term-1", "term-2"])
    }

    func testRowsWithoutTerminalSessionIDAreIgnored() throws {
        let baseline = RemoteAgentSnapshotDiff.diff(
            previous: [:], newRows: [row(terminal: "term-1", status: "spinning")], watchedTerminalSessionIDs: ["term-1"])
        // A row with no terminal session id cannot be a watch target and never matches.
        let result = RemoteAgentSnapshotDiff.diff(
            previous: baseline.snapshot, newRows: [row(terminal: nil, status: "waiting")], watchedTerminalSessionIDs: ["term-1"])
        // term-1 is now absent from the listing = exited; the nil-terminal row is simply ignored.
        XCTAssertEqual(result.transitions.map(\.kind), [.exited])
    }

    // MARK: - Subscribe validation

    private struct FakeDevice { let name: String }

    func testValidateThrowsForUnknownDevice() {
        XCTAssertThrowsError(
            try RemoteAgentSubscriptionValidation.validate(
                deviceID: "dev-missing", childTerminalSessionID: "term-1", resolveDevice: { _ in Optional<FakeDevice>.none }, deviceName: { $0.name },
                fetchRows: { _ in [] })
        ) { error in XCTAssertTrue("\(error)".contains("No paired device dev-missing")) }
    }

    func testValidateThrowsForUnknownRemoteSession() {
        XCTAssertThrowsError(
            try RemoteAgentSubscriptionValidation.validate(
                deviceID: "dev-1", childTerminalSessionID: "term-1", resolveDevice: { _ in FakeDevice(name: "Studio") }, deviceName: { $0.name },
                fetchRows: { _ in [self.row(terminal: "other-term", status: "waiting")] })
        ) { error in XCTAssertTrue("\(error)".contains("No agent session for terminal term-1 on Studio")) }
    }

    func testValidatePassesForPairedDeviceWithMatchingChild() throws {
        try RemoteAgentSubscriptionValidation.validate(
            deviceID: "dev-1", childTerminalSessionID: "term-1", resolveDevice: { _ in FakeDevice(name: "Studio") }, deviceName: { $0.name },
            fetchRows: { _ in [self.row(terminal: "term-1", status: "waiting")] })
    }

    // MARK: - Fixtures

    private func row(terminal: String?, status: String) -> SpacesDeviceAgentSessionRow {
        SpacesDeviceAgentSessionRow(
            id: "row-\(terminal ?? "none")", terminalSessionID: terminal, agent: "CLI", label: "CLI", status: status, note: nil, projectID: "p",
            projectName: "P", workspaceID: "w", workspaceName: "W", workspaceDir: "/remote/workspaces/W", branch: nil, updatedAt: "now",
            lastSignalAt: "now")
    }
}
