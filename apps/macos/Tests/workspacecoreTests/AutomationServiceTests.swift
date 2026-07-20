import XCTest
import spacesterminalcore

@testable import workspacecore

#if canImport(Darwin)
    import Darwin
#endif

/// Behavior coverage for the scheduled-automation scheduler and executor: the concurrency policy matrix,
/// missed-run catch-up on daemon start, the ended-only attributed-session sweep, run-history retention, and
/// the executor's real exit-code/timeout/cancel handling. Session launches route through a process-wide
/// fake terminal host so no real daemon or Ghostty PTY is needed; the exit-code, timeout, and cancel tests
/// run real short shell commands through that host so the executor's command wrapping and signal escalation
/// are exercised end to end.
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

    // MARK: - Missed-run catch-up

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
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .skip,
            nextFireTime: harness.now().addingTimeInterval(-3 * 24 * 60 * 60))
        harness.service.reconcileMissedRunsOnStart()
        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .skipped)
        XCTAssertEqual(runs.first?.skipReason, .missed)
    }

    func testFutureNextFireTimeIsNotCaughtUp() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .runOnce,
            nextFireTime: harness.now().addingTimeInterval(60 * 60))
        harness.service.reconcileMissedRunsOnStart()
        XCTAssertTrue(try harness.store.automationRuns(automationID: automation.id).isEmpty)
    }

    // MARK: - Attributed-session sweep

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
        XCTAssertTrue(try harness.store.terminalSessionIDs(automationRunID: priorRun.id).contains(liveSessionID), "the live session survives the sweep")
        XCTAssertFalse(
            try harness.store.terminalSessionIDs(automationRunID: priorRun.id).contains(endedSessionID), "the ended session is removed from the product")
        XCTAssertTrue(harness.host.delivered.contains { $0.sessionID == "watcher" && $0.line.contains("exited") }, "the watcher is told the child exited")
    }

    // MARK: - Retention

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
        let running = try harness.insertRun(
            automationID: automation.id, status: .running, createdAt: harness.now().addingTimeInterval(1000))
        harness.service.cancelRun(runID: running.id)

        XCTAssertEqual(try harness.store.automationRuns(automationID: automation.id).count, 100, "only the newest 100 runs are kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(oldestRunDir).path), "a pruned run's artifact directory is deleted")
    }

    // MARK: - Executor exit codes

    func testExecutorRecordsZeroExitAsSucceeded() throws {
        let harness = try Harness(self, realCommands: true)
        let automation = try harness.insertAutomation(script: "exit 0", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let finished = try harness.runUntilTerminal(runID: run.id)
        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertEqual(finished.exitCode, 0)
    }

    func testExecutorRecordsNonZeroExitCode() throws {
        let harness = try Harness(self, realCommands: true)
        let automation = try harness.insertAutomation(script: "exit 3", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let finished = try harness.runUntilTerminal(runID: run.id)
        XCTAssertEqual(finished.status, .failed)
        XCTAssertEqual(finished.exitCode, 3)
    }

    // MARK: - Agent kind execution

    /// Happy path: spawn the agent, wait for foreground detection, deliver the seed prompt as two
    /// independent writes (text then a bare CR) in order, persist `promptDeliveredAt`, and complete
    /// `succeeded` on the agent row's `done` signal with the session left open (never killed).
    func testAgentRunSpawnsDetectsDeliversPromptAndSucceedsOnDone() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAgentAutomation(workspaceID: workspace.id, prompt: "investigate the failing test")
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let sessionID = try XCTUnwrap(harness.store.automationRun(id: run.id)?.terminalSessionID, "the run records its spawned agent session")

        // Before detection nothing is delivered.
        harness.service.tick()
        XCTAssertTrue(harness.host.writtenInput.isEmpty, "no prompt is delivered until the agent is detected")
        XCTAssertNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt)

        // Detection → the next tick delivers the prompt as two writes and records delivery.
        harness.host.markSessionForegroundDetected(sessionID: sessionID)
        harness.service.tick()
        let writes = harness.host.writtenInput
        XCTAssertEqual(writes.count, 2, "the prompt is delivered as two independent writes")
        XCTAssertEqual(writes.first?.input, .text("investigate the failing test"), "the first write is the verbatim prompt text")
        XCTAssertEqual(writes.last?.input, .bytes(Data([0x0D])), "the second write is a bare CR (byte 13)")
        XCTAssertEqual(writes.map(\.sessionID), [sessionID, sessionID])
        XCTAssertNotNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt, "delivery is persisted once the CR write succeeds")

        // A second tick before `done` neither re-sends nor completes the run.
        harness.service.tick()
        XCTAssertEqual(harness.host.writtenInput.count, 2, "a delivered prompt is not re-sent")
        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .running)

        // The agent row signals done → succeeded, and the session is left open.
        _ = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: sessionID, status: .done)
        harness.service.tick()
        let finished = try XCTUnwrap(harness.store.automationRun(id: run.id))
        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertNil(finished.exitCode)
        XCTAssertTrue(harness.orchestrator.automationSessionIsLive(sessionID: sessionID), "a done agent's session stays open")
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
        XCTAssertEqual(harness.host.writtenInput.count, 2, "the detecting phase resumes into prompt delivery after a restart")
        XCTAssertNotNil(try harness.store.automationRun(id: run.id)?.promptDeliveredAt)

        // Phase 2 (delivered): another restarted service resumes into awaiting the done signal.
        _ = try harness.registerAgentRow(workspaceID: workspace.id, sessionID: sessionID, status: .done)
        let resumed2 = harness.makeService()
        resumed2.tick()
        XCTAssertEqual(harness.host.writtenInput.count, 2, "the delivered phase does not re-send the prompt after a restart")
        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .succeeded)
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

    /// A script run's own workspace-less `.automation` wrapper session is attributed but is not a coding
    /// agent, so it never appears in the attributed-agent breakdown.
    func testAttributedAgentSummariesExcludeNonAgentSessions() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        let run = try harness.insertRun(automationID: automation.id, status: .running)
        let sessionID = UUID().uuidString
        try harness.writeAttributedSessionFiles(workspaceID: nil, runID: run.id, sessionID: sessionID, kind: .automation, live: true)

        let byRunID = try AutomationAttributedAgents.summariesByRunID(
            runs: [run], store: harness.store, liveSessions: try TerminalSessionCatalog.listLiveSessions())
        XCTAssertEqual(byRunID[run.id], [], "the .automation wrapper session is not a coding agent")
    }

    // MARK: - Timeout + cancel

    func testTimeoutKillsCommandAndRecordsTimedOut() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, realCommands: true, now: clock.now)
        let automation = try harness.insertAutomation(script: "sleep 30", concurrency: .allow, timeoutSeconds: 1)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let childPID = try XCTUnwrap(harness.host.lastChildPID)

        clock.advance(by: 5)  // push past the 1s budget without waiting
        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .timedOut)
        try harness.assertProcessDies(pid: childPID, drivingTicks: harness.service.tick)
    }

    func testCancelKillsCommandAndRecordsCanceled() throws {
        let harness = try Harness(self, realCommands: true)
        let automation = try harness.insertAutomation(script: "sleep 30", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let childPID = try XCTUnwrap(harness.host.lastChildPID)

        harness.service.cancelRun(runID: run.id)

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .canceled)
        try harness.assertProcessDies(pid: childPID, drivingTicks: harness.service.tick)
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

        harness.service.deleteAutomation(id: automation.id)

        XCTAssertFalse(
            harness.orchestrator.automationSessionIsLive(sessionID: sessionID), "the live attributed session is terminated before its records are removed")
        XCTAssertNil(try harness.store.agentWindow(id: agent.id), "the agent row is finalized through the kill chokepoint")
        XCTAssertTrue(
            harness.host.delivered.contains { $0.sessionID == "watcher" && $0.line.contains("exited") }, "the subscriber is told the agent exited")
        XCTAssertNil(try harness.store.automation(id: automation.id), "the automation is deleted")
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
            agentPrompt: "do the thing", workspaceID: "ws-1", workingDirectory: "", timeoutSeconds: nil, concurrencyPolicy: .allow,
            missedRunPolicy: .runOnce)
        XCTAssertThrowsError(try harness.service.updateAutomation(id: automation.id, draft: switchToAgent)) { error in
            XCTAssertTrue(error is AutomationValidationError, "the kind cannot change while a run is active")
        }
        XCTAssertEqual(try harness.store.automation(id: automation.id)?.kind, .script, "the rejected change never persists")

        let renameOnly = AutomationDraft(
            name: "Renamed", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "sleep 60", agentCommand: nil,
            agentPrompt: nil, workspaceID: nil, workingDirectory: "/tmp", timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce)
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
            agentPrompt: "do the thing", workspaceID: "ws-1", workingDirectory: "", timeoutSeconds: nil, concurrencyPolicy: .allow,
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
}

// MARK: - Test harness

@MainActor private final class Harness {
    let store: SQLiteStore
    let orchestrator: WorkspaceOrchestrator
    let host: FakeAutomationTerminalHost
    let service: AutomationService
    let now: () -> Date

    init(_ testCase: XCTestCase, realCommands: Bool = false, now: @escaping () -> Date = Date.init) throws {
        store = try testCase.makeTemporaryStore()
        let host = FakeAutomationTerminalHost(realCommands: realCommands)
        self.host = host
        host.install()
        testCase.addTeardownBlock { host.uninstall() }
        orchestrator = WorkspaceOrchestrator(store: store)
        self.now = now
        service = AutomationService(
            store: store, orchestrator: orchestrator, binaryDirectory: "/usr/bin", timeZone: .current, now: now, terminationGrace: 0.2,
            logError: { _ in })
    }

    /// Builds a fresh `AutomationService` over the same store/orchestrator, modeling a daemon restart:
    /// nothing is carried in memory, so a new instance must resume purely from the persisted run rows.
    func makeService() -> AutomationService {
        AutomationService(
            store: store, orchestrator: orchestrator, binaryDirectory: "/usr/bin", timeZone: .current, now: now, terminationGrace: 0.2,
            logError: { _ in })
    }

    func insertAutomation(
        script: String = "true", kind: AutomationKind = .script, triggerKind: AutomationTriggerKind = .manual, cronExpression: String? = nil,
        concurrency: AutomationConcurrencyPolicy = .allow, missedRunPolicy: AutomationMissedRunPolicy = .runOnce, timeoutSeconds: Int? = nil,
        nextFireTime: Date? = nil
    ) throws -> Automation {
        let automation = Automation(
            id: UUID().uuidString, name: "Test", enabled: true, triggerKind: triggerKind, cronExpression: cronExpression, kind: kind,
            script: script, workingDirectory: FileManager.default.temporaryDirectory.path, timeoutSeconds: timeoutSeconds,
            concurrencyPolicy: concurrency, missedRunPolicy: missedRunPolicy, nextFireTime: nextFireTime, createdAt: now(), updatedAt: now())
        try store.upsertAutomation(automation)
        return automation
    }

    func insertAgentAutomation(
        workspaceID: String, command: String = "codex", prompt: String = "investigate the failing test", concurrency: AutomationConcurrencyPolicy = .allow,
        timeoutSeconds: Int? = nil
    ) throws -> Automation {
        let automation = Automation(
            id: UUID().uuidString, name: "Agent Test", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .agent, script: "",
            agentCommand: command, agentPrompt: prompt, workspaceID: workspaceID, workingDirectory: "", timeoutSeconds: timeoutSeconds,
            concurrencyPolicy: concurrency, missedRunPolicy: .runOnce, nextFireTime: nil, createdAt: now(), updatedAt: now())
        try store.upsertAutomation(automation)
        return automation
    }

    /// Registers a Spaces agent orchestration row bound to a spawned agent session's terminal id, modeling
    /// the row that appears once the agent reports a hook signal.
    @discardableResult func registerAgentRow(workspaceID: String, sessionID: String, status: AgentWindowStatus) throws -> AgentWindowRecord {
        try orchestrator.registerAgentWindow(
            workspaceID: workspaceID, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: status)
    }

    @discardableResult func insertRun(automationID: String, status: AutomationRunStatus, createdAt: Date? = nil) throws -> AutomationRun {
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automationID, status: status, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: nil, startedAt: status == .running ? (createdAt ?? now()) : nil, endedAt: status.isTerminal ? (createdAt ?? now()) : nil,
            createdAt: createdAt ?? now())
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
                updatedAt: "2026-06-06T00:00:01Z", exitedAt: live ? nil : "2026-06-06T00:00:01Z", title: title, workingDirectory: "/tmp"), paths: paths)
        if live { FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()) }
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

    /// Drives `tick()` until a run reaches a terminal status, waiting for the fake host's background waiter
    /// to publish the command's ended runtime state. Fails if the run does not settle within the deadline.
    func runUntilTerminal(runID: String, timeout: TimeInterval = 5) throws -> AutomationRun {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            service.tick()
            if let run = try store.automationRun(id: runID), run.status.isTerminal { return run }
            usleep(30_000)
        }
        throw XCTSkip("run \(runID) did not reach a terminal status within \(timeout)s")
    }

    /// Asserts a process is killed within a deadline, driving the escalation ticks so a SIGTERM that the
    /// command ignored escalates to SIGKILL.
    func assertProcessDies(pid: Int32, drivingTicks tick: () -> Void, timeout: TimeInterval = 3) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            tick()
            usleep(30_000)
        }
        XCTFail("process \(pid) was not terminated within \(timeout)s")
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

/// Process-wide terminal-session launcher/terminator stand-in for the daemon's PTY session machinery. In
/// `realCommands` mode it runs the exact wrapped command the executor built (`/bin/sh -c …`) in its own
/// session via `posix_spawn` (so a timeout's process-group signal is safe and effective), redirecting
/// output to the session's `output.log`, and publishes the session's `.running` then `.exited` runtime
/// state. Otherwise it writes a non-completing `.running` session so concurrency/retention tests observe a
/// run that stays running until the test ends it.
private final class FakeAutomationTerminalHost: @unchecked Sendable {
    private let realCommands: Bool
    private let lock = NSLock()
    private(set) var lastChildPID: Int32?
    var delivered: [(sessionID: String, line: String)] {
        lock.lock()
        defer { lock.unlock() }
        return deliveredStore
    }
    private var deliveredStore: [(sessionID: String, line: String)] = []
    /// Raw terminal-input writes the automation executor made, in order — the seam the agent-kind executor
    /// delivers its seed prompt through. Agent-prompt tests assert the two-write text-then-CR submit.
    var writtenInput: [(sessionID: String, input: TerminalProfileInput)] {
        lock.lock()
        defer { lock.unlock() }
        return writtenInputStore
    }
    private var writtenInputStore: [(sessionID: String, input: TerminalProfileInput)] = []
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
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionInputWriter { [weak self] sessionID, input in
            self?.lock.lock()
            self?.writtenInputStore.append((sessionID: sessionID, input: input))
            self?.lock.unlock()
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

    /// Publishes the daemon's foreground-detection result for a live session (still `.running`), the signal
    /// the agent-kind executor waits for before delivering the prompt.
    func markSessionForegroundDetected(sessionID: String, kind: TerminalDetectedAgentKind = .codex) {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
        try? TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
                updatedAt: ISO8601DateFormatter().string(from: Date()), foregroundDetectedAgentKind: kind), paths: paths)
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
            lastChildPID = pid
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
            id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
            backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: getpid(),
            childPID: childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
    }

    private func terminate(sessionID: String) {
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
