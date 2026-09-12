import Foundation
import spacesdatabase
import spacesterminalcore

extension SQLiteStore {
    /// Canonical column order for reading a capture off the live session tables; shared by both capture
    /// queries so they decode through one row shape.
    ///
    /// The agent row is joined in on the left: a spawned agent session exists as a terminal session from
    /// the moment it launches, while its `agent_sessions` row is written once its hooks or foreground
    /// detection report it, so a session captured before that still restores, just without a
    /// conversation id to resume. A session's manual rename wins over its launch title, matching how a
    /// session is named everywhere else.
    private static let restorableCaptureColumns = """
        terminal_sessions.session_id,
        terminal_sessions.workspace_id,
        COALESCE(agent_sessions.detected_agent_kind, ''),
        COALESCE(agent_sessions.session_key, ''),
        terminal_sessions.launch_command,
        terminal_sessions.working_directory,
        COALESCE(NULLIF(terminal_sessions.user_title, ''), terminal_sessions.title)
        """

    /// Canonical column order for a stored `restorable_sessions` row.
    private static let restorableSessionColumns = """
        session_id, generation, workspace_id, COALESCE(agent_kind, ''), COALESCE(agent_session_key, ''), launch_command, working_directory,
        title, captured_at
        """

    /// Every coding-agent session that is still live, across every workspace. This is what a clean Stop
    /// All and Quit captures, read before the stops run so the rows are still there to read.
    public func liveAgentSessionCaptures() throws -> [RestorableSessionCapture] {
        let interactiveStates = TerminalSessionState.allCases.filter(\.isInteractive).map(\.rawValue)
        let placeholders = Array(repeating: "?", count: interactiveStates.count).joined(separator: ", ")
        let rows = try queryRows(
            sql: """
                SELECT \(Self.restorableCaptureColumns)
                FROM terminal_sessions
                JOIN workspaces ON workspaces.id = terminal_sessions.workspace_id
                JOIN terminal_runtime_states ON terminal_runtime_states.root_directory = terminal_sessions.root_directory
                LEFT JOIN agent_sessions ON agent_sessions.terminal_session_id = terminal_sessions.session_id
                WHERE \(Self.restorableCaptureFilter) AND terminal_runtime_states.state IN (\(placeholders))
                ORDER BY terminal_sessions.created_at, terminal_sessions.session_id
                """, bindings: interactiveStates)
        return Self.firstCapturePerSession(rows.compactMap(Self.decodeCapture(row:)))
    }

    /// The captures for the named sessions, whatever state their runtime rows are in now. This is what the
    /// unclean-exit derivation reads: its sessions have just been finalized, and the fact that makes them
    /// restorable is how they ended, not what state they are in.
    public func agentSessionCaptures(sessionIDs: [String]) throws -> [RestorableSessionCapture] {
        guard !sessionIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
        let rows = try queryRows(
            sql: """
                SELECT \(Self.restorableCaptureColumns)
                FROM terminal_sessions
                JOIN workspaces ON workspaces.id = terminal_sessions.workspace_id
                LEFT JOIN agent_sessions ON agent_sessions.terminal_session_id = terminal_sessions.session_id
                WHERE \(Self.restorableCaptureFilter) AND terminal_sessions.session_id IN (\(placeholders))
                ORDER BY terminal_sessions.created_at, terminal_sessions.session_id
                """, bindings: sessionIDs)
        return Self.firstCapturePerSession(rows.compactMap(Self.decodeCapture(row:)))
    }

    /// What makes a session restorable at all, shared by both capture queries so neither can widen on its
    /// own: a coding-agent session (never a shell, an automation, or a configured process, since a shell is the
    /// user's own typing, and the other two come back through their own machinery), bound to a workspace,
    /// and carrying the raw command it was launched with. An automation's own agent runs as an `.agent`
    /// session too, and is excluded by its run attribution: that agent belongs to a run the automation
    /// machinery owns end to end, and bringing it back outside its run would report to nothing. Both
    /// queries inner-join `workspaces` for the same reason the offer exists at all: an agent can only be
    /// relaunched into a workspace that is still there, and a session whose workspace has since been
    /// deleted has nowhere to come back to.
    private static let restorableCaptureFilter = """
        terminal_sessions.kind = 'agent'
        AND terminal_sessions.workspace_id IS NOT NULL
        AND terminal_sessions.automation_run_id IS NULL
        AND COALESCE(terminal_sessions.launch_command, '') <> ''
        """

    /// Records every live coding agent as restorable under a fresh generation, and reports how many were
    /// captured. This is what a teardown writes: a clean Stop All and Quit before its stops run, and a
    /// daemon shutdown before it finalizes the sessions it is about to end.
    ///
    /// A capture that finds no live agents leaves the outstanding record untouched rather than clearing
    /// it. A teardown with nothing to offer has nothing to say about an offer nobody has answered yet, and
    /// replacing the record with an empty one would discard it silently.
    @discardableResult public func captureLiveAgentSessionsForRestore(generation: String, capturedAt: String) throws -> Int {
        let captures = try liveAgentSessionCaptures()
        guard !captures.isEmpty else { return 0 }
        try replaceRestorableSessions(generation: generation, capturedAt: capturedAt, captures: captures)
        return captures.count
    }

    /// Replaces the whole restorable record with `captures` under a fresh `generation`. One record is
    /// outstanding at a time: a newer capture supersedes an older one that nobody answered, so the offer a
    /// client sees always describes the most recent way sessions ended. Writing an empty list clears the
    /// record.
    public func replaceRestorableSessions(generation: String, capturedAt: String, captures: [RestorableSessionCapture]) throws {
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM restorable_sessions", bindings: [])
            for capture in captures {
                let record = capture.record(generation: generation, capturedAt: capturedAt)
                try execute(
                    sql: """
                        INSERT INTO restorable_sessions(
                          session_id, generation, workspace_id, agent_kind, agent_session_key, launch_command, working_directory, title, captured_at
                        )
                        VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?, ?, ?)
                        """,
                    bindings: [
                        record.sessionID, record.generation, record.workspaceID, record.agentKind?.rawValue ?? "", record.agentSessionKey ?? "",
                        record.launchCommand, record.workingDirectory, record.title, record.capturedAt,
                    ])
            }
        }
    }

    /// The outstanding restorable record, oldest capture first.
    public func restorableSessions() throws -> [RestorableSessionRecord] {
        let rows = try queryRows(
            sql: """
                SELECT \(Self.restorableSessionColumns)
                FROM restorable_sessions
                ORDER BY captured_at, session_id
                """)
        return rows.compactMap(Self.decodeRestorableSession(row:))
    }

    /// Whether the outstanding record names this terminal session.
    ///
    /// Read by the one place a device would otherwise tell a client to close that session's pane: a pane
    /// showing a session on the record is the seat its restored agent comes back to.
    public func holdsRestorableSession(sessionID: String) throws -> Bool {
        try !queryRows(sql: "SELECT 1 FROM restorable_sessions WHERE session_id = ? LIMIT 1", bindings: [sessionID]).isEmpty
    }

    /// Drops the record `generation` names. Both answers to the offer end here: Restore clears it once the
    /// relaunches are done, Skip clears it instead of restoring.
    ///
    /// Scoped to the answered generation rather than emptying the table, because the two are not the same
    /// record by the time the answer lands: a capture written while the relaunches ran (a quit parking its
    /// agents over the profile socket, a startup deriving an unclean exit) is a newer offer about a
    /// different set of sessions, and an unscoped delete would drop it before anyone saw it.
    public func clearRestorableSessions(generation: String) throws {
        try execute(sql: "DELETE FROM restorable_sessions WHERE generation = ?", bindings: [generation])
    }

    /// Drops from `generation` the rows whose terminal session is still live, and reports how many rows
    /// remain. This is what a cancelled Stop All and Quit asks for: the quit parked every live coding agent
    /// before its stops ran, then a stop failed and the app stayed open, so the parked record now describes
    /// two different situations at once. An agent whose workspace did stop is gone and its parked row is
    /// the only way back to it; an agent still running needs no offer, and restoring it would bring up a
    /// second copy of a conversation the user is still looking at.
    ///
    /// Scoped to the named generation for the same reason the clear is: a capture written since is a
    /// different offer. A reconcile that empties the generation leaves the record gone, exactly as a clear
    /// would, since nothing in it needs bringing back.
    @discardableResult public func reconcileRestorableSessionsWithLiveSessions(generation: String) throws -> Int {
        let interactiveStates = TerminalSessionState.allCases.filter(\.isInteractive).map(\.rawValue)
        let placeholders = Array(repeating: "?", count: interactiveStates.count).joined(separator: ", ")
        try execute(
            sql: """
                DELETE FROM restorable_sessions
                WHERE generation = ?
                  AND session_id IN (
                    SELECT terminal_sessions.session_id
                    FROM terminal_sessions
                    JOIN terminal_runtime_states ON terminal_runtime_states.root_directory = terminal_sessions.root_directory
                    WHERE terminal_runtime_states.state IN (\(placeholders))
                  )
                """, bindings: [generation] + interactiveStates)
        return try restorableSessions().count
    }

    /// Keeps one capture per terminal session. The agent-row join is on `terminal_session_id`, which
    /// carries no uniqueness guarantee, and a session with two agent rows bound to it would otherwise
    /// produce two captures of one session and fail the record's primary key mid-write.
    private static func firstCapturePerSession(_ captures: [RestorableSessionCapture]) -> [RestorableSessionCapture] {
        var seen = Set<String>()
        return captures.filter { seen.insert($0.sessionID).inserted }
    }

    /// Decodes one capture row, and is the single place that decides whether a session comes back resumed
    /// or fresh. A Codex `exec` run is captured without its conversation id even when one was reported:
    /// that run is a one-shot job whose options belong to the `exec` subcommand, so the relaunch cannot
    /// place a resume selector in it safely (see `CodingAgent.launchIsOneShotCodexExec`). Dropping the key
    /// here puts such a row on the path an agent that never reported a conversation already takes: the
    /// offer says it comes back as a new run, and the relaunch runs the recorded command unchanged.
    private static func decodeCapture(row: [String]) -> RestorableSessionCapture? {
        guard row.count >= 7, !row[0].isEmpty, !row[1].isEmpty, !row[4].isEmpty else { return nil }
        let launchCommand = row[4]
        let agentSessionKey = row[3].isEmpty || CodingAgent.launchIsOneShotCodexExec(launchCommand: launchCommand) ? nil : row[3]
        return RestorableSessionCapture(
            sessionID: row[0], workspaceID: row[1], agentKind: TerminalDetectedAgentKind(rawValue: row[2]), agentSessionKey: agentSessionKey,
            launchCommand: launchCommand, workingDirectory: row[5], title: row[6])
    }

    private static func decodeRestorableSession(row: [String]) -> RestorableSessionRecord? {
        guard row.count >= 9 else { return nil }
        return RestorableSessionRecord(
            sessionID: row[0], generation: row[1], workspaceID: row[2], agentKind: TerminalDetectedAgentKind(rawValue: row[3]),
            agentSessionKey: row[4].isEmpty ? nil : row[4], launchCommand: row[5], workingDirectory: row[6], title: row[7], capturedAt: row[8])
    }
}
