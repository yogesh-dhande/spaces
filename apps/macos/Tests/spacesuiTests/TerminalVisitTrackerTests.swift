import Foundation
import Testing
import spacesdevicecore
import spacestestsupport
import workspacecore

@testable import spacesui

/// A visit is a terminal's pane holding focus while Spaces is frontmost. These drive the tracker with a
/// manual clock and scheduler, so the 2 second dwell is exercised without waiting.
@MainActor @Suite struct TerminalVisitTrackerTests {
    typealias Terminal = TerminalVisitTracker.FocusedTerminal
    typealias Clearables = TerminalVisitTracker.Clearables

    private let terminalA = Terminal(deviceID: "mac", sessionID: "session-a")
    private let terminalB = Terminal(deviceID: "mac", sessionID: "session-b")

    @MainActor final class Harness {
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        var clearables: [Terminal: Clearables] = [:]
        var sent: [(terminal: Terminal, focusedFor: TimeInterval, keys: Set<String>)] = []
        var deviceTakesReports = true
        /// When set, a report waits here until `releaseReport()`, so a test can hold one in flight.
        var holdsReports = false
        private var heldReports: [CheckedContinuation<Void, Never>] = []
        private var scheduled: [(id: Int, fireAt: Date, work: @MainActor () -> Void)] = []
        private var nextID = 0
        var scheduledCount: Int { scheduled.count }
        var tracker: TerminalVisitTracker!
        /// What the app reports as focused when a report is due; follows `update` unless a test moves
        /// focus without telling the tracker.
        var focusedNow: Terminal?

        func update(focus: Terminal?, isActive: Bool) {
            focusedNow = isActive ? focus : nil
            tracker.update(focus: focus, isActive: isActive)
        }

        init() {
            tracker = TerminalVisitTracker(
                now: { [unowned self] in now },
                schedule: { [unowned self] delay, work in
                    let id = nextID
                    nextID += 1
                    scheduled.append((id, now.addingTimeInterval(delay), work))
                    return { [weak self] in self?.scheduled.removeAll { $0.id == id } }
                },
                clearables: { [unowned self] in clearables[$0] ?? Clearables() },
                currentFocus: { [unowned self] in focusedNow },
                sendVisit: { [unowned self] terminal, focusedFor, keys in
                    sent.append((terminal, focusedFor, keys))
                    if holdsReports { await withCheckedContinuation { heldReports.append($0) } }
                    return deviceTakesReports
                })
        }

        /// Moves time forward, firing whatever comes due in order, and lets the report tasks finish.
        func advance(by seconds: TimeInterval) async {
            let target = now.addingTimeInterval(seconds)
            while let next = scheduled.filter({ $0.fireAt <= target }).min(by: { $0.fireAt < $1.fireAt }) {
                scheduled.removeAll { $0.id == next.id }
                now = max(now, next.fireAt)
                next.work()
                await settle()
            }
            now = target
        }

        func releaseReport() async {
            let held = heldReports
            heldReports = []
            for continuation in held { continuation.resume() }
            await settle()
        }

        func settle() async { for _ in 0..<20 { await Task.yield() } }
    }

    @Test func aTerminalFocusedForTheDwellReportsWhatAVisitClears() async {
        let harness = Harness()
        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1"])
        harness.update(focus: terminalA, isActive: true)

        await harness.advance(by: 1.9)
        #expect(harness.sent.isEmpty)
        await harness.advance(by: 0.1)
        #expect(harness.sent.count == 1)
        #expect(harness.sent.first?.terminal == terminalA)
        #expect(harness.sent.first?.focusedFor == 2)
    }

    @Test func aVisitWithNothingToClearSendsNothing() async {
        let harness = Harness()
        harness.update(focus: terminalA, isActive: true)
        #expect(harness.scheduledCount == 0)
        await harness.advance(by: 30)
        #expect(harness.sent.isEmpty)
    }

    @Test func leavingTheTerminalCancelsThePendingVisit() async {
        let harness = Harness()
        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 1.5)
        harness.update(focus: nil, isActive: true)
        await harness.advance(by: 10)
        #expect(harness.sent.isEmpty)
    }

    @Test func spacesResigningActiveCancelsAndReturningRestartsTheDwell() async {
        let harness = Harness()
        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 1.5)
        harness.update(focus: terminalA, isActive: false)
        await harness.advance(by: 10)
        #expect(harness.sent.isEmpty)

        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 1.9)
        #expect(harness.sent.isEmpty, "the earlier stretch of focus does not count")
        await harness.advance(by: 0.1)
        #expect(harness.sent.count == 1)
        #expect(harness.sent.first?.focusedFor == 2)
    }

    @Test func focusingAnotherTerminalStartsThatTerminalsOwnDwell() async {
        let harness = Harness()
        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1"])
        harness.clearables[terminalB] = Clearables(alertKeys: ["agent:b:done:t1"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 1.5)
        harness.update(focus: terminalB, isActive: true)
        await harness.advance(by: 1.9)
        #expect(harness.sent.isEmpty)
        await harness.advance(by: 0.1)
        #expect(harness.sent.map(\.terminal) == [terminalB])
    }

    @Test func anAlertArrivingWhileWatchedIsReportedTwoSecondsLaterWithTheFullFocusDuration() async {
        let harness = Harness()
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 10)
        #expect(harness.sent.isEmpty)

        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t2"])
        harness.tracker.reconcile()
        await harness.advance(by: 1.9)
        #expect(harness.sent.isEmpty)
        await harness.advance(by: 0.1)
        #expect(harness.sent.count == 1)
        #expect(harness.sent.first?.focusedFor == 12, "counted from the visit's start, not from the alert")
    }

    @Test func aMarkSetDuringTheVisitIsNeverReportedButOneThatPredatedItIs() async {
        let harness = Harness()
        harness.clearables[terminalA] = Clearables(flagKeys: ["comebacklater:agent:old"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 2)
        #expect(harness.sent.count == 1)

        harness.clearables[terminalA] = Clearables(flagKeys: ["comebacklater:agent:old", "comebacklater:agent:new"])
        harness.tracker.reconcile()
        await harness.advance(by: 30)
        #expect(harness.sent.count == 1, "the mark set while watching stays until the user leaves and returns")
    }

    @Test func aMarkRemovedAndSetAgainDuringTheVisitIsNotReported() async {
        let harness = Harness()
        harness.clearables[terminalA] = Clearables(flagKeys: ["comebacklater:agent:old"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 1)

        harness.clearables[terminalA] = Clearables()
        harness.tracker.reconcile()
        harness.clearables[terminalA] = Clearables(flagKeys: ["comebacklater:agent:old"])
        harness.tracker.reconcile()
        await harness.advance(by: 30)
        #expect(harness.sent.isEmpty, "a mark the visit saw disappear is a new mark")
    }

    @Test func focusLeavingTheTerminalWithoutAnUpdateEndsTheVisitBeforeItsReport() async {
        let harness = Harness()
        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 1.5)

        harness.focusedNow = nil
        await harness.advance(by: 10)
        #expect(harness.sent.isEmpty)

        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 2)
        #expect(harness.sent.count == 1, "returning starts a fresh visit")
        #expect(harness.sent.first?.focusedFor == 2)
    }

    @Test func aReportInFlightHoldsBackTheNextForTheSameSession() async {
        let harness = Harness()
        harness.holdsReports = true
        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 2)
        #expect(harness.sent.count == 1)

        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1", "agent:a:done:t2"])
        harness.tracker.reconcile()
        await harness.advance(by: 10)
        #expect(harness.sent.count == 1, "only one request per session at a time")

        harness.holdsReports = false
        await harness.releaseReport()
        await harness.advance(by: 0)
        #expect(harness.sent.count == 2)
        #expect(harness.sent.last?.focusedFor == 12)
    }

    @Test func aReportNamesOnlyTheKeysWhoseDwellCompleted() async {
        let harness = Harness()
        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 1.75)

        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1", "agent:a:done:t2"])
        harness.tracker.reconcile()
        await harness.advance(by: 0.25)
        #expect(harness.sent.map(\.keys) == [["agent:a:done:t1"]], "the later key has not had its own dwell")

        await harness.advance(by: 1.5)
        #expect(harness.sent.count == 1)
        await harness.advance(by: 0.25)
        #expect(harness.sent.map(\.keys) == [["agent:a:done:t1"], ["agent:a:done:t2"]])
        #expect(abs((harness.sent.last?.focusedFor ?? 0) - 3.75) < 0.001)
    }

    @Test func leavingAndReturningWhileAReportIsInFlightStillReportsTheNewVisit() async {
        let harness = Harness()
        harness.holdsReports = true
        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 2)
        #expect(harness.sent.count == 1)

        harness.update(focus: nil, isActive: true)
        await harness.advance(by: 1)
        harness.update(focus: terminalA, isActive: true)
        harness.holdsReports = false
        await harness.releaseReport()
        await harness.advance(by: 2)

        #expect(harness.sent.count == 2, "the new visit schedules once the slot is free, without another overview")
        #expect(harness.sent.last?.focusedFor == 2)
    }

    @Test func aReportTheDeviceDidNotTakeIsNotRetriedOnATimerButByTheNextOverview() async {
        let harness = Harness()
        harness.deviceTakesReports = false
        harness.clearables[terminalA] = Clearables(alertKeys: ["agent:a:done:t1"])
        harness.update(focus: terminalA, isActive: true)
        await harness.advance(by: 2)
        await harness.advance(by: 30)
        #expect(harness.sent.count == 1)

        harness.deviceTakesReports = true
        harness.tracker.reconcile()
        await harness.advance(by: 0)
        #expect(harness.sent.count == 2)
    }

    // MARK: - What a visit clears, read from an overview

    @Test func clearablesAreTheUndismissedFinishedWorkAndMarksOfTheSession() {
        let agentRows = [
            SpacesDeviceWorkspaceCodingAgentRow(
                id: "a-done", workspaceID: "w1", name: "a", command: "claude", agentID: "a-done", sessionID: "s1", runState: .running,
                activityState: .done, updatedAt: "2026-07-14T09:00:00Z", brief: nil, briefUpdatedAt: nil, canStop: true),
            SpacesDeviceWorkspaceCodingAgentRow(
                id: "a-wait", workspaceID: "w1", name: "b", command: "claude", agentID: "a-wait", sessionID: "s1", runState: .running,
                activityState: .waiting, updatedAt: "2026-07-14T09:01:00Z", brief: nil, briefUpdatedAt: nil, canStop: true),
            SpacesDeviceWorkspaceCodingAgentRow(
                id: "a-other", workspaceID: "w1", name: "c", command: "claude", agentID: "a-other", sessionID: "s2", runState: .running,
                activityState: .done, updatedAt: "2026-07-14T09:02:00Z", brief: nil, briefUpdatedAt: nil, canStop: true),
        ]
        let workspace = SpacesDeviceWorkspaceSummary(
            id: "w1", projectID: "p", projectName: "P", branch: "main", baseBranch: nil, dir: "/tmp/w1", isRunning: true, isHidden: false,
            isDefault: false, hasTrackedRuntimeIndicators: false, codingAgentRows: agentRows)
        let flag = SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "a-wait", flaggedAt: "2026-07-14T09:30:00Z")

        let live = SpacesDeviceOverviewPayload(workspaces: [workspace], sessions: [], comeBackLaterFlags: [flag])
        let found = TerminalVisitTracker.clearables(overview: live, sessionID: "s1")
        #expect(found.alertKeys == ["agent:a-done:done:2026-07-14T09:00:00Z"], "a waiting agent needs an answer, not a look")
        #expect(found.flagKeys == [flag.alertKey])

        let dismissed = SpacesDeviceOverviewPayload(
            workspaces: [workspace], sessions: [], dismissedAlertKeys: ["agent:a-done:done:2026-07-14T09:00:00Z"])
        #expect(TerminalVisitTracker.clearables(overview: dismissed, sessionID: "s1").alertKeys.isEmpty)
    }
}
