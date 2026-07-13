import XCTest

@testable import spacesterminalcore

/// Unit coverage for the exec-in-place handoff decisions the daemon seam makes. The decisions live
/// as pure functions in `DaemonHandoffDecision` (rather than on the private `SpacesDaemonController`,
/// whose executable target is not importable) precisely so they can be exercised here without a live
/// PTY, GhosttyKit, or a running daemon.
final class DaemonHandoffDecisionTests: XCTestCase {
    // MARK: - Generation guard

    func testGenerationGuardProceedsOnFreshBoot() {
        // No table was consumed: generation 0, no recorded source version.
        XCTAssertFalse(DaemonHandoffDecision.refusesExecByGenerationGuard(generation: 0, lastSourceVersion: nil, currentVersion: "0.2.0"))
    }

    func testGenerationGuardProceedsBelowThreshold() {
        // Same version landed on twice — still under the third-consecutive threshold.
        XCTAssertFalse(DaemonHandoffDecision.refusesExecByGenerationGuard(generation: 2, lastSourceVersion: "0.2.0", currentVersion: "0.2.0"))
    }

    func testGenerationGuardRefusesAtAndAboveThresholdOnSameVersion() {
        XCTAssertTrue(DaemonHandoffDecision.refusesExecByGenerationGuard(generation: 3, lastSourceVersion: "0.2.0", currentVersion: "0.2.0"))
        XCTAssertTrue(DaemonHandoffDecision.refusesExecByGenerationGuard(generation: 5, lastSourceVersion: "0.2.0", currentVersion: "0.2.0"))
    }

    func testGenerationGuardProceedsWhenVersionChangedEvenPastThreshold() {
        // A version change breaks the loop: high generation but a different source version proceeds.
        XCTAssertFalse(DaemonHandoffDecision.refusesExecByGenerationGuard(generation: 5, lastSourceVersion: "0.1.0", currentVersion: "0.2.0"))
        XCTAssertFalse(DaemonHandoffDecision.refusesExecByGenerationGuard(generation: 5, lastSourceVersion: nil, currentVersion: "0.2.0"))
    }

    // MARK: - Resume-record selection

    func testResumeAdoptsLiveSessionWithValidDescriptor() {
        XCTAssertEqual(DaemonHandoffDecision.resumeAction(descriptorLooksLikePTYMaster: true, childIsAlive: true), .adopt)
    }

    func testResumeFinalizesExitedWhenChildDeadButDescriptorValid() {
        XCTAssertEqual(DaemonHandoffDecision.resumeAction(descriptorLooksLikePTYMaster: true, childIsAlive: false), .finalizeExited)
    }

    func testResumeDiscardsWhenDescriptorInvalidRegardlessOfChild() {
        XCTAssertEqual(DaemonHandoffDecision.resumeAction(descriptorLooksLikePTYMaster: false, childIsAlive: true), .discardInvalidDescriptor)
        XCTAssertEqual(DaemonHandoffDecision.resumeAction(descriptorLooksLikePTYMaster: false, childIsAlive: false), .discardInvalidDescriptor)
    }
}
