import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// Behavior coverage for `SQLiteStore+RestorableSessions.swift`: which sessions a client can be offered
/// to bring back, what a capture carries, and how the outstanding record is replaced across generations.
final class RestorableSessionStoreTests: XCTestCase {

    // MARK: - liveAgentSessionCaptures

    /// Only a `.agent`-kind session is captured. A `.shell`, `.automation`, and `.process` session in the
    /// same workspace, each carrying a launch command too, prove the filter is on kind, not on whether a
    /// command happens to be recorded.
    func testLiveAgentSessionCapturesOnlyCapturesAgentKindSessions() throws {
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
                detectedAgentKind: TerminalDetectedAgentKind.claude.rawValue, createdAt: "2026-09-11T00:00:00Z",
                updatedAt: "2026-09-11T00:00:00Z"))

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

    /// An automation's own agent runs as an `.agent`-kind session with a run attribution, and is not
    /// captured: that agent belongs to a run the automation machinery starts and ends, so bringing it back
    /// on its own would leave it reporting to nothing.
    func testLiveAgentSessionCapturesSkipsAnAutomationRunsOwnAgentSession() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try seedLiveSession(sessionID: "spawned-agent", workspaceID: workspace.id, kind: .agent, launchCommand: "claude")
        try seedLiveSession(
            sessionID: "automation-agent", workspaceID: workspace.id, kind: .agent, launchCommand: "claude", automationRunID: "run-1")

        XCTAssertEqual(try store.liveAgentSessionCaptures().map(\.sessionID), ["spawned-agent"])
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
                    detectedAgentKind: TerminalDetectedAgentKind.codex.rawValue, createdAt: "2026-09-11T00:00:00Z",
                    updatedAt: "2026-09-11T00:00:00Z"))
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
                        sessionID: sessionID, servicePID: 100, childPID: 100, state: .running, updatedAt: "2026-09-11T00:00:01Z"),
                    paths: paths, databasePath: databasePath)
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
                        sessionID: sessionID, servicePID: 100, childPID: 100, state: .exited, updatedAt: "2026-09-11T00:00:02Z"),
                    paths: paths, databasePath: databasePath)
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
            TerminalSessionRuntimeState(sessionID: "agent-stopped", servicePID: 100, childPID: 100, state: .exited, updatedAt: "2026-09-11T00:01:00Z"),
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
        sessionID: String, workspaceID: String, kind: TerminalSessionKind, launchCommand: String?, automationRunID: String? = nil
    ) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: sessionID, workingDirectory: "/tmp/\(sessionID)", shell: "/bin/zsh", command: "wrapped-\(sessionID)",
                createdAt: "2026-09-11T00:00:00Z", workspaceID: workspaceID, kind: kind, automationRunID: automationRunID,
                launchCommand: launchCommand), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(sessionID: sessionID, servicePID: 100, childPID: 100, state: .running, updatedAt: "2026-09-11T00:00:01Z"),
            paths: paths)
    }

    /// Seeds an `.agent`-kind session's launch configuration and marks it ended, the shape
    /// `agentSessionCaptures(sessionIDs:)` reads: it derives restorability from how the session ended,
    /// not from what runtime state it is in.
    private func seedEndedSession(sessionID: String, workspaceID: String, launchCommand: String?) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: sessionID, workingDirectory: "/tmp/\(sessionID)", shell: "/bin/zsh", command: "wrapped-\(sessionID)",
                createdAt: "2026-09-11T00:00:00Z", workspaceID: workspaceID, kind: .agent, launchCommand: launchCommand), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(sessionID: sessionID, servicePID: 100, childPID: 100, state: .exited, updatedAt: "2026-09-11T00:00:01Z"),
            paths: paths)
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
