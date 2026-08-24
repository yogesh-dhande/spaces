import XCTest
import spacesterminalcore

@testable import workspacecore

#if canImport(Darwin)
    import Darwin
#endif

/// Behavior coverage for the scheduled-automation scheduler and executor: the concurrency policy matrix,
/// missed-run catch-up on daemon start, the ended-only attributed-session sweep, run-history retention, and
/// the executor's real exit-code/timeout/cancel handling. Session launches route through a process-wide
/// fake terminal host so no real daemon or Ghostty PTY is needed. Exit-code tests run short shell commands
/// through that host; process-lifecycle tests use directly waitable process-group fixtures so their signal
/// assertions do not depend on shell job control or process reparenting.
@MainActor final class AutomationServiceTests: XCTestCase {
    // MARK: - Concurrency policy matrix

    func testAllowPolicyStartsConcurrentRuns() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        _ = harness.service.triggerManually(automationID: automation.id)
        _ = harness.service.triggerManually(automationID: automation.id)
        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.filter { $0.status == .running }.count, 2, "allow always starts a new run")
    }

    func testSkipPolicySkipsWhileRunning() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .skip)
        _ = harness.service.triggerManually(automationID: automation.id)
        let second = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(second.status, .skipped)
        XCTAssertEqual(second.skipReason, .concurrency)
        XCTAssertEqual(try harness.store.automationRuns(automationID: automation.id).filter { $0.status == .running }.count, 1)
    }

    func testSkipPolicyRunsWhenIdle() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .skip)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(run.status, .running)
    }

    func testQueuePolicyCoalescesToOnePendingRun() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .queue)
        _ = harness.service.triggerManually(automationID: automation.id)  // running
        let queued = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(queued.status, .queued)
        let overflow = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(overflow.status, .skipped, "a second fire while one run is queued is skipped")
        XCTAssertEqual(overflow.skipReason, .concurrency)
        XCTAssertEqual(try harness.store.activeAutomationRuns(automationID: automation.id).filter { $0.status == .queued }.count, 1)
    }

    func testQueuedRunPromotedWhenRunningCompletes() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .queue)
        let first = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let queued = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(queued.status, .queued)

        // Simulate the running command ending, then let the scheduler poll observe it and promote.
        let firstSessionID = try XCTUnwrap(harness.store.automationRun(id: first.id)?.terminalSessionID)
        harness.host.markSessionEnded(sessionID: firstSessionID)
        harness.service.tick()

        XCTAssertTrue(try XCTUnwrap(harness.store.automationRun(id: first.id)).status.isTerminal)
        XCTAssertEqual(try harness.store.automationRun(id: queued.id)?.status, .running, "the queued run executes once the current one finishes")
    }

    func testQueuePolicyWaitsForPendingTerminationBeforePromoting() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let fixture = try AutomationProcessGroupFixture()
        defer { fixture.terminateAndReap() }
        let automation = try harness.insertAutomation(script: "sleep 60", concurrency: .queue)
        let first = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let queued = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(first.terminalSessionID)
        try harness.setRuntimeChildPID(sessionID: sessionID, childPID: fixture.leaderPID)

        harness.service.cancelRun(runID: first.id)
        harness.service.tick()

        XCTAssertTrue(harness.processIsRunning(fixture.survivorPID), "the predecessor is still alive during its termination grace")
        XCTAssertEqual(
            try harness.store.automationRun(id: queued.id)?.status, .queued,
            "queue concurrency includes a predecessor whose SIGKILL escalation is still pending")
    }

    /// A tick admitted while ticks are suspended (the daemon sets this during an exec handoff) must be a
    /// complete no-op — firing against quiesced cores would misread preserved sessions as dead — and the
    /// suspended occurrence fires normally on the first tick after suspension lifts.
    func testTickIsANoOpWhileTicksAreSuspended() throws {
        final class SuspendFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = true
            var isSuspended: Bool {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            func lift() {
                lock.lock()
                value = false
                lock.unlock()
            }
        }
        let flag = SuspendFlag()
        let harness = try Harness(self, ticksSuspended: { flag.isSuspended })
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", nextFireTime: harness.now().addingTimeInterval(-60))
        harness.service.tick()
        XCTAssertTrue(try harness.store.automationRuns(automationID: automation.id).isEmpty, "a suspended tick must not fire, poll, or promote")
        flag.lift()
        harness.service.tick()
        XCTAssertEqual(try harness.store.automationRuns(automationID: automation.id).count, 1, "the due occurrence fires once suspension lifts")
    }

    // MARK: - Missed-run catch-up

    /// Startup reconciliation can already be queued when daemon shutdown begins. Once teardown latches,
    /// that queued pass must leave the overdue occurrence untouched so the next daemon can catch it up.
    func testMissedRunReconciliationIsANoOpWhileTicksAreSuspended() throws {
        let harness = try Harness(self, ticksSuspended: { true })
        let overdue = harness.now().addingTimeInterval(-3 * 24 * 60 * 60)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .runOnce, nextFireTime: overdue)
        let persistedOverdue = try harness.store.automation(id: automation.id)?.nextFireTime

        harness.service.reconcileMissedRunsOnStart()

        XCTAssertTrue(try harness.store.automationRuns(automationID: automation.id).isEmpty)
        XCTAssertEqual(try harness.store.automation(id: automation.id)?.nextFireTime, persistedOverdue)
    }

    func testMissedRunOnceFiresExactlyOnce() throws {
        let harness = try Harness(self)
        // A once-a-minute cron whose next fire time is days in the past: many occurrences were missed.
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .runOnce,
            nextFireTime: harness.now().addingTimeInterval(-3 * 24 * 60 * 60))
        harness.service.reconcileMissedRunsOnStart()
        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.count, 1, "run_once fires exactly one catch-up run regardless of occurrences missed")
        XCTAssertEqual(runs.first?.trigger, .missedCatchUp)
        XCTAssertNotNil(try harness.store.automation(id: automation.id)?.nextFireTime, "the next fire time is recomputed from now")
    }

    func testMissedSkipRecordsOneSkippedRow() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .skip, nextFireTime: harness.now().addingTimeInterval(-3 * 24 * 60 * 60)
        )
        harness.service.reconcileMissedRunsOnStart()
        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .skipped)
        XCTAssertEqual(runs.first?.skipReason, .missed)
    }

    func testFutureNextFireTimeIsNotCaughtUp() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .runOnce, nextFireTime: harness.now().addingTimeInterval(60 * 60))
        harness.service.reconcileMissedRunsOnStart()
        XCTAssertTrue(try harness.store.automationRuns(automationID: automation.id).isEmpty)
    }

    /// A stale `running` run row left by the previous daemon lifetime — its command finished (or died with
    /// the daemon) while the daemon was down, so its session is dead — must not suppress a `runOnce` catch-up.
    /// Reconciliation polls the stale row to its real terminal state before the concurrency gate evaluates the
    /// catch-up, so the catch-up starts a real run instead of being recorded concurrency-skipped and then lost
    /// forever when the cron anchor advances.
    func testStaleRunningRunDoesNotSuppressMissedCatchUp() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", concurrency: .skip, missedRunPolicy: .runOnce,
            nextFireTime: harness.now().addingTimeInterval(-3 * 24 * 60 * 60))

        // A run row still `running` from the previous daemon lifetime, pointing at a now-dead session (the
        // daemon's stale-session recovery already flipped it to a non-interactive `.exited` state on start).
        let staleSessionID = UUID().uuidString
        let staleStart = harness.now().addingTimeInterval(-4 * 24 * 60 * 60)
        let staleRun = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .script, status: .running, skipReason: nil, trigger: .cron, exitCode: nil,
            terminalSessionID: staleSessionID, startedAt: staleStart, endedAt: nil, createdAt: staleStart)
        try harness.store.insertAutomationRun(staleRun)
        try harness.writeAttributedSessionFiles(
            workspaceID: automation.workspaceID, runID: staleRun.id, sessionID: staleSessionID, kind: .automation, live: false)

        harness.service.reconcileMissedRunsOnStart()

        XCTAssertTrue(
            try XCTUnwrap(harness.store.automationRun(id: staleRun.id)).status.isTerminal,
            "the stale running row is reconciled to its real terminal state before the catch-up fires")
        let catchUp = try XCTUnwrap(
            harness.store.automationRuns(automationID: automation.id).first { $0.trigger == .missedCatchUp }, "a catch-up run is recorded")
        XCTAssertEqual(catchUp.status, .running, "the catch-up starts a real run rather than being concurrency-skipped")
        XCTAssertNil(catchUp.skipReason)
    }

    // MARK: - Overview recent-run window

    /// The overview's recent-run window (`terminalAutomationRuns`) counts only terminal runs, so a burst of
    /// active (queued/running) runs — always the newest rows — can never crowd completed history out of the
    /// newest-N window. The overview unions the active runs back in separately, so they are never lost.
    func testTerminalRunWindowExcludesActiveRunsAndCapsToLimit() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Ten active runs, all newer than every terminal run: if they counted against the window they would
        // fill it and starve the completed history.
        for offset in 0..<10 {
            _ = try harness.insertRun(automationID: automation.id, status: .running, createdAt: base.addingTimeInterval(Double(1_000 + offset)))
        }
        // Six older terminal runs; the window is capped below that so the cap is exercised too.
        var terminalIDs: [String] = []
        for offset in 0..<6 {
            let run = try harness.insertRun(automationID: automation.id, status: .succeeded, createdAt: base.addingTimeInterval(Double(offset)))
            terminalIDs.append(run.id)
        }

        let window = try harness.store.terminalAutomationRuns(limit: 5)
        XCTAssertEqual(window.count, 5, "the window is capped at the limit")
        XCTAssertTrue(window.allSatisfy { $0.status.isTerminal }, "no active run consumes the window")
        // Newest-first: the five newest terminal runs (offsets 5..1), not the oldest (offset 0).
        XCTAssertEqual(window.map(\.id), Array(terminalIDs.reversed().prefix(5)))
    }

    // MARK: - Time-zone changes

    /// A device carried into a new time zone recomputes its cron anchors: a daily schedule keeps firing at
    /// the same wall-clock hour in the new zone, without waiting for a daemon restart. The provider closure
    /// models the device's current zone; a tick after it changes triggers the recompute.
    func testCronAnchorsRecomputeWhenDeviceTimeZoneChanges() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let zone = MutableTimeZone(newYork)
        // A fixed winter instant so both zones are on standard time (no DST ambiguity), ~2024-01-15.
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_705_341_600))
        let harness = try Harness(self, now: clock.now, timeZone: zone.provide)

        // Daily at 09:00 local; the initial anchor is computed in New_York.
        let automation = try harness.insertAutomation(triggerKind: .cron, cronExpression: "0 9 * * *")
        try harness.service.computeInitialNextFireTime(automationID: automation.id)
        harness.service.tick()  // zone unchanged: the anchor stays in New_York
        let nyFire = try XCTUnwrap(harness.store.automation(id: automation.id)?.nextFireTime)
        XCTAssertEqual(hour(of: nyFire, in: newYork), 9, "the anchor fires at 09:00 New_York wall-clock")

        // The device moves to Los Angeles; the next tick recomputes the anchor in the new zone.
        zone.set(losAngeles)
        harness.service.tick()
        let laFire = try XCTUnwrap(harness.store.automation(id: automation.id)?.nextFireTime)
        XCTAssertNotEqual(laFire, nyFire, "an absolute anchor moves when the zone changes")
        XCTAssertEqual(hour(of: laFire, in: losAngeles), 9, "the anchor now fires at 09:00 Los_Angeles wall-clock")
    }

    /// A zone change while the daemon is down must reinterpret the persisted next occurrence at the same
    /// wall-clock time in the new zone before deciding whether it was missed. LA's pending 09:00 is still
    /// in the future at 10:00 New York as an absolute instant, but New York's 09:00 occurrence has elapsed.
    func testOfflineTimeZoneChangeAppliesMissedRunPolicyToCurrentZoneOccurrence() throws {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let newYork = TimeZone(identifier: "America/New_York")!
        let zone = MutableTimeZone(losAngeles)
        // 2026-01-15 08:00 Los Angeles / 11:00 New York.
        let clock = MutableClock(start: ISO8601DateFormatter().date(from: "2026-01-15T16:00:00Z")!)
        let harness = try Harness(self, now: clock.now, timeZone: zone.provide)
        let automation = try harness.insertAutomation(triggerKind: .cron, cronExpression: "0 9 * * *", missedRunPolicy: .runOnce)
        try harness.service.computeInitialNextFireTime(automationID: automation.id)
        XCTAssertEqual(
            try XCTUnwrap(harness.store.automation(id: automation.id)?.nextFireTime), ISO8601DateFormatter().date(from: "2026-01-15T17:00:00Z"))

        // The daemon is stopped during the move, then starts at 10:00 New York. The same local-date 09:00
        // occurrence is 14:00Z in New York and therefore needs one catch-up even though 17:00Z is future.
        zone.set(newYork)
        clock.advance(by: -60 * 60)
        harness.makeService().reconcileMissedRunsOnStart()

        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.trigger, .missedCatchUp)
    }

    private func hour(of date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.hour, from: date)
    }

    // MARK: - Attributed-session sweep

    /// The sweep finalizes an ended attributed session's orchestration state but never removes the session
    /// itself: its run is still listed in the Runs tab and replays that session's transcript, so the row and
    /// the on-disk directory have to outlive the sweep and survive until the run is pruned.
    func testSweepFinalizesEndedAttributedSessionAndKeepsLiveOne() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAutomation(concurrency: .allow)

        // A completed prior run that spawned two coding-agent sessions: one ended, one still live.
        let priorRun = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let endedSessionID = UUID().uuidString
        let liveSessionID = UUID().uuidString
        let endedAgent = try harness.writeAttributedAgentSession(
            workspaceID: workspace.id, runID: priorRun.id, sessionID: endedSessionID, live: false)
        _ = try harness.writeAttributedAgentSession(workspaceID: workspace.id, runID: priorRun.id, sessionID: liveSessionID, live: true)
        try harness.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher", agentSessionID: endedAgent.id, createdAt: "t")

        // Starting a new run of the same automation triggers the prior-run sweep.
        _ = harness.service.triggerManually(automationID: automation.id)

        XCTAssertNil(try harness.store.agentWindow(id: endedAgent.id), "the ended attributed agent row is finalized away")
        XCTAssertTrue(
            try harness.store.terminalSessionIDs(automationRunID: priorRun.id).contains(liveSessionID), "the live session survives the sweep")
        XCTAssertTrue(
            try harness.store.terminalSessionIDs(automationRunID: priorRun.id).contains(endedSessionID),
            "the ended session stays attributed to its run so the run's replay still has a source")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try TerminalSessionPaths.forSession(id: endedSessionID).outputPath),
            "the ended session's transcript survives the sweep")
        XCTAssertTrue(
            harness.host.delivered.contains { $0.sessionID == "watcher" && $0.line.contains("exited") }, "the watcher is told the child exited")
    }

    /// A spawned agent session that ended before its agent row was registered still leaves its spawn-time
    /// workspace tracking (a tracked terminal window and the workspace marked running). The sweep must
    /// release that state through the row-less cleanup seam, not just delete the session row and files.
    func testSweepReleasesWorkspaceTrackingForRowlessEndedAgentSession() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAutomation(concurrency: .allow)

        // A completed prior run whose spawned agent session ended before any agent row was created: it has
        // its ended session files plus the spawn-time tracked window and running workspace, but no agent row.
        let priorRun = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let endedSessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(workspaceID: workspace.id, runID: priorRun.id, sessionID: endedSessionID, kind: .agent, live: false)
        try harness.seedSpawnedAgentWorkspaceTracking(workspace: workspace, sessionID: endedSessionID)
        XCTAssertTrue(try XCTUnwrap(harness.store.workspace(id: workspace.id)).isRunning, "the workspace starts running from the spawn")
        XCTAssertTrue(
            try harness.store.windows(workspaceID: workspace.id).contains { $0.terminalTrackingID == endedSessionID },
            "the spawn-time tracked window exists before the sweep")

        // Starting a new run of the same automation triggers the prior-run sweep.
        _ = harness.service.triggerManually(automationID: automation.id)

        XCTAssertTrue(
            try harness.store.terminalSessionIDs(automationRunID: priorRun.id).contains(endedSessionID), "the ended session itself is left replayable"
        )
        XCTAssertFalse(
            try harness.store.windows(workspaceID: workspace.id).contains { $0.terminalTrackingID == endedSessionID },
            "the row-less session's tracked window is released")
        XCTAssertFalse(
            try XCTUnwrap(harness.store.workspace(id: workspace.id)).isRunning, "the workspace is not left running once its only tracked session ends"
        )
    }

    // MARK: - Retention

    /// A finished run's own terminal stays replayable from the Runs tab: neither the run ending nor the next
    /// run's sweep removes it. Retention pruning the run is what finally takes the session with it: row,
    /// attribution, and on-disk directory.
    func testEndedRunSessionSurvivesTheSweepUntilRetentionPrunesItsRun() throws {
        let harness = try Harness(self, retentionLimit: 2)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let priorRun = try harness.insertRun(automationID: automation.id, status: .succeeded, createdAt: harness.now())
        let sessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(
            workspaceID: automation.workspaceID, runID: priorRun.id, sessionID: sessionID, kind: .automation, live: false)
        let rootDirectory = try TerminalSessionPaths.forSession(id: sessionID).rootDirectory
        try harness.store.upsert(
            window: WindowRecord(
                id: "pruned-script-runtime-target", workspaceID: automation.workspaceID, app: TerminalHost.spaces.appName, name: "Test",
                terminalTrackingID: sessionID, role: .terminal, orderIndex: 0, lastSeenAt: "2026-06-06T00:00:00Z"))

        // Starting a new run of the same automation triggers the prior-run sweep.
        _ = harness.service.triggerManually(automationID: automation.id)

        XCTAssertEqual(try harness.store.terminalSessionIDs(automationRunID: priorRun.id), [sessionID], "the ended run's session survives the sweep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootDirectory), "its transcript directory survives the sweep")

        // More newer terminal rows than the cap, then a terminal transition to drive the prune.
        for offset in 1...4 {
            _ = try harness.insertRun(
                automationID: automation.id, status: .skipped, createdAt: harness.now().addingTimeInterval(TimeInterval(offset)))
        }
        let throwaway = try harness.insertRun(automationID: automation.id, status: .running, createdAt: harness.now().addingTimeInterval(100))
        harness.service.cancelRun(runID: throwaway.id)

        XCTAssertNil(try harness.store.automationRun(id: priorRun.id), "the over-cap run is pruned")
        XCTAssertTrue(try harness.store.terminalSessionIDs(automationRunID: priorRun.id).isEmpty, "its session row goes with it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootDirectory), "and so does its transcript directory")
        XCTAssertFalse(
            try harness.store.windows(workspaceID: automation.workspaceID).contains { $0.terminalTrackingID == sessionID },
            "retention uses the same cleanup to remove the pruned script terminal's runtime target")
    }

    func testRetentionPrunesToNewestHundredAndDeletesArtifacts() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        var oldestRunDir: URL?
        for index in 0..<105 {
            let run = try harness.insertRun(
                automationID: automation.id, status: .succeeded, createdAt: harness.now().addingTimeInterval(TimeInterval(index)))
            let directory = try AutomationPaths.ensureRunDirectory(runID: run.id)
            if index == 0 { oldestRunDir = directory }
        }
        // A terminal transition triggers retention: cancel a fresh running run (no session → no teardown).
        let running = try harness.insertRun(automationID: automation.id, status: .running, createdAt: harness.now().addingTimeInterval(1000))
        harness.service.cancelRun(runID: running.id)

        XCTAssertEqual(try harness.store.automationRuns(automationID: automation.id).count, 100, "only the newest 100 runs are kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(oldestRunDir).path), "a pruned run's artifact directory is deleted")
    }

    /// Retention never prunes a run whose attributed agent session is still live: a succeeded agent-kind run
    /// deliberately leaves its agent open, and pruning it would terminate that live agent (the no-kill
    /// guarantee). The run stays retained past the cap until its session ends, after which the next prune
    /// removes it.
    func testRetentionSkipsRunWithLiveAttributedSessionUntilItEnds() throws {
        // A small cap so a handful of newer terminal rows push the live-session run past the window.
        let harness = try Harness(self, retentionLimit: 2)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)

        // The oldest run is a succeeded agent run whose agent session is deliberately left live.
        let liveRun = try harness.insertRun(automationID: automation.id, status: .succeeded, createdAt: harness.now())
        let liveSessionID = UUID().uuidString
        let agent = try harness.writeAttributedAgentSession(
            workspaceID: workspace.id, runID: liveRun.id, sessionID: liveSessionID, live: true, status: .done)
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: liveSessionID))

        // More newer terminal (skipped) rows than the cap, so the live-session run is beyond the newest 2.
        for offset in 1...4 {
            _ = try harness.insertRun(
                automationID: automation.id, status: .skipped, createdAt: harness.now().addingTimeInterval(TimeInterval(offset)))
        }

        // Retention runs on a real terminal transition; cancel a fresh session-less running run to drive one.
        func triggerPrune(at offset: TimeInterval) throws {
            let throwaway = try harness.insertRun(automationID: automation.id, status: .running, createdAt: harness.now().addingTimeInterval(offset))
            harness.service.cancelRun(runID: throwaway.id)
        }

        // The prune leaves the live-session run and its agent: pruning it would kill the live agent.
        try triggerPrune(at: 100)
        XCTAssertNotNil(try harness.store.automationRun(id: liveRun.id), "a run with a live attributed session is retained past the cap")
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: liveSessionID), "its live agent session is never killed by retention")
        XCTAssertNotNil(try harness.store.agentWindow(id: agent.id), "its agent row survives")

        // Once the session ends, the next prune removes the now-prunable run.
        harness.host.markSessionEnded(sessionID: liveSessionID)
        XCTAssertFalse(harness.orchestrator.automationSessionIsLive(sessionID: liveSessionID), "the session is no longer live once ended")
        try triggerPrune(at: 101)
        XCTAssertNil(try harness.store.automationRun(id: liveRun.id), "once its session ends the run is pruned on the next prune")
    }

    // MARK: - Executor exit codes

    func testExecutorRecordsZeroExitAsSucceeded() throws {
        let harness = try Harness(self, realCommands: true)
        let automation = try harness.insertAutomation(script: "exit 0", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let finished = try harness.runUntilTerminal(runID: run.id)
        let sessionID = try XCTUnwrap(finished.terminalSessionID)
        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertEqual(finished.exitCode, 0)
        XCTAssertFalse(
            try harness.store.windows(workspaceID: automation.workspaceID).contains { $0.terminalTrackingID == sessionID },
            "an exited automation disappears from the workspace runtime list")
        XCTAssertEqual(
            try harness.store.terminalSessionIDs(automationRunID: run.id), [sessionID],
            "detaching the live runtime target preserves the Runs-tab replay session")
    }

    func testExecutorRecordsNonZeroExitCode() throws {
        let harness = try Harness(self, realCommands: true)
        let automation = try harness.insertAutomation(script: "exit 3", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let finished = try harness.runUntilTerminal(runID: run.id)
        XCTAssertEqual(finished.status, .failed)
        XCTAssertEqual(finished.exitCode, 3)
    }

    // MARK: - Per-run kind

    /// A run row records its automation's kind at fire time and keeps it even after the automation's kind is
    /// edited (which is only allowed once the run is terminal). This is what lets opening a historical run's
    /// terminal dispatch on the shape the run actually ran with rather than the automation's current kind.
    func testRunKindIsStampedAtFireTimeAndSurvivesAutomationKindEdit() throws {
        let harness = try Harness(self, realCommands: true)
        let automation = try harness.insertAutomation(script: "exit 0", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(run.kind, .script, "the run is stamped with the automation's kind when it fires")
        let finished = try harness.runUntilTerminal(runID: run.id)
        XCTAssertTrue(finished.status.isTerminal)

        // Editing the automation to Agent is allowed only now that the run is terminal; the historical run
        // must keep its original script kind.
        let agentDraft = AutomationDraft(
            name: automation.name, enabled: true, triggerKind: .manual, cronExpression: nil, kind: .agent, script: "", agentCommand: "codex",
            agentPrompt: "investigate", workspaceID: automation.workspaceID, timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce
        )
        let updated = try harness.service.updateAutomation(id: automation.id, draft: agentDraft)
        XCTAssertEqual(updated.kind, .agent)
        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.kind, .script, "the retained run keeps the kind it ran with, not the new one")
    }

    // MARK: - Agent kind execution

    /// Happy path: spawn the agent, wait until it is both detected and reading input, deliver the seed
    /// prompt as one submit-send, persist `promptDeliveredAt` once that write is acknowledged, and complete
    /// `succeeded` on the agent row's `done` signal with the session left open (never killed).
    func testAgentRunSpawnsDetectsDeliversPromptAndSucceedsOnDone() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id, prompt: "investigate the failing test")
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID, "the run records its spawned agent session")

        // Before readiness nothing is delivered.
        harness.service.tick()
        XCTAssertTrue(harness.host.writtenInput.isEmpty, "no prompt is delivered until the agent is ready for it")
        XCTAssertNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt)

        // Readiness → the next tick delivers the prompt as one submit-send and records delivery.
        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.service.tick()
        let writes = harness.host.writtenInput
        XCTAssertEqual(writes.count, 1, "the prompt is delivered as one submit-send")
        XCTAssertEqual(writes.first?.input, .text("investigate the failing test"), "the write is the verbatim prompt text")
        XCTAssertEqual(writes.first?.appendNewline, true, "the send submits (the chokepoint writes the spaced Enter)")
        XCTAssertEqual(writes.map(\.sessionID), [sessionID])
        XCTAssertNotNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt, "delivery is persisted once the write succeeds")

        // A second tick before `done` neither re-sends nor completes the run.
        harness.service.tick()
        XCTAssertEqual(harness.host.writtenInput.count, 1, "a delivered prompt is not re-sent")
        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .running)

        // The agent row signals done → succeeded, and the session is left open.
        _ = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: sessionID, status: .done)
        harness.service.tick()
        let finished = try XCTUnwrap(harness.store.automationRun(id: run.id))
        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertNil(finished.exitCode)
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID), "a done agent's session stays open")
    }

    /// The readiness gate: foreground detection fires on process identity, a second or two before the
    /// agent's TUI has taken the terminal over. A prompt sent in that window lands in a pre-raw-mode buffer
    /// or sits unsubmitted in a composer that was still initializing, so a detected-but-not-yet-reading
    /// agent must not be prompted — and the moment it reports bracketed paste, it is.
    func testAgentRunWaitsForTheDetectedAgentToStartReadingInputBeforeDeliveringThePrompt() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id, prompt: "investigate the failing test")
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        harness.host.markSessionForegroundDetected(sessionID: sessionID, bracketedPasteActive: false)
        harness.service.tick()
        XCTAssertTrue(harness.host.writtenInput.isEmpty, "a detected agent that is not reading input yet must not be prompted")
        XCTAssertNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt)

        harness.host.markSessionForegroundDetected(sessionID: sessionID, bracketedPasteActive: true)
        harness.service.tick()
        XCTAssertEqual(harness.host.writtenInput.count, 1, "the prompt goes out once the agent is reading input")
        XCTAssertEqual(harness.host.writtenInput.first?.input, .text("investigate the failing test"))
        XCTAssertNotNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt)
    }

    /// The write acknowledgement: a send whose bytes never reached the PTY is not a delivery. The run keeps
    /// `promptDeliveredAt` NULL — so it stays in the delivering phase rather than waiting forever on an
    /// agent that was never given work — and the next tick sends again.
    func testAgentRunRetriesPromptDeliveryUntilTheWriteIsAcknowledged() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id, prompt: "investigate the failing test")
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.host.failInputWrites()
        harness.service.tick()
        XCTAssertEqual(harness.host.writtenInput.count, 1, "the prompt is attempted")
        XCTAssertNil(
            try harness.store.automationRun(id: run.id)?.promptDeliveredAt, "an unacknowledged write must not be recorded as a delivered prompt")

        harness.host.acknowledgeInputWrites()
        harness.service.tick()
        XCTAssertEqual(harness.host.writtenInput.count, 2, "the next tick re-sends the prompt")
        XCTAssertNotNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt, "delivery is recorded once the write is acknowledged")

        harness.service.tick()
        XCTAssertEqual(harness.host.writtenInput.count, 2, "a delivered prompt is not re-sent")
    }

    /// Delivery that never lands is a loud failure, not a silent wait: the run fails at the same 90s budget
    /// that bounds readiness, and its session is left running for inspection.
    func testAgentRunFailsWhenPromptDeliveryNeverReachesTheAgent() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.host.failInputWrites()
        harness.service.tick()
        XCTAssertNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt)

        clock.advance(by: 91)
        harness.service.tick()

        let finished = try XCTUnwrap(harness.store.automationRun(id: run.id))
        XCTAssertEqual(finished.status, .failed)
        XCTAssertNil(finished.promptDeliveredAt)
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID), "the session is left running for inspection")
    }

    /// Detection deadline miss: the agent is never classified within the 90s budget, so the run fails but
    /// its session is left running for inspection (mirrors `spaces agent spawn`).
    func testAgentRunFailsOnDetectionDeadlineWithoutKillingSession() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        clock.advance(by: 91)  // past the 90s detection deadline, agent never detected
        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .failed)
        XCTAssertTrue(harness.host.writtenInput.isEmpty, "no prompt is delivered when detection never succeeds")
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID), "the session is left running for inspection")
    }

    /// The session ends before the prompt is delivered → failed (the agent never received its work).
    func testAgentRunFailsWhenSessionEndsBeforeDelivery() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        harness.host.markSessionEnded(sessionID: sessionID)
        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .failed)
        XCTAssertNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt)
    }

    /// After delivery, a clean session end (no recorded failure, no `done`) completes `succeeded` — a
    /// deliberate close is the common case.
    func testAgentRunSucceedsWhenSessionEndsCleanlyAfterDelivery() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.service.tick()  // delivers prompt
        harness.host.markSessionEnded(sessionID: sessionID)
        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .succeeded)
    }

    /// After delivery, a session that ends with the platform's recorded failure state completes `failed`.
    func testAgentRunFailsWhenSessionEndsWithRecordedFailureAfterDelivery() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.service.tick()  // delivers prompt
        harness.host.markSessionFailed(sessionID: sessionID)
        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .failed)
    }

    /// The skip policy blocks a new agent run while a prior run's agent session is still live, even though
    /// that prior run already reached a terminal (`succeeded`) status — agent concurrency gates on live
    /// sessions, not just active run rows.
    func testAgentSkipPolicyBlocksWhileAttributedSessionLive() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id, concurrency: .skip)
        let first = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: first.id)?.terminalSessionID)

        // Drive the first run to succeeded with its session left live (done path).
        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.service.tick()
        _ = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: sessionID, status: .done)
        harness.service.tick()
        XCTAssertEqual(try harness.store.automationRun(id: first.id)?.status, .succeeded)
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID))

        // A new fire is skipped for concurrency while that session is still live.
        let second = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(second.status, .skipped)
        XCTAssertEqual(second.skipReason, .concurrency)
    }

    /// The allow policy spawns a new agent run regardless of a live prior session.
    func testAgentAllowPolicySpawnsDespiteLiveAttributedSession() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id, concurrency: .allow)
        let first = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let firstSessionID = try XCTUnwrap(harness.store.automationRun(id: first.id)?.terminalSessionID)

        harness.host.markSessionForegroundDetected(sessionID: firstSessionID)
        harness.service.tick()
        _ = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: firstSessionID, status: .done)
        harness.service.tick()
        XCTAssertEqual(try harness.store.automationRun(id: first.id)?.status, .succeeded)

        let second = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(second.status, .running)
        let secondSessionID = try XCTUnwrap(harness.store.automationRun(id: second.id)?.terminalSessionID)
        XCTAssertNotEqual(secondSessionID, firstSessionID, "allow spawns a fresh agent session")
    }

    /// Canceling a running agent run routes through the agent-kill flow, so the agent row is finalized and
    /// its subscriber is told the child exited (not a plain process-group signal).
    func testAgentCancelKillsThroughAgentKillFlow() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)
        let agent = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: sessionID, status: .spinning)
        try harness.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher", agentSessionID: agent.id, createdAt: "t")

        harness.service.cancelRun(runID: run.id)

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .canceled)
        XCTAssertNil(try harness.store.agentWindow(id: agent.id), "the agent row is finalized through the kill flow")
        XCTAssertTrue(
            harness.host.delivered.contains { $0.sessionID == "watcher" && $0.line.contains("exited") }, "the subscriber is told the agent exited")
    }

    /// Restart safety: the run row is the single source of truth for the agent-run phase, so a fresh
    /// service instance (a restarted daemon) resumes deterministically — the detecting phase resumes into
    /// prompt delivery, and the delivered phase resumes into awaiting done.
    func testAgentRunResumesAcrossRestartInBothPhases() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        // Phase 1 (detecting, promptDeliveredAt NULL): a restarted service resumes into delivery.
        XCTAssertNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt)
        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        let resumed1 = harness.makeService()
        resumed1.tick()
        XCTAssertEqual(harness.host.writtenInput.count, 1, "the detecting phase resumes into prompt delivery after a restart")
        XCTAssertNotNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt)

        // Phase 2 (delivered): another restarted service resumes into awaiting the done signal.
        _ = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: sessionID, status: .done)
        let resumed2 = harness.makeService()
        resumed2.tick()
        XCTAssertEqual(harness.host.writtenInput.count, 1, "the delivered phase does not re-send the prompt after a restart")
        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .succeeded)
    }

    /// An observed completion wins over the timeout: an agent that recorded `.done` before its deadline —
    /// whose next poll lands after it — is finished `.succeeded` by the awaiting-phase handler, not killed
    /// and recorded `.timedOut`. The done agent's session is deliberately left live and is not torn down.
    func testAgentRunDoneBeatsTimeout() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id, timeoutSeconds: 5)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        // Reach the awaiting phase: detect, deliver the prompt, then record the agent's done signal.
        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.service.tick()  // delivers prompt
        _ = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: sessionID, status: .done)

        // The next tick lands after the timeout budget, but the agent already recorded done: completion wins.
        clock.advance(by: 10)  // past the 5s budget
        harness.service.tick()

        let finished = try XCTUnwrap(harness.store.automationRun(id: run.id))
        XCTAssertEqual(finished.status, .succeeded, "an observed done wins over a timeout that lands after it")
        XCTAssertNil(finished.exitCode)
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID), "the done agent's session is not torn down by the timeout")
    }

    /// Genuine-hang path: an agent still live at its deadline with no `done` row is reaped — recorded
    /// `.timedOut` and its session torn down. This is the case the timeout exists for.
    func testAgentRunTimesOutAndTearsDownHungAgent() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id, timeoutSeconds: 5)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        // Reach the awaiting phase with a live session and no done signal — a genuinely hung agent.
        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.service.tick()  // delivers prompt

        clock.advance(by: 10)  // past the 5s budget, still no done row
        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .timedOut, "a hung agent with no done row is timed out")
        XCTAssertFalse(harness.orchestrator.automationSessionIsLive(sessionID: sessionID), "the hung agent's session is torn down")
    }

    /// A pending agent launch has no runtime row yet, but its configured timeout still applies. The run must
    /// tear down that pending session instead of waiting for the launch grace to expire and failing unowned.
    func testAgentRunTimesOutDuringLaunchPendingGrace() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let automation = try harness.insertAgentAutomation(workspaceID: "workspace-1", timeoutSeconds: 5)
        let sessionID = UUID().uuidString
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .agent, status: .running, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: sessionID, startedAt: clock.now(), endedAt: nil, createdAt: clock.now())
        try harness.store.insertAutomationRun(run)
        try harness.writeLaunchConfigurationOnly(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .agent, createdAt: Date())

        clock.advance(by: 10)
        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .timedOut)
        XCTAssertTrue(harness.host.terminated.contains(sessionID), "the pending agent session is torn down on timeout")
    }

    func testWorkspaceStopMarkerAllowsUnrelatedWorkspaceProgressAndPreservesTargetCronAnchor() throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try Harness(self, now: clock.now)
        let (_, workspaceA) = try harness.makeProjectAndWorkspace()
        let (_, workspaceB) = try harness.makeProjectAndWorkspace()
        let target = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", concurrency: .queue, nextFireTime: clock.now(), workspaceID: workspaceA.id)
        let unrelated = try harness.insertAutomation(concurrency: .allow, workspaceID: workspaceB.id)
        let started = expectation(description: "workspace stop operation started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let finished = expectation(description: "workspace stop operation finished")
        Thread.detachNewThread {
            do {
                try harness.service.cancelRunsForWorkspaceStop(workspaceID: workspaceA.id) { begin in
                    try begin()
                    started.fulfill()
                    release.wait()
                }
                finished.fulfill()
            } catch { XCTFail("workspace stop failed: \(error)") }
        }
        wait(for: [started], timeout: 2)
        let beforeAnchor = try XCTUnwrap(try harness.store.automation(id: target.id)?.nextFireTime)
        let queued = try harness.insertRun(automationID: target.id, kind: .script, status: .queued)
        XCTAssertNil(harness.service.triggerManually(automationID: target.id), "target workspace cannot launch during stop")
        XCTAssertNotNil(harness.service.triggerManually(automationID: unrelated.id), "unrelated workspace remains usable")
        harness.service.tick()
        XCTAssertEqual(try harness.store.automation(id: target.id)?.nextFireTime, beforeAnchor, "target cron anchor is preserved")
        XCTAssertEqual(try harness.store.automationRun(id: queued.id)?.status, .queued, "target queued run is not promoted during stop")
        release.signal()
        wait(for: [finished], timeout: 2)
        harness.service.tick()
        XCTAssertEqual(try harness.store.automationRun(id: queued.id)?.status, .running, "target queued run promotes after stop completes")
        XCTAssertNotNil(
            try harness.store.automationRuns(automationID: target.id).first { $0.status == .running }, "target fires after stop completes")
    }

    func testWorkspaceStopMarkerClearsWhenOperationThrows() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        XCTAssertThrowsError(
            try harness.service.cancelRunsForWorkspaceStop(workspaceID: workspace.id) { _ in throw NSError(domain: "test", code: 1) })
        let automation = try harness.insertAutomation(concurrency: .allow, workspaceID: workspace.id)
        XCTAssertNotNil(harness.service.triggerManually(automationID: automation.id), "marker must clear after operation failure")
    }

    func testCompetingWorkspaceStopCannotClearFirstMarker() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAutomation(concurrency: .allow, workspaceID: workspace.id)
        let began = expectation(description: "first cancellation began")
        let finished = expectation(description: "first cancellation finished")
        let release = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? harness.service.cancelRunsForWorkspaceStop(workspaceID: workspace.id) { begin in
                try begin()
                began.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
            finished.fulfill()
        }
        wait(for: [began], timeout: 2)
        XCTAssertThrowsError(
            try harness.service.cancelRunsForWorkspaceStop(workspaceID: workspace.id) { _ in throw WorkspaceError.dependencyMissing(message: "busy") }
        )
        XCTAssertNil(harness.service.triggerManually(automationID: automation.id), "the first stop marker remains active")
        release.signal()
        wait(for: [finished], timeout: 2)
    }

    // MARK: - End attributed agents

    /// End-agents over a terminal run reaps its still-live attributed agent session through the agent-kill
    /// flow (the agent row is finalized and its subscriber told it exited), without touching the run row.
    func testEndAttributedAgentsKillsLiveAgentOfTerminalRunAndKeepsRunStatus() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)

        // Drive an agent run to succeeded with its session deliberately left live (the done path).
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)
        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.service.tick()  // delivers prompt
        let agent = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: sessionID, status: .done)
        harness.service.tick()  // observes done → succeeded, session left open
        try harness.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher", agentSessionID: agent.id, createdAt: "t")
        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .succeeded)
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID))

        let returned = try harness.service.endAttributedAgents(runID: run.id)

        XCTAssertEqual(returned.status, .succeeded, "end-agents leaves the run's terminal status untouched")
        XCTAssertFalse(harness.orchestrator.automationSessionIsLive(sessionID: sessionID), "the live attributed agent session is ended")
        XCTAssertNil(try harness.store.agentWindow(id: agent.id), "the agent row is finalized through the kill flow")
        XCTAssertTrue(
            harness.host.delivered.contains { $0.sessionID == "watcher" && $0.line.contains("exited") }, "the subscriber is told the agent exited")
    }

    /// End-agents is a no-op for a terminal run with no live attributed sessions (all already swept/ended),
    /// and still returns the unchanged run.
    func testEndAttributedAgentsIsNoOpWhenNoLiveAgents() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try harness.insertRun(automationID: automation.id, status: .failed)
        _ = try harness.writeAttributedAgentSession(workspaceID: workspace.id, runID: run.id, sessionID: UUID().uuidString, live: false)

        let returned = try harness.service.endAttributedAgents(runID: run.id)
        XCTAssertEqual(returned.status, .failed)
    }

    /// A running (non-terminal) run is rejected loudly: a live run is stopped with cancel, not end-agents.
    func testEndAttributedAgentsErrorsOnRunningRun() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(script: "sleep 60", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(run.status, .running)
        XCTAssertThrowsError(try harness.service.endAttributedAgents(runID: run.id)) { error in
            XCTAssertTrue(error is AutomationValidationError, "a running run cannot be end-agents'd")
        }
        // The run is still running (untouched); clean it up.
        harness.service.cancelRun(runID: run.id)
    }

    /// End-agents prunes retention after ending the run's live agent. A terminal run beyond the retention
    /// cap that lingered only because its attributed agent session was live (the no-kill guard) is removed —
    /// its run row and artifacts — as soon as End agents ends that session, rather than waiting for some
    /// later run to prune.
    func testEndAttributedAgentsPrunesOverCapRunAfterEndingItsLiveAgent() throws {
        // A small cap so a handful of newer terminal rows push the live-session run past the window.
        let harness = try Harness(self, retentionLimit: 2)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)

        // The oldest run is a succeeded agent run whose agent session is deliberately left live; retention
        // would prune it were its session not live.
        let overCapRun = try harness.insertRun(automationID: automation.id, status: .succeeded, createdAt: harness.now())
        let liveSessionID = UUID().uuidString
        let agent = try harness.writeAttributedAgentSession(
            workspaceID: workspace.id, runID: overCapRun.id, sessionID: liveSessionID, live: true, status: .done)
        let runDirectory = try AutomationPaths.ensureRunDirectory(runID: overCapRun.id)

        // More newer terminal (skipped) rows than the cap, so the live-session run is beyond the newest 2.
        for offset in 1...4 {
            _ = try harness.insertRun(
                automationID: automation.id, status: .skipped, createdAt: harness.now().addingTimeInterval(TimeInterval(offset)))
        }

        // A prune while the session is live leaves the over-cap run (pruning it would kill the live agent).
        let throwaway = try harness.insertRun(automationID: automation.id, status: .running, createdAt: harness.now().addingTimeInterval(100))
        harness.service.cancelRun(runID: throwaway.id)
        XCTAssertNotNil(try harness.store.automationRun(id: overCapRun.id), "a run with a live attributed session survives pruning")

        // End agents ends the live session, then prunes: the now-prunable over-cap run is removed here.
        let returned = try harness.service.endAttributedAgents(runID: overCapRun.id)
        XCTAssertEqual(returned.status, .succeeded, "end-agents returns the run's final (untouched) status")

        XCTAssertNil(try harness.store.automationRun(id: overCapRun.id), "the over-cap run is pruned once End agents ends its live session")
        XCTAssertNil(try harness.store.agentWindow(id: agent.id), "its agent row is finalized")
        XCTAssertFalse(harness.orchestrator.automationSessionIsLive(sessionID: liveSessionID), "its live agent session is ended")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path), "the pruned run's artifact directory is deleted")
    }

    // MARK: - Attributed-agent summaries

    /// Attributed-agent summaries reflect the agent row's status and the session's liveness: a live agent
    /// carries its row status with `live == true`, and a done agent whose session has ended (not yet swept)
    /// carries its status with `live == false`.
    func testAttributedAgentSummariesReflectStatusAndLiveness() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let liveSessionID = UUID().uuidString
        let endedSessionID = UUID().uuidString
        _ = try harness.writeAttributedAgentSession(workspaceID: workspace.id, runID: run.id, sessionID: liveSessionID, live: true, status: .spinning)
        _ = try harness.writeAttributedAgentSession(workspaceID: workspace.id, runID: run.id, sessionID: endedSessionID, live: false, status: .done)

        let byRunID = try AutomationAttributedAgents.summariesByRunID(
            runs: [run], store: harness.store, liveSessions: try TerminalSessionCatalog.listLiveSessions())
        let agents = try XCTUnwrap(byRunID[run.id])
        let live = try XCTUnwrap(agents.first { $0.terminalSessionID == liveSessionID })
        XCTAssertEqual(live.status, "spinning")
        XCTAssertTrue(live.live)
        XCTAssertEqual(live.workspaceID, workspace.id)
        let ended = try XCTUnwrap(agents.first { $0.terminalSessionID == endedSessionID })
        XCTAssertEqual(ended.status, "done")
        XCTAssertFalse(ended.live)
    }

    /// A live agent-launch session with no orchestration row yet — the detection / prompt-delivery phase —
    /// reads as `idle` with `live == true` rather than being dropped.
    func testAttributedAgentSummaryForDetectionPendingSessionReadsIdleLive() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try harness.insertRun(automationID: automation.id, status: .running)
        let sessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(workspaceID: workspace.id, runID: run.id, sessionID: sessionID, kind: .agent, live: true)

        let byRunID = try AutomationAttributedAgents.summariesByRunID(
            runs: [run], store: harness.store, liveSessions: try TerminalSessionCatalog.listLiveSessions())
        let agent = try XCTUnwrap(byRunID[run.id]?.first { $0.terminalSessionID == sessionID })
        XCTAssertEqual(agent.status, "idle")
        XCTAssertTrue(agent.live)
    }

    /// A script run's own workspace-bound `.automation` wrapper session is attributed but is not a coding
    /// agent, so it never appears in the attributed-agent breakdown.
    func testAttributedAgentSummariesExcludeNonAgentSessions() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let run = try harness.insertRun(automationID: automation.id, status: .running)
        let sessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .automation, live: true)

        let byRunID = try AutomationAttributedAgents.summariesByRunID(
            runs: [run], store: harness.store, liveSessions: try TerminalSessionCatalog.listLiveSessions())
        XCTAssertEqual(byRunID[run.id], [], "the .automation wrapper session is not a coding agent")
    }

    /// An ended agent session with no agent row still lists as an agent, derived from its persisted session
    /// row, so the run's retained replay stays reachable from a chip. The run's own ended `.automation`
    /// wrapper is still not an agent.
    func testAttributedAgentSummariesKeepEndedRowlessAgentSession() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let agentSessionID = UUID().uuidString
        let wrapperSessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(
            workspaceID: workspace.id, runID: run.id, sessionID: agentSessionID, kind: .agent, live: false, title: "Codex CLI")
        try harness.writeAttributedSessionFiles(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: wrapperSessionID, kind: .automation, live: false)

        let byRunID = try AutomationAttributedAgents.summariesByRunID(
            runs: [run], store: harness.store, liveSessions: try TerminalSessionCatalog.listLiveSessions())
        let agents = try XCTUnwrap(byRunID[run.id])
        XCTAssertNil(agents.first { $0.terminalSessionID == wrapperSessionID }, "the ended .automation wrapper session is still not a coding agent")
        let agent = try XCTUnwrap(agents.first { $0.terminalSessionID == agentSessionID })
        XCTAssertEqual(agent.status, "exited")
        XCTAssertFalse(agent.live)
        XCTAssertEqual(agent.title, "Codex CLI")
        XCTAssertEqual(agent.workspaceID, workspace.id)
    }

    /// The next run's sweep finalizes an ended attributed agent's row away, but the run keeps listing that
    /// agent: the session it replays is retained until the run is pruned, so the chip that opens it has to
    /// outlive the row.
    func testAttributedAgentSummariesSurviveTheSweepFinalizingTheAgentRow() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAutomation(concurrency: .allow)
        let priorRun = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let endedSessionID = UUID().uuidString
        let endedAgent = try harness.writeAttributedAgentSession(
            workspaceID: workspace.id, runID: priorRun.id, sessionID: endedSessionID, live: false, status: .done)

        // Starting a new run of the same automation triggers the prior-run sweep.
        _ = harness.service.triggerManually(automationID: automation.id)
        XCTAssertNil(try harness.store.agentWindow(id: endedAgent.id), "the ended attributed agent row is finalized away")

        let byRunID = try AutomationAttributedAgents.summariesByRunID(
            runs: [priorRun], store: harness.store, liveSessions: try TerminalSessionCatalog.listLiveSessions())
        let agent = try XCTUnwrap(byRunID[priorRun.id]?.first { $0.terminalSessionID == endedSessionID })
        XCTAssertEqual(agent.status, "exited")
        XCTAssertFalse(agent.live)
    }

    /// Once the session collector releases a long-ended attributed session (the age / byte-budget bound), the
    /// run has nothing left to replay, so its agent stops being listed.
    func testAttributedAgentSummariesOmitReleasedSession() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let sessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(workspaceID: workspace.id, runID: run.id, sessionID: sessionID, kind: .agent, live: false)
        try harness.store.clearTerminalSessionAutomationAttribution(sessionID: sessionID)

        let byRunID = try AutomationAttributedAgents.summariesByRunID(
            runs: [run], store: harness.store, liveSessions: try TerminalSessionCatalog.listLiveSessions())
        XCTAssertEqual(byRunID[run.id], [], "a released session leaves no agent behind")
    }

    func testAttributedSessionBatchIncludesOnlyRequestedRuns() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let requested = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let unrelated = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let requestedSessionID = UUID().uuidString
        let unrelatedSessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(workspaceID: "ws-1", runID: requested.id, sessionID: requestedSessionID, kind: .agent, live: false)
        try harness.writeAttributedSessionFiles(workspaceID: "ws-1", runID: unrelated.id, sessionID: unrelatedSessionID, kind: .agent, live: false)

        let sessions = try harness.store.automationAttributedSessionsByRunID(runIDs: [requested.id])

        XCTAssertEqual(sessions[requested.id]?.map(\.sessionID), [requestedSessionID])
        XCTAssertNil(sessions[unrelated.id], "the batch does not scan or return attribution outside the requested run window")
    }

    // MARK: - Timeout + cancel

    func testTimeoutKillsCommandAndRecordsTimedOut() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let fixture = try AutomationProcessGroupFixture()
        defer { fixture.terminateAndReap() }
        let automation = try harness.insertAutomation(script: "sleep 30", concurrency: .allow, timeoutSeconds: 1)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(run.terminalSessionID)
        try harness.setRuntimeChildPID(sessionID: sessionID, childPID: fixture.leaderPID)

        clock.advance(by: 5)  // push past the 1s budget without waiting
        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .timedOut)
        try harness.assertProcessDies(pid: fixture.leaderPID, drivingTicks: harness.service.tick)
    }

    /// A script that finishes right at its deadline wins over the timeout: its exit-code sentinel is written
    /// synchronously at command exit while the exited runtime row is write-behind and can still read
    /// interactive when the timeout tick lands. The present sentinel is completion evidence that outranks the
    /// stale interactive row, so the run is finalized from the sentinel (succeeded, exit 0) rather than killed
    /// and recorded `.timedOut` despite completing within budget.
    func testScriptCompletionSentinelBeatsTimeout() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let automation = try harness.insertAutomation(concurrency: .allow, timeoutSeconds: 5)
        let sessionID = UUID().uuidString
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .script, status: .running, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: sessionID, startedAt: clock.now(), endedAt: nil, createdAt: clock.now())
        try harness.store.insertAutomationRun(run)
        // The session's runtime row still reads interactive (write-behind: the exited state has not landed) ...
        try harness.writeAttributedSessionFiles(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .automation, live: true)
        // ... but the wrapped command already recorded its exit code at exit.
        try harness.writeExitCodeSentinel(runID: run.id, exitCode: 0)
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID))

        clock.advance(by: 10)  // past the 5s budget
        harness.service.tick()

        let finished = try XCTUnwrap(harness.store.automationRun(id: run.id))
        XCTAssertEqual(finished.status, .succeeded, "a present exit-code sentinel beats a timeout that lands after completion")
        XCTAssertEqual(finished.exitCode, 0)
        XCTAssertFalse(harness.host.terminated.contains(sessionID), "a completed script is not torn down by the timeout")
    }

    /// A short-timeout script whose session has no runtime row yet but a fresh launch configuration
    /// (launch-pending under write-behind persistence) still times out on budget: the timeout branch covers
    /// the pending case, so the session is torn down and the run recorded `.timedOut` on time — rather than
    /// the short timeout silently stretching toward the 60s pending window and later finalizing `.failed`
    /// with no teardown, orphaning a possibly live process.
    func testScriptTimesOutDuringLaunchPendingGrace() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let automation = try harness.insertAutomation(concurrency: .allow, timeoutSeconds: 5)
        let sessionID = UUID().uuidString
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .script, status: .running, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: sessionID, startedAt: clock.now(), endedAt: nil, createdAt: clock.now())
        try harness.store.insertAutomationRun(run)
        // No runtime row, only a fresh launch config → launch-pending. The pending check reads the real wall
        // clock, so the config is written at `Date()` while the MutableClock advances only the timeout budget.
        try harness.writeLaunchConfigurationOnly(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .automation, createdAt: Date())

        clock.advance(by: 10)  // past the 5s budget while still launch-pending
        harness.service.tick()

        XCTAssertEqual(
            try harness.store.automationRun(id: run.id)?.status, .timedOut, "a launch-pending session past its budget is timed out, not stretched")
        XCTAssertTrue(harness.host.terminated.contains(sessionID), "the launch-pending session is terminated via the no-PID fallback")
    }

    /// `builtInSessionLaunchIsPending` consults the pending-launch registry before the durable launch-
    /// configuration row, so a session whose row has not committed yet (the write-behind window the
    /// launch-configuration write goes through, see `TerminalSessionPendingLaunchRegistry`) still reads as
    /// launch-pending purely from the registry entry. This covers the registry-only path: no row is ever
    /// written to disk here, only the registry is populated and cleared directly.
    func testBuiltInSessionLaunchIsPendingReadsTheRegistryBeforeTheDurableRow() throws {
        let harness = try Harness(self)
        let sessionID = UUID().uuidString
        // Tracks the generation of whichever recordPending call is most recent, so the teardown defer
        // clears exactly the entry left standing at the end of the test, not a stale generation.
        var pendingGeneration: UInt64?
        defer { if let pendingGeneration { TerminalSessionPendingLaunchRegistry.shared.clear(sessionID: sessionID, generation: pendingGeneration) } }

        XCTAssertFalse(
            harness.orchestrator.builtInSessionLaunchIsPending(sessionID: sessionID),
            "a session with no durable row and no registry entry is not launch-pending")

        let configuration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "cmd", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
            createdAt: TerminalSessionTimestamp.string(from: Date()), workspaceID: "workspace-1", kind: .automation)
        pendingGeneration = TerminalSessionPendingLaunchRegistry.shared.recordPending(configuration)
        XCTAssertTrue(
            harness.orchestrator.builtInSessionLaunchIsPending(sessionID: sessionID),
            "a recent registry entry alone must read as launch-pending, with no durable row required")

        TerminalSessionPendingLaunchRegistry.shared.clear(sessionID: sessionID, generation: pendingGeneration!)
        XCTAssertFalse(
            harness.orchestrator.builtInSessionLaunchIsPending(sessionID: sessionID),
            "clearing the registry entry with no durable row drops it back to not-pending")

        let staleConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "cmd", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
            createdAt: TerminalSessionTimestamp.string(from: Date().addingTimeInterval(-120)), workspaceID: "workspace-1", kind: .automation)
        pendingGeneration = TerminalSessionPendingLaunchRegistry.shared.recordPending(staleConfiguration)
        XCTAssertFalse(
            harness.orchestrator.builtInSessionLaunchIsPending(sessionID: sessionID),
            "a registry entry older than the launch-pending grace window is not launch-pending, same as a stale durable row")
    }

    /// Reproduces a relaunch under the same session id: the previous run's write-behind rows are already
    /// durably committed as `.exited`, and a fresh core for the relaunch records a registry entry before its
    /// own replacement rows land. `builtInSessionLaunchIsPending` must trust that fresh registry entry over
    /// the stale durable row, but its runtime-state check runs before the registry consult and returns false
    /// on sight of the exited row, so a live relaunch reads as not launch-pending and a liveness probe can
    /// tear it down mid-launch.
    func testBuiltInSessionLaunchIsPendingTrustsTheRegistryOverAStaleExitedRuntimeRowOnRelaunch() throws {
        let harness = try Harness(self)
        let sessionID = UUID().uuidString
        var pendingGeneration: UInt64?
        defer { if let pendingGeneration { TerminalSessionPendingLaunchRegistry.shared.clear(sessionID: sessionID, generation: pendingGeneration) } }

        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "cmd", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: TerminalSessionTimestamp.string(from: Date().addingTimeInterval(-120)), workspaceID: "workspace-1", kind: .automation),
            paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .exited,
                updatedAt: TerminalSessionTimestamp.string(from: Date().addingTimeInterval(-119)),
                exitedAt: TerminalSessionTimestamp.string(from: Date().addingTimeInterval(-119)), title: "cmd"), paths: paths)

        XCTAssertFalse(
            harness.orchestrator.builtInSessionLaunchIsPending(sessionID: sessionID),
            "the previous run's exited row is past the grace window on its own, before any relaunch")

        let relaunchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "cmd", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
            createdAt: TerminalSessionTimestamp.string(from: Date()), workspaceID: "workspace-1", kind: .automation)
        pendingGeneration = TerminalSessionPendingLaunchRegistry.shared.recordPending(relaunchConfiguration)
        XCTAssertTrue(
            harness.orchestrator.builtInSessionLaunchIsPending(sessionID: sessionID),
            "a fresh pending relaunch must read as launch-pending even while the previous run's exited runtime row is still the committed truth")
    }

    /// On a same-session-id relaunch, the launch-configuration write commits and clears the
    /// `TerminalSessionPendingLaunchRegistry` entry before the new run's first runtime-state write lands. In that
    /// gap the previous run's `.exited` runtime row in `terminal_runtime_states` is still the committed truth, since
    /// `writeLaunchConfiguration` does not touch it, and the registry has nothing recorded for the fresh launch.
    /// `builtInSessionLaunchIsPending` must still read the freshly committed launch row as pending rather than
    /// trusting the leftover exited runtime row, or a liveness probe running in this gap can tear down the live
    /// relaunch.
    func testBuiltInSessionLaunchIsPendingTreatsAFreshlyCommittedLaunchRowAsPendingAfterTheRegistryClears() throws {
        let harness = try Harness(self)
        let sessionID = UUID().uuidString
        // No recordPending here: this test targets the post-commit, post-clear gap where the registry has
        // nothing recorded for the session id, so there is no registry entry to tear down at teardown.

        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "cmd", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: TerminalSessionTimestamp.string(from: Date().addingTimeInterval(-120)), workspaceID: "workspace-1", kind: .automation),
            paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .exited,
                updatedAt: TerminalSessionTimestamp.string(from: Date().addingTimeInterval(-119)),
                exitedAt: TerminalSessionTimestamp.string(from: Date().addingTimeInterval(-119)), title: "cmd"), paths: paths)

        // Simulate the relaunch's launch write having just committed and the registry having just cleared: the
        // same session ID gets a fresh launch-configuration row, but nothing is recorded in the registry, matching
        // the post-commit, post-clear gap this test targets.
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "cmd", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: TerminalSessionTimestamp.string(from: Date()), workspaceID: "workspace-1", kind: .automation), paths: paths)

        XCTAssertTrue(
            harness.orchestrator.builtInSessionLaunchIsPending(sessionID: sessionID),
            "a freshly committed relaunch row must read as launch-pending until the new run's runtime state commits, even though the previous run's exited runtime row is still on disk"
        )
    }

    func testCancelKillsCommandAndRecordsCanceled() throws {
        let harness = try Harness(self)
        let fixture = try AutomationProcessGroupFixture()
        defer { fixture.terminateAndReap() }
        let automation = try harness.insertAutomation(script: "sleep 30", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(run.terminalSessionID)
        try harness.setRuntimeChildPID(sessionID: sessionID, childPID: fixture.leaderPID)

        harness.service.cancelRun(runID: run.id)

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .canceled)
        try harness.assertProcessDies(pid: fixture.leaderPID, drivingTicks: harness.service.tick)
    }

    func testCancelDelegatesTeardownWhenChildHasNoSafeProcessGroup() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(run.terminalSessionID)
        // The test process is provably not a safe child-owned group: it is either not its group leader or
        // its group is the daemon/test runner's own. The fake session terminator records delegation without
        // actually signaling this process.
        try harness.setRuntimeChildPID(sessionID: sessionID, childPID: getpid())

        _ = try harness.service.cancelAutomationRun(runID: run.id)

        XCTAssertTrue(
            harness.host.terminated.contains(sessionID),
            "a child in the daemon's process group is torn down by its owning session instead of arming a delayed raw-PID kill")
    }

    /// Canceling a run whose finalization makes it immediately prunable returns the run's `canceled` final
    /// state without throwing: converting an old queued run to a terminal status can push it past the
    /// retention cap (enough newer terminal rows already exist), so a naive re-fetch after the cancel would
    /// throw "run not found" even though the cancel succeeded and pruned the row.
    func testCancelReturnsCanceledRunEvenWhenRetentionPrunesIt() throws {
        let harness = try Harness(self, retentionLimit: 2)
        let automation = try harness.insertAutomation(concurrency: .allow)

        // The oldest run is queued; canceling it makes it terminal — and thus prunable.
        let queued = try harness.insertRun(automationID: automation.id, status: .queued, createdAt: harness.now())
        // More newer terminal rows than the cap, so once the queued run becomes `canceled` (the oldest terminal
        // run) it falls beyond the newest `retentionLimit` and is pruned within the same cancel.
        for offset in 1...4 {
            _ = try harness.insertRun(
                automationID: automation.id, status: .succeeded, createdAt: harness.now().addingTimeInterval(TimeInterval(offset)))
        }

        let canceled = try harness.service.cancelAutomationRun(runID: queued.id)
        XCTAssertEqual(canceled.id, queued.id)
        XCTAssertEqual(canceled.status, .canceled, "the returned run carries the canceled final state")
        XCTAssertNil(canceled.exitCode)
        XCTAssertNotNil(canceled.endedAt, "the canceled run's end time is set")
        XCTAssertNil(try harness.store.automationRun(id: queued.id), "the canceled run was indeed pruned from the store")
    }

    /// SIGKILL escalation tracks the whole process group, not just the leader: a canceled run whose command's
    /// group leader exits on SIGTERM while another group member ignores it must still escalate to SIGKILL and
    /// kill the survivor. If escalation keyed only on the leader pid, the leader's death would drop the pending
    /// kill and leave the survivor running forever. The fixture is made from directly spawned, waitable
    /// processes rather than nested shells so the test does not depend on shell job-control or reparenting.
    func testCancelEscalatesToSIGKILLForSurvivingChildAfterLeaderExits() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, now: clock.now)
        let fixture = try AutomationProcessGroupFixture()
        defer { fixture.terminateAndReap() }
        let automation = try harness.insertAutomation(script: "sleep 60", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(run.terminalSessionID)
        try harness.setRuntimeChildPID(sessionID: sessionID, childPID: fixture.leaderPID)
        harness.service.cancelRun(runID: run.id)
        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .canceled)
        // Establish the behavior this regression protects before allowing escalation: SIGTERM has reaped the
        // group leader while the member that ignored it remains in that leader's captured process group.
        try fixture.waitForLeaderExit()
        XCTAssertTrue(harness.processIsRunning(fixture.survivorPID), "the TERM-ignoring child survives the initial SIGTERM")

        clock.advance(by: 1)
        try harness.assertProcessDies(pid: fixture.survivorPID, drivingTicks: harness.service.tick)
    }

    /// An exec handoff preserves terminal children but replaces the AutomationService, so it must finish
    /// any pending SIGKILL escalation before the in-memory pending-kill table is discarded.
    func testHandoffDrainCompletesPendingSIGKILLEscalation() async throws {
        let harness = try Harness(self)
        let fixture = try AutomationProcessGroupFixture()
        defer { fixture.terminateAndReap() }
        let automation = try harness.insertAutomation(script: "sleep 60", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(run.terminalSessionID)
        try harness.setRuntimeChildPID(sessionID: sessionID, childPID: fixture.leaderPID)

        harness.service.cancelRun(runID: run.id)
        XCTAssertTrue(harness.processIsRunning(fixture.survivorPID))
        await harness.service.completePendingTerminationsForHandoff()

        try harness.assertProcessDies(pid: fixture.survivorPID, drivingTicks: {})
    }

    // MARK: - Delete terminates live attributed sessions

    /// Deleting an automation whose succeeded agent-kind run deliberately left its agent session live must
    /// terminate that session and finalize its agent row before the run's records are removed, so no orphaned
    /// process survives running-but-unreachable. Retention pruning shares the same helper, so this covers both.
    func testDeleteAutomationTerminatesLiveAttributedAgentSession() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let sessionID = UUID().uuidString
        let agent = try harness.writeAttributedAgentSession(workspaceID: workspace.id, runID: run.id, sessionID: sessionID, live: true, status: .done)
        try harness.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher", agentSessionID: agent.id, createdAt: "t")
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID))

        try harness.service.deleteAutomation(id: automation.id)

        XCTAssertFalse(
            harness.orchestrator.automationSessionIsLive(sessionID: sessionID),
            "the live attributed session is terminated before its records are removed")
        XCTAssertNil(try harness.store.agentWindow(id: agent.id), "the agent row is finalized through the kill chokepoint")
        XCTAssertTrue(
            harness.host.delivered.contains { $0.sessionID == "watcher" && $0.line.contains("exited") }, "the subscriber is told the agent exited")
        XCTAssertNil(try harness.store.automation(id: automation.id), "the automation is deleted")
    }

    /// Script wrapper sessions are workspace runtime targets too, even though they never have an agent row.
    /// Explicit deletion terminates a live wrapper, removes that target before deleting the run's session and
    /// artifacts, and leaves a workspace with no other runtime indicators stopped.
    func testDeleteAutomationReleasesWorkspaceTrackingForLiveScriptSession() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let workspace = try XCTUnwrap(harness.store.workspace(id: automation.workspaceID))
        let run = try harness.insertRun(automationID: automation.id, status: .running)
        let sessionID = UUID().uuidString
        try harness.store.updateAutomationRun(
            id: run.id, status: .running, skipReason: nil, exitCode: nil, terminalSessionID: sessionID, startedAt: run.startedAt, endedAt: nil,
            promptDeliveredAt: nil)
        try harness.writeAttributedSessionFiles(
            workspaceID: workspace.id, runID: run.id, sessionID: sessionID, kind: .automation, live: true, title: "Test")
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try harness.store.upsert(
            window: WindowRecord(
                id: "script-delete-runtime-target", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "Test",
                terminalTrackingID: sessionID, role: .terminal, orderIndex: 0, lastSeenAt: "2026-06-06T00:00:00Z"))
        try harness.store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-06-06T00:00:00Z")

        try harness.service.deleteAutomation(id: automation.id)

        XCTAssertNil(try harness.store.automation(id: automation.id))
        XCTAssertNil(try harness.store.automationRun(id: run.id), "automation deletion removes its run row")
        XCTAssertTrue(harness.host.terminated.contains(sessionID), "explicit deletion terminates the live script session")
        XCTAssertTrue(try harness.store.terminalSessionIDs(automationRunID: run.id).isEmpty, "the script session persistence is deleted")
        XCTAssertThrowsError(
            try TerminalSessionPersistence.readLaunchConfiguration(paths: paths), "the script replay session is removed by explicit deletion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rootDirectory), "the script transcript artifact is removed")
        XCTAssertFalse(
            try harness.store.windows(workspaceID: workspace.id).contains { $0.terminalTrackingID == sessionID },
            "the script runtime target is removed before its terminal persistence")
        XCTAssertFalse(try XCTUnwrap(harness.store.workspace(id: workspace.id)).isRunning, "the workspace no longer has a runtime indicator")
    }

    /// Deleting an automation must finalize an ENDED attributed agent session too — including one that died
    /// before its agent row was registered — releasing its spawn-time workspace tracking (a tracked terminal
    /// window and the workspace-running flag). Without the row-less finalize the delete would drop the session
    /// rows/files and leak that tracking permanently, since no later sweep can reach the gone rows.
    func testDeleteReleasesWorkspaceTrackingForRowlessEndedAgentSession() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)

        // A terminal run whose spawned agent session ended before any agent row was created: ended session
        // files plus the spawn-time tracked window and running workspace, but no agent row.
        let run = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let endedSessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(workspaceID: workspace.id, runID: run.id, sessionID: endedSessionID, kind: .agent, live: false)
        try harness.seedSpawnedAgentWorkspaceTracking(workspace: workspace, sessionID: endedSessionID)
        XCTAssertTrue(try XCTUnwrap(harness.store.workspace(id: workspace.id)).isRunning, "the workspace starts running from the spawn")
        XCTAssertTrue(
            try harness.store.windows(workspaceID: workspace.id).contains { $0.terminalTrackingID == endedSessionID },
            "the spawn-time tracked window exists before deletion")

        try harness.service.deleteAutomation(id: automation.id)

        XCTAssertNil(try harness.store.automation(id: automation.id), "the automation is deleted")
        XCTAssertFalse(
            try harness.store.windows(workspaceID: workspace.id).contains { $0.terminalTrackingID == endedSessionID },
            "the row-less ended session's tracked window is released")
        XCTAssertFalse(
            try XCTUnwrap(harness.store.workspace(id: workspace.id)).isRunning, "the workspace is not left running once its only tracked session ends"
        )
    }

    /// Project/workspace deletion holds the workspace lifecycle gate while it asks AutomationService to
    /// remove targeting automations. A spawned child can exit before its first hook signal, leaving only
    /// its terminal runtime target; teardown must release that row-less tracking directly instead of
    /// routing through the public agent-stop path, which would try to claim the gate again.
    func testWorkspaceTeardownDeletesRowlessAttributedAgentWithoutReclaimingLifecycleGate() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id)
        let run = try harness.insertRun(automationID: automation.id, kind: .agent, status: .succeeded)
        let sessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(workspaceID: workspace.id, runID: run.id, sessionID: sessionID, kind: .agent, live: false)
        try harness.seedSpawnedAgentWorkspaceTracking(workspace: workspace, sessionID: sessionID)

        XCTAssertNoThrow(
            try harness.orchestrator.withWorkspaceLifecycleLock(workspaceID: workspace.id) {
                try harness.service.deleteAutomationsTargetingWorkspaceDuringTeardown(workspaceID: workspace.id)
            })
        XCTAssertNil(try harness.store.automation(id: automation.id))
        XCTAssertFalse(
            try harness.store.windows(workspaceID: workspace.id).contains { $0.terminalTrackingID == sessionID },
            "the row-less runtime target is removed while the held-gate teardown is still in progress")
        XCTAssertFalse(try XCTUnwrap(harness.store.workspace(id: workspace.id)).isRunning)
    }

    // MARK: - Workspace target validation

    func testCreateRejectsAutomationTargetingMissingWorkspace() throws {
        let harness = try Harness(self)
        let draft = AutomationDraft(
            name: "Missing target", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "true",
            workspaceID: "deleted-workspace", timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce)

        XCTAssertThrowsError(try harness.service.createAutomation(draft)) { error in
            XCTAssertTrue(error is AutomationValidationError, "a missing workspace is a user-facing validation error")
        }
        XCTAssertTrue(try harness.service.listAutomations().isEmpty, "the rejected draft must not persist")
    }

    func testUpdateRejectsAutomationWhoseWorkspaceWasDeleted() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation()
        try harness.store.deleteWorkspace(id: automation.workspaceID)
        let draft = AutomationDraft(
            name: "Retargeted", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "true",
            workspaceID: automation.workspaceID, timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce)

        XCTAssertThrowsError(try harness.service.updateAutomation(id: automation.id, draft: draft)) { error in
            XCTAssertTrue(error is AutomationValidationError, "a deleted workspace is a user-facing validation error")
        }
        XCTAssertEqual(try harness.store.automation(id: automation.id)?.name, automation.name, "the rejected update must not persist")
    }

    // MARK: - Kind-change guard

    /// Switching an automation between Script and Agent while a run is queued or running is rejected — the
    /// poll path dispatches on the current kind, so the change would misclassify the in-flight run. Only the
    /// kind change is blocked; every other edit stays allowed mid-run.
    func testUpdateRejectsKindChangeWhileRunActive() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(script: "sleep 60", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(run.status, .running)

        let switchToAgent = AutomationDraft(
            name: automation.name, enabled: true, triggerKind: .manual, cronExpression: nil, kind: .agent, script: "", agentCommand: "claude",
            agentPrompt: "do the thing", workspaceID: automation.workspaceID, timeoutSeconds: nil, concurrencyPolicy: .allow,
            missedRunPolicy: .runOnce)
        XCTAssertThrowsError(try harness.service.updateAutomation(id: automation.id, draft: switchToAgent)) { error in
            XCTAssertTrue(error is AutomationValidationError, "the kind cannot change while a run is active")
        }
        XCTAssertEqual(try harness.store.automation(id: automation.id)?.kind, .script, "the rejected change never persists")

        let renameOnly = AutomationDraft(
            name: "Renamed", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "sleep 60", agentCommand: nil,
            agentPrompt: nil, workspaceID: automation.workspaceID, timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce)
        let updated = try harness.service.updateAutomation(id: automation.id, draft: renameOnly)
        XCTAssertEqual(updated.name, "Renamed", "a non-kind edit is allowed while the run is active")

        harness.service.cancelRun(runID: run.id)
    }

    /// With no active run, switching kind is allowed.
    func testUpdateAllowsKindChangeWithNoActiveRuns() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(script: "echo hi", concurrency: .allow)
        let switchToAgent = AutomationDraft(
            name: automation.name, enabled: true, triggerKind: .manual, cronExpression: nil, kind: .agent, script: "", agentCommand: "claude",
            agentPrompt: "do the thing", workspaceID: automation.workspaceID, timeoutSeconds: nil, concurrencyPolicy: .allow,
            missedRunPolicy: .runOnce)
        let updated = try harness.service.updateAutomation(id: automation.id, draft: switchToAgent)
        XCTAssertEqual(updated.kind, .agent)
    }

    // MARK: - startRun returns the persisted row

    /// A trigger whose launch fails returns the persisted `failed` row, not the pre-launch `running` local
    /// value: an agent automation targeting a nonexistent workspace fails at spawn.
    func testTriggerReturnsPersistedFailedRunOnAgentLaunchFailure() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAgentAutomation(workspaceID: "missing-workspace")
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(run.status, .failed, "the returned run reflects the persisted launch failure")
        XCTAssertNil(run.terminalSessionID)
    }

    /// A successful script trigger returns the persisted `running` row carrying its launched terminal session
    /// id, not the pre-launch value whose session id was still nil.
    func testTriggerReturnsPersistedRunningRunWithSessionForScript() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(script: "true", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(run.status, .running)
        let sessionID = try XCTUnwrap(run.terminalSessionID, "the returned run carries the launched session id")
        XCTAssertEqual(sessionID, try harness.store.automationRun(id: run.id)?.terminalSessionID)
        harness.service.cancelRun(runID: run.id)
    }

    // MARK: - Launch-persistence grace

    /// A script run whose session has no runtime row yet but a fresh launch configuration is within the
    /// launch-persistence grace window (write-behind persistence, post-#224, has not landed the runtime row):
    /// the tick reads the absent runtime row as indeterminate (session still coming up), not as completion, so
    /// the run stays `.running` rather than being falsely finalized as failed.
    func testScriptRunWithPendingLaunchAndNoRuntimeStateStaysRunning() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let sessionID = UUID().uuidString
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .script, status: .running, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: sessionID, startedAt: harness.now(), endedAt: nil, createdAt: harness.now())
        try harness.store.insertAutomationRun(run)
        try harness.writeLaunchConfigurationOnly(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .automation, createdAt: Date())

        harness.service.tick()
        XCTAssertEqual(
            try harness.store.automationRun(id: run.id)?.status, .running,
            "an absent runtime row within the launch grace window is indeterminate, not completion")
    }

    /// A script run whose session has no runtime row and only a stale launch configuration (outside the grace
    /// window) is a vanished session, so the tick finalizes the run rather than waiting for a row that will
    /// never land. No recorded exit code finalizes it as failed.
    func testScriptRunWithNoRuntimeStateAndStaleLaunchFinalizes() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let sessionID = UUID().uuidString
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .script, status: .running, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: sessionID, startedAt: harness.now(), endedAt: nil, createdAt: harness.now())
        try harness.store.insertAutomationRun(run)
        try harness.writeLaunchConfigurationOnly(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .automation, createdAt: Date().addingTimeInterval(-120))

        harness.service.tick()
        let finished = try XCTUnwrap(harness.store.automationRun(id: run.id))
        XCTAssertEqual(finished.status, .failed, "a vanished session outside the grace window finalizes (no exit code → failed)")
    }

    /// An agent run whose runtime row never lands is finalized only after the attributed agent session is
    /// torn down. This prevents an unreachable live agent from surviving a failed run and falsely holding
    /// concurrency open elsewhere.
    func testAgentRunWithNoRuntimeStateAndStaleLaunchTearsDownSessionBeforeFinalizing() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAgentAutomation(workspaceID: "workspace-1")
        let sessionID = UUID().uuidString
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .agent, status: .running, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: sessionID, startedAt: harness.now(), endedAt: nil, createdAt: harness.now())
        try harness.store.insertAutomationRun(run)
        try harness.writeLaunchConfigurationOnly(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .agent, createdAt: Date().addingTimeInterval(-120))

        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .failed)
        XCTAssertTrue(harness.host.terminated.contains(sessionID), "the vanished agent session is torn down before finalization")
    }

    // MARK: - Stale nil-session running row

    /// A `.running` run row with no session id is a stale crash leftover: the daemon died between inserting
    /// the row and persisting its launched session id. Queue confinement means a tick can never legitimately
    /// observe that mid-`startRun` window, so the tick fails the row — which would otherwise stay `.running`
    /// forever and block skip/queue concurrency — and the automation is unblocked for its next trigger.
    func testRunningRunWithoutSessionIsFailedAndUnblocksConcurrency() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .skip)
        let orphan = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .script, status: .running, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: nil, startedAt: harness.now(), endedAt: nil, createdAt: harness.now())
        try harness.store.insertAutomationRun(orphan)

        harness.service.tick()
        XCTAssertEqual(
            try harness.store.automationRun(id: orphan.id)?.status, .failed, "a nil-session running row is failed as a stale crash leftover")

        // With the stale row failed, a skip-policy trigger starts a real run instead of being blocked.
        let next = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(next.status, .running, "the failed stale row no longer blocks skip concurrency")
        harness.service.cancelRun(runID: next.id)
    }

    // MARK: - Cancel/timeout with no persisted childPID

    /// A cancel that lands in the write-behind no-PID window — the session is genuinely live but its runtime
    /// row carries no `childPID` yet — must still terminate the session, not just finalize the run. The
    /// preferred process-group signal cannot run without a pid, so teardown falls back to terminating the whole
    /// session through the daemon, so a run finalized `canceled` can never leave its own session running.
    func testCancelTerminatesOwnSessionWhenNoChildPIDPersisted() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let sessionID = UUID().uuidString
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .script, status: .running, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: sessionID, startedAt: harness.now(), endedAt: nil, createdAt: harness.now())
        try harness.store.insertAutomationRun(run)
        // A live session whose runtime row has no childPID (write-behind: the pid has not landed yet).
        try harness.writeAttributedSessionFiles(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .automation, live: true)
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID))

        harness.service.cancelRun(runID: run.id)

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .canceled)
        XCTAssertFalse(
            harness.orchestrator.automationSessionIsLive(sessionID: sessionID),
            "with no persisted childPID the whole session is terminated so the canceled run leaves nothing running")
    }

    // MARK: - Completions polled before due cron fires

    /// A run whose command exits between ticks must be finalized before the due cron fire judges overlap:
    /// `tick()` polls running runs before firing due crons, so a `skip`-policy occurrence coming due the same
    /// tick sees the just-finished run as idle and starts a real run rather than consuming the anchor on a
    /// skipped occurrence recorded against work that is no longer running.
    func testTickPollsCompletionBeforeDueCronFireSoSkipDoesNotSkipFinishedRun() throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try Harness(self, now: clock.now)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", concurrency: .skip, nextFireTime: clock.now().addingTimeInterval(60))

        // A run is already running from a prior (manual) fire.
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(run.status, .running)
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID)

        // Its command exits just before the next cron occurrence is due — no tick has observed it yet.
        harness.host.markSessionEnded(sessionID: sessionID)

        // The occurrence is now due; a single tick polls the completion first, so the due fire sees an idle
        // automation and starts a real run rather than skipping against the just-finished run.
        clock.advance(by: 60)
        harness.service.tick()

        XCTAssertTrue(try XCTUnwrap(harness.store.automationRun(id: run.id)).status.isTerminal, "the finished run is finalized this tick")
        let cronRuns = try harness.store.automationRuns(automationID: automation.id).filter { $0.trigger == .cron }
        XCTAssertEqual(cronRuns.count, 1, "the due occurrence fires exactly one run")
        XCTAssertEqual(cronRuns.first?.status, .running, "the due fire starts a real run, not a skipped occurrence")
        XCTAssertFalse(cronRuns.contains { $0.status == .skipped }, "no skipped occurrence is recorded against the finished run")
        harness.service.cancelRun(runID: try XCTUnwrap(cronRuns.first).id)
    }

    // MARK: - Terminal-session companion cleanup

    /// Deleting a terminal session removes its companion rows keyed by the session id, not just the
    /// `terminal_sessions` row, so retention pruning and the ended-agent sweep leave no orphaned persistence
    /// behind. Runtime state and a signal-event row are seeded and asserted here; the other companion tables
    /// (`terminal_clients`, `terminal_attachments`, `terminal_remote_session_states`) are keyed by session id
    /// with no FK cascade and are deleted in the same transaction (covered by schema reading, not seeded here).
    func testDeleteTerminalSessionRemovesCompanionRuntimeState() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let run = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let sessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .automation, live: false)

        // A pending agent-signal row keyed by the session id — the signal history a signaling agent leaves in
        // the profile store (not a per-session database), so it is not swept away by removing session files.
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.appendPendingAgentSignal(
            TerminalServiceAgentSignalEvent(
                id: UUID().uuidString, sessionID: sessionID, workspaceID: nil, workspacePath: nil, type: "done", createdAt: "2026-06-06T00:00:02Z"),
            paths: paths)

        // The session row, its runtime state, and its signal-event row are all present before deletion.
        XCTAssertTrue(try harness.store.terminalSessionIDs(automationRunID: run.id).contains(sessionID))
        XCTAssertNoThrow(try TerminalSessionPersistence.readRuntimeState(paths: paths), "the runtime row exists before deletion")
        XCTAssertEqual(try harness.signalEventCount(sessionID: sessionID), 1, "the signal-event row exists before deletion")

        try harness.store.deleteTerminalSession(sessionID: sessionID)

        XCTAssertFalse(try harness.store.terminalSessionIDs(automationRunID: run.id).contains(sessionID), "the terminal_sessions row is removed")
        XCTAssertThrowsError(
            try TerminalSessionPersistence.readRuntimeState(paths: paths), "the companion runtime_states row is removed in the same delete")
        XCTAssertEqual(try harness.signalEventCount(sessionID: sessionID), 0, "the companion signal-event rows are removed in the same delete")
    }

    /// An automation session can itself be an agent-watch SUBSCRIBER (its script ran `spaces agent … --subscribe`).
    /// Deleting the session drops its subscriber-keyed edges in `agent_subscriptions`,
    /// `agent_pending_notifications`, and `agent_remote_subscriptions` in the same transaction, so a
    /// retention/sweep delete (which bypasses the orchestrator's `subscriberDidExit` path) leaves no dangling
    /// remote watch stream or notification aimed at the gone session. Rows where the session is the WATCHED
    /// agent are owned by the agent-row lifecycle and must survive.
    func testDeleteTerminalSessionRemovesSubscriberWatchEdges() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAutomation(concurrency: .allow)
        let run = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let sessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(
            workspaceID: automation.workspaceID, runID: run.id, sessionID: sessionID, kind: .automation, live: false)

        // The deleted session watches a live child agent (local edge), holds a coalesced notification for it,
        // and watches a remote agent on a paired device.
        let child = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: "child-session", status: .waiting)
        try harness.store.insertAgentSubscription(subscriberTerminalSessionID: sessionID, agentSessionID: child.id, createdAt: "t")
        try harness.store.upsertPendingAgentNotification(
            subscriberTerminalSessionID: sessionID, agentSessionID: child.id, transition: "blocked", message: "child is blocked", createdAt: "t")
        try harness.store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: sessionID, deviceID: "dev-1", agentSessionID: "remote-term", createdAt: "t")

        XCTAssertFalse(
            try harness.store.agentSubscriptions(subscriberTerminalSessionID: sessionID).isEmpty, "the local watch edge exists before deletion")
        XCTAssertFalse(
            try harness.store.pendingAgentNotifications(subscriberTerminalSessionID: sessionID).isEmpty,
            "the pending notification exists before deletion")
        XCTAssertFalse(
            try harness.store.agentRemoteSubscriptions(subscriberTerminalSessionID: sessionID).isEmpty, "the remote watch edge exists before deletion"
        )

        try harness.store.deleteTerminalSession(sessionID: sessionID)

        XCTAssertTrue(
            try harness.store.agentSubscriptions(subscriberTerminalSessionID: sessionID).isEmpty, "the subscriber's local watch edge is removed")
        XCTAssertTrue(
            try harness.store.pendingAgentNotifications(subscriberTerminalSessionID: sessionID).isEmpty,
            "the subscriber's pending notification is removed")
        XCTAssertTrue(
            try harness.store.agentRemoteSubscriptions(subscriberTerminalSessionID: sessionID).isEmpty,
            "the subscriber's remote watch edge is removed")
        XCTAssertNotNil(try harness.store.agentWindow(id: child.id), "the watched child agent row is untouched by the subscriber-side delete")
    }

    // MARK: - Next-run override

    /// A one-time override fires at its own instant instead of the cron schedule's, then the cron schedule
    /// resumes computing subsequent occurrences from its expression (not from the overridden instant).
    func testNextRunOverrideFiresAtItsTimeAndCronResumes() throws {
        let utc = TimeZone(identifier: "UTC")!
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try Harness(self, now: clock.now, timeZone: { utc })
        let automation = try harness.insertAutomation(triggerKind: .cron, cronExpression: "0 9 * * *")
        try harness.service.computeInitialNextFireTime(automationID: automation.id)
        let cronAnchor = try XCTUnwrap(harness.store.automation(id: automation.id)?.nextFireTime)

        let overrideTime = clock.now().addingTimeInterval(60)
        XCTAssertLessThan(overrideTime, cronAnchor, "the override fires before the cron anchor it temporarily replaces")
        _ = try harness.service.setAutomationNextRunTime(id: automation.id, nextRunTime: overrideTime)

        harness.service.tick()
        XCTAssertTrue(try harness.store.automationRuns(automationID: automation.id).isEmpty, "no run fires before the override's own time")

        clock.advance(by: 61)
        harness.service.tick()

        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.count, 1, "exactly one run fires at the override")
        XCTAssertEqual(runs.first?.trigger, .scheduled, "the fire is attributed to the override, not to cron")

        let refreshed = try XCTUnwrap(harness.store.automation(id: automation.id))
        XCTAssertNil(refreshed.nextFireOverride, "the override is cleared once it fires")
        let schedule = try AutomationCronSchedule.parse("0 9 * * *")
        XCTAssertEqual(
            refreshed.nextFireTime, schedule.nextFireDate(after: clock.now(), timeZone: utc),
            "the cron schedule resumes from its expression, computed from now")
    }

    /// A pending override outranks a due cron anchor it outran: ordinary cron firing is suppressed until the
    /// override itself fires (or is replaced by an edit).
    func testPendingOverrideSuppressesTheCronOccurrenceItOutran() throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try Harness(self, now: clock.now)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", nextFireTime: clock.now().addingTimeInterval(-60))
        _ = try harness.service.setAutomationNextRunTime(id: automation.id, nextRunTime: clock.now().addingTimeInterval(3600))

        harness.service.tick()

        XCTAssertTrue(
            try harness.store.automationRuns(automationID: automation.id).isEmpty, "the pending override suppresses the due cron occurrence")
    }

    /// A manual automation has no cron schedule to resume, so its override fires exactly once and leaves the
    /// automation with no next fire time afterward.
    func testManualAutomationOverrideFiresOnceAsAOneShot() throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try Harness(self, now: clock.now)
        let automation = try harness.insertAutomation(triggerKind: .manual)
        _ = try harness.service.setAutomationNextRunTime(id: automation.id, nextRunTime: clock.now().addingTimeInterval(60))

        clock.advance(by: 61)
        harness.service.tick()

        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.count, 1, "the override fires exactly once")
        XCTAssertEqual(runs.first?.trigger, .scheduled)
        let refreshed = try XCTUnwrap(harness.store.automation(id: automation.id))
        XCTAssertNil(refreshed.nextFireOverride, "the override is consumed")
        XCTAssertNil(refreshed.nextFireTime, "a manual automation has no cron anchor to resume")

        harness.service.tick()
        XCTAssertEqual(try harness.store.automationRuns(automationID: automation.id).count, 1, "a further tick does not fire again")
    }

    /// A pending override is the user's explicit claim on the next run: a restart neither fires a missed cron
    /// catch-up nor re-anchors while it stands, and an override whose time passed while the daemon was down
    /// fires (late) on the first tick of the fresh service.
    func testOverrideSurvivesDaemonRestartReconcileAndFiresLate() throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try Harness(self, now: clock.now)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .runOnce,
            nextFireTime: clock.now().addingTimeInterval(-3 * 24 * 60 * 60))
        let overrideTime = clock.now().addingTimeInterval(60)
        _ = try harness.service.setAutomationNextRunTime(id: automation.id, nextRunTime: overrideTime)

        harness.makeService().reconcileMissedRunsOnStart()

        XCTAssertTrue(
            try harness.store.automationRuns(automationID: automation.id).isEmpty,
            "a restart neither catches up nor advances the anchor while an override is pending")
        XCTAssertEqual(
            try harness.store.automation(id: automation.id)?.nextFireOverride, overrideTime, "the override persists across the restart reconcile")

        clock.advance(by: 61)
        harness.makeService().tick()

        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.count, 1, "the overdue override fires late on the first tick of the fresh service")
        XCTAssertEqual(runs.first?.trigger, .scheduled)
    }

    /// An override is an absolute instant the user picked outright, not a derived anchor, so a device
    /// time-zone change leaves it untouched even while it moves the cron anchor.
    func testOverrideSurvivesTimeZoneRecompute() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let zone = MutableTimeZone(newYork)
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_705_341_600))
        let harness = try Harness(self, now: clock.now, timeZone: zone.provide)
        let automation = try harness.insertAutomation(triggerKind: .cron, cronExpression: "0 9 * * *")
        try harness.service.computeInitialNextFireTime(automationID: automation.id)
        let cronAnchorBefore = try XCTUnwrap(harness.store.automation(id: automation.id)?.nextFireTime)

        let overrideTime = clock.now().addingTimeInterval(3 * 24 * 60 * 60)
        _ = try harness.service.setAutomationNextRunTime(id: automation.id, nextRunTime: overrideTime)

        zone.set(losAngeles)
        harness.service.tick()

        let refreshed = try XCTUnwrap(harness.store.automation(id: automation.id))
        XCTAssertEqual(refreshed.nextFireOverride, overrideTime, "the user-picked override is byte-identical after the zone change")
        XCTAssertNotEqual(refreshed.nextFireTime, cronAnchorBefore, "the cron anchor still moves when the zone changes")
    }

    /// An explicit edit re-authors the automation's schedule, so it also clears any pending one-time
    /// next-run override rather than leaving a stale override standing against the edited automation.
    func testUpdatingAnAutomationClearsItsNextRunOverride() throws {
        // A fixed whole-second clock, matching the other override tests: the real wall clock's fractional
        // seconds survive a Swift round trip but can lose precision through SQLite's REAL affinity text
        // conversion, which would make the exact-equality assertion below flaky for reasons unrelated to
        // the behavior under test.
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try Harness(self, now: clock.now)
        let draft = AutomationDraft(
            name: "Nightly", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "true", agentCommand: nil,
            agentPrompt: nil, workspaceID: "workspace-1", timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce)
        let created = try harness.service.createAutomation(draft)
        let overrideTime = harness.now().addingTimeInterval(60)
        _ = try harness.service.setAutomationNextRunTime(id: created.id, nextRunTime: overrideTime)
        XCTAssertEqual(try harness.store.automation(id: created.id)?.nextFireOverride, overrideTime, "the override is set before the edit")

        var editedDraft = draft
        editedDraft.name = "Nightly (renamed)"
        _ = try harness.service.updateAutomation(id: created.id, draft: editedDraft)

        XCTAssertNil(try harness.store.automation(id: created.id)?.nextFireOverride, "an explicit edit clears the pending override")
    }

    func testSchedulingAPastTimeIsRejected() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(triggerKind: .manual)
        XCTAssertThrowsError(try harness.service.setAutomationNextRunTime(id: automation.id, nextRunTime: harness.now().addingTimeInterval(-60))) {
            error in XCTAssertTrue(error is AutomationValidationError, "a past next-run time is rejected as invalid")
        }
        XCTAssertNil(try harness.store.automation(id: automation.id)?.nextFireOverride, "the rejected schedule never persists an override")
    }

    func testSchedulingADisabledAutomationIsRejected() throws {
        let harness = try Harness(self)
        let enabled = try harness.insertAutomation(triggerKind: .manual)
        // Disable directly through the store: the harness's `insertAutomation` always creates an enabled row,
        // and disabling through `updateAutomation` is not the behavior under test here.
        let disabled = Automation(
            id: enabled.id, name: enabled.name, enabled: false, triggerKind: enabled.triggerKind, cronExpression: enabled.cronExpression,
            kind: enabled.kind, script: enabled.script, workspaceID: enabled.workspaceID, timeoutSeconds: enabled.timeoutSeconds,
            concurrencyPolicy: enabled.concurrencyPolicy, missedRunPolicy: enabled.missedRunPolicy, nextFireTime: enabled.nextFireTime,
            createdAt: enabled.createdAt, updatedAt: enabled.updatedAt)
        try harness.store.upsertAutomation(disabled)

        XCTAssertThrowsError(try harness.service.setAutomationNextRunTime(id: enabled.id, nextRunTime: harness.now().addingTimeInterval(60))) {
            error in XCTAssertTrue(error is AutomationValidationError, "scheduling a disabled automation is rejected")
        }
        XCTAssertNil(try harness.store.automation(id: enabled.id)?.nextFireOverride, "the rejected schedule never persists an override")
    }

    /// The concurrency gate applies to an override fire exactly as it does to any other trigger: a `.skip`
    /// automation with a run already active records the override fire as a skipped/concurrency row, and the
    /// override is still consumed (cleared) rather than retried on every subsequent tick forever.
    func testOverrideFireObeysTheConcurrencyPolicy() throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try Harness(self, now: clock.now)
        let automation = try harness.insertAutomation(concurrency: .skip)
        let running = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(running.status, .running, "a run is active before the override fires")

        _ = try harness.service.setAutomationNextRunTime(id: automation.id, nextRunTime: clock.now().addingTimeInterval(60))
        clock.advance(by: 61)
        harness.service.tick()

        let runs = try harness.store.automationRuns(automationID: automation.id)
        let scheduled = try XCTUnwrap(runs.first { $0.trigger == .scheduled }, "the override fires despite the active run")
        XCTAssertEqual(scheduled.status, .skipped, "the skip concurrency policy still applies to an override fire")
        XCTAssertEqual(scheduled.skipReason, .concurrency)
        XCTAssertNil(try harness.store.automation(id: automation.id)?.nextFireOverride, "the override is consumed rather than retried forever")
    }
}

// MARK: - Test harness

@MainActor private final class Harness {
    let store: SQLiteStore
    let orchestrator: WorkspaceOrchestrator
    let host: FakeAutomationTerminalHost
    let service: AutomationService
    let now: () -> Date
    private let timeZone: @Sendable () -> TimeZone
    private let retentionLimit: Int
    private let realCommands: Bool

    init(
        _ testCase: XCTestCase, realCommands: Bool = false, now: @escaping () -> Date = Date.init,
        timeZone: @escaping @Sendable () -> TimeZone = { .current }, retentionLimit: Int = 100,
        ticksSuspended: @escaping @Sendable () -> Bool = { false }
    ) throws {
        store = try testCase.makeTemporaryStore()
        let workspaceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let project = makeProjectRecord(dir: workspaceDirectory.deletingLastPathComponent().path)
        try store.upsert(project: project)
        try store.upsert(workspace: makeWorkspaceRecord(id: "workspace-1", projectID: project.id, dir: workspaceDirectory.path))
        let host = FakeAutomationTerminalHost(realCommands: realCommands)
        self.host = host
        self.realCommands = realCommands
        host.install()
        testCase.addTeardownBlock { host.uninstall() }
        orchestrator = WorkspaceOrchestrator(store: store)
        self.now = now
        self.timeZone = timeZone
        self.retentionLimit = retentionLimit
        service = AutomationService(
            store: store, orchestrator: orchestrator, binaryDirectory: "/usr/bin", timeZone: timeZone, now: now, terminationGrace: 0.2,
            retentionLimit: retentionLimit, ticksSuspended: ticksSuspended, logError: { _ in })
    }

    /// Builds a fresh `AutomationService` over the same store/orchestrator, modeling a daemon restart:
    /// nothing is carried in memory, so a new instance must resume purely from the persisted run rows.
    func makeService() -> AutomationService {
        AutomationService(
            store: store, orchestrator: orchestrator, binaryDirectory: "/usr/bin", timeZone: timeZone, now: now, terminationGrace: 0.2,
            retentionLimit: retentionLimit, logError: { _ in })
    }

    func insertAutomation(
        script: String = "true", kind: AutomationKind = .script, triggerKind: AutomationTriggerKind = .manual, cronExpression: String? = nil,
        concurrency: AutomationConcurrencyPolicy = .allow, missedRunPolicy: AutomationMissedRunPolicy = .runOnce, timeoutSeconds: Int? = nil,
        nextFireTime: Date? = nil, workspaceID: String = "workspace-1", nextFireOverride: Date? = nil
    ) throws -> Automation {
        let automation = Automation(
            id: UUID().uuidString, name: "Test", enabled: true, triggerKind: triggerKind, cronExpression: cronExpression, kind: kind, script: script,
            workspaceID: workspaceID, timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrency, missedRunPolicy: missedRunPolicy,
            nextFireTime: nextFireTime, createdAt: now(), updatedAt: now(), nextFireOverride: nextFireOverride)
        try store.upsertAutomation(automation)
        return automation
    }

    func insertAgentAutomation(
        workspaceID: String, command: String = "codex", prompt: String = "investigate the failing test",
        concurrency: AutomationConcurrencyPolicy = .allow, timeoutSeconds: Int? = nil
    ) throws -> Automation {
        let automation = Automation(
            id: UUID().uuidString, name: "Agent Test", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .agent, script: "",
            agentCommand: command, agentPrompt: prompt, workspaceID: workspaceID, timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrency,
            missedRunPolicy: .runOnce, nextFireTime: nil, createdAt: now(), updatedAt: now())
        try store.upsertAutomation(automation)
        return automation
    }

    /// Registers a Spaces agent orchestration row bound to a spawned agent session's terminal id, modeling
    /// the row that appears once the agent reports a hook signal.
    @discardableResult func registerAgentRow(workspaceID: String, sessionID: String, status: AgentWindowStatus) throws -> AgentWindowRecord {
        try orchestrator.registerAgentWindow(
            workspaceID: workspaceID, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: status)
    }

    @discardableResult func insertRun(automationID: String, kind: AutomationKind = .script, status: AutomationRunStatus, createdAt: Date? = nil)
        throws -> AutomationRun
    {
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automationID, kind: kind, status: status, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: nil, startedAt: status == .running ? (createdAt ?? now()) : nil,
            endedAt: status.isTerminal ? (createdAt ?? now()) : nil, createdAt: createdAt ?? now())
        try store.insertAutomationRun(run)
        return run
    }

    func makeProjectAndWorkspace() throws -> (ProjectRecord, WorkspaceRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: dir + "/ws")
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    /// Writes an attributed terminal session (workspace-scoped, stamped with the run id) to the store and to
    /// disk, WITHOUT an agent row — the session the product creates for a spawned agent before it signals, or
    /// a plain `.automation` wrapper session. `live` controls whether the runtime state reads as interactive
    /// with a live control socket; `kind` distinguishes an agent-launch session from the run's own wrapper.
    func writeAttributedSessionFiles(
        workspaceID: String?, runID: String, sessionID: String, kind: TerminalSessionKind, live: Bool, title: String = "agent"
    ) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: title, workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: "2026-06-06T00:00:00Z", workspaceID: workspaceID, kind: kind, automationRunID: runID), paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: Data("agent transcript\n".utf8))
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: live ? getpid() : 1, childPID: nil, state: live ? .running : .exited,
                updatedAt: "2026-06-06T00:00:01Z", exitedAt: live ? nil : "2026-06-06T00:00:01Z", title: title), paths: paths)
        if live { FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()) }
    }

    /// Writes ONLY a launch configuration for a session — no runtime state and no control socket — modeling
    /// the write-behind window just after a launch where the runtime row has not landed yet. `createdAt`
    /// drives whether `builtInSessionLaunchIsPending` reads the launch as still coming up (recent) or stale
    /// (old).
    func writeLaunchConfigurationOnly(workspaceID: String?, runID: String, sessionID: String, kind: TerminalSessionKind, createdAt: Date) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "cmd", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: TerminalSessionTimestamp.string(from: createdAt), workspaceID: workspaceID, kind: kind, automationRunID: runID),
            paths: paths)
    }

    func setRuntimeChildPID(sessionID: String, childPID: Int32) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: childPID, state: .running,
                updatedAt: "2026-06-06T00:00:01Z", title: "cmd"), paths: paths)
    }

    /// Writes an attributed coding-agent terminal session (workspace-scoped, stamped with the run id) plus
    /// its agent row, modeling a `spaces agent spawn` a run's command performed. `live` controls whether the
    /// runtime state reads as interactive with a live control socket; `status` is the agent row's status.
    @discardableResult func writeAttributedAgentSession(
        workspaceID: String, runID: String, sessionID: String, live: Bool, status: AgentWindowStatus = .spinning
    ) throws -> AgentWindowRecord {
        try writeAttributedSessionFiles(workspaceID: workspaceID, runID: runID, sessionID: sessionID, kind: .agent, live: live)
        return try orchestrator.registerAgentWindow(
            workspaceID: workspaceID, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: status)
    }

    /// Seeds the workspace-side state a spawned agent session persists at launch time (`createWorkspaceAgentSession`):
    /// a tracked terminal window keyed by the session id and the workspace marked running. Modeling this
    /// without an agent row reproduces a session that ended before the foreground reconciler registered its
    /// row. Returns the tracked window's id.
    @discardableResult func seedSpawnedAgentWorkspaceTracking(workspace: WorkspaceRecord, sessionID: String, title: String = "agent") throws -> String
    {
        let windowRecordID = UUID().uuidString
        try store.upsert(
            window: WindowRecord(
                id: windowRecordID, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: title, detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "2026-06-06T00:00:00Z"))
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-06-06T00:00:00Z")
        return windowRecordID
    }

    /// Writes the exit-code sentinel a wrapped command records at its own exit (`AutomationPaths.exitCodePath`),
    /// modeling a script that finished and recorded its status while its exited runtime row is still write-behind.
    func writeExitCodeSentinel(runID: String, exitCode: Int) throws {
        try AutomationPaths.ensureRunDirectory(runID: runID)
        try String(exitCode).write(to: try AutomationPaths.exitCodePath(runID: runID), atomically: true, encoding: .utf8)
    }

    /// Counts the `terminal_agent_signal_events` rows keyed to a session id in the profile store, used to
    /// assert the companion signal history is pruned with the session.
    func signalEventCount(sessionID: String) throws -> Int {
        try store.queryRows(sql: "SELECT COUNT(*) FROM terminal_agent_signal_events WHERE session_id = ?", bindings: [sessionID]).first?.first
            .flatMap(Int.init) ?? 0
    }

    /// Drives `tick()` until a run reaches a terminal status, waiting for the fake host's background waiter
    /// to publish the command's ended runtime state. Fails if the run does not settle within the deadline.
    ///
    /// The terminal status and the ended runtime state are two independently timed signals: the status
    /// comes from the exit-code sentinel the wrapped script writes, the runtime state from the host's
    /// detached `waitpid` thread. A real-command harness therefore keeps ticking until that thread has
    /// published, and ticks once more so the tick-driven cleanup that keys on the ended state (detaching
    /// the run's runtime target) has applied. A fake-command host never publishes an ended state, so the
    /// wait is scoped to real commands; waiting there would block until the deadline.
    func runUntilTerminal(runID: String, timeout: TimeInterval = 5) throws -> AutomationRun {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            service.tick()
            if let run = try store.automationRun(id: runID), run.status.isTerminal {
                guard realCommands, let sessionID = run.terminalSessionID else { return run }
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                    service.tick()
                    return run
                }
            }
            usleep(30_000)
        }
        throw XCTSkip("run \(runID) did not reach a terminal status within \(timeout)s")
    }

    /// What actually became of a child process. `kill(pid, 0)` cannot distinguish a zombie from a running
    /// process, so use Darwin's process table to make termination assertions meaningful in CI.
    private enum ProcessLifecycle: String {
        case running
        case zombie
        case reaped
    }

    private static func processLifecycle(_ pid: Int32) -> ProcessLifecycle {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return .reaped }
        return Int32(info.kp_proc.p_stat) == SZOMB ? .zombie : .running
    }

    func processIsRunning(_ pid: Int32) -> Bool { Self.processLifecycle(pid) == .running }

    private static func processDiagnostics(_ pid: Int32) -> String {
        let lifecycle = processLifecycle(pid).rawValue
        let processGroup = getpgid(pid)
        let processGroupDescription = processGroup >= 0 ? String(processGroup) : "unavailable (errno \(errno))"
        return "lifecycle=\(lifecycle), processGroup=\(processGroupDescription)"
    }

    /// Asserts a process dies across a bounded polling budget, driving escalation ticks so a command that
    /// ignored SIGTERM receives SIGKILL without making CI scheduler latency consume its observation window.
    func assertProcessDies(pid: Int32, drivingTicks tick: () -> Void, timeout: TimeInterval = 3) throws {
        // Count polling opportunities rather than ending against a wall-clock deadline. A heavily loaded CI
        // worker can deschedule this test for the whole nominal interval after the first check; it must still
        // get enough chances to observe the already-delivered signal when it resumes.
        let pollInterval: TimeInterval = 0.03
        let attempts = max(1, Int(ceil(timeout / pollInterval)))
        for _ in 0..<attempts {
            // A SIGKILLed child may remain as a zombie until its owner reaps it. Both states mean it
            // cannot execute; only the running state indicates that escalation failed.
            if Self.processLifecycle(pid) != .running { return }
            tick()
            usleep(useconds_t(pollInterval * 1_000_000))
        }
        XCTFail("process \(pid) was not terminated after \(attempts) polls (\(Self.processDiagnostics(pid)))")
    }
}

/// A settable time-zone provider so the zone-change test can move the "device" across zones between ticks.
private final class MutableTimeZone: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeZone
    init(_ start: TimeZone) { current = start }
    func provide() -> TimeZone {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func set(_ zone: TimeZone) {
        lock.lock()
        current = zone
        lock.unlock()
    }
}

/// A settable clock so timeout tests can jump past a budget without waiting real time while the command
/// process runs in real time.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { current = start }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

/// A small process group owned by the test itself. The leader uses the platform's default SIGTERM handling,
/// while the survivor inherits SIGTERM ignored from the test process just for its `posix_spawn` call. Both are
/// direct `/bin/sleep` children, and the test retains their pids so it can wait for each child instead of
/// inferring descendant state through a shell pid file.
private final class AutomationProcessGroupFixture {
    let leaderPID: Int32
    let survivorPID: Int32
    private var leaderReaped = false
    private var survivorReaped = false
    private var cleaned = false

    init() throws {
        let leader = try Self.spawnSleep(processGroup: 0, ignoresSIGTERM: false)
        do {
            let survivor = try Self.spawnSleep(processGroup: leader, ignoresSIGTERM: true)
            leaderPID = leader
            survivorPID = survivor
        } catch {
            _ = kill(-leader, SIGKILL)
            Self.reap(leader)
            throw error
        }
    }

    deinit { terminateAndReap() }

    /// Waits until the group leader has both exited and been reaped. This is intentionally a waitpid-based
    /// assertion: a zombie still makes `kill(pid, 0)` look alive and would make the setup scheduler-dependent.
    func waitForLeaderExit(timeout: TimeInterval = 3) throws {
        var status: Int32 = 0
        let pollInterval: TimeInterval = 0.03
        let attempts = max(1, Int(ceil(timeout / pollInterval)))
        for _ in 0..<attempts {
            let result = waitpid(leaderPID, &status, WNOHANG)
            if result == leaderPID || (result == -1 && errno == ECHILD) {
                leaderReaped = true
                return
            }
            if result == -1, errno != EINTR { break }
            usleep(useconds_t(pollInterval * 1_000_000))
        }
        throw NSError(
            domain: "AutomationProcessGroupFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "process group leader \(leaderPID) did not exit within \(timeout)s"])
    }

    /// Terminates the complete group and reaps both directly spawned children. It is safe after the service
    /// already killed either member: waitpid then returns ECHILD for that member and cleanup continues.
    func terminateAndReap() {
        guard !cleaned else { return }
        // Keep the group kill while the survivor may still hold the group open, but do not signal the
        // leader by raw pid after waitForLeaderExit has already reaped it (the pid could be reused).
        if !survivorReaped { _ = kill(-leaderPID, SIGKILL) }
        if !leaderReaped {
            _ = kill(leaderPID, SIGKILL)
            Self.reap(leaderPID)
            leaderReaped = true
        }
        if !survivorReaped {
            _ = kill(survivorPID, SIGKILL)
            Self.reap(survivorPID)
            survivorReaped = true
        }
        cleaned = true
    }

    private static func spawnSleep(processGroup: Int32, ignoresSIGTERM: Bool) throws -> Int32 {
        let previousHandler = ignoresSIGTERM ? signal(SIGTERM, SIG_IGN) : nil
        defer { if let previousHandler { _ = signal(SIGTERM, previousHandler) } }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw spawnError() }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw spawnError() }
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        if !ignoresSIGTERM {
            var defaultSignals = sigset_t()
            sigemptyset(&defaultSignals)
            sigaddset(&defaultSignals, SIGTERM)
            guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0 else { throw spawnError() }
            flags |= Int16(POSIX_SPAWN_SETSIGDEF)
        }
        guard posix_spawnattr_setflags(&attributes, flags) == 0, posix_spawnattr_setpgroup(&attributes, pid_t(processGroup)) == 0 else {
            throw spawnError()
        }

        let arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/sleep", "60"].map { argument in argument.withCString { strdup($0) } }
        let allocatedArguments = arguments
        var cArguments = arguments + [nil]
        defer { for argument in allocatedArguments { free(argument) } }
        var pid: pid_t = 0
        let result = cArguments.withUnsafeMutableBufferPointer { buffer in
            "/bin/sleep".withCString { path in posix_spawn(&pid, path, &actions, &attributes, buffer.baseAddress, environ) }
        }
        guard result == 0 else { throw spawnError(result) }
        return pid
    }

    private static func reap(_ pid: Int32) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    private static func spawnError(_ code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed: \(String(cString: strerror(code)))"])
    }
}

/// Process-wide terminal-session launcher/terminator stand-in for the daemon's PTY session machinery. In
/// `realCommands` mode it runs the exact wrapped command the executor built (`/bin/sh -c …`) in its own
/// session via `posix_spawn` (so a timeout's process-group signal is safe and effective), redirecting
/// output to the session's `output.log`, and publishes the session's `.running` then `.exited` runtime
/// state. Otherwise it writes a non-completing `.running` session so concurrency/retention tests observe a
/// run that stays running until the test ends it.
private final class FakeAutomationTerminalHost: @unchecked Sendable {
    private let realCommands: Bool
    private let lock = NSLock()
    var delivered: [(sessionID: String, line: String)] {
        lock.lock()
        defer { lock.unlock() }
        return deliveredStore
    }
    private var deliveredStore: [(sessionID: String, line: String)] = []
    /// Raw terminal-input writes the automation executor made, in order — the seam the agent-kind executor
    /// delivers its seed prompt through. Agent-prompt tests assert the single submit-send
    /// (`appendNewline: true`), whose spaced text+Enter split lives at the session host's send chokepoint.
    var writtenInput: [(sessionID: String, input: TerminalProfileInput, appendNewline: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return writtenInputStore
    }
    private var writtenInputStore: [(sessionID: String, input: TerminalProfileInput, appendNewline: Bool)] = []
    /// When set, every input write is attempted and then reported as failed, standing in for a daemon send
    /// whose bytes never reached the PTY (the session went away between enqueue and write). The write is
    /// still recorded, so a test can tell "attempted but not acknowledged" from "never attempted".
    private var inputWriteFailureMessage: String?
    /// Session ids the executor asked to terminate through the process-wide terminator seam, in order — the
    /// seam a timeout/cancel no-PID teardown uses to end a whole session.
    var terminated: [String] {
        lock.lock()
        defer { lock.unlock() }
        return terminatedStore
    }
    private var terminatedStore: [String] = []
    private var trackedPIDs: [Int32] = []

    init(realCommands: Bool) { self.realCommands = realCommands }

    func install() {
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher { [weak self] configuration in
            guard let self else { throw NSError(domain: "test", code: 1) }
            return try self.launch(configuration)
        }
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator { [weak self] sessionID in self?.terminate(sessionID: sessionID) }
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { [weak self] sessionID, line in
            self?.lock.lock()
            self?.deliveredStore.append((sessionID: sessionID, line: line))
            self?.lock.unlock()
        }
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionInputWriter { [weak self] sessionID, input, appendNewline in
            guard let self else { return }
            self.lock.lock()
            self.writtenInputStore.append((sessionID: sessionID, input: input, appendNewline: appendNewline))
            let failure = self.inputWriteFailureMessage
            self.lock.unlock()
            if let failure { throw WorkspaceError.invalidArgument(message: failure) }
        }
    }

    func uninstall() {
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher(nil)
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator(nil)
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil)
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionInputWriter(nil)
        lock.lock()
        let pids = trackedPIDs
        lock.unlock()
        for pid in pids { kill(pid, SIGKILL) }
    }

    func markSessionEnded(sessionID: String) {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
        writeRuntimeState(sessionID: sessionID, paths: paths, state: .exited, childPID: nil)
    }

    /// Marks a session as ended with the platform's recorded failure state (`.failed`), modeling an agent
    /// session that crashed rather than closed cleanly.
    func markSessionFailed(sessionID: String) {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
        writeRuntimeState(sessionID: sessionID, paths: paths, state: .failed, childPID: nil)
    }

    /// Makes the daemon's send path report every write as failed until `acknowledgeInputWrites()`.
    func failInputWrites(message: String = "Terminal session stopped accepting input before the send reached it.") {
        lock.lock()
        inputWriteFailureMessage = message
        lock.unlock()
    }

    func acknowledgeInputWrites() {
        lock.lock()
        inputWriteFailureMessage = nil
        lock.unlock()
    }

    /// Publishes the daemon's live runtime state for a session (still `.running`): the foreground-detection
    /// result and whether the program running in it has bracketed paste enabled. The agent-kind executor
    /// waits for BOTH before delivering the prompt, so `bracketedPasteActive: false` models the window
    /// between the agent process being identified and its TUI actually reading input.
    func markSessionForegroundDetected(sessionID: String, kind: TerminalDetectedAgentKind = .codex, bracketedPasteActive: Bool = true) {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
        try? TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
                updatedAt: ISO8601DateFormatter().string(from: Date()), foregroundDetectedAgentKind: kind,
                bracketedPasteActive: bracketedPasteActive), paths: paths)
    }

    private func launch(_ configuration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary {
        let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
        FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())

        var childPID: Int32?
        if realCommands, let command = configuration.command {
            let pid = Self.spawnDetachedSession(command: command, workingDirectory: configuration.workingDirectory, outputPath: paths.outputPath)
            childPID = pid
            lock.lock()
            trackedPIDs.append(pid)
            lock.unlock()
            writeRuntimeState(sessionID: configuration.sessionID, paths: paths, state: .running, childPID: pid)
            Thread.detachNewThread {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                self.writeRuntimeState(sessionID: configuration.sessionID, paths: paths, state: .exited, childPID: pid)
            }
        } else {
            writeRuntimeState(sessionID: configuration.sessionID, paths: paths, state: .running, childPID: nil)
        }

        return TerminalServiceSessionSummary(
            id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory, backend: configuration.backend,
            lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: getpid(), childPID: childPID,
            controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
    }

    private func terminate(sessionID: String) {
        lock.lock()
        terminatedStore.append(sessionID)
        lock.unlock()
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
        writeRuntimeState(sessionID: sessionID, paths: paths, state: .exited, childPID: nil)
        try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
    }

    private func writeRuntimeState(sessionID: String, paths: TerminalSessionPaths, state: TerminalSessionState, childPID: Int32?) {
        try? TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: childPID, state: state,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                exitedAt: state.isInteractive ? nil : ISO8601DateFormatter().string(from: Date())), paths: paths)
    }

    /// Spawns `/bin/sh -c command` in a fresh session (so it becomes its own process-group leader, exactly
    /// like a PTY child), with stdout/stderr redirected to `outputPath`. Returns the child pid, or -1.
    private static func spawnDetachedSession(command: String, workingDirectory: String, outputPath: String) -> Int32 {
        #if canImport(Darwin)
            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            posix_spawn_file_actions_addopen(&fileActions, 1, outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

            var cArguments: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", command].map { $0.withCString { strdup($0) } }
            cArguments.append(nil)
            defer { for argument in cArguments where argument != nil { free(argument) } }

            var pid: pid_t = 0
            let result = cArguments.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, buffer.baseAddress, environ)
            }
            return result == 0 ? pid : -1
        #else
            return -1
        #endif
    }
}
