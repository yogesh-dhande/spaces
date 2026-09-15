import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// Behavior coverage for `SQLiteStore+RestorableSessions.swift`: which sessions a client can be offered
/// to bring back, what a capture carries, and how the outstanding record is replaced across generations.
final class RestorableSessionStoreTests: XCTestCase {

    // MARK: - liveAgentSessionCaptures

    /// A `.agent`-kind session is captured, and a bare `.shell` is not: it holds no state worth bringing
    /// back. An `.automation` script session and a `.process` session stay out too, each carrying a launch
    /// command, which proves the filter is on what the session is rather than on whether a command happens
    /// to be recorded.
    func testLiveAgentSessionCapturesSkipsShellAutomationAndProcessSessionsWithNoAgentOfTheirOwn() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let agentSession = "agent-session"
        try seedLiveSession(sessionID: agentSession, workspaceID: workspace.id, kind: .agent, launchCommand: "claude --resume")
        try seedLiveSession(sessionID: "shell-session", workspaceID: workspace.id, kind: .shell, launchCommand: "echo hi")
        try seedLiveSession(sessionID: "automation-session", workspaceID: workspace.id, kind: .automation, launchCommand: "./run.sh")
        try seedLiveSession(sessionID: "process-session", workspaceID: workspace.id, kind: .process, launchCommand: "npm run dev")

        let captures = try store.liveAgentSessionCaptures()

        XCTAssertEqual(captures.map(\.sessionID), [agentSession])
        XCTAssertEqual(captures.first?.launchCommand, "claude --resume")
    }

    /// An agent session with no launch command is not captured: there is nothing for a relaunch to run.
    func testLiveAgentSessionCapturesSkipsAgentSessionWithNoLaunchCommand() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try seedLiveSession(sessionID: "agent-no-command", workspaceID: workspace.id, kind: .agent, launchCommand: nil)

        XCTAssertTrue(try store.liveAgentSessionCaptures().isEmpty)
    }

    /// A capture carries the agent's conversation id and detected kind off its `agent_sessions` row when
    /// one exists, and still captures the session (with neither) when detection has never reported one.
    func testCaptureIncludesAgentConversationIdAndKindWhenPresentAndOmitsThemWhenAbsent() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let withAgentRow = "agent-with-hooks"
        try seedLiveSession(sessionID: withAgentRow, workspaceID: workspace.id, kind: .agent, launchCommand: "claude --resume")
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "Claude",
                terminalTarget: TerminalTargetRecord(trackingID: withAgentRow), sessionKey: "conv-123", status: .idle,
                detectedAgentKind: TerminalDetectedAgentKind.claude.rawValue, createdAt: "2026-09-11T00:00:00Z", updatedAt: "2026-09-11T00:00:00Z"))

        let withoutAgentRow = "agent-before-hooks-fired"
        try seedLiveSession(sessionID: withoutAgentRow, workspaceID: workspace.id, kind: .agent, launchCommand: "codex")

        let captures = Dictionary(uniqueKeysWithValues: try store.liveAgentSessionCaptures().map { ($0.sessionID, $0) })

        let withHooks = try XCTUnwrap(captures[withAgentRow])
        XCTAssertEqual(withHooks.agentSessionKey, "conv-123")
        XCTAssertEqual(withHooks.agentKind, .claude)

        let beforeHooks = try XCTUnwrap(captures[withoutAgentRow])
        XCTAssertNil(beforeHooks.agentSessionKey)
        XCTAssertNil(beforeHooks.agentKind)
    }

    /// An automation's own agent is a live coding agent like any other and is captured. It comes back as a
    /// standalone conversation: the relaunch carries no run attribution, because the run that owned it was
    /// canceled with the teardown that captured it.
    func testLiveAgentSessionCapturesIncludesAnAutomationRunsOwnAgentSession() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try seedLiveSession(sessionID: "spawned-agent", workspaceID: workspace.id, kind: .agent, launchCommand: "claude")
        try seedLiveSession(sessionID: "automation-agent", workspaceID: workspace.id, kind: .agent, launchCommand: "claude", automationRunID: "run-1")

        XCTAssertEqual(Set(try store.liveAgentSessionCaptures().map(\.sessionID)), ["spawned-agent", "automation-agent"])
    }

    // MARK: - An agent the user typed into a terminal

    /// A shell session running a detected coding agent is captured live off its runtime row: the command is
    /// the foreground sample the session's own core wrote (the session row has none), the conversation id
    /// and kind come off the agent row, and the directory is the live one the agent `cd`-ed to rather than
    /// the directory the terminal opened in.
    func testLiveCaptureReadsATypedAgentsCommandFromTheRuntimeRow() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "typed-agent"
        try seedLiveSession(
            sessionID: sessionID, workspaceID: workspace.id, kind: .shell, launchCommand: nil, workingDirectory: "/tmp/\(sessionID)/packages/api",
            foregroundAgentKind: .claude, foregroundCommand: #"claude --model opus 'fix the build'"#)
        try upsertAgentRow(
            store: store, workspaceID: workspace.id, terminalSessionID: sessionID, status: .spinning, sessionKey: "conv-typed",
            launchCommand: "claude")

        let capture = try XCTUnwrap(try store.liveAgentSessionCaptures().first { $0.sessionID == sessionID })

        XCTAssertEqual(capture.launchCommand, #"claude --model opus 'fix the build'"#)
        XCTAssertEqual(capture.workingDirectory, "/tmp/\(sessionID)/packages/api")
        XCTAssertEqual(capture.agentSessionKey, "conv-typed")
        XCTAssertEqual(capture.agentKind, .claude)
    }

    /// An agent typed seconds before the teardown is captured even though the classification pass has not
    /// written its agent row yet: the runtime row alone says an agent is in the foreground and what it would
    /// take to relaunch it. Without a row there is no conversation to resume, so the offer says it comes back
    /// as a new conversation, which is the same thing it says for an agent that never reported one.
    func testLiveCaptureTakesATypedAgentBeforeItsAgentRowExists() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "typed-agent-not-yet-classified"
        try seedLiveSession(
            sessionID: sessionID, workspaceID: workspace.id, kind: .shell, launchCommand: nil, foregroundAgentKind: .claude,
            foregroundCommand: "claude --model opus")

        let capture = try XCTUnwrap(try store.liveAgentSessionCaptures().first { $0.sessionID == sessionID })

        XCTAssertEqual(capture.launchCommand, "claude --model opus")
        XCTAssertNil(capture.agentSessionKey)
        XCTAssertNil(capture.agentKind)
    }

    /// A terminal outlives the agents typed into it, and its agent row is reused rather than replaced. An
    /// agent typed after the previous one exited is captured against the exited row until the foreground
    /// relaunch reconciler resets it, so the exited row contributes no conversation id: the new command
    /// comes back as a fresh conversation rather than reopening the conversation the user had finished
    /// with. The same runtime row over a row the reconciler has already reset takes that row's key, which
    /// is what the ordinary live capture does.
    func testLiveCaptureIgnoresTheConversationOfAnExitedAgentRowUnderANewForegroundAgent() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let unreconciled = "agent-typed-over-an-exited-row"
        try seedLiveSession(
            sessionID: unreconciled, workspaceID: workspace.id, kind: .shell, launchCommand: nil, foregroundAgentKind: .claude,
            foregroundCommand: #"claude "start the migration""#)
        try upsertAgentRow(
            store: store, workspaceID: workspace.id, terminalSessionID: unreconciled, status: .exited, sessionKey: "conv-finished",
            launchCommand: "claude")

        let reconciled = "agent-typed-over-a-reset-row"
        try seedLiveSession(
            sessionID: reconciled, workspaceID: workspace.id, kind: .shell, launchCommand: nil, foregroundAgentKind: .claude,
            foregroundCommand: #"claude "start the migration""#)
        try upsertAgentRow(
            store: store, workspaceID: workspace.id, terminalSessionID: reconciled, status: .idle, sessionKey: "conv-live", launchCommand: "claude")

        let captures = Dictionary(uniqueKeysWithValues: try store.liveAgentSessionCaptures().map { ($0.sessionID, $0) })

        let overExitedRow = try XCTUnwrap(captures[unreconciled])
        XCTAssertEqual(overExitedRow.launchCommand, #"claude "start the migration""#)
        XCTAssertNil(overExitedRow.agentSessionKey)
        XCTAssertNil(overExitedRow.agentKind)

        let overIdleRow = try XCTUnwrap(captures[reconciled])
        XCTAssertEqual(overIdleRow.launchCommand, #"claude "start the migration""#)
        XCTAssertEqual(overIdleRow.agentSessionKey, "conv-live")
        XCTAssertEqual(overIdleRow.agentKind, .claude)
    }

    /// A shell whose foreground is back at its prompt is not captured live, even while an agent row from the
    /// agent that just ended is still sitting there: the reconcilers clear that row on their own tick, and
    /// until they do, the runtime row is the one telling the truth about what is running.
    func testLiveCaptureSkipsAShellWhoseRuntimeRowShowsNoForegroundAgent() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try seedLiveSession(sessionID: "agent-just-ended", workspaceID: workspace.id, kind: .shell, launchCommand: nil)
        try upsertAgentRow(
            store: store, workspaceID: workspace.id, terminalSessionID: "agent-just-ended", status: .spinning, sessionKey: "conv-gone",
            launchCommand: "claude")
        try seedLiveSession(sessionID: "plain-shell", workspaceID: workspace.id, kind: .shell, launchCommand: nil)

        XCTAssertTrue(try store.liveAgentSessionCaptures().isEmpty)
    }

    /// The unclean-exit capture reads the typed agent off its agent row instead, because it runs after the
    /// daemon-start repair has nulled every foreground column of the runtime row. The command survives on
    /// the agent row, and the directory on the repaired runtime row.
    func testStrandedCaptureStillCarriesATypedAgentsCommandAndDirectoryAfterTheRepair() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "stranded-typed-agent"
        try seedEndedSession(
            sessionID: sessionID, workspaceID: workspace.id, kind: .shell, launchCommand: nil, workingDirectory: "/tmp/\(sessionID)/services/web")
        try upsertAgentRow(
            store: store, workspaceID: workspace.id, terminalSessionID: sessionID, status: .waiting, sessionKey: "conv-stranded",
            launchCommand: #"claude 'fix the build'"#)

        let capture = try XCTUnwrap(try store.agentSessionCaptures(sessionIDs: [sessionID]).first)

        XCTAssertEqual(capture.launchCommand, #"claude 'fix the build'"#)
        XCTAssertEqual(capture.workingDirectory, "/tmp/\(sessionID)/services/web")
        XCTAssertEqual(capture.agentSessionKey, "conv-stranded")
    }

    /// The stranded capture skips a shell whose agent had finished before the daemon died, and one whose
    /// agent row carries no command: the first ran its agent to the end and the second has nothing to
    /// relaunch, which is the state of a row detection has seen but not yet sampled a command onto.
    func testStrandedCaptureSkipsAShellWhoseAgentExitedOrCarriesNoCommand() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try seedEndedSession(sessionID: "exited-agent-shell", workspaceID: workspace.id, kind: .shell, launchCommand: nil)
        try upsertAgentRow(
            store: store, workspaceID: workspace.id, terminalSessionID: "exited-agent-shell", status: .exited, sessionKey: "conv-gone",
            launchCommand: "claude")
        try seedEndedSession(sessionID: "unsampled-agent-shell", workspaceID: workspace.id, kind: .shell, launchCommand: nil)
        try upsertAgentRow(
            store: store, workspaceID: workspace.id, terminalSessionID: "unsampled-agent-shell", status: .idle, sessionKey: nil, launchCommand: nil)
        try seedEndedSession(sessionID: "plain-ended-shell", workspaceID: workspace.id, kind: .shell, launchCommand: nil)

        XCTAssertTrue(try store.agentSessionCaptures(sessionIDs: ["exited-agent-shell", "unsampled-agent-shell", "plain-ended-shell"]).isEmpty)
    }

    /// A Codex `exec` run is captured without its conversation id even though its hooks reported one: the
    /// run is a one-shot job whose options belong to the `exec` subcommand, so the relaunch runs the
    /// recorded command unchanged and the offer says it comes back as a new run.
    func testCodexExecRunIsCapturedWithNoConversationSoItComesBackAsANewRun() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        for (sessionID, command) in [("exec-sandbox", #"codex exec --sandbox read-only "fix it""#), ("exec-model", #"codex -m gpt-5 exec "fix""#)] {
            try seedLiveSession(sessionID: sessionID, workspaceID: workspace.id, kind: .agent, launchCommand: command)
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "Codex",
                    terminalTarget: TerminalTargetRecord(trackingID: sessionID), sessionKey: "conversation-1", status: .idle,
                    detectedAgentKind: TerminalDetectedAgentKind.codex.rawValue, createdAt: "2026-09-11T00:00:00Z", updatedAt: "2026-09-11T00:00:00Z")
            )
        }

        let captures = Dictionary(uniqueKeysWithValues: try store.liveAgentSessionCaptures().map { ($0.sessionID, $0) })

        for (sessionID, command) in [("exec-sandbox", #"codex exec --sandbox read-only "fix it""#), ("exec-model", #"codex -m gpt-5 exec "fix""#)] {
            let capture = try XCTUnwrap(captures[sessionID])
            XCTAssertNil(capture.agentSessionKey, "an exec run carries no conversation into the record")
            XCTAssertFalse(capture.record(generation: "gen", capturedAt: "2026-09-11T00:00:00Z").summary.hasResumeKey)
            XCTAssertEqual(
                CodingAgent.resumeCommand(launchCommand: capture.launchCommand, sessionKey: capture.agentSessionKey), command,
                "the relaunch runs the recorded command unchanged")
        }
    }

    // MARK: - captureLiveAgentSessionsForRestore

    /// The capture every teardown writes: the live coding agents replace the record under the new
    /// generation, and a teardown that finds none leaves the outstanding offer alone rather than clearing
    /// an offer nobody has answered.
    func testCaptureLiveAgentSessionsForRestoreReplacesTheRecordAndKeepsItWhenNothingIsLive() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.replaceRestorableSessions(
            generation: "gen-parked", capturedAt: "2026-09-11T00:00:00Z",
            captures: [makeCapture(sessionID: "parked-session", workspaceID: workspace.id, agentSessionKey: "conv-parked")])

        XCTAssertEqual(try store.captureLiveAgentSessionsForRestore(generation: "gen-empty", capturedAt: "2026-09-11T00:01:00Z"), 0)
        XCTAssertEqual(try store.restorableSessions().map(\.sessionID), ["parked-session"], "an empty capture leaves the outstanding offer")

        try seedLiveSession(sessionID: "live-agent", workspaceID: workspace.id, kind: .agent, launchCommand: "claude")

        XCTAssertEqual(try store.captureLiveAgentSessionsForRestore(generation: "gen-live", capturedAt: "2026-09-11T00:02:00Z"), 1)
        let captured = try store.restorableSessions()
        XCTAssertEqual(captured.map(\.sessionID), ["live-agent"])
        XCTAssertEqual(captured.first?.generation, "gen-live")
    }

    /// A park that lands moments after an agent launched still captures that agent. A session's rows are
    /// written write-behind on its core's persistence queue, so a capture taken while that write is still
    /// in flight reads a table that has not heard about the launch, and the agent would be torn down with
    /// nothing to bring it back. Draining the queue first, which is what the daemon does before every
    /// capture, is what closes that window.
    func testAnAgentWhoseLaunchIsStillQueuedIsCapturedOnceItsPersistenceQueueDrains() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "agent-just-launched"
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        let configuration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: sessionID, workingDirectory: "/tmp/\(sessionID)", shell: "/bin/zsh", command: "wrapped-\(sessionID)",
            createdAt: "2026-09-11T00:00:00Z", workspaceID: workspace.id, kind: .agent, launchCommand: "codex")

        // Park the queue, then enqueue the launch the way a core does, so the write is demonstrably still
        // pending when the capture below runs rather than merely likely to be.
        let queue = TerminalCorePersistenceQueue(label: "restorable-capture-fence-test")
        let parked = DispatchSemaphore(value: 0)
        queue.enqueueOrderedWork { parked.wait() }
        let writeFailure = ThrownErrorBox()
        queue.enqueueWrite { databasePath in
            do {
                try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths, databasePath: databasePath)
                try TerminalSessionPersistence.writeRuntimeState(
                    TerminalSessionRuntimeState(
                        sessionID: sessionID, servicePID: 100, childPID: 100, state: .running, updatedAt: "2026-09-11T00:00:01Z"), paths: paths,
                    databasePath: databasePath)
            } catch { writeFailure.record(error) }
        }

        XCTAssertTrue(try store.liveAgentSessionCaptures().isEmpty, "the launch write has not committed, so the table shows no session yet")

        parked.signal()
        queue.drain()

        XCTAssertNil(writeFailure.error)
        XCTAssertEqual(try store.liveAgentSessionCaptures().map(\.sessionID), [sessionID])
    }

    /// A park that lands moments after an agent was killed does not capture it. Ending a session writes its
    /// `.exited` state write-behind too, so a capture taken while that write is in flight still reads the
    /// session as running and would offer back an agent the user deliberately stopped. The same drain
    /// closes this window from the other side.
    func testAnAgentKilledMomentsAgoIsNotCapturedOnceItsExitWriteDrains() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "agent-just-killed"
        try seedLiveSession(sessionID: sessionID, workspaceID: workspace.id, kind: .agent, launchCommand: "codex")
        let paths = try TerminalSessionPaths.forSession(id: sessionID)

        let queue = TerminalCorePersistenceQueue(label: "restorable-exit-fence-test")
        let parked = DispatchSemaphore(value: 0)
        queue.enqueueOrderedWork { parked.wait() }
        let writeFailure = ThrownErrorBox()
        queue.enqueueWrite { databasePath in
            do {
                try TerminalSessionPersistence.writeRuntimeState(
                    TerminalSessionRuntimeState(
                        sessionID: sessionID, servicePID: 100, childPID: 100, state: .exited, updatedAt: "2026-09-11T00:00:02Z"), paths: paths,
                    databasePath: databasePath)
            } catch { writeFailure.record(error) }
        }

        XCTAssertEqual(
            try store.liveAgentSessionCaptures().map(\.sessionID), [sessionID], "the exit write has not committed, so the table still reads running")

        parked.signal()
        queue.drain()

        XCTAssertNil(writeFailure.error)
        XCTAssertTrue(try store.liveAgentSessionCaptures().isEmpty)
    }

    // MARK: - reconcileRestorableSessionsWithLiveSessions(generation:)

    /// The cancelled quit's reconcile. The quit parked both agents, then stopped one workspace before a
    /// failure on the other left the app open: the stopped workspace's agent is gone and its parked row is
    /// the only way back to it, while the still-running agent needs no offer and would come back as a
    /// second copy of itself.
    func testReconcileKeepsTheStoppedWorkspacesAgentAndDropsTheRunningOne() throws {
        let store = try makeTemporaryStore()
        let (_, stopped) = try makeProjectAndWorkspace(store: store)
        let (_, running) = try makeProjectAndWorkspace(store: store)
        try seedLiveSession(sessionID: "agent-stopped", workspaceID: stopped.id, kind: .agent, launchCommand: "claude")
        try seedLiveSession(sessionID: "agent-running", workspaceID: running.id, kind: .agent, launchCommand: "codex")
        XCTAssertEqual(try store.captureLiveAgentSessionsForRestore(generation: "gen-quit", capturedAt: "2026-09-11T00:00:00Z"), 2)

        // The quit stopped one workspace before it was canceled, which ended that workspace's agent.
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "agent-stopped", servicePID: 100, childPID: 100, state: .exited, updatedAt: "2026-09-11T00:01:00Z"),
            paths: try TerminalSessionPaths.forSession(id: "agent-stopped"))

        XCTAssertEqual(try store.reconcileRestorableSessionsWithLiveSessions(generation: "gen-quit"), 1)
        XCTAssertEqual(try store.restorableSessions().map(\.sessionID), ["agent-stopped"])
    }

    /// A reconcile that finds every parked agent still running leaves no record: the quit did not happen and
    /// nothing needs bringing back. It touches no other generation, for the same reason the clear does not.
    func testReconcileEmptiesARecordOfEntirelyLiveAgentsAndLeavesOtherGenerationsAlone() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try seedLiveSession(sessionID: "agent-live", workspaceID: workspace.id, kind: .agent, launchCommand: "claude")
        XCTAssertEqual(try store.captureLiveAgentSessionsForRestore(generation: "gen-quit", capturedAt: "2026-09-11T00:00:00Z"), 1)

        XCTAssertEqual(try store.reconcileRestorableSessionsWithLiveSessions(generation: "gen-quit"), 0)
        XCTAssertTrue(try store.restorableSessions().isEmpty)

        try store.replaceRestorableSessions(
            generation: "gen-newer", capturedAt: "2026-09-11T00:02:00Z",
            captures: [makeCapture(sessionID: "agent-live", workspaceID: workspace.id, agentSessionKey: nil)])

        XCTAssertEqual(try store.reconcileRestorableSessionsWithLiveSessions(generation: "gen-quit"), 1)
        XCTAssertEqual(try store.restorableSessions().map(\.sessionID), ["agent-live"], "a newer record is not the one being answered")
    }

    // MARK: - agentSessionCaptures(sessionIDs:)

    /// Returns rows for the named ended sessions, whatever runtime state they are in, and silently
    /// ignores ids it does not know about.
    func testAgentSessionCapturesReturnsNamedSessionsAndIgnoresUnknownIDs() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = "ended-agent-one"
        let second = "ended-agent-two"
        try seedEndedSession(sessionID: first, workspaceID: workspace.id, launchCommand: "claude --resume")
        try seedEndedSession(sessionID: second, workspaceID: workspace.id, launchCommand: "codex")

        let captures = try store.agentSessionCaptures(sessionIDs: [first, second, "no-such-session"])

        XCTAssertEqual(Set(captures.map(\.sessionID)), [first, second])
    }

    // MARK: - replaceRestorableSessions / restorableSessions / clearRestorableSessions

    /// Writing a new generation replaces the whole record: an older generation's rows are gone and
    /// `restorableSessions()` reports only the newest generation. Writing an empty list clears it.
    func testReplaceRestorableSessionsReplacesWholeRecordAcrossGenerations() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let captureA = makeCapture(sessionID: "session-a", workspaceID: workspace.id, agentSessionKey: "conv-a")
        try store.replaceRestorableSessions(generation: "gen-a", capturedAt: "2026-09-11T00:00:00Z", captures: [captureA])
        XCTAssertEqual(try store.restorableSessions().map(\.sessionID), ["session-a"])
        XCTAssertEqual(try store.restorableSessions().first?.generation, "gen-a")

        let captureB = makeCapture(sessionID: "session-b", workspaceID: workspace.id, agentSessionKey: nil)
        let captureC = makeCapture(sessionID: "session-c", workspaceID: workspace.id, agentSessionKey: nil)
        try store.replaceRestorableSessions(generation: "gen-b", capturedAt: "2026-09-11T00:01:00Z", captures: [captureB, captureC])

        let afterB = try store.restorableSessions()
        XCTAssertEqual(Set(afterB.map(\.sessionID)), ["session-b", "session-c"])
        XCTAssertTrue(afterB.allSatisfy { $0.generation == "gen-b" }, "every row shares the newest generation")

        try store.replaceRestorableSessions(generation: "gen-c", capturedAt: "2026-09-11T00:02:00Z", captures: [])
        XCTAssertTrue(try store.restorableSessions().isEmpty, "an empty capture list clears the record")
    }

    /// Clearing empties the record the answer named, the way both Restore and Skip do once they have
    /// answered the offer, and leaves a record written since alone: a quit that parked its agents while the
    /// relaunches ran is a newer offer about different sessions, and nobody has seen it yet.
    func testClearRestorableSessionsEmptiesTheAnsweredRecordAndKeepsANewerOne() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.replaceRestorableSessions(
            generation: "gen-a", capturedAt: "2026-09-11T00:00:00Z",
            captures: [makeCapture(sessionID: "session-a", workspaceID: workspace.id, agentSessionKey: nil)])
        XCTAssertFalse(try store.restorableSessions().isEmpty)

        try store.clearRestorableSessions(generation: "gen-a")

        XCTAssertTrue(try store.restorableSessions().isEmpty)

        try store.replaceRestorableSessions(
            generation: "gen-b", capturedAt: "2026-09-11T00:01:00Z",
            captures: [makeCapture(sessionID: "session-b", workspaceID: workspace.id, agentSessionKey: nil)])

        try store.clearRestorableSessions(generation: "gen-a")

        XCTAssertEqual(try store.restorableSessions().map(\.sessionID), ["session-b"], "answering an older offer leaves a newer one standing")
    }

    // MARK: - RestorableSessionRecord.summary

    /// `hasResumeKey` is true only when a conversation id was actually captured.
    func testSummaryHasResumeKeyReflectsWhetherAKeyWasCaptured() {
        let withKey = RestorableSessionRecord(
            sessionID: "s1", generation: "gen", workspaceID: "ws", agentKind: .claude, agentSessionKey: "conv-1", launchCommand: "claude",
            workingDirectory: "/tmp", title: "Session", capturedAt: "2026-09-11T00:00:00Z")
        XCTAssertTrue(withKey.summary.hasResumeKey)

        let withoutKey = RestorableSessionRecord(
            sessionID: "s2", generation: "gen", workspaceID: "ws", agentKind: nil, agentSessionKey: nil, launchCommand: "codex",
            workingDirectory: "/tmp", title: "Session", capturedAt: "2026-09-11T00:00:00Z")
        XCTAssertFalse(withoutKey.summary.hasResumeKey)
    }

    // MARK: - Fixtures

    private func makeProjectAndWorkspace(store: SQLiteStore) throws -> (ProjectRecord, WorkspaceRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: dir + "/ws")
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    /// Seeds a session's launch configuration and marks it live with a running runtime-state row, the
    /// shape `liveAgentSessionCaptures()` reads.
    private func seedLiveSession(
        sessionID: String, workspaceID: String, kind: TerminalSessionKind, launchCommand: String?, automationRunID: String? = nil,
        workingDirectory: String? = nil, foregroundAgentKind: TerminalDetectedAgentKind? = nil, foregroundCommand: String? = nil
    ) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: sessionID, workingDirectory: "/tmp/\(sessionID)", shell: "/bin/zsh", command: "wrapped-\(sessionID)",
                createdAt: "2026-09-11T00:00:00Z", workspaceID: workspaceID, kind: kind, automationRunID: automationRunID,
                launchCommand: launchCommand), paths: paths)
        // The runtime row carries the live directory, which advances with the agent's own `cd`; the launch
        // configuration's never moves off the directory the terminal opened in. Its foreground columns are
        // what the session's core samples off the running process, and are how the live capture recognises
        // an agent the user typed into the terminal.
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, servicePID: 100, childPID: 100, state: .running, updatedAt: "2026-09-11T00:00:01Z",
                workingDirectory: workingDirectory, foregroundDetectedAgentKind: foregroundAgentKind, foregroundCommand: foregroundCommand),
            paths: paths)
    }

    /// The agent row foreground detection promotes a terminal to, carrying the command a restore relaunches
    /// a typed agent from.
    private func upsertAgentRow(
        store: SQLiteStore, workspaceID: String, terminalSessionID: String, status: AgentWindowStatus, sessionKey: String?, launchCommand: String?
    ) throws {
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-\(terminalSessionID)", workspaceID: workspaceID, provider: .spaces, label: "claude",
                terminalTarget: TerminalTargetRecord(trackingID: terminalSessionID), sessionKey: sessionKey, status: status,
                detectedAgentKind: TerminalDetectedAgentKind.claude.rawValue, launchCommand: launchCommand, createdAt: "2026-09-11T00:00:00Z",
                updatedAt: "2026-09-11T00:00:00Z"))
    }

    /// Seeds an `.agent`-kind session's launch configuration and marks it ended, the shape
    /// `agentSessionCaptures(sessionIDs:)` reads: it derives restorability from how the session ended,
    /// not from what runtime state it is in.
    private func seedEndedSession(
        sessionID: String, workspaceID: String, kind: TerminalSessionKind = .agent, launchCommand: String?, workingDirectory: String? = nil
    ) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: sessionID, workingDirectory: "/tmp/\(sessionID)", shell: "/bin/zsh", command: "wrapped-\(sessionID)",
                createdAt: "2026-09-11T00:00:00Z", workspaceID: workspaceID, kind: kind, launchCommand: launchCommand), paths: paths)
        // What the daemon-start repair leaves behind: the run's terminal state and its last known directory,
        // and no foreground columns at all.
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, servicePID: 100, childPID: 100, state: .failed, updatedAt: "2026-09-11T00:00:01Z",
                exitedAt: "2026-09-11T00:00:01Z", workingDirectory: workingDirectory), paths: paths)
    }

    /// Carries an error thrown on the persistence queue back to the test body.
    private final class ThrownErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (any Error)?

        var error: (any Error)? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ error: any Error) {
            lock.lock()
            defer { lock.unlock() }
            stored = error
        }
    }

    private func makeCapture(sessionID: String, workspaceID: String, agentSessionKey: String?) -> RestorableSessionCapture {
        RestorableSessionCapture(
            sessionID: sessionID, workspaceID: workspaceID, agentKind: nil, agentSessionKey: agentSessionKey, launchCommand: "claude --resume",
            workingDirectory: "/tmp", title: sessionID)
    }
}
