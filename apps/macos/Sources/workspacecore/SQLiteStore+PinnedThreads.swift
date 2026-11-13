import Foundation

extension SQLiteStore {
    /// Canonical column order for a pinned-thread read. The brief is the one saved for the pin's
    /// conversation, which is what a not-running pin shows.
    private static let pinnedThreadColumns = """
        pinned_threads.id,
        pinned_threads.workspace_id,
        pinned_threads.session_key,
        pinned_threads.name,
        pinned_threads.launch_command,
        pinned_threads.working_directory,
        COALESCE(pinned_threads.agent_session_id, ''),
        pinned_threads.pinned_at,
        COALESCE(agent_conversation_briefs.brief, ''),
        COALESCE(agent_conversation_briefs.brief_updated_at, '')
        """

    private static let pinnedThreadSource = """
        FROM pinned_threads
        LEFT JOIN agent_conversation_briefs
          ON agent_conversation_briefs.workspace_id = pinned_threads.workspace_id
          AND agent_conversation_briefs.session_key = pinned_threads.session_key
        """

    /// Pin order: oldest first, with the insertion order breaking a tie between pins made in one instant.
    private static let pinnedThreadOrder = "ORDER BY pinned_threads.pinned_at, pinned_threads.rowid"

    public func insertPinnedThread(_ pin: PinnedThreadRecord) throws {
        try execute(
            sql: """
                INSERT INTO pinned_threads(id, workspace_id, session_key, name, launch_command, working_directory, agent_session_id, pinned_at)
                VALUES (?, ?, ?, ?, ?, ?, NULLIF(?, ''), ?)
                """,
            bindings: [
                pin.id, pin.workspaceID, pin.sessionKey, pin.name, pin.launchCommand, pin.workingDirectory, pin.agentSessionID ?? "", pin.pinnedAt,
            ])
    }

    public func pinnedThread(id: String) throws -> PinnedThreadRecord? {
        guard let row = try queryRow(sql: "SELECT \(Self.pinnedThreadColumns) \(Self.pinnedThreadSource) WHERE pinned_threads.id = ?", bindings: [id])
        else { return nil }
        return Self.decodePinnedThread(row: row)
    }

    public func pinnedThread(attachedToAgentID agentID: String) throws -> PinnedThreadRecord? {
        guard
            let row = try queryRow(
                sql: "SELECT \(Self.pinnedThreadColumns) \(Self.pinnedThreadSource) WHERE pinned_threads.agent_session_id = ?", bindings: [agentID])
        else { return nil }
        return Self.decodePinnedThread(row: row)
    }

    public func pinnedThread(workspaceID: String, sessionKey: String) throws -> PinnedThreadRecord? {
        guard
            let row = try queryRow(
                sql:
                    "SELECT \(Self.pinnedThreadColumns) \(Self.pinnedThreadSource) WHERE pinned_threads.workspace_id = ? AND pinned_threads.session_key = ?",
                bindings: [workspaceID, sessionKey])
        else { return nil }
        return Self.decodePinnedThread(row: row)
    }

    public func pinnedThreads(workspaceID: String) throws -> [PinnedThreadRecord] {
        try queryRows(
            sql: "SELECT \(Self.pinnedThreadColumns) \(Self.pinnedThreadSource) WHERE pinned_threads.workspace_id = ? \(Self.pinnedThreadOrder)",
            bindings: [workspaceID]
        ).compactMap(Self.decodePinnedThread(row:))
    }

    /// Batched form of `pinnedThreads(workspaceID:)` for the overview hot path; each group keeps pin order.
    public func pinnedThreadsByWorkspace() throws -> [String: [PinnedThreadRecord]] {
        let rows = try queryRows(sql: "SELECT \(Self.pinnedThreadColumns) \(Self.pinnedThreadSource) \(Self.pinnedThreadOrder)")
        return Dictionary(grouping: rows.compactMap(Self.decodePinnedThread(row:)), by: \.workspaceID)
    }

    public func setPinnedThreadAgent(id: String, agentSessionID: String?) throws {
        try execute(sql: "UPDATE pinned_threads SET agent_session_id = NULLIF(?, '') WHERE id = ?", bindings: [agentSessionID ?? "", id])
    }

    public func setPinnedThreadName(id: String, name: String) throws {
        try execute(sql: "UPDATE pinned_threads SET name = ? WHERE id = ?", bindings: [name, id])
    }

    public func deletePinnedThread(id: String) throws { try execute(sql: "DELETE FROM pinned_threads WHERE id = ?", bindings: [id]) }

    /// The conversation an agent row could be pinned as, nil when no row has that id. The command and
    /// directory follow the rule the restorable capture applies (`restorableCaptureColumns`), because a
    /// pin resumes the way a restore does: a typed agent relaunches from its terminal's foreground command,
    /// falling back to the command sampled onto its row once the agent has exited and the foreground
    /// columns are clear, and a Spaces-launched agent from its session's own command. The conversation id is
    /// the row's stored one even when the row is exited: a pin of an exited agent is allowed.
    public func pinnableConversation(agentID: String) throws -> PinnableConversation? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT
                      COALESCE(agent_sessions.session_key, ''),
                      COALESCE(
                        CASE terminal_sessions.kind
                          WHEN 'shell' THEN COALESCE(NULLIF(terminal_runtime_states.foreground_command, ''), agent_sessions.launch_command)
                          ELSE terminal_sessions.launch_command
                        END, ''),
                      COALESCE(\(Self.restorableWorkingDirectoryColumn), '')
                    FROM agent_sessions
                    LEFT JOIN terminal_sessions ON terminal_sessions.session_id = agent_sessions.terminal_session_id
                    LEFT JOIN terminal_runtime_states ON terminal_runtime_states.root_directory = terminal_sessions.root_directory
                    WHERE agent_sessions.id = ?
                    """, bindings: [agentID]), row.count >= 3
        else { return nil }
        return PinnableConversation(
            sessionKey: row[0].isEmpty ? nil : row[0], launchCommand: row[1].isEmpty ? nil : row[1], workingDirectory: row[2].isEmpty ? nil : row[2])
    }

    private static func decodePinnedThread(row: [String]) -> PinnedThreadRecord? {
        guard row.count >= 10 else { return nil }
        return PinnedThreadRecord(
            id: row[0], workspaceID: row[1], sessionKey: row[2], name: row[3], launchCommand: row[4], workingDirectory: row[5],
            agentSessionID: row[6].isEmpty ? nil : row[6], pinnedAt: row[7], brief: row[8].isEmpty ? nil : row[8],
            briefUpdatedAt: row[9].isEmpty ? nil : row[9])
    }
}
