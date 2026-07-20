import Foundation
import XCTest
import spacesdevicecore
import workspacecore

@testable import spacesdeviceapi

/// Coverage for the automation section of the Device API overview: the run-selection contract (all active
/// runs plus the newest terminal runs, de-duplicated, newest first) and the boundary error classification
/// the remote automation handlers rely on. Both are pure/static, so no running server or store is needed.
final class AutomationOverviewTests: XCTestCase {
    private func run(id: String, status: AutomationRunStatus, createdAt: TimeInterval, automationID: String = "auto") -> AutomationRun {
        AutomationRun(
            id: id, automationID: automationID, status: status, skipReason: nil, trigger: .cron, exitCode: status == .failed ? 1 : nil,
            terminalSessionID: nil, startedAt: status.isTerminal ? nil : Date(timeIntervalSince1970: createdAt), endedAt: nil,
            createdAt: Date(timeIntervalSince1970: createdAt))
    }

    func testSelectionIncludesActiveRunsBeyondRecentWindow() {
        // Recent terminal window (already limited by the caller's query) that does not contain the active
        // run: the active run must still appear so a live run is never dropped by the cap.
        let recentTerminal = [run(id: "t1", status: .succeeded, createdAt: 300), run(id: "t2", status: .failed, createdAt: 200)]
        let active = [run(id: "a1", status: .running, createdAt: 100)]
        let selected = SpacesDeviceOverviewBuilder.selectOverviewRuns(recentTerminal: recentTerminal, latestPerAutomation: [], active: active)
        XCTAssertTrue(selected.contains { $0.id == "a1" }, "an active run outside the recent window is still included")
        XCTAssertEqual(selected.count, 3)
    }

    func testSelectionIncludesLatestPerAutomationBeyondRecentWindow() {
        // The recent window is filled entirely by one chatty automation; a quiet automation's last terminal
        // run is outside that window but must still appear so its last-run status is never lost.
        let recentTerminal = [
            run(id: "chatty1", status: .succeeded, createdAt: 300, automationID: "chatty"),
            run(id: "chatty2", status: .succeeded, createdAt: 250, automationID: "chatty"),
        ]
        let latestPerAutomation = [
            run(id: "chatty1", status: .succeeded, createdAt: 300, automationID: "chatty"),
            run(id: "quiet1", status: .failed, createdAt: 50, automationID: "quiet"),
        ]
        let selected = SpacesDeviceOverviewBuilder.selectOverviewRuns(
            recentTerminal: recentTerminal, latestPerAutomation: latestPerAutomation, active: [])
        XCTAssertTrue(selected.contains { $0.id == "quiet1" }, "a quiet automation's latest terminal run survives the recent-window cap")
        XCTAssertEqual(selected.map(\.id), ["chatty1", "chatty2", "quiet1"], "deduplicated across all three inputs, newest first")
    }

    func testSelectionIsNewestFirstAndDeduplicated() {
        // An active run that is also present in the recent window must not be duplicated, and the result is
        // ordered newest-first by creation time.
        let shared = run(id: "shared", status: .running, createdAt: 250)
        let recentTerminal = [run(id: "t1", status: .succeeded, createdAt: 300), shared]
        let active = [shared]
        let selected = SpacesDeviceOverviewBuilder.selectOverviewRuns(recentTerminal: recentTerminal, latestPerAutomation: [], active: active)
        XCTAssertEqual(selected.map(\.id), ["t1", "shared"], "deduplicated and newest-first")
    }

    func testFailedAndTimedOutRunsAreIdentifiableForAlerts() {
        let recentTerminal = [
            run(id: "ok", status: .succeeded, createdAt: 300), run(id: "bad", status: .failed, createdAt: 200),
            run(id: "slow", status: .timedOut, createdAt: 100),
        ]
        let selected = SpacesDeviceOverviewBuilder.selectOverviewRuns(recentTerminal: recentTerminal, latestPerAutomation: [], active: [])
        let alertable = selected.filter { $0.status == .failed || $0.status == .timedOut }.map(\.id)
        XCTAssertEqual(Set(alertable), ["bad", "slow"], "recent failed/timed-out runs survive selection so clients can derive alerts")
    }

    func testValidationErrorsMapToInvalidArgument() {
        XCTAssertEqual(SpacesDeviceAPIServer.errorCode(for: AutomationValidationError("bad")), .invalidArgument)
        XCTAssertEqual(SpacesDeviceAPIServer.errorCode(for: AutomationCronScheduleError("bad cron")), .invalidArgument)
    }
}
