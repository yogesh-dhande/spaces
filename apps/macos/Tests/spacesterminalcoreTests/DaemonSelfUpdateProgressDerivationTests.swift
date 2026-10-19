import Foundation
import XCTest

@testable import spacesterminalcore

final class DaemonSelfUpdateProgressDerivationTests: XCTestCase {
    private let prefix = "spaces-install-linux: "

    private func derive(_ lines: [String], running: String = "0.23.0", sizes: [String: Int64] = [:]) -> DaemonSelfUpdateProgressDerivation.Result {
        DaemonSelfUpdateProgressDerivation.derive(
            logText: lines.joined(separator: "\n"), targetVersion: "0.24.0", runningVersion: running, archiveSize: { sizes[$0] })
    }

    func testDownloadingReportsReceivedBytesFromTheArchiveOnDisk() {
        let result = derive([prefix + "step downloading 38000000 /tmp/spaces/archive.tar.gz"], sizes: ["/tmp/spaces/archive.tar.gz": 12_400_000])

        XCTAssertEqual(
            result.progress, DaemonSelfUpdateProgress(targetVersion: "0.24.0", step: .downloading, receivedBytes: 12_400_000, totalBytes: 38_000_000))
        XCTAssertFalse(result.isRunSpent)
    }

    func testDownloadingWithNoSizeInTheManifestHasNoTotal() {
        let result = derive([prefix + "step downloading - /tmp/a.tar.gz"], sizes: ["/tmp/a.tar.gz": 5])

        XCTAssertEqual(result.progress?.receivedBytes, 5)
        XCTAssertNil(result.progress?.totalBytes)
    }

    func testDownloadingBeforeTheArchiveExistsReportsZeroReceived() {
        let result = derive([prefix + "step downloading 100 /tmp/missing.tar.gz"])

        XCTAssertEqual(result.progress?.receivedBytes, 0)
        XCTAssertEqual(result.progress?.totalBytes, 100)
    }

    func testArchivePathMayContainSpaces() {
        let result = derive([prefix + "step downloading 100 /tmp/my dir/a.tar.gz"], sizes: ["/tmp/my dir/a.tar.gz": 40])

        XCTAssertEqual(result.progress?.receivedBytes, 40)
    }

    func testInstallingAndRestartingFollowTheLastStepLine() {
        XCTAssertEqual(derive([prefix + "step downloading 1 /a", prefix + "step installing"]).progress?.step, .installing)
        XCTAssertEqual(derive([prefix + "step installing", prefix + "step restarting"]).progress?.step, .restarting)
    }

    func testALaunchedRunThatHasPrintedNothingReadsAsStartingTheDownload() {
        let result = derive([])

        XCTAssertEqual(result.progress, DaemonSelfUpdateProgress(targetVersion: "0.24.0", step: .downloading, receivedBytes: 0, totalBytes: nil))
    }

    func testCleanExitReportsNothingAndLeavesTheRunUnspent() {
        let result = derive([prefix + "step installing", prefix + "step exited 0"])

        XCTAssertNil(result.progress)
        XCTAssertFalse(result.isRunSpent)
    }

    func testFailedExitUsesTheLastInstallerMessageAsASentence() {
        let result = derive([
            prefix + "step downloading 100 /a", prefix + "signature verification failed", prefix + "no data arrived for 60 seconds.",
            prefix + "step exited 1",
        ])

        XCTAssertEqual(result.progress?.step, .failed)
        XCTAssertEqual(result.progress?.failureReason, "No data arrived for 60 seconds.")
        XCTAssertNil(result.progress?.receivedBytes)
    }

    func testFailedExitInTheBundledInstallScriptUsesItsUnprefixedMessage() {
        let result = derive([
            prefix + "step installing", prefix + "installing Spaces daemon 0.24.0 (linux x86_64)...",
            "spacesd did not accept the staged handoff; leaving the running daemon and its sessions untouched", prefix + "step exited 1",
        ])

        XCTAssertEqual(
            result.progress?.failureReason, "Spacesd did not accept the staged handoff; leaving the running daemon and its sessions untouched")
    }

    func testAMessageBeforeTheLastStepIsNotTheReason() {
        let result = derive([prefix + "informational line", prefix + "step installing", prefix + "step exited 3"])

        XCTAssertEqual(result.progress?.failureReason, "The installer exited with status 3.")
    }

    func testFailedExitWithoutAMessageNamesTheStatus() {
        let result = derive([prefix + "step installing", prefix + "step exited 7"])

        XCTAssertEqual(result.progress?.failureReason, "The installer exited with status 7.")
    }

    func testLinesWithoutThePrefixAreIgnored() {
        let result = derive(["curl: (28) timeout", prefix + "step installing", "noise"])

        XCTAssertEqual(result.progress?.step, .installing)
    }

    func testRunningVersionAtTheTargetSpendsTheRun() {
        for running in ["0.24.0", "0.25.0"] {
            let result = derive([prefix + "step restarting"], running: running)

            XCTAssertNil(result.progress)
            XCTAssertTrue(result.isRunSpent)
        }
    }

    func testRecoveryFailsARunThatNeverWroteExitedWhenNoRunnerIsAlive() {
        let progress = DaemonSelfUpdateProgressDerivation.recoveredProgress(
            logText: prefix + "step installing\n", targetVersion: "0.24.0", runningVersion: "0.23.0", runnerUnitIsActive: false)

        XCTAssertEqual(progress?.step, .failed)
        XCTAssertEqual(progress?.failureReason, "The update stopped before it finished.")
        XCTAssertEqual(progress?.targetVersion, "0.24.0")
    }

    func testRecoveryLeavesALiveRunnerAlone() {
        XCTAssertNil(
            DaemonSelfUpdateProgressDerivation.recoveredProgress(
                logText: prefix + "step installing\n", targetVersion: "0.24.0", runningVersion: "0.23.0", runnerUnitIsActive: true))
    }

    func testRecoveryLeavesAFinishedRunToItsExitLine() {
        XCTAssertNil(
            DaemonSelfUpdateProgressDerivation.recoveredProgress(
                logText: prefix + "step exited 1\n", targetVersion: "0.24.0", runningVersion: "0.23.0", runnerUnitIsActive: false))
    }

    func testRecoveryIgnoresARunWhoseTargetIsAlreadyRunning() {
        XCTAssertNil(
            DaemonSelfUpdateProgressDerivation.recoveredProgress(
                logText: prefix + "step restarting\n", targetVersion: "0.24.0", runningVersion: "0.24.0", runnerUnitIsActive: false))
    }
}
