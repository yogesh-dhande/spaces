import Foundation
import XCTest

@testable import spacesterminalcore

final class SpacesWireProtocolTests: XCTestCase {
    func testEvaluateCompatibleWhenVersionsMatch() {
        let verdict = SpacesWireCompatibility.evaluate(daemonProtocolVersion: 3, localVersion: 3)
        XCTAssertEqual(verdict, .compatible)
        XCTAssertTrue(verdict.isCompatible)
    }

    func testEvaluateDaemonTooOldWhenBelowLocal() {
        let verdict = SpacesWireCompatibility.evaluate(daemonProtocolVersion: 2, localVersion: 3)
        XCTAssertEqual(verdict, .daemonTooOld)
        XCTAssertFalse(verdict.isCompatible)
    }

    func testEvaluateClientTooOldWhenAboveLocal() {
        let verdict = SpacesWireCompatibility.evaluate(daemonProtocolVersion: 4, localVersion: 3)
        XCTAssertEqual(verdict, .clientTooOld)
        XCTAssertFalse(verdict.isCompatible)
    }

    func testEvaluateFromDaemonStatusUsesAdvertisedVersion() {
        let status = TerminalServiceDaemonStatus(
            version: "9.9.9", artifactVersion: nil, certificateFingerprint: nil, activeSessionCount: 2,
            protocolVersion: SpacesWireProtocol.version)
        XCTAssertEqual(SpacesWireCompatibility.evaluate(daemonStatus: status), .compatible)
    }

    func testDaemonStatusRoundTripsAllFields() throws {
        let status = TerminalServiceDaemonStatus(
            version: "0.2.0", artifactVersion: "abc", certificateFingerprint: "ff", activeSessionCount: 3,
            protocolVersion: 7, runningProcesses: 2, activeAgents: 1, waitingAgents: 4, operatingSystem: "Linux")
        let decoded = try JSONDecoder().decode(TerminalServiceDaemonStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
        XCTAssertTrue(decoded.isLinuxDaemon)
    }
}
