import XCTest

@testable import workspacecore

final class ComputeHostLifecycleTests: XCTestCase {
    func testStatusReportMarksCurrentManagedArtifact() {
        let report = ComputeHostDaemonStatusReport(
            daemonVersion: "1.2.3", artifactVersion: "1.2.3", certificateFingerprint: "SHA256:abc", activeSessionCount: 0,
            savedCertificateFingerprint: "SHA256:abc", appVersion: "1.2.3")

        XCTAssertEqual(report.upgradeState, .current)
        XCTAssertEqual(report.certificatePinMatches, true)
        XCTAssertTrue(report.displayText.contains("daemon 1.2.3"))
        XCTAssertTrue(report.displayText.contains("artifact 1.2.3"))
        XCTAssertTrue(report.displayText.contains("pin matched"))
        XCTAssertTrue(report.displayText.contains("0 active sessions"))
        XCTAssertTrue(report.displayText.contains("current"))
    }

    func testStatusReportMarksUpgradeAvailableAndPinMismatch() {
        let report = ComputeHostDaemonStatusReport(
            daemonVersion: "1.2.2", artifactVersion: "1.2.2", certificateFingerprint: "SHA256:remote", activeSessionCount: 2,
            savedCertificateFingerprint: "SHA256:saved", appVersion: "1.2.3")

        XCTAssertEqual(report.upgradeState, .upgradeAvailable)
        XCTAssertEqual(report.certificatePinMatches, false)
        XCTAssertTrue(report.displayText.contains("pin mismatch"))
        XCTAssertTrue(report.displayText.contains("2 active sessions"))
        XCTAssertTrue(report.displayText.contains("upgrade available"))
    }

    func testStatusReportMarksUnknownUpgradeStateWithoutArtifactVersion() {
        let report = ComputeHostDaemonStatusReport(
            daemonVersion: nil, artifactVersion: nil, certificateFingerprint: nil, activeSessionCount: nil,
            savedCertificateFingerprint: "SHA256:saved", appVersion: "1.2.3")

        XCTAssertEqual(report.upgradeState, .unknown)
        XCTAssertNil(report.certificatePinMatches)
        XCTAssertTrue(report.displayText.contains("daemon unknown"))
        XCTAssertTrue(report.displayText.contains("artifact unknown"))
        XCTAssertTrue(report.displayText.contains("pin unknown"))
        XCTAssertTrue(report.displayText.contains("upgrade unknown"))
    }
}
