import Foundation
import spacesdatabase
import spacesterminalcore

extension SQLiteStore {
    /// Where a typed agent's relaunch command comes from, which is the one thing the two capture queries
    /// read differently. Each query reads the row that is authoritative at the moment it runs, so neither
    /// depends on the other's timing.
    private struct TypedAgentSource {
        /// The SQL expression holding the command of an agent the user typed into a terminal.
        let command: String
        /// The SQL predicate that admits a `.shell`-kind session as running an agent.
        let admission: String

        /// What the live capture reads: the runtime row's own foreground sample, which the session's core
        /// refreshes on its tick while the agent runs. It is the row that knows an agent is in the
        /// foreground right now, before the orchestrator's classification pass has written an agent row for
        /// it, so an agent typed a moment before a quit is still offered back.
        static let liveRuntimeRow = TypedAgentSource(
            command: "terminal_runtime_states.foreground_command",
            admission: """
                terminal_runtime_states.foreground_detected_agent_kind IS NOT NULL
                AND COALESCE(terminal_runtime_states.foreground_command, '') <> ''
                """)

        /// What the stranded capture reads: the agent row's sampled command. That capture runs at daemon
        /// start, after `TerminalSessionStaleRecovery` has nulled every `foreground_*` column of the runtime
        /// row, so the runtime row can no longer say what was running; the agent row survives the repair and
        /// its status is what says the agent had not finished.
        ///
        /// Accepted consequence: an unclean exit that lands between the first foreground sample and the
        /// reconciler pass that turns it into an agent row strands a typed agent this capture cannot see,
        /// since the repair has already taken the runtime row's copy of the command away. The window is one
        /// reconciler pass wide: the pass runs on the runtime-state-change notification the first sample
        /// itself raises, milliseconds later, and that sample lands about a second after the agent starts,
        /// so a crash has to fall inside a few milliseconds roughly a second into an agent's life to hit it.
        /// Carrying the foreground fields through the repair, or starting the reconciler before the capture,
        /// would buy that back by making the repair or daemon startup owe this capture something, which is a
        /// worse trade than losing an agent a second old.
        static let agentRow = TypedAgentSource(
            command: "agent_sessions.launch_command",
            admission: """
                agent_sessions.status IS NOT NULL
                AND agent_sessions.status <> 'exited'
                AND COALESCE(agent_sessions.launch_command, '') <> ''
                """)
    }

    /// Canonical column order for reading a capture off the live session tables; shared by both capture
    /// queries so they decode through one row shape, with only the typed agent's command coming from the
    /// query's own `source`.
    ///
    /// The agent row is joined in on the left: a spawned agent session exists as a terminal session from
    /// the moment it launches, while its `agent_sessions` row is written once its hooks or foreground
    /// detection report it, so a session captured before that still restores, just without a
    /// conversation id to resume. The kind and the conversation id always come off that row, in both
    /// queries (see `typedAgentIdentity(_:)` for the one case a row is not read), which is why a typed
    /// agent captured in the window before the classification pass has written its row carries neither:
    /// the offer lists it, says it comes back as a new conversation, and relaunches the command the
    /// runtime row recorded. A session's manual rename wins over its launch title, matching how a session
    /// is named everywhere else.
    ///
    /// The command is decided by what the session is, not by which row happens to hold a value: an agent
    /// Spaces launched relaunches from its own session row, and an agent typed into a terminal from the
    /// query's typed-agent source, which is the only place that command exists. The directory is the
    /// runtime row's live one, which advances with the agent's `cd`, and the session's launch directory
    /// only when no runtime row is joined in: the agent comes back where it was working, not where its
    /// terminal opened.
    ///
    /// The automation is resolved through the run the session was attributed to rather than stored on the
    /// session: the run row is where a session's automation is named, and a restore needs the automation
    /// itself, not the run, because the run that owned this session is canceled with the teardown that
    /// captured it.
    ///
    /// Only an `agent` automation's own agent carries that automation. A script automation exports its run
    /// id into the script's terminal, so an agent the script spawned from there (`spaces agent spawn`, the
    /// MCP server's spawn tool) is stamped with the same run id even though the automation runs a script.
    /// Such an agent is the script's work, not the automation's session shape: there is no agent run for it
    /// to come back as, since the poll and cancel paths dispatch on the automation's kind. It captures with
    /// no automation and comes back the way any agent the user started does.
    private static func restorableCaptureColumns(source: TypedAgentSource) -> String {
        """
        terminal_sessions.session_id,
        terminal_sessions.workspace_id,
        \(typedAgentIdentity("agent_sessions.detected_agent_kind")),
        \(typedAgentIdentity("agent_sessions.session_key")),
        CASE terminal_sessions.kind WHEN 'shell' THEN \(source.command) ELSE terminal_sessions.launch_command END,
        COALESCE(NULLIF(terminal_runtime_states.working_directory, ''), terminal_sessions.working_directory),
        COALESCE(NULLIF(terminal_sessions.user_title, ''), terminal_sessions.title),
        COALESCE(CASE WHEN automations.kind = 'agent' THEN automation_runs.automation_id END, '')
        """
    }

    /// `column` read off the joined `agent_sessions` row, which a `.shell`-kind session takes only while
    /// that row's status says the agent lifecycle it describes has not finished.
    ///
    /// A terminal outlives the agents typed into it, and its agent row is reused rather than replaced. When
    /// one agent exits and the user types another shortly before a teardown, the row bound to that terminal
    /// is still the exited predecessor's, carrying the predecessor's conversation id, until the foreground
    /// relaunch reconciler (`WorkspaceOrchestrator.registerAgentWindow`, driven from
    /// `reconcileForegroundAgentRows`) resets it and clears `session_key` on its next tick. Reading it
    /// unconditionally would pair the runtime row's new command with the old conversation, and the restore
    /// would reopen a conversation the user had already finished with. An exited row therefore contributes
    /// no kind and no key: the capture relaunches the command the runtime row recorded as a fresh
    /// conversation, which is the honest outcome, and once the reconciler has reset the row it is idle and
    /// keyless until the new agent's hook signal supplies its own key.
    ///
    /// An `.agent`-kind session is unaffected: its terminal exists to run the one agent Spaces launched
    /// into it, so its agent row always describes that session's own lifecycle.
    private static func typedAgentIdentity(_ column: String) -> String {
        "COALESCE(CASE WHEN terminal_sessions.kind <> 'shell' OR agent_sessions.status <> 'exited' THEN \(column) END, '')"
    }

    /// Canonical column order for a stored `restorable_sessions` row.
    private static let restorableSessionColumns = """
        session_id, generation, workspace_id, COALESCE(agent_kind, ''), COALESCE(agent_session_key, ''), launch_command, working_directory,
        title, captured_at, COALESCE(automation_id, '')
        """

    /// Every coding-agent session that is still live, across every workspace. This is what a clean Stop
    /// All and Quit captures, read before the stops run so the rows are still there to read.
    public func liveAgentSessionCaptures() throws -> [RestorableSessionCapture] {
        let interactiveStates = TerminalSessionState.allCases.filter(\.isInteractive).map(\.rawValue)
        let placeholders = Array(repeating: "?", count: interactiveStates.count).joined(separator: ", ")
        let rows = try queryRows(
            sql: """
                SELECT \(Self.restorableCaptureColumns(source: .liveRuntimeRow))
                FROM terminal_sessions
                JOIN workspaces ON workspaces.id = terminal_sessions.workspace_id
                JOIN terminal_runtime_states ON terminal_runtime_states.root_directory = terminal_sessions.root_directory
                LEFT JOIN agent_sessions ON agent_sessions.terminal_session_id = terminal_sessions.session_id
                LEFT JOIN automation_runs ON automation_runs.id = terminal_sessions.automation_run_id
                LEFT JOIN automations ON automations.id = automation_runs.automation_id
                WHERE \(Self.restorableCaptureFilter(source: .liveRuntimeRow)) AND terminal_runtime_states.state IN (\(placeholders))
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
                SELECT \(Self.restorableCaptureColumns(source: .agentRow))
                FROM terminal_sessions
                JOIN workspaces ON workspaces.id = terminal_sessions.workspace_id
                LEFT JOIN terminal_runtime_states ON terminal_runtime_states.root_directory = terminal_sessions.root_directory
                LEFT JOIN agent_sessions ON agent_sessions.terminal_session_id = terminal_sessions.session_id
                LEFT JOIN automation_runs ON automation_runs.id = terminal_sessions.automation_run_id
                LEFT JOIN automations ON automations.id = automation_runs.automation_id
                WHERE \(Self.restorableCaptureFilter(source: .agentRow)) AND terminal_sessions.session_id IN (\(placeholders))
                ORDER BY terminal_sessions.created_at, terminal_sessions.session_id
                """, bindings: sessionIDs)
        return Self.firstCapturePerSession(rows.compactMap(Self.decodeCapture(row:)))
    }

    /// What makes a session restorable at all, shared by both capture queries so neither can widen on its
    /// own. Every live coding agent is restorable however it was started, which is two shapes in SQL:
    ///  - an `.agent`-kind session carrying the raw command it was launched with. That is every agent
    ///    Spaces started: the CLI, the MCP server, an automation, and a previous restore.
    ///  - a `.shell`-kind session that `source` says is running an agent. That is an agent the user typed
    ///    into a terminal, whose command lives nowhere on the session row.
    ///
    /// The typed-agent half is the only part the two queries disagree on, and deliberately so: each reads
    /// the row that is authoritative when it runs (see `TypedAgentSource`). The live capture asks the
    /// runtime row what is in the foreground, because that row is written by the session's own core and
    /// owes nothing to the orchestrator's classification tick: an agent typed seconds before a quit has no
    /// agent row yet, and admitting it through one would drop it from the offer. The stranded capture asks
    /// the agent row, because by the time it runs the daemon-start repair has nulled the runtime row's
    /// foreground columns and the agent row is the only surviving record of what was running.
    ///
    /// A bare shell is excluded because it holds no state worth bringing back, and an automation's script
    /// session and a configured process come back through their own machinery.
    ///
    /// An agent automation's own agent IS captured, and comes back as a run of that automation: the capture
    /// carries the automation the session's run named, and the restore starts a fresh run to relaunch it
    /// under. The run that owned the captured session was canceled with the teardown, so the attribution
    /// has to be rebuilt rather than reused, and rebuilding it is what keeps the automation's concurrency
    /// policy seeing the restored agent as its live work: a `skip` automation skips its next scheduled
    /// fire while the restored agent is still going, instead of starting a second copy beside it. An agent
    /// a script automation spawned is captured too, carrying no automation, because it is the script's own
    /// work rather than the automation's session shape (see `restorableCaptureColumns(source:)`).
    ///
    /// Both queries inner-join `workspaces` for the same reason the offer exists at all: an agent can only
    /// be relaunched into a workspace that is still there, and a session whose workspace has since been
    /// deleted has nowhere to come back to.
    private static func restorableCaptureFilter(source: TypedAgentSource) -> String {
        """
        terminal_sessions.workspace_id IS NOT NULL
        AND (
          (terminal_sessions.kind = 'agent' AND COALESCE(terminal_sessions.launch_command, '') <> '')
          OR (
            terminal_sessions.kind = 'shell'
            AND \(source.admission)
          )
        )
        """
    }

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
                          session_id, generation, workspace_id, agent_kind, agent_session_key, launch_command, working_directory, title, captured_at,
                          automation_id
                        )
                        VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?, ?, ?, NULLIF(?, ''))
                        """,
                    bindings: [
                        record.sessionID, record.generation, record.workspaceID, record.agentKind?.rawValue ?? "", record.agentSessionKey ?? "",
                        record.launchCommand, record.workingDirectory, record.title, record.capturedAt, record.automationID ?? "",
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
    /// or fresh. A one-shot run (`codex exec`, `claude -p`, `opencode run`) is captured without its
    /// conversation id even when one was reported: such a run prints an answer and exits rather than
    /// holding a conversation, and Codex takes its own as `codex exec resume <key>` after options whose
    /// arity only Codex knows (see `CodingAgent.launchIsOneShotJob`). Dropping the key here puts such a row
    /// on the path an agent that never reported a conversation already takes: the offer says it comes back
    /// as a new run, and the relaunch runs the recorded command unchanged.
    private static func decodeCapture(row: [String]) -> RestorableSessionCapture? {
        guard row.count >= 8, !row[0].isEmpty, !row[1].isEmpty, !row[4].isEmpty else { return nil }
        let launchCommand = row[4]
        let agentSessionKey = row[3].isEmpty || CodingAgent.launchIsOneShotJob(launchCommand: launchCommand) ? nil : row[3]
        return RestorableSessionCapture(
            sessionID: row[0], workspaceID: row[1], agentKind: TerminalDetectedAgentKind(rawValue: row[2]), agentSessionKey: agentSessionKey,
            launchCommand: launchCommand, workingDirectory: row[5], title: row[6], automationID: row[7].isEmpty ? nil : row[7])
    }

    private static func decodeRestorableSession(row: [String]) -> RestorableSessionRecord? {
        guard row.count >= 10 else { return nil }
        return RestorableSessionRecord(
            sessionID: row[0], generation: row[1], workspaceID: row[2], agentKind: TerminalDetectedAgentKind(rawValue: row[3]),
            agentSessionKey: row[4].isEmpty ? nil : row[4], launchCommand: row[5], workingDirectory: row[6], title: row[7], capturedAt: row[8],
            automationID: row[9].isEmpty ? nil : row[9])
    }
}
