import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
    /// Canonical column order for a full `agent_sessions` row read, joined against `runtime_targets`
    /// for the terminal target fields; reused by every SELECT below. This is not the same list as the
    /// `agent_sessions` INSERT columns (which write the base table directly, without the join), so it
    /// is not shared with the INSERT.
    private static let agentWindowColumns = """
        agent_sessions.id,
        agent_sessions.workspace_id,
        agent_sessions.provider,
        agent_sessions.label,
        COALESCE(agent_sessions.runtime_target_id, ''),
        COALESCE(runtime_targets.app, ''),
        COALESCE(runtime_targets.name, ''),
        COALESCE(runtime_targets.detail, ''),
        COALESCE(runtime_targets.tracking_id, ''),
        COALESCE(agent_sessions.terminal_session_id, ''),
        COALESCE(agent_sessions.session_key, ''),
        COALESCE(agent_sessions.claimed_launcher_id, ''),
        COALESCE(agent_sessions.claimed_launcher_name, ''),
        agent_sessions.status,
        agent_sessions.note,
        agent_sessions.created_at,
        agent_sessions.updated_at
        """

    public func upsertAgentWindow(_ record: AgentWindowRecord) throws {
        let runtimeTargetID = try ensureRuntimeTargetForAgentWindow(record)
        let terminalSessionID = spacesAgentTerminalSessionID(record)
        try withImmediateTransaction {
            try execute(
                sql: """
                        INSERT INTO agent_sessions(
                          id, workspace_id, provider, label, status, runtime_target_id, terminal_session_id, session_key, claimed_launcher_id, claimed_launcher_name, note, created_at, updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                          workspace_id = excluded.workspace_id,
                          provider = excluded.provider,
                          label = excluded.label,
                          status = excluded.status,
                          runtime_target_id = excluded.runtime_target_id,
                          terminal_session_id = COALESCE(excluded.terminal_session_id, agent_sessions.terminal_session_id),
                          session_key = excluded.session_key,
                          claimed_launcher_id = COALESCE(excluded.claimed_launcher_id, agent_sessions.claimed_launcher_id),
                          claimed_launcher_name = excluded.claimed_launcher_name,
                          note = COALESCE(excluded.note, agent_sessions.note),
                          updated_at = excluded.updated_at
                    """,
                bindings: [
                    record.id, record.workspaceID, record.provider.rawValue, record.label ?? "", record.status.rawValue, runtimeTargetID ?? "",
                    terminalSessionID ?? "", record.sessionKey ?? "", record.claimedLauncherID ?? "", record.claimedLauncherName ?? "",
                    record.note ?? "", record.createdAt, record.updatedAt,
                ])
        }
    }

    public func agentWindows(workspaceID: String) throws -> [AgentWindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT
                  \(Self.agentWindowColumns)
                FROM agent_sessions
                LEFT JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                WHERE agent_sessions.workspace_id = ?
                ORDER BY agent_sessions.created_at
                """, bindings: [workspaceID])
        return rows.compactMap { decodeAgentWindow(row: $0) }
    }

    /// Batched form of `agentWindows(workspaceID:)`: one full-table SELECT grouped by workspace in Swift,
    /// eliminating the per-workspace query on the overview hot path. Grouping preserves element order,
    /// and the SELECT orders by `workspace_id` then the same `created_at` key the per-workspace query
    /// uses, so each group matches `agentWindows(workspaceID:)` exactly.
    public func agentWindowsByWorkspace() throws -> [String: [AgentWindowRecord]] {
        let rows = try queryRows(
            sql: """
                SELECT
                  \(Self.agentWindowColumns)
                FROM agent_sessions
                LEFT JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                ORDER BY agent_sessions.workspace_id, agent_sessions.created_at
                """)
        return Dictionary(grouping: rows.compactMap { decodeAgentWindow(row: $0) }, by: { $0.workspaceID })
    }

    public func agentWindow(workspaceID: String, terminalTrackingID: String) throws -> AgentWindowRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT
                      \(Self.agentWindowColumns)
                    FROM agent_sessions
                    LEFT JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                    WHERE agent_sessions.workspace_id = ?
                      AND (runtime_targets.tracking_id = ? OR agent_sessions.terminal_session_id = ?)
                    """, bindings: [workspaceID, terminalTrackingID, terminalTrackingID])
        else { return nil }
        return decodeAgentWindow(row: row)
    }

    public func agentWindowsByProvider(workspaceID: String, provider: AgentProvider) throws -> [AgentWindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT
                  \(Self.agentWindowColumns)
                FROM agent_sessions
                LEFT JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                WHERE agent_sessions.workspace_id = ?
                AND agent_sessions.provider = ?
                ORDER BY agent_sessions.created_at
                """, bindings: [workspaceID, provider.rawValue])
        return rows.compactMap { decodeAgentWindow(row: $0) }
    }

    public func updateAgentWindowStatus(id: String, status: AgentWindowStatus, updatedAt: String) throws {
        try execute(sql: "UPDATE agent_sessions SET status = ?, updated_at = ? WHERE id = ?", bindings: [status.rawValue, updatedAt, id])
    }

    public func agentSessionRuntimeTargetID(id: String) throws -> String? {
        let row = try queryRow(sql: "SELECT COALESCE(runtime_target_id, '') FROM agent_sessions WHERE id = ?", bindings: [id])
        guard let value = row?.first, !value.isEmpty else { return nil }
        return value
    }

    public func latestAgentSessionEventMessage(id: String, eventType: String, source: String) throws -> String? {
        guard
            let value = try queryRow(
                sql: """
                    SELECT COALESCE(message, '')
                    FROM agent_session_events
                    WHERE agent_session_id = ?
                      AND event_type = ?
                      AND source = ?
                      AND length(COALESCE(message, '')) > 0
                    ORDER BY created_at DESC, rowid DESC
                    LIMIT 1
                    """, bindings: [id, eventType, source])?.first, !value.isEmpty
        else { return nil }
        return value
    }

    public func appendAgentSessionEvent(agentSessionID: String, eventType: String, source: String, message: String?, createdAt: String) throws {
        try execute(
            sql: """
                INSERT INTO agent_session_events(id, agent_session_id, event_type, source, message, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, bindings: [UUID().uuidString, agentSessionID, eventType, source, message ?? "", createdAt])
    }

    public func deleteAgentWindows(workspaceID: String) throws {
        try execute(sql: "DELETE FROM agent_sessions WHERE workspace_id = ?", bindings: [workspaceID])
    }

    public func deleteAgentWindow(id: String) throws { try execute(sql: "DELETE FROM agent_sessions WHERE id = ?", bindings: [id]) }

    /// Sets (or, with an empty `note`, clears) an agent session's explicit annotation. The note is
    /// written directly here rather than through `upsertAgentWindow` so a status signal — which upserts
    /// with a nil note and therefore preserves the stored one — never clobbers an annotation.
    public func setAgentSessionNote(id: String, note: String?, updatedAt: String) throws {
        try execute(sql: "UPDATE agent_sessions SET note = NULLIF(?, ''), updated_at = ? WHERE id = ?", bindings: [note ?? "", updatedAt, id])
    }

    /// Whether an agent session row with this id exists in any workspace. Used to validate a
    /// subscription target before persisting the edge, since the subscriber references an agent row by
    /// id rather than by a workspace-scoped lookup.
    public func agentWindowExists(id: String) throws -> Bool {
        try queryRow(sql: "SELECT 1 FROM agent_sessions WHERE id = ? LIMIT 1", bindings: [id]) != nil
    }

    public func insertAgentSubscription(subscriberTerminalSessionID: String, agentSessionID: String, createdAt: String) throws {
        try execute(
            sql: """
                INSERT INTO agent_subscriptions(subscriber_terminal_session_id, agent_session_id, created_at)
                VALUES (?, ?, ?)
                ON CONFLICT(subscriber_terminal_session_id, agent_session_id) DO NOTHING
                """, bindings: [subscriberTerminalSessionID, agentSessionID, createdAt])
    }

    public func deleteAgentSubscription(subscriberTerminalSessionID: String, agentSessionID: String) throws {
        try execute(
            sql: "DELETE FROM agent_subscriptions WHERE subscriber_terminal_session_id = ? AND agent_session_id = ?",
            bindings: [subscriberTerminalSessionID, agentSessionID])
    }

    /// Subscribers watching a given agent session (used when that agent changes state).
    public func agentSubscriptions(agentSessionID: String) throws -> [AgentSubscriptionRecord] {
        try queryRows(
            sql: """
                SELECT subscriber_terminal_session_id, agent_session_id, created_at
                FROM agent_subscriptions
                WHERE agent_session_id = ?
                ORDER BY created_at
                """, bindings: [agentSessionID]
        ).compactMap(decodeAgentSubscription)
    }

    /// Agent sessions a given terminal session is watching (used when that subscriber goes idle).
    public func agentSubscriptions(subscriberTerminalSessionID: String) throws -> [AgentSubscriptionRecord] {
        try queryRows(
            sql: """
                SELECT subscriber_terminal_session_id, agent_session_id, created_at
                FROM agent_subscriptions
                WHERE subscriber_terminal_session_id = ?
                ORDER BY created_at
                """, bindings: [subscriberTerminalSessionID]
        ).compactMap(decodeAgentSubscription)
    }

    /// Timestamp of the most recent hook-sourced lifecycle signal for an agent session, or `nil` when it
    /// has never been signaled. Readiness is defined by a real `spaces_agent_signal` event, so
    /// foreground-detection events (a different source) are deliberately excluded.
    public func lastAgentSignalAt(agentSessionID: String) throws -> String? {
        guard
            let value = try queryRow(
                sql: "SELECT MAX(created_at) FROM agent_session_events WHERE agent_session_id = ? AND source = 'spaces_agent_signal'",
                bindings: [agentSessionID])?.first, !value.isEmpty
        else { return nil }
        return value
    }

    private func decodeAgentSubscription(row: [String]) -> AgentSubscriptionRecord? {
        guard row.count >= 3 else { return nil }
        return AgentSubscriptionRecord(subscriberTerminalSessionID: row[0], agentSessionID: row[1], createdAt: row[2])
    }

    public func deleteAgentWindowsByProvider(workspaceID: String, provider: AgentProvider) throws {
        try execute(sql: "DELETE FROM agent_sessions WHERE workspace_id = ? AND provider = ?", bindings: [workspaceID, provider.rawValue])
    }

    func decodeAgentWindow(row: [String]) -> AgentWindowRecord? {
        guard row.count >= 17 else { return nil }
        guard let provider = AgentProvider(rawValue: row[2]) else { return nil }
        let terminalSessionID = row[9].isEmpty ? nil : row[9]
        let status = AgentWindowStatus(rawValue: row[13]) ?? .idle
        let resolvedTrackingID = row[8].isEmpty ? row[9] : row[8]
        let terminalTarget = decodeTerminalTarget(
            runtimeTargetID: row[4], app: row[5].isEmpty && terminalSessionID != nil ? TerminalHost.spaces.appName : row[5], name: row[6],
            detail: row[7], trackingID: resolvedTrackingID)
        return AgentWindowRecord(
            id: row[0], workspaceID: row[1], provider: provider, label: row[3].isEmpty ? nil : row[3], runtimeTargetID: row[4].isEmpty ? nil : row[4],
            terminalTarget: terminalTarget, sessionKey: row[10].isEmpty ? nil : row[10], claimedLauncherID: row[11].isEmpty ? nil : row[11],
            claimedLauncherName: row[12].isEmpty ? nil : row[12], status: status, note: row[14].isEmpty ? nil : row[14], createdAt: row[15],
            updatedAt: row[16])
    }

    func spacesAgentTerminalSessionID(_ record: AgentWindowRecord) -> String? {
        guard record.provider == .spaces, let terminalTrackingID = record.terminalTrackingID, !terminalTrackingID.isEmpty else { return nil }
        return terminalTrackingID
    }

    func ensureRuntimeTargetForAgentWindow(_ record: AgentWindowRecord) throws -> String? {
        let runtimeTargetID =
            try record.runtimeTargetID ?? matchingRuntimeTargetID(workspaceID: record.workspaceID, trackingID: record.terminalTrackingID)
        guard let terminalTarget = record.terminalTarget else { return runtimeTargetID }
        let targetID = runtimeTargetID ?? terminalTarget.runtimeTargetID ?? record.id
        let existingWindows = try windows(workspaceID: record.workspaceID)
        let existingWindow = existingWindows.first(where: { $0.id == targetID })
        let now = TerminalSessionTimestamp.string(from: Date())
        let preservesExistingMetadata = try preservesExistingTerminalMetadata(for: record)
        try upsert(
            window: WindowRecord(
                id: targetID, workspaceID: record.workspaceID, app: TerminalHost.spaces.appName,
                name: preservesExistingMetadata ? (existingWindow?.name ?? record.label ?? "Coding Agent CLI") : (record.label ?? "Coding Agent CLI"),
                detail: preservesExistingMetadata ? existingWindow?.detail : nil, targetURL: nil, terminalTrackingID: terminalTarget.trackingID,
                role: "terminal",
                orderIndex: existingWindow?.orderIndex ?? nextRuntimeTargetOrderIndex(existing: existingWindows, role: "terminal", orderOffset: 200),
                lastSeenAt: now))
        return targetID
    }

    func preservesExistingTerminalMetadata(for record: AgentWindowRecord) throws -> Bool {
        if let sessionID = spacesAgentTerminalSessionID(record), let kind = try terminalSessionKind(sessionID: sessionID) { return kind == .shell }
        return record.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && record.claimedLauncherName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    func terminalSessionKind(sessionID: String) throws -> TerminalSessionKind? {
        let row = try queryRow(sql: "SELECT kind FROM terminal_sessions WHERE session_id = ? LIMIT 1", bindings: [sessionID])
        guard let rawKind = row?.first, !rawKind.isEmpty else { return nil }
        return TerminalSessionKind(rawValue: rawKind)
    }
}
