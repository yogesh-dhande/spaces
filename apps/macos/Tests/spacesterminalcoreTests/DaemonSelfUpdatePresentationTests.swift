import Foundation
import XCTest

@testable import spacesterminalcore

final class DaemonSelfUpdatePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func status(
        version: String = "0.23.0", available: String? = nil, progress: DaemonSelfUpdateProgress? = nil, hasSelfUpdate: Bool = true
    ) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: version, installedVersion: version, certificateFingerprint: nil, activeSessionCount: 0,
            selfUpdate: hasSelfUpdate ? DaemonSelfUpdateStatus(channel: .stable, availableVersion: available, progress: progress) : nil)
    }

    private func progress(_ step: DaemonSelfUpdateProgress.Step, received: Int64? = nil, total: Int64? = nil, reason: String? = nil)
        -> DaemonSelfUpdateProgress
    { DaemonSelfUpdateProgress(targetVersion: "0.24.0", step: step, receivedBytes: received, totalBytes: total, failureReason: reason) }

    private func resolve(_ status: TerminalServiceDaemonStatus, reachable: Bool = true, attempt: DaemonSelfUpdateAttempt? = nil)
        -> DaemonSelfUpdatePresentation
    { DaemonSelfUpdatePresentation.resolve(status: status, isReachable: reachable, attempt: attempt, now: now) }

    func testDaemonThatCannotUpdateItselfShowsNothing() {
        XCTAssertEqual(resolve(status(available: "0.24.0", hasSelfUpdate: false)), .none)
    }

    func testNothingNewerShowsNothing() { XCTAssertEqual(resolve(status()), .none) }

    func testAvailableVersionIsOffered() {
        XCTAssertEqual(resolve(status(available: "0.24.0")), .available(from: "0.23.0", to: "0.24.0"))
    }

    func testDaemonProgressMapsToEachState() {
        XCTAssertEqual(
            resolve(status(available: "0.24.0", progress: progress(.downloading, received: 10, total: 40))),
            .downloading(from: "0.23.0", to: "0.24.0", received: 10, total: 40))
        XCTAssertEqual(resolve(status(progress: progress(.installing))), .installing(from: "0.23.0", to: "0.24.0"))
        XCTAssertEqual(resolve(status(progress: progress(.restarting))), .restarting(from: "0.23.0", to: "0.24.0"))
        XCTAssertEqual(
            resolve(status(progress: progress(.failed, reason: "Disk full."))), .failed(from: "0.23.0", to: "0.24.0", reason: "Disk full."))
    }

    func testDownloadWithoutTotalKeepsTheTotalUnknown() {
        XCTAssertEqual(
            resolve(status(progress: progress(.downloading, received: 7))), .downloading(from: "0.23.0", to: "0.24.0", received: 7, total: nil))
    }

    func testFailureWithoutAReasonUsesTheFallbackSentence() {
        XCTAssertEqual(
            resolve(status(progress: progress(.failed))), .failed(from: "0.23.0", to: "0.24.0", reason: DaemonSelfUpdateCopy.failedFallbackReason))
    }

    func testAttemptIsOverOnceTheDeviceReportsTheTargetVersion() {
        let attempt = DaemonSelfUpdateAttempt(targetVersion: "0.24.0", restartingSince: now)

        XCTAssertEqual(resolve(status(version: "0.24.0", available: nil, progress: progress(.restarting)), attempt: attempt), .none)
        XCTAssertEqual(resolve(status(version: "0.25.0"), attempt: attempt), .none)
    }

    func testUnreachableDeviceWithAnAttemptReadsAsRestarting() {
        let attempt = DaemonSelfUpdateAttempt(targetVersion: "0.24.0")

        XCTAssertEqual(
            resolve(status(progress: progress(.installing)), reachable: false, attempt: attempt), .restarting(from: "0.23.0", to: "0.24.0"))
    }

    func testUnreachableDeviceWhoseLastStepFailedStaysFailed() {
        let attempt = DaemonSelfUpdateAttempt(targetVersion: "0.24.0")

        XCTAssertEqual(
            resolve(status(progress: progress(.failed, reason: "No space left.")), reachable: false, attempt: attempt),
            .failed(from: "0.23.0", to: "0.24.0", reason: "No space left."))
    }

    func testUnreachableDeviceWithoutAnAttemptShowsItsLastKnownState() {
        XCTAssertEqual(resolve(status(available: "0.24.0"), reachable: false), .available(from: "0.23.0", to: "0.24.0"))
    }

    func testStillRestartingAppearsAtExactlyOneHundredTwentySeconds() {
        let target = "0.24.0"
        let justBefore = DaemonSelfUpdateAttempt(targetVersion: target, restartingSince: now.addingTimeInterval(-119.9))
        let boundary = DaemonSelfUpdateAttempt(targetVersion: target, restartingSince: now.addingTimeInterval(-120))

        XCTAssertEqual(resolve(status(), reachable: false, attempt: justBefore), .restarting(from: "0.23.0", to: target))
        XCTAssertEqual(resolve(status(), reachable: false, attempt: boundary), .stillRestarting(from: "0.23.0", to: target))
    }

    func testDaemonReportedRestartingAlsoTurnsIntoStillRestarting() {
        let attempt = DaemonSelfUpdateAttempt(targetVersion: "0.24.0", restartingSince: now.addingTimeInterval(-300))

        XCTAssertEqual(
            resolve(status(progress: progress(.restarting)), attempt: attempt), .stillRestarting(from: "0.23.0", to: "0.24.0"))
    }

    func testRestartingWithoutARecordedStartNeverReadsAsStill() {
        let attempt = DaemonSelfUpdateAttempt(targetVersion: "0.24.0", restartingSince: nil)

        XCTAssertEqual(resolve(status(), reachable: false, attempt: attempt), .restarting(from: "0.23.0", to: "0.24.0"))
        XCTAssertTrue(resolve(status(), reachable: false, attempt: attempt).isRestarting)
        XCTAssertFalse(DaemonSelfUpdatePresentation.stillRestarting(from: "a", to: "b").isRestarting)
    }

    // MARK: - Copy

    func testDownloadDetailFormatsMegabytesWithOneDecimal() {
        XCTAssertEqual(DaemonSelfUpdateCopy.downloadingDetail(received: 12_400_000, total: 38_000_000), "Downloading 12.4 of 38.0 MB")
        XCTAssertEqual(DaemonSelfUpdateCopy.downloadingDetail(received: 12_400_000, total: nil), "Downloading 12.4 MB")
        XCTAssertEqual(DaemonSelfUpdateCopy.downloadingDetail(received: 0, total: nil), "Downloading 0.0 MB")
    }

    func testApprovedCopy() {
        XCTAssertEqual(
            DaemonSelfUpdateCopy.availableBody(version: "0.24.0", deviceName: "build-box"),
            "Spaces 0.24.0 is out for build-box. It updates itself, and nothing it's running stops.")
        XCTAssertEqual(DaemonSelfUpdateCopy.updateButtonTitle(deviceName: "build-box"), "Update build-box")
        XCTAssertEqual(DaemonSelfUpdateCopy.downloadingTitle(deviceName: "build-box"), "Updating build-box")
        XCTAssertEqual(DaemonSelfUpdateCopy.installingBody(version: "0.24.0"), "Checking the signature and installing 0.24.0.")
        XCTAssertEqual(DaemonSelfUpdateCopy.restartingBody(version: "0.24.0"), "Restarting on 0.24.0. Its terminals keep running.")
        XCTAssertEqual(
            DaemonSelfUpdateCopy.stillRestartingBody(deviceName: "build-box", version: "0.24.0"),
            "build-box hasn't come back on 0.24.0 yet. Its terminals keep running.")
        XCTAssertEqual(DaemonSelfUpdateCopy.macWhoLine(deviceName: "build-box", channel: .stable), "build-box · stable releases")
        XCTAssertEqual(DaemonSelfUpdateCopy.macWhoLine(deviceName: "build-box", channel: .prerelease), "build-box · pre-release updates")
        XCTAssertEqual(
            DaemonSelfUpdateCopy.macBody(deviceName: "build-box", version: "0.24.0"),
            "build-box downloads and installs Spaces 0.24.0 itself. Nothing it's running stops.")
        XCTAssertEqual(DaemonSelfUpdateCopy.heroWhoLine(availableVersion: "0.24.0", deviceName: "build-box"), "0.24.0 is available for build-box")
        XCTAssertEqual(
            DaemonSelfUpdateCopy.heroBody(deviceName: "build-box"), "build-box downloads and installs it itself. Nothing it's running stops.")
    }
}
