import Foundation

extension SQLiteStore {
    // MARK: - Epoch helpers

    /// Timestamps in the automation tables are REAL epoch seconds. Bindings are text-only, so a Date is
    /// written as its epoch string (SQLite's REAL affinity converts it) and read back through `Double`.
    private static func epochString(_ date: Date) -> String { String(date.timeIntervalSince1970) }
    private static func date(fromEpoch text: String) -> Date? {
        guard !text.isEmpty, let seconds = Double(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Automations CRUD

    private static let automationColumns = """
        id, name, enabled, trigger_kind, cron_expression, kind, script, agent_command, agent_prompt, workspace_id, working_directory,
        timeout_seconds, concurrency_policy, missed_run_policy, next_fire_time, created_at, updated_at
        """

    public func upsertAutomation(_ automation: Automation) throws {
        try execute(
            sql: """
                INSERT INTO automations(
                  id, name, enabled, trigger_kind, cron_expression, kind, script, agent_command, agent_prompt, workspace_id, working_directory,
                  timeout_seconds, concurrency_policy, missed_run_policy, next_fire_time, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?, NULLIF(?, ''), ?, ?, NULLIF(?, ''), ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  enabled = excluded.enabled,
                  trigger_kind = excluded.trigger_kind,
                  cron_expression = excluded.cron_expression,
                  kind = excluded.kind,
                  script = excluded.script,
                  agent_command = excluded.agent_command,
                  agent_prompt = excluded.agent_prompt,
                  workspace_id = excluded.workspace_id,
                  working_directory = excluded.working_directory,
                  timeout_seconds = excluded.timeout_seconds,
                  concurrency_policy = excluded.concurrency_policy,
                  missed_run_policy = excluded.missed_run_policy,
                  next_fire_time = excluded.next_fire_time,
                  updated_at = excluded.updated_at
                """,
            bindings: [
                automation.id, automation.name, automation.enabled ? "1" : "0", automation.triggerKind.rawValue, automation.cronExpression ?? "",
                automation.kind.rawValue, automation.script, automation.agentCommand ?? "", automation.agentPrompt ?? "",
                automation.workspaceID ?? "", automation.workingDirectory, automation.timeoutSeconds.map(String.init) ?? "",
                automation.concurrencyPolicy.rawValue, automation.missedRunPolicy.rawValue,
                automation.nextFireTime.map(Self.epochString) ?? "", Self.epochString(automation.createdAt), Self.epochString(automation.updatedAt),
            ])
    }

    public func automation(id: String) throws -> Automation? {
        guard let row = try queryRow(sql: "SELECT \(Self.automationColumns) FROM automations WHERE id = ?", bindings: [id]) else { return nil }
        return Self.decodeAutomation(row: row)
    }

    public func automations() throws -> [Automation] {
        try queryRows(sql: "SELECT \(Self.automationColumns) FROM automations ORDER BY created_at, id").compactMap(Self.decodeAutomation)
    }

    public func enabledCronAutomations() throws -> [Automation] {
        try queryRows(
            sql: "SELECT \(Self.automationColumns) FROM automations WHERE enabled = 1 AND trigger_kind = 'cron' ORDER BY created_at, id"
        ).compactMap(Self.decodeAutomation)
    }

    /// Persists a cron automation's next-due time (the missed-run anchor a restarted daemon reads). Touches
    /// only `next_fire_time`, never `updated_at`, so the scheduler advancing the anchor is not mistaken for a
    /// user edit.
    public func setAutomationNextFireTime(id: String, nextFireTime: Date?) throws {
        try execute(
            sql: "UPDATE automations SET next_fire_time = NULLIF(?, '') WHERE id = ?",
            bindings: [nextFireTime.map(Self.epochString) ?? "", id])
    }

    public func deleteAutomation(id: String) throws { try execute(sql: "DELETE FROM automations WHERE id = ?", bindings: [id]) }

    private static func decodeAutomation(row: [String]) -> Automation? {
        guard row.count >= 17 else { return nil }
        guard let triggerKind = AutomationTriggerKind(rawValue: row[3]) else { return nil }
        guard let kind = AutomationKind(rawValue: row[5]) else { return nil }
        guard let concurrencyPolicy = AutomationConcurrencyPolicy(rawValue: row[12]) else { return nil }
        guard let missedRunPolicy = AutomationMissedRunPolicy(rawValue: row[13]) else { return nil }
        guard let createdAt = date(fromEpoch: row[15]), let updatedAt = date(fromEpoch: row[16]) else { return nil }
        return Automation(
            id: row[0], name: row[1], enabled: row[2] == "1", triggerKind: triggerKind, cronExpression: row[4].isEmpty ? nil : row[4], kind: kind,
            script: row[6], agentCommand: row[7].isEmpty ? nil : row[7], agentPrompt: row[8].isEmpty ? nil : row[8],
            workspaceID: row[9].isEmpty ? nil : row[9], workingDirectory: row[10], timeoutSeconds: row[11].isEmpty ? nil : Int(row[11]),
            concurrencyPolicy: concurrencyPolicy, missedRunPolicy: missedRunPolicy, nextFireTime: date(fromEpoch: row[14]), createdAt: createdAt,
            updatedAt: updatedAt)
    }

    // MARK: - Automation runs

    private static let automationRunColumns = """
        id, automation_id, kind, status, skip_reason, trigger_kind, exit_code, terminal_session_id, started_at, ended_at, created_at,
        prompt_delivered_at
        """

    public func insertAutomationRun(_ run: AutomationRun) throws {
        try execute(
            sql: """
                INSERT INTO automation_runs(
                  id, automation_id, kind, status, skip_reason, trigger_kind, exit_code, terminal_session_id, started_at, ended_at, created_at,
                  prompt_delivered_at
                )
                VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?, NULLIF(?, ''))
                """,
            bindings: [
                run.id, run.automationID, run.kind.rawValue, run.status.rawValue, run.skipReason?.rawValue ?? "", run.trigger.rawValue,
                run.exitCode.map(String.init) ?? "", run.terminalSessionID ?? "", run.startedAt.map(Self.epochString) ?? "",
                run.endedAt.map(Self.epochString) ?? "", Self.epochString(run.createdAt), run.promptDeliveredAt.map(Self.epochString) ?? "",
            ])
    }

    /// Updates the mutable fields of a run row. Every field is written from the passed value, so the caller
    /// composes the full desired state (e.g. terminal state + exit code + ended_at) in one update.
    public func updateAutomationRun(
        id: String, status: AutomationRunStatus, skipReason: AutomationRunSkipReason?, exitCode: Int?, terminalSessionID: String?,
        startedAt: Date?, endedAt: Date?, promptDeliveredAt: Date?
    ) throws {
        try execute(
            sql: """
                UPDATE automation_runs
                SET status = ?, skip_reason = NULLIF(?, ''), exit_code = NULLIF(?, ''), terminal_session_id = NULLIF(?, ''),
                    started_at = NULLIF(?, ''), ended_at = NULLIF(?, ''), prompt_delivered_at = NULLIF(?, '')
                WHERE id = ?
                """,
            bindings: [
                status.rawValue, skipReason?.rawValue ?? "", exitCode.map(String.init) ?? "", terminalSessionID ?? "",
                startedAt.map(Self.epochString) ?? "", endedAt.map(Self.epochString) ?? "", promptDeliveredAt.map(Self.epochString) ?? "", id,
            ])
    }

    public func automationRun(id: String) throws -> AutomationRun? {
        guard let row = try queryRow(sql: "SELECT \(Self.automationRunColumns) FROM automation_runs WHERE id = ?", bindings: [id]) else {
            return nil
        }
        return Self.decodeAutomationRun(row: row)
    }

    /// Runs for one automation, newest first.
    public func automationRuns(automationID: String) throws -> [AutomationRun] {
        try queryRows(
            sql: "SELECT \(Self.automationRunColumns) FROM automation_runs WHERE automation_id = ? ORDER BY created_at DESC, id DESC",
            bindings: [automationID]
        ).compactMap(Self.decodeAutomationRun)
    }

    /// Runs across every automation, newest first — the unfiltered runs listing.
    public func allAutomationRuns() throws -> [AutomationRun] {
        try queryRows(
            sql: "SELECT \(Self.automationRunColumns) FROM automation_runs ORDER BY created_at DESC, id DESC"
        ).compactMap(Self.decodeAutomationRun)
    }

    /// The newest terminal-status runs across every automation, capped at `limit` — the overview's recent-run
    /// window. Only terminal runs count against the window so a burst of active (queued/running) runs can
    /// never crowd out completed history; the overview unions these with the active runs separately. The
    /// status filter is derived from `AutomationRunStatus.isTerminal` so it can't drift from the enum.
    public func terminalAutomationRuns(limit: Int) throws -> [AutomationRun] {
        let terminalStatuses = AutomationRunStatus.allCases.filter(\.isTerminal).map { "'\($0.rawValue)'" }.joined(separator: ", ")
        return try queryRows(
            sql: """
                SELECT \(Self.automationRunColumns) FROM automation_runs
                WHERE status IN (\(terminalStatuses))
                ORDER BY created_at DESC, id DESC
                LIMIT \(limit)
                """
        ).compactMap(Self.decodeAutomationRun)
    }

    /// Each automation's single newest terminal-status run (one row per automation), newest first. The
    /// overview unions this with the recent-run window so every automation's last-run status stays accurate
    /// even when a chatty automation's runs fill the global recent window and evict the quieter ones. The
    /// status filter is derived from `AutomationRunStatus.isTerminal` (same pattern as `terminalAutomationRuns`)
    /// so it can't drift from the enum; ties on `created_at` break on `id` for a deterministic single winner.
    public func latestTerminalAutomationRunPerAutomation() throws -> [AutomationRun] {
        let terminalStatuses = AutomationRunStatus.allCases.filter(\.isTerminal).map { "'\($0.rawValue)'" }.joined(separator: ", ")
        return try queryRows(
            sql: """
                SELECT \(Self.automationRunColumns) FROM automation_runs a
                WHERE a.status IN (\(terminalStatuses))
                  AND NOT EXISTS (
                    SELECT 1 FROM automation_runs b
                    WHERE b.automation_id = a.automation_id AND b.status IN (\(terminalStatuses))
                      AND (b.created_at > a.created_at OR (b.created_at = a.created_at AND b.id > a.id))
                  )
                ORDER BY a.created_at DESC, a.id DESC
                """
        ).compactMap(Self.decodeAutomationRun)
    }

    /// Runs across every automation that are still active (queued or running), oldest first — the overview
    /// always includes these regardless of the recent-run window so a live run is never dropped.
    public func activeAutomationRuns() throws -> [AutomationRun] {
        try queryRows(
            sql: "SELECT \(Self.automationRunColumns) FROM automation_runs WHERE status IN ('queued', 'running') ORDER BY created_at, id"
        ).compactMap(Self.decodeAutomationRun)
    }

    /// Runs of one automation in a non-terminal state (queued or running), oldest first.
    public func activeAutomationRuns(automationID: String) throws -> [AutomationRun] {
        try queryRows(
            sql: """
                SELECT \(Self.automationRunColumns) FROM automation_runs
                WHERE automation_id = ? AND status IN ('queued', 'running')
                ORDER BY created_at, id
                """, bindings: [automationID]
        ).compactMap(Self.decodeAutomationRun)
    }

    /// Every run across all automations that is currently `running` — the executor's poll set.
    public func runningAutomationRuns() throws -> [AutomationRun] {
        try queryRows(
            sql: "SELECT \(Self.automationRunColumns) FROM automation_runs WHERE status = 'running' ORDER BY created_at, id"
        ).compactMap(Self.decodeAutomationRun)
    }

    /// The single pending queued run for one automation (there is at most one under the queue policy),
    /// oldest first for determinism.
    public func queuedAutomationRun(automationID: String) throws -> AutomationRun? {
        try queryRows(
            sql: """
                SELECT \(Self.automationRunColumns) FROM automation_runs
                WHERE automation_id = ? AND status = 'queued'
                ORDER BY created_at, id
                LIMIT 1
                """, bindings: [automationID]
        ).compactMap(Self.decodeAutomationRun).first
    }

    public func deleteAutomationRun(id: String) throws { try execute(sql: "DELETE FROM automation_runs WHERE id = ?", bindings: [id]) }

    /// The ids of terminal runs of one automation beyond the newest `keeping`, oldest first — the retention
    /// prune set. Non-terminal runs (queued/running) never appear, so a live run is never pruned.
    public func prunableAutomationRunIDs(automationID: String, keeping: Int) throws -> [String] {
        try queryRows(
            sql: """
                SELECT id FROM automation_runs
                WHERE automation_id = ? AND status NOT IN ('queued', 'running')
                ORDER BY created_at DESC, id DESC
                LIMIT -1 OFFSET ?
                """, bindings: [automationID, String(keeping)]
        ).compactMap { $0.first }
    }

    private static func decodeAutomationRun(row: [String]) -> AutomationRun? {
        guard row.count >= 12 else { return nil }
        guard let kind = AutomationKind(rawValue: row[2]) else { return nil }
        guard let status = AutomationRunStatus(rawValue: row[3]) else { return nil }
        guard let trigger = AutomationRunTrigger(rawValue: row[5]) else { return nil }
        guard let createdAt = date(fromEpoch: row[10]) else { return nil }
        return AutomationRun(
            id: row[0], automationID: row[1], kind: kind, status: status, skipReason: row[4].isEmpty ? nil : AutomationRunSkipReason(rawValue: row[4]),
            trigger: trigger, exitCode: row[6].isEmpty ? nil : Int(row[6]), terminalSessionID: row[7].isEmpty ? nil : row[7],
            startedAt: date(fromEpoch: row[8]), endedAt: date(fromEpoch: row[9]), createdAt: createdAt, promptDeliveredAt: date(fromEpoch: row[11]))
    }

    // MARK: - Attributed terminal sessions

    /// The terminal sessions stamped with a given automation run id, in creation order. Includes the run's
    /// own `.automation` session and every coding-agent session spawned during the run.
    public func terminalSessionIDs(automationRunID: String) throws -> [String] {
        try queryRows(
            sql: "SELECT session_id FROM terminal_sessions WHERE automation_run_id = ? ORDER BY created_at, session_id",
            bindings: [automationRunID]
        ).compactMap { $0.first }
    }

    /// Deletes a terminal session and every companion row keyed by its session id — used to remove an ended
    /// automation-attributed session from the product once its artifacts have been captured. The session row
    /// and its runtime state, client, attachment, and remote-session-state rows are removed in one
    /// transaction so a deleted session leaves no orphaned persistence behind (none of these tables declares a
    /// foreign-key cascade onto `terminal_sessions`, so each must be deleted explicitly).
    public func deleteTerminalSession(sessionID: String) throws {
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM terminal_sessions WHERE session_id = ?", bindings: [sessionID])
            try execute(sql: "DELETE FROM terminal_runtime_states WHERE session_id = ?", bindings: [sessionID])
            try execute(sql: "DELETE FROM terminal_clients WHERE session_id = ?", bindings: [sessionID])
            try execute(sql: "DELETE FROM terminal_attachments WHERE session_id = ?", bindings: [sessionID])
            try execute(sql: "DELETE FROM terminal_remote_session_states WHERE session_id = ?", bindings: [sessionID])
        }
    }
}
