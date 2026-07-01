import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
    public func upsertAgentWindow(_ record: AgentWindowRecord) throws {
        let runtimeTargetID = try ensureRuntimeTargetForAgentWindow(record)
        let terminalSessionID = spacesAgentTerminalSessionID(record)
        try withImmediateTransaction {
            try execute(
                sql: """
                        INSERT INTO agent_sessions(
                          id, workspace_id, provider, label, status, runtime_target_id, terminal_session_id, session_key, claimed_launcher_id, claimed_launcher_name, created_at, updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?, ?)
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
                          updated_at = excluded.updated_at
                    """,
                bindings: [
                    record.id, record.workspaceID, record.provider.rawValue, record.label ?? "", record.status.rawValue, runtimeTargetID ?? "",
                    terminalSessionID ?? "", record.sessionKey ?? "", record.claimedLauncherID ?? "", record.claimedLauncherName ?? "",
                    record.createdAt, record.updatedAt,
                ])
        }
    }

    public func agentWindows(workspaceID: String) throws -> [AgentWindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT
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
                  agent_sessions.created_at,
                  agent_sessions.updated_at
                FROM agent_sessions
                LEFT JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                WHERE agent_sessions.workspace_id = ?
                ORDER BY agent_sessions.created_at
                """, bindings: [workspaceID])
        return rows.compactMap { decodeAgentWindow(row: $0) }
    }

    public func agentWindow(workspaceID: String, terminalTrackingID: String) throws -> AgentWindowRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT
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
                      agent_sessions.created_at,
                      agent_sessions.updated_at
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
                  agent_sessions.created_at,
                  agent_sessions.updated_at
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

    public func appendAgentSessionEvent(
        agentSessionID: String, eventType: String, source: String, message: String?, runtimeTargetID: String?, createdAt: String
    ) throws {
        try execute(
            sql: """
                INSERT INTO agent_session_events(id, agent_session_id, event_type, source, message, runtime_target_id, created_at)
                VALUES (?, ?, ?, ?, ?, NULLIF(?, ''), ?)
                """, bindings: [UUID().uuidString, agentSessionID, eventType, source, message ?? "", runtimeTargetID ?? "", createdAt])
    }

    public func deleteAgentWindows(workspaceID: String) throws {
        try execute(sql: "DELETE FROM agent_sessions WHERE workspace_id = ?", bindings: [workspaceID])
    }

    public func deleteAgentWindow(id: String) throws { try execute(sql: "DELETE FROM agent_sessions WHERE id = ?", bindings: [id]) }

    public func deleteAgentWindowsByProvider(workspaceID: String, provider: AgentProvider) throws {
        try execute(sql: "DELETE FROM agent_sessions WHERE workspace_id = ? AND provider = ?", bindings: [workspaceID, provider.rawValue])
    }

    func decodeAgentWindow(row: [String]) -> AgentWindowRecord? {
        guard row.count >= 16 else { return nil }
        guard let provider = AgentProvider(rawValue: row[2]) else { return nil }
        let terminalSessionID = row[9].isEmpty ? nil : row[9]
        let status = AgentWindowStatus(rawValue: row[13]) ?? .idle
        let resolvedTrackingID = row[8].isEmpty ? row[9] : row[8]
        // The captured desktop window belongs to the linked runtime target (row[4]); an agent
        // detached from its target has none, so its window ID resolves to nil.
        let terminalTarget = decodeTerminalTarget(
            runtimeTargetID: row[4], app: row[5].isEmpty && terminalSessionID != nil ? TerminalHost.spaces.appName : row[5], name: row[6],
            detail: row[7], windowID: overlaidWindowID(workspaceID: row[1], runtimeTargetID: row[4].isEmpty ? nil : row[4]),
            trackingID: resolvedTrackingID)
        return AgentWindowRecord(
            id: row[0], workspaceID: row[1], provider: provider, label: row[3].isEmpty ? nil : row[3], runtimeTargetID: row[4].isEmpty ? nil : row[4],
            terminalTarget: terminalTarget, sessionKey: row[10].isEmpty ? nil : row[10], claimedLauncherID: row[11].isEmpty ? nil : row[11],
            claimedLauncherName: row[12].isEmpty ? nil : row[12], status: status, createdAt: row[14], updatedAt: row[15])
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
        let now = ISO8601DateFormatter().string(from: Date())
        let preservesExistingMetadata = try preservesExistingTerminalMetadata(for: record)
        try upsert(
            window: WindowRecord(
                id: targetID, workspaceID: record.workspaceID, app: TerminalHost.spaces.appName,
                name: preservesExistingMetadata ? (existingWindow?.name ?? record.label ?? "Coding Agent CLI") : (record.label ?? "Coding Agent CLI"),
                detail: preservesExistingMetadata ? existingWindow?.detail : nil, targetURL: nil, windowID: terminalTarget.windowID,
                terminalTrackingID: terminalTarget.trackingID, terminalNativeID: terminalTarget.trackingID, role: "terminal",
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
