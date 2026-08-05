import Foundation
import spacesdatabase
import spacesdevicecore
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
        agent_sessions.updated_at,
        COALESCE(agent_sessions.detected_agent_kind, ''),
        COALESCE(agent_sessions.user_label, '')
        """

    /// Lifecycle-owning upsert. Hook/lifecycle writers (`registerAgentWindow`, `updateAgentWindowStatus`,
    /// launcher launch) hold the authoritative record they just computed, so on conflict the row's
    /// lifecycle columns take the caller's values: `status`, `session_key`, and `claimed_launcher_name`
    /// are overwritten from `excluded`. `detected_agent_kind` is the exception both upserts share: a
    /// caller that observed no kind (foreground detection has not classified the session, or already
    /// cleared its classification at exit) carries nil, and nil must never erase a kind the row already
    /// learned — the stored value is what the exit notification names.
    public func upsertAgentWindow(_ record: AgentWindowRecord) throws {
        try upsertAgentWindow(record, conflictClause: Self.lifecycleOwningConflictClause)
    }

    /// Records a finalized exit status on an agent row, but only while the row still is the one the
    /// caller judged — same id, still bound to the same terminal session. The exit reconcilers
    /// (`reconcileExitedSessionBackedAgentRows`, the foreground reconciler) run on their own connection
    /// without the workspace lifecycle lock, so a stop or restart can delete the row, and a fresh agent
    /// reusing the row can rebind it to a new session, between the pass reading its snapshot and writing
    /// its verdict. An upsert would re-insert the deleted row: it would hold the configured launcher's
    /// slot on a dead session (reported "exited" forever) and, still carrying the agent's name, force the
    /// replacement agent onto a deduplicated `<name>-2` row. Returns whether the write applied.
    public func markAgentWindowExitStatus(_ snapshot: AgentWindowRecord, status: AgentWindowStatus, updatedAt: String) throws -> Bool {
        let expectedSessionID = spacesAgentTerminalSessionID(snapshot)
        return try withImmediateTransaction {
            try execute(
                sql: """
                    UPDATE agent_sessions
                    SET status = ?, updated_at = ?
                    WHERE id = ? AND terminal_session_id IS NULLIF(?, '')
                    """, bindings: [status.rawValue, updatedAt, snapshot.id, expectedSessionID ?? ""])
            guard let row = try queryRow(sql: "SELECT changes()"), let changed = Int(row.first ?? "") else { return false }
            return changed > 0
        }
    }

    /// Detection/reconciler upsert. Foreground detection and the exited-session reconciler only ever
    /// create or refresh a row's label/command/runtime-target binding; detection never owns lifecycle
    /// state. The re-read they perform before upserting runs several intervening statements earlier on a
    /// separate connection, during which a hook signal (its own connection) can commit a newer
    /// status/session-key. An overwriting upsert would revert that live state to the caller's stale
    /// snapshot; this guarantee is therefore enforced in SQL, not in the caller: on conflict the
    /// lifecycle columns keep the STORED row's values — `status`, `session_key`, `claimed_launcher_name`
    /// (coalesced), `created_at`, and `updated_at` — regardless of what the caller's record carried,
    /// closing the read-modify-upsert race entirely. `updated_at` tracks when the row's lifecycle state
    /// was entered (see `setAgentSessionNote`), so it must move in lockstep with `status`, not with a
    /// detection refresh that leaves status untouched. On first insert (no conflict) the record's own
    /// values are used, so a detection record must still carry sensible initial lifecycle values.
    public func upsertDetectedAgentWindow(_ record: AgentWindowRecord) throws {
        try upsertAgentWindow(record, conflictClause: Self.detectionPreservingConflictClause)
    }

    private static let lifecycleOwningConflictClause = """
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
          detected_agent_kind = COALESCE(excluded.detected_agent_kind, agent_sessions.detected_agent_kind),
          updated_at = excluded.updated_at
        """

    private static let detectionPreservingConflictClause = """
        ON CONFLICT(id) DO UPDATE SET
          workspace_id = excluded.workspace_id,
          provider = excluded.provider,
          label = excluded.label,
          status = agent_sessions.status,
          runtime_target_id = excluded.runtime_target_id,
          terminal_session_id = COALESCE(excluded.terminal_session_id, agent_sessions.terminal_session_id),
          session_key = agent_sessions.session_key,
          claimed_launcher_id = COALESCE(excluded.claimed_launcher_id, agent_sessions.claimed_launcher_id),
          claimed_launcher_name = COALESCE(excluded.claimed_launcher_name, agent_sessions.claimed_launcher_name),
          note = COALESCE(excluded.note, agent_sessions.note),
          detected_agent_kind = COALESCE(excluded.detected_agent_kind, agent_sessions.detected_agent_kind),
          created_at = agent_sessions.created_at,
          updated_at = agent_sessions.updated_at
        """

    /// Neither upsert writes `user_label`: it is absent from the INSERT column list and from both conflict
    /// clauses, so a lifecycle, hook, or detection write can neither set nor erase a user's rename, which
    /// is what keeps a rename stable while the agent keeps signaling. Every write to the column goes
    /// through `setAgentSessionUserLabel`, and only two callers reach it: the rename command, and claim
    /// formation clearing a rename off an agent a configured launcher has taken over naming.
    /// `AgentWindowRecord.userLabel` is therefore read-only here: a record carrying one is not rejected,
    /// it simply does not carry that field into the table.
    private func upsertAgentWindow(_ record: AgentWindowRecord, conflictClause: String) throws {
        let runtimeTargetID = try ensureRuntimeTargetForAgentWindow(record)
        let terminalSessionID = spacesAgentTerminalSessionID(record)
        try withImmediateTransaction {
            try execute(
                sql: """
                        INSERT INTO agent_sessions(
                          id, workspace_id, provider, label, status, runtime_target_id, terminal_session_id, session_key, claimed_launcher_id, claimed_launcher_name, note, detected_agent_kind, created_at, updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?, ?)
                        \(conflictClause)
                    """,
                bindings: [
                    record.id, record.workspaceID, record.provider.rawValue, record.label ?? "", record.status.rawValue, runtimeTargetID ?? "",
                    terminalSessionID ?? "", record.sessionKey ?? "", record.claimedLauncherID ?? "", record.claimedLauncherName ?? "",
                    record.note ?? "", record.detectedAgentKind ?? "", record.createdAt, record.updatedAt,
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
    /// Updates only the note column. `updated_at` tracks when an agent entered its current lifecycle
    /// state (read as the alert event timestamp by clients such as iOS Alerts), so annotating must not
    /// touch it or a stale blocked/finished event would appear to have just occurred.
    public func setAgentSessionNote(id: String, note: String?) throws {
        try execute(sql: "UPDATE agent_sessions SET note = NULLIF(?, '') WHERE id = ?", bindings: [note ?? "", id])
    }

    /// Sets (or, with a nil `userLabel`, clears) the user-authored name of an agent session, writing that
    /// column and nothing else. It is the only writer of `user_label`, which is what makes a rename
    /// survive the hook and detection writes that keep `label` current. `updated_at` is deliberately left
    /// alone for the same reason `setAgentSessionNote` leaves it: it marks when the row entered its current
    /// lifecycle state (clients read it as an alert's event time), and renaming is not a transition.
    /// Returns whether a row matched, so the rename can fail loudly on an unknown id.
    @discardableResult public func setAgentSessionUserLabel(id: String, userLabel: String?) throws -> Bool {
        try withImmediateTransaction {
            try execute(sql: "UPDATE agent_sessions SET user_label = NULLIF(?, '') WHERE id = ?", bindings: [userLabel ?? "", id])
            guard let row = try queryRow(sql: "SELECT changes()"), let changed = Int(row.first ?? "") else { return false }
            return changed > 0
        }
    }

    /// Records the coding-agent kind foreground detection classified for an agent session, writing that
    /// column and nothing else — for the same reason `setAgentSessionNote` writes directly rather than
    /// through `upsertAgentWindow`: `updated_at` tracks when the row entered its current lifecycle state
    /// (clients read it as the alert's event time), and learning which agent is running is not a lifecycle
    /// transition, so bumping it would re-date a stale blocked/finished alert to now. Takes a non-optional
    /// kind because a nil observation must never erase a kind the row already learned — the same rule both
    /// upserts enforce with `COALESCE`.
    public func setAgentSessionDetectedKind(id: String, kind: String) throws {
        try execute(sql: "UPDATE agent_sessions SET detected_agent_kind = ? WHERE id = ?", bindings: [kind, id])
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

    /// Drops every watch edge where `subscriberTerminalSessionID` is the SUBSCRIBER — the outgoing-edge
    /// counterpart to explicit inbound-edge deletion for a terminated agent row.
    /// `agent_subscriptions` carries no foreign key on `subscriber_terminal_session_id` (only on the
    /// watched `agent_session_id`), so when a subscriber terminal's own agent exits, its own watches of
    /// OTHER agents survive the exit unless dropped here explicitly. Used on subscriber-exit paths
    /// (`AgentNotificationEngine.subscriberDidExit`).
    public func deleteAgentSubscriptions(subscriberTerminalSessionID: String) throws {
        try execute(sql: "DELETE FROM agent_subscriptions WHERE subscriber_terminal_session_id = ?", bindings: [subscriberTerminalSessionID])
    }

    /// Drops every INBOUND watch edge to an agent row — the edges where `agentSessionID` is the watched
    /// target. `agent_subscriptions.agent_session_id` is `ON DELETE RESTRICT`, so the row delete no longer
    /// cascades these away; the termination chokepoint (`WorkspaceOrchestrator.finalizeAgentRow`) calls
    /// this to drop them explicitly AFTER notifying the subscribers, so the delete then succeeds. A delete
    /// that skips the chokepoint leaves these edges in place and RESTRICT makes it fail loudly.
    public func deleteAgentSubscriptions(agentSessionID: String) throws {
        try execute(sql: "DELETE FROM agent_subscriptions WHERE agent_session_id = ?", bindings: [agentSessionID])
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

    /// Whether this agent session's CURRENT life has a recorded `exit` lifecycle event — the persisted,
    /// unambiguous fact that its exit was already delivered through the termination chokepoint. Exit
    /// finalization (`WorkspaceOrchestrator.handleAgentExit` → `recordAgentExitStatus`, and the delete
    /// branch) always appends an `event_type = 'exit'` row, and that event survives on a row the
    /// finalization keeps: a configured launcher held at `.done`, or a live-terminal row held at `.exited`.
    /// A live agent sitting `.done` after merely completing a turn has only `done` transition events, never
    /// an `exit` event, so this is what distinguishes a launcher whose exit was already notified from one
    /// that is still running between turns — a distinction `.done` status alone cannot make.
    ///
    /// The fact is scoped to the row's current life: a kept row is REUSED when a fresh agent starts in the
    /// same terminal (the restart-reuse reset in `registerAgentWindow` preserves the row id, and both the
    /// daemon and remote init paths record an `init` event on it), so the previous life's `exit` event must
    /// not mark the reincarnated, live agent as finalized — that would silently suppress the new life's
    /// exited notice on kill/sweep. An `exit` therefore only counts when no `init` event was recorded after
    /// it. Ordering uses `rowid` (insertion order), not the `created_at` strings, so two events appended in
    /// the same second cannot tie.
    public func agentSessionHasRecordedExitEvent(agentSessionID: String) throws -> Bool {
        guard
            let row = try queryRow(
                sql: """
                    SELECT COALESCE(MAX(CASE WHEN event_type = 'exit' THEN rowid END), 0),
                           COALESCE(MAX(CASE WHEN event_type = 'init' THEN rowid END), 0)
                    FROM agent_session_events
                    WHERE agent_session_id = ?
                    """, bindings: [agentSessionID]), row.count >= 2, let lastExitRowID = Int64(row[0]), let lastInitRowID = Int64(row[1])
        else { return false }
        return lastExitRowID > 0 && lastExitRowID > lastInitRowID
    }

    /// Claims the one exit finalization an agent session's current life is allowed, recording its `exit`
    /// lifecycle event AND queueing the already-rendered exited notice for every current subscriber in the
    /// same transaction. Returns whether THIS caller claimed it; a false result means the exit was already
    /// recorded (or the row is gone) and the caller must do nothing further.
    ///
    /// The check and the record are one conditional INSERT inside an immediate transaction, so two
    /// reconcile passes observing the same transition on their own connections cannot both pass a
    /// finalized check and both record the exit — the very read-then-write window that duplicated the
    /// event and, with it, the notification every subscriber received. The condition is exactly the
    /// finalized fact `agentSessionHasRecordedExitEvent` and `agentRowIsFinalized` read: the row must
    /// still exist, must not already be held `exited`, and must have no `exit` event recorded after its
    /// last `init` (which is what scopes the fact to the row's CURRENT life, so a fresh agent reusing the
    /// row is finalizable again). `eventType` binds both the recorded event and the condition, so the
    /// claim is self-consistent for whatever event type the termination reason carries.
    ///
    /// Queueing the notice INSIDE the same transaction is what makes the claim safe to observe. The
    /// recorded `exit` event is the finalized fact every other termination path reads, and a path that
    /// reads it suppresses its own notice and drops the row's `agent_subscriptions` edges. Enqueueing
    /// afterwards would expose a window in which the exit is finalized but nothing is owed to anyone: a
    /// teardown landing in it would delete the edges, and the claimant would then find no subscribers and
    /// deliver nothing at all. Committed together, the delivery obligation exists the instant the
    /// finalized fact does; `agent_pending_notifications` carries no foreign key, so neither the edge
    /// drop nor the row delete can take it back. The queued rows are what the claimant then delivers
    /// (`AgentNotificationEngine.deliverClaimedExitNotices`), and any it cannot deliver yet stay queued
    /// for the subscriber's next idle flush.
    ///
    /// Accepted window: the claim commits before the caller applies the row's disposition (the `done`/delete
    /// that `handleAgentExit` decides), so a daemon death in between leaves a durable `exit` event on a row
    /// that is still listed as active, which both reconcilers then skip as finalized. A recoverable
    /// disposition, or a completion marker committed only after it lands, is what closes it — deliberately
    /// deferred (issue #401) rather than built here, because the window is a few milliseconds wide and the
    /// stranded row is still removable: `agent kill` destroys unconditionally even when it loses the claim.
    public func claimAgentSessionExitEvent(
        agentSessionID: String, eventType: String, source: String, message: String?, createdAt: String, exitedNoticeTransition: String,
        exitedNoticeMessage: String
    ) throws -> Bool {
        try withImmediateTransaction {
            try execute(
                sql: """
                    INSERT INTO agent_session_events(id, agent_session_id, event_type, source, message, created_at)
                    SELECT ?, ?, ?, ?, ?, ?
                    WHERE EXISTS (SELECT 1 FROM agent_sessions WHERE id = ? AND status <> ?)
                      AND COALESCE(
                            (SELECT MAX(CASE WHEN event_type = ? THEN rowid END) FROM agent_session_events WHERE agent_session_id = ?), 0)
                          <= COALESCE(
                            (SELECT MAX(CASE WHEN event_type = 'init' THEN rowid END) FROM agent_session_events WHERE agent_session_id = ?), 0)
                    """,
                bindings: [
                    UUID().uuidString, agentSessionID, eventType, source, message ?? "", createdAt, agentSessionID, AgentWindowStatus.exited.rawValue,
                    eventType, agentSessionID, agentSessionID,
                ])
            // Read immediately after the conditional INSERT: `changes()` reports the most recently
            // completed write, and the enqueue below would otherwise overwrite the answer.
            guard let row = try queryRow(sql: "SELECT changes()"), let changed = Int(row.first ?? ""), changed > 0 else { return false }
            for subscription in try agentSubscriptions(agentSessionID: agentSessionID) {
                try upsertPendingAgentNotification(
                    subscriberTerminalSessionID: subscription.subscriberTerminalSessionID, agentSessionID: agentSessionID,
                    transition: exitedNoticeTransition, message: exitedNoticeMessage, createdAt: createdAt)
            }
            return true
        }
    }

    private func decodeAgentSubscription(row: [String]) -> AgentSubscriptionRecord? {
        guard row.count >= 3 else { return nil }
        return AgentSubscriptionRecord(subscriberTerminalSessionID: row[0], agentSessionID: row[1], createdAt: row[2])
    }

    // MARK: - Cross-device watch edges (agent_remote_subscriptions)

    public func insertAgentRemoteSubscription(subscriberTerminalSessionID: String, deviceID: String, agentSessionID: String, createdAt: String) throws
    {
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
        try execute(sql: "DELETE FROM agent_remote_subscriptions WHERE device_id = ? AND agent_session_id = ?", bindings: [deviceID, agentSessionID])
    }

    /// Drops every cross-device watch edge where `subscriberTerminalSessionID` is the SUBSCRIBER — the
    /// remote counterpart of `deleteAgentSubscriptions(subscriberTerminalSessionID:)`, used on the same
    /// subscriber-exit path so a local terminal that just exited never keeps a paired device's overview
    /// stream open for edges that can never deliver again. `agent_remote_subscriptions` has no foreign
    /// key at all (the watched agent lives on another device's database), so nothing else drops these.
    public func deleteAgentRemoteSubscriptions(subscriberTerminalSessionID: String) throws {
        try execute(sql: "DELETE FROM agent_remote_subscriptions WHERE subscriber_terminal_session_id = ?", bindings: [subscriberTerminalSessionID])
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

    // MARK: - Remote watch baselines (agent_remote_watch_baselines)

    /// Replaces one device's persisted watch baseline with `baseline` (watched child terminal session
    /// id → last-seen listing row) in a single transaction, so a reader never observes a half-replaced
    /// device. The watch service mirrors its in-memory baseline here on every change, which is what
    /// lets a restarted daemon diff its first listing against the state the previous run had reported.
    public func replaceAgentRemoteWatchBaseline(deviceID: String, baseline: [String: SpacesDeviceAgentSessionRow]) throws {
        let encoder = JSONEncoder()
        let encoded = try baseline.map { (agentSessionID, row) in (agentSessionID, String(decoding: try encoder.encode(row), as: UTF8.self)) }
        try withTransaction {
            try execute(sql: "DELETE FROM agent_remote_watch_baselines WHERE device_id = ?", bindings: [deviceID])
            for (agentSessionID, rowJSON) in encoded {
                try execute(
                    sql: "INSERT INTO agent_remote_watch_baselines(device_id, agent_session_id, row_json) VALUES (?, ?, ?)",
                    bindings: [deviceID, agentSessionID, rowJSON])
            }
        }
    }

    /// Every device's persisted watch baseline, in the shape the watch service holds in memory. A row
    /// whose JSON no longer decodes is skipped — the watch then seeds that child silently, exactly as
    /// if it had never been observed.
    public func agentRemoteWatchBaselines() throws -> [String: [String: SpacesDeviceAgentSessionRow]] {
        let decoder = JSONDecoder()
        var baselines: [String: [String: SpacesDeviceAgentSessionRow]] = [:]
        for row in try queryRows(sql: "SELECT device_id, agent_session_id, row_json FROM agent_remote_watch_baselines") {
            guard row.count >= 3, let decoded = try? decoder.decode(SpacesDeviceAgentSessionRow.self, from: Data(row[2].utf8)) else { continue }
            baselines[row[0], default: [:]][row[1]] = decoded
        }
        return baselines
    }

    /// Retires one device's persisted watch baseline — the device's last watch edge was removed or the
    /// device unpaired, so a later watch of it must start fresh instead of diffing against dead state.
    public func deleteAgentRemoteWatchBaseline(deviceID: String) throws {
        try execute(sql: "DELETE FROM agent_remote_watch_baselines WHERE device_id = ?", bindings: [deviceID])
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

    /// Every agent row (all providers, all workspaces) whose `terminal_session_id` references a given
    /// terminal session. The session-retention release path (`WorkspaceOrchestrator
    /// .releaseEndedTerminalSessionReferences`) uses this to find the product rows to finalize when a
    /// long-ended terminal session is being aged out — deliberately unfiltered by provider, since every
    /// row that pins the session must be released, not just the Spaces-native ones. Keyed on
    /// `terminal_session_id` (not the joined `runtime_targets.tracking_id`) so it matches exactly the
    /// column `terminalSessionIsReferencedByProduct` tests as the agent-side reference.
    public func agentWindowsByTerminalSession(terminalSessionID: String) throws -> [AgentWindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT
                  \(Self.agentWindowColumns)
                FROM agent_sessions
                LEFT JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                WHERE agent_sessions.terminal_session_id = ?
                ORDER BY agent_sessions.created_at
                """, bindings: [terminalSessionID])
        return rows.compactMap { decodeAgentWindow(row: $0) }
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

    /// Every subscriber's pending notification for ONE watched agent, in enqueue order — the rows the
    /// exit claim (`claimAgentSessionExitEvent`) just wrote. The claimant reads them straight back to
    /// deliver the ones whose subscriber is idle; it keys on the agent rather than the subscriber so it
    /// touches only the notice it owes, leaving other children's held lines for their own idle flush.
    public func pendingAgentNotifications(agentSessionID: String) throws -> [AgentPendingNotificationRecord] {
        try queryRows(
            sql: """
                SELECT id, subscriber_terminal_session_id, agent_session_id, message, created_at
                FROM agent_pending_notifications
                WHERE agent_session_id = ?
                ORDER BY created_at, rowid
                """, bindings: [agentSessionID]
        ).compactMap(decodePendingAgentNotification)
    }

    /// Takes one queued notification out of the queue for delivery, returning it only to the caller that
    /// removed it. A nil result means another drain already took the row and this caller owes nothing.
    ///
    /// THE CONSUME INVARIANT, shared by every path that drains this queue: a row is READ AND DELETED in
    /// one `BEGIN IMMEDIATE` transaction, and only then delivered. `BEGIN IMMEDIATE` takes the database's
    /// write lock before the SELECT runs, so two drains on separate connections — the exit claimant's
    /// `deliverClaimedExitNotices`, a subscriber's idle flush, and the MCP piggyback drain all run on
    /// their own — cannot both observe the same row: the second one blocks, then finds it gone. Reading
    /// first and deleting after delivery would reopen exactly the duplicate the exit claim was built to
    /// close, one layer down, since the delivery in between is a terminal round-trip.
    ///
    /// Consuming BEFORE delivering rather than after is deliberate. A delivery that throws means one
    /// thing here — the subscriber terminal is gone — and every caller answers it with
    /// `subscriberDidExit`, which discards that subscriber's whole queue anyway, so the consumed row was
    /// never going to be delivered to anyone. What the ordering costs is a block lost if the process dies
    /// between the commit and the send; what it buys is that a block can never be injected twice, which
    /// would make an orchestrating agent act twice on one child exit. At-most-once is the deliberate
    /// choice for a notice whose whole purpose is to prompt an action.
    public func claimPendingAgentNotification(id: String) throws -> AgentPendingNotificationRecord? {
        try withImmediateTransaction {
            guard
                let row = try queryRow(
                    sql: """
                        SELECT id, subscriber_terminal_session_id, agent_session_id, message, created_at
                        FROM agent_pending_notifications
                        WHERE id = ?
                        """, bindings: [id]), let record = decodePendingAgentNotification(row: row)
            else { return nil }
            try execute(sql: "DELETE FROM agent_pending_notifications WHERE id = ?", bindings: [id])
            return record
        }
    }

    /// Atomically drains a subscriber terminal's held notifications: reads its pending rows in `created_at`
    /// order and deletes them in one `BEGIN IMMEDIATE` transaction, returning the rendered messages. This is
    /// the MCP piggyback path — a busy orchestrator (whose idle-flush has therefore not run) picks its
    /// watched children's held events up on the response of its next tool call. It is the whole-queue form
    /// of the consume invariant on `claimPendingAgentNotification`: the write lock is held across the read
    /// and the delete, so the rows this returns are rows no other drain can also return, and the caller
    /// owns delivering them.
    public func consumePendingAgentNotifications(subscriberTerminalSessionID: String) throws -> [String] {
        try withImmediateTransaction {
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
        guard row.count >= 19 else { return nil }
        guard let provider = AgentProvider(rawValue: row[2]) else { return nil }
        let terminalSessionID = row[9].isEmpty ? nil : row[9]
        let status = AgentWindowStatus(rawValue: row[13]) ?? .idle
        let resolvedTrackingID = row[8].isEmpty ? row[9] : row[8]
        let terminalTarget = decodeTerminalTarget(
            runtimeTargetID: row[4], app: row[5].isEmpty && terminalSessionID != nil ? TerminalHost.spaces.appName : row[5], name: row[6],
            detail: row[7], trackingID: resolvedTrackingID)
        return AgentWindowRecord(
            id: row[0], workspaceID: row[1], provider: provider, label: row[3].isEmpty ? nil : row[3], userLabel: row[18].isEmpty ? nil : row[18],
            runtimeTargetID: row[4].isEmpty ? nil : row[4], terminalTarget: terminalTarget, sessionKey: row[10].isEmpty ? nil : row[10],
            claimedLauncherID: row[11].isEmpty ? nil : row[11], claimedLauncherName: row[12].isEmpty ? nil : row[12], status: status,
            note: row[14].isEmpty ? nil : row[14], detectedAgentKind: row[17].isEmpty ? nil : row[17], createdAt: row[15], updatedAt: row[16])
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
