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

    // MARK: - Cross-device watch edges (agent_remote_subscriptions)

    public func insertAgentRemoteSubscription(subscriberTerminalSessionID: String, deviceID: String, agentSessionID: String, createdAt: String) throws {
        try execute(
            sql: """
                INSERT INTO agent_remote_subscriptions(subscriber_terminal_session_id, device_id, agent_session_id, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(subscriber_terminal_session_id, device_id, agent_session_id) DO NOTHING
                """, bindings: [subscriberTerminalSessionID, deviceID, agentSessionID, createdAt])
    }

    public func deleteAgentRemoteSubscription(subscriberTerminalSessionID: String, deviceID: String, agentSessionID: String) throws {
        try execute(
            sql: """
                DELETE FROM agent_remote_subscriptions
                WHERE subscriber_terminal_session_id = ? AND device_id = ? AND agent_session_id = ?
                """, bindings: [subscriberTerminalSessionID, deviceID, agentSessionID])
    }

    /// Drops every subscriber's edge to one remote agent — used when the watch service sees that agent
    /// exit (its row left the remote listing), after the terminating line has been delivered.
    public func deleteAgentRemoteSubscriptions(deviceID: String, agentSessionID: String) throws {
        try execute(
            sql: "DELETE FROM agent_remote_subscriptions WHERE device_id = ? AND agent_session_id = ?", bindings: [deviceID, agentSessionID])
    }

    /// Remote agents a given local terminal is watching (used when that subscriber goes idle to flush its
    /// queue — the flush path is shared with local subscriptions and keys only on the subscriber).
    public func agentRemoteSubscriptions(subscriberTerminalSessionID: String) throws -> [AgentRemoteSubscriptionRecord] {
        try queryRows(
            sql: """
                SELECT subscriber_terminal_session_id, device_id, agent_session_id, created_at
                FROM agent_remote_subscriptions
                WHERE subscriber_terminal_session_id = ?
                ORDER BY created_at
                """, bindings: [subscriberTerminalSessionID]
        ).compactMap(decodeAgentRemoteSubscription)
    }

    /// Every watch edge pointed at a given device (used by the watch service to compute the set of remote
    /// agents to diff for that device's overview stream).
    public func agentRemoteSubscriptions(deviceID: String) throws -> [AgentRemoteSubscriptionRecord] {
        try queryRows(
            sql: """
                SELECT subscriber_terminal_session_id, device_id, agent_session_id, created_at
                FROM agent_remote_subscriptions
                WHERE device_id = ?
                ORDER BY created_at
                """, bindings: [deviceID]
        ).compactMap(decodeAgentRemoteSubscription)
    }

    /// The subscriber terminal ids watching one remote agent (used to fan a transition out to watchers).
    public func agentRemoteSubscribers(deviceID: String, agentSessionID: String) throws -> [String] {
        try queryRows(
            sql: """
                SELECT subscriber_terminal_session_id
                FROM agent_remote_subscriptions
                WHERE device_id = ? AND agent_session_id = ?
                ORDER BY created_at
                """, bindings: [deviceID, agentSessionID]
        ).compactMap { $0.first }
    }

    /// Distinct device ids with at least one watch edge — the set of paired devices the watch service
    /// keeps an overview stream open to.
    public func agentRemoteSubscriptionDeviceIDs() throws -> [String] {
        try queryRows(sql: "SELECT DISTINCT device_id FROM agent_remote_subscriptions ORDER BY device_id").compactMap { $0.first }
    }

    private func decodeAgentRemoteSubscription(row: [String]) -> AgentRemoteSubscriptionRecord? {
        guard row.count >= 4 else { return nil }
        return AgentRemoteSubscriptionRecord(subscriberTerminalSessionID: row[0], deviceID: row[1], agentSessionID: row[2], createdAt: row[3])
    }

    /// The Spaces agent row bound to a terminal session id, searched across every workspace. Returns
    /// `nil` when the terminal has no agent row — a plain shell terminal, which the notification engine
    /// treats as idle. Orchestration reaches an agent by terminal session id (subscriptions key on it)
    /// without knowing the owning workspace, hence the unscoped lookup.
    public func agentWindowByTerminalSession(terminalSessionID: String) throws -> AgentWindowRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT
                      \(Self.agentWindowColumns)
                    FROM agent_sessions
                    LEFT JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                    WHERE agent_sessions.terminal_session_id = ? OR runtime_targets.tracking_id = ?
                    LIMIT 1
                    """, bindings: [terminalSessionID, terminalSessionID])
        else { return nil }
        return decodeAgentWindow(row: row)
    }

    /// The agent row with this id (across every workspace), or `nil` when absent. Subscription
    /// validation resolves the watched agent by its row id to read the terminal it is bound to.
    public func agentWindow(id: String) throws -> AgentWindowRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT
                      \(Self.agentWindowColumns)
                    FROM agent_sessions
                    LEFT JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                    WHERE agent_sessions.id = ?
                    LIMIT 1
                    """, bindings: [id])
        else { return nil }
        return decodeAgentWindow(row: row)
    }

    /// Enqueues (or coalesces onto) the pending notification for a (subscriber, agent) pair. `INSERT OR
    /// REPLACE` on the unique index replaces any existing pending line for the same pair, so a child that
    /// goes blocked then done while its subscriber is busy leaves exactly one row rendering the latest
    /// state. `transition` is the transition word the rendered `message` carries (`blocked`/`done`/
    /// `exited`) — the structural key a resume uses to withdraw held blocked lines. A fresh `id` is
    /// generated on every write like the other event stores.
    public func upsertPendingAgentNotification(
        subscriberTerminalSessionID: String, agentSessionID: String, transition: String, message: String, createdAt: String
    ) throws {
        try execute(
            sql: """
                INSERT OR REPLACE INTO agent_pending_notifications(id, subscriber_terminal_session_id, agent_session_id, transition, message, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, bindings: [UUID().uuidString, subscriberTerminalSessionID, agentSessionID, transition, message, createdAt])
    }

    /// Pending notifications for a subscriber terminal in enqueue order, flushed when it goes idle.
    public func pendingAgentNotifications(subscriberTerminalSessionID: String) throws -> [AgentPendingNotificationRecord] {
        try queryRows(
            sql: """
                SELECT id, subscriber_terminal_session_id, agent_session_id, message, created_at
                FROM agent_pending_notifications
                WHERE subscriber_terminal_session_id = ?
                ORDER BY created_at, rowid
                """, bindings: [subscriberTerminalSessionID]
        ).compactMap(decodePendingAgentNotification)
    }

    public func deletePendingAgentNotification(id: String) throws {
        try execute(sql: "DELETE FROM agent_pending_notifications WHERE id = ?", bindings: [id])
    }

    /// Atomically drains a subscriber terminal's held notifications: reads its pending rows in `created_at`
    /// order and deletes them in one `BEGIN IMMEDIATE` transaction, returning the rendered messages. This is
    /// the MCP piggyback path — a busy orchestrator (whose idle-flush has therefore not run) picks its
    /// watched children's held events up on the response of its next tool call. Reusing the same
    /// `pendingAgentNotifications` SELECT the idle-flush path (`AgentNotificationEngine.subscriberDidBecomeIdle`)
    /// reads, then deleting the whole set inside the transaction on the store's single connection, is what
    /// keeps the two delivery paths from ever handing out the same row twice: whichever runs first removes
    /// the rows atomically before the other can observe them, and both delete as they deliver.
    public func consumePendingAgentNotifications(subscriberTerminalSessionID: String) throws -> [String] {
        try withTransaction {
            let pending = try pendingAgentNotifications(subscriberTerminalSessionID: subscriberTerminalSessionID)
            guard !pending.isEmpty else { return [] }
            try deletePendingAgentNotifications(subscriberTerminalSessionID: subscriberTerminalSessionID)
            return pending.map(\.message)
        }
    }

    public func deletePendingAgentNotifications(subscriberTerminalSessionID: String) throws {
        try execute(sql: "DELETE FROM agent_pending_notifications WHERE subscriber_terminal_session_id = ?", bindings: [subscriberTerminalSessionID])
    }

    /// Withdraws every subscriber's held line for one watched agent when that line renders `transition`.
    /// Used when a blocked child resumes working: its held `blocked` lines (across all subscribers) are
    /// misinformation, while `done`/`exited` lines are terminal facts and are never passed here.
    public func deletePendingAgentNotifications(agentSessionID: String, transition: String) throws {
        try execute(
            sql: "DELETE FROM agent_pending_notifications WHERE agent_session_id = ? AND transition = ?", bindings: [agentSessionID, transition])
    }

    private func decodePendingAgentNotification(row: [String]) -> AgentPendingNotificationRecord? {
        guard row.count >= 5 else { return nil }
        return AgentPendingNotificationRecord(
            id: row[0], subscriberTerminalSessionID: row[1], agentSessionID: row[2], message: row[3], createdAt: row[4])
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
