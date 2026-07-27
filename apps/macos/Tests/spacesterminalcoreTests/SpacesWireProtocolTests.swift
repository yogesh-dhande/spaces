import Foundation
import XCTest

@testable import spacesterminalcore

final class SpacesWireProtocolTests: XCTestCase {
    func testCurrentWireProtocolVersion() { XCTAssertEqual(SpacesWireProtocol.version, 12) }

    func testEvaluateCompatibleWhenVersionsMatch() {
        let verdict = SpacesWireCompatibility.evaluate(daemonProtocolVersion: 5, localVersion: 5)
        XCTAssertEqual(verdict, .compatible)
        XCTAssertTrue(verdict.isCompatible)
    }

    func testEvaluateDaemonTooOldWhenBelowLocal() {
        let verdict = SpacesWireCompatibility.evaluate(daemonProtocolVersion: 4, localVersion: 5)
        XCTAssertEqual(verdict, .daemonTooOld)
        XCTAssertFalse(verdict.isCompatible)
    }

    func testEvaluateClientTooOldWhenAboveLocal() {
        let verdict = SpacesWireCompatibility.evaluate(daemonProtocolVersion: 6, localVersion: 5)
        XCTAssertEqual(verdict, .clientTooOld)
        XCTAssertFalse(verdict.isCompatible)
    }

    func testEvaluateFromDaemonStatusUsesAdvertisedVersion() {
        let status = TerminalServiceDaemonStatus(
            version: "9.9.9", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 2, protocolVersion: SpacesWireProtocol.version)
        XCTAssertEqual(SpacesWireCompatibility.evaluate(daemonStatus: status), .compatible)
    }

    func testDaemonStatusRoundTripsAllFields() throws {
        let status = TerminalServiceDaemonStatus(
            version: "0.2.0", installedVersion: "abc", certificateFingerprint: "ff", activeSessionCount: 3, protocolVersion: 7, runningProcesses: 2,
            activeAgents: 1, waitingAgents: 4, operatingSystem: "Linux")
        let decoded = try JSONDecoder().decode(TerminalServiceDaemonStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
        XCTAssertTrue(decoded.isLinuxDaemon)
    }

    func testDaemonStatusDecodesWhenPeerOmitsNewerFields() throws {
        // A peer whose field set predates this build (no protocolVersion / counts / OS). The frozen
        // core must still decode instead of throwing keyNotFound on the negotiation handshake.
        let json = Data(#"{"version":"0.1.0","activeSessionCount":2}"#.utf8)
        let status = try JSONDecoder().decode(TerminalServiceDaemonStatus.self, from: json)
        XCTAssertEqual(status.version, "0.1.0")
        XCTAssertEqual(status.activeSessionCount, 2)
        // Missing protocolVersion is treated as "unknown / too old", not as a match.
        XCTAssertEqual(status.protocolVersion, TerminalServiceDaemonStatus.unknownProtocolVersion)
        XCTAssertEqual(SpacesWireCompatibility.evaluate(daemonStatus: status), .daemonTooOld)
        XCTAssertFalse(SpacesWireCompatibility.evaluate(daemonStatus: status).isCompatible)
    }

    func testDaemonStatusDecodesWhenPeerAddsUnknownFields() throws {
        // A newer peer that adds a field this build does not know must still decode here.
        let json = Data(
            #"{"version":"9.9.9","activeSessionCount":1,"protocolVersion":\#(SpacesWireProtocol.version),"runningProcesses":0,"activeAgents":0,"waitingAgents":0,"operatingSystem":"macOS","futureField":"ignored"}"#
                .utf8)
        let status = try JSONDecoder().decode(TerminalServiceDaemonStatus.self, from: json)
        XCTAssertEqual(status.protocolVersion, SpacesWireProtocol.version)
        XCTAssertEqual(SpacesWireCompatibility.evaluate(daemonStatus: status), .compatible)
    }

    func testIsVersionOlderThanComparesNumericComponents() {
        XCTAssertTrue(SpacesWireProtocol.isVersion("0.1.0", olderThan: "0.2.0"))
        XCTAssertTrue(SpacesWireProtocol.isVersion("0.1.9", olderThan: "0.2.0"))
        XCTAssertTrue(SpacesWireProtocol.isVersion("0.1", olderThan: "0.1.1"))
        XCTAssertFalse(SpacesWireProtocol.isVersion("0.2.0", olderThan: "0.1.0"))
        XCTAssertFalse(SpacesWireProtocol.isVersion("0.2.0", olderThan: "0.2.0"))
        XCTAssertFalse(SpacesWireProtocol.isVersion("0.2.0", olderThan: "0.2"))
    }

    func testIsVersionOlderThanTreatsEmptyAsEqual() {
        XCTAssertFalse(SpacesWireProtocol.isVersion("", olderThan: "1.0.0"))
        XCTAssertFalse(SpacesWireProtocol.isVersion("1.0.0", olderThan: ""))
        XCTAssertFalse(SpacesWireProtocol.isVersion("", olderThan: ""))
    }

    func testUpdatePendingWhenInstalledBuildIsNewerThanRunningBuild() {
        let status = makeStatus(version: "0.1.0", installedVersion: "0.2.0")
        XCTAssertTrue(status.isUpdatePending)
    }

    func testUpdateNotPendingWhenRunningBuildIsTheInstalledBuild() {
        let status = makeStatus(version: "0.2.0", installedVersion: "0.2.0")
        XCTAssertFalse(status.isUpdatePending)
    }

    /// The daemon reports no installed build (it runs from a development build directory), which means
    /// there is nothing staged to restart onto — not "unknown, assume an update".
    func testUpdateNotPendingWhenDaemonReportsNoInstalledBuild() {
        let status = makeStatus(version: "0.1.0", installedVersion: nil)
        XCTAssertFalse(status.isUpdatePending)
    }

    /// A daemon that has *already* restarted onto a build newer than what is installed (a downgrade on
    /// disk) is not "pending" — nothing is waiting to be applied.
    func testUpdateNotPendingWhenRunningBuildIsNewerThanInstalled() {
        let status = makeStatus(version: "0.3.0", installedVersion: "0.2.0")
        XCTAssertFalse(status.isUpdatePending)
    }

    /// The pending-update answer belongs to the daemon's device and travels over the wire, so a client
    /// gets the same verdict it would compute locally, without consulting its own build version.
    func testUpdatePendingSurvivesTheWire() throws {
        let status = makeStatus(version: "0.1.0", installedVersion: "0.2.0")
        let decoded = try JSONDecoder().decode(TerminalServiceDaemonStatus.self, from: JSONEncoder().encode(status))
        XCTAssertTrue(decoded.isUpdatePending)
    }

    private func makeStatus(version: String, installedVersion: String?) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(version: version, installedVersion: installedVersion, certificateFingerprint: nil, activeSessionCount: 0)
    }

    // MARK: - Nightly channel versions

    // A nightly build's marketing version is the stable release it was built from plus a fourth
    // numeric component, the build timestamp (e.g. "0.5.1" -> "0.5.1.202607250900") — never a "-nightly"
    // suffix. `isVersion(_:olderThan:)` splits on "." and maps any non-numeric component to 0, so a
    // suffixed string like "0.5.1-nightly" would compare as "0.5.0" — the whole "1-nightly"
    // component is non-numeric, so the patch number is lost entirely — and sort *below* "0.5.1",
    // making the daemon think a nightly install is older than the release it superseded and
    // silently drop the "an update is staged on this device" hint. The tests below pin the
    // product behavior (the staged-update decision) that depends on the all-numeric scheme.

    func testNightlyIsStagedUpdateOverItsBaseRelease() {
        // "0.5.1" -> "0.5.1.202607250900" is newer: a nightly built from the running release is staged.
        let status = makeStatus(version: "0.5.1", installedVersion: "0.5.1.202607250900")
        XCTAssertTrue(status.isUpdatePending)
        XCTAssertEqual(status.stagedVersion, "0.5.1.202607250900")
    }

    func testBaseReleaseIsNotStagedUpdateOverItsOwnNightly() {
        // Reverse of the above: a daemon already running the nightly has nothing newer staged.
        let status = makeStatus(version: "0.5.1.202607250900", installedVersion: "0.5.1")
        XCTAssertFalse(status.isUpdatePending)
        XCTAssertNil(status.stagedVersion)
    }

    func testNextStableIsStagedUpdateOverAPriorNightly() {
        // "0.5.1.202607250900" -> "0.5.2" is newer: the next stable release supersedes any nightly cut
        // from the release before it.
        let status = makeStatus(version: "0.5.1.202607250900", installedVersion: "0.5.2")
        XCTAssertTrue(status.isUpdatePending)
        XCTAssertEqual(status.stagedVersion, "0.5.2")
    }

    func testNightlyIsNotStagedUpdateOverTheNextStableItPredates() {
        // Reverse of the above: a daemon already running the newer stable has nothing staged.
        let status = makeStatus(version: "0.5.2", installedVersion: "0.5.1.202607250900")
        XCTAssertFalse(status.isUpdatePending)
        XCTAssertNil(status.stagedVersion)
    }

    func testLaterNightlyIsStagedUpdateOverAnEarlierNightly() {
        // Consecutive nightlies off the same base release order by their date component.
        let status = makeStatus(version: "0.5.1.202607240900", installedVersion: "0.5.1.202607250900")
        XCTAssertTrue(status.isUpdatePending)
        XCTAssertEqual(status.stagedVersion, "0.5.1.202607250900")
    }

    /// Two nightlies cut on the same UTC day — the schedule plus a later manual run — must still be
    /// distinguishable here. The timestamp carries minute precision for exactly this case: were the
    /// marketing versions equal, Sparkle would install the second build while the daemon saw no
    /// staged update and kept running the first build's binary.
    func testSameDayNightliesAreDistinguishedByTheirTimestamp() {
        let status = makeStatus(version: "0.5.1.202607250900", installedVersion: "0.5.1.202607251500")
        XCTAssertTrue(status.isUpdatePending)
        XCTAssertEqual(status.stagedVersion, "0.5.1.202607251500")
    }

    func testEarlierNightlyIsNotStagedUpdateOverALaterNightly() {
        // Reverse of the above: a daemon already on the later nightly has nothing staged.
        let status = makeStatus(version: "0.5.1.202607250900", installedVersion: "0.5.1.202607240900")
        XCTAssertFalse(status.isUpdatePending)
        XCTAssertNil(status.stagedVersion)
    }
}
