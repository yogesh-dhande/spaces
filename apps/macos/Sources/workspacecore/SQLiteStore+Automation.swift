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
        id, name, enabled, trigger_kind, cron_expression, command, working_directory, timeout_seconds, concurrency_policy, missed_run_policy,
        next_fire_time, created_at, updated_at
        """

    public func upsertAutomation(_ automation: Automation) throws {
        try execute(
            sql: """
                INSERT INTO automations(
                  id, name, enabled, trigger_kind, cron_expression, command, working_directory, timeout_seconds, concurrency_policy,
                  missed_run_policy, next_fire_time, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, ?, NULLIF(?, ''), ?, ?, NULLIF(?, ''), ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  enabled = excluded.enabled,
                  trigger_kind = excluded.trigger_kind,
                  cron_expression = excluded.cron_expression,
                  command = excluded.command,
                  working_directory = excluded.working_directory,
                  timeout_seconds = excluded.timeout_seconds,
                  concurrency_policy = excluded.concurrency_policy,
                  missed_run_policy = excluded.missed_run_policy,
                  next_fire_time = excluded.next_fire_time,
                  updated_at = excluded.updated_at
                """,
            bindings: [
                automation.id, automation.name, automation.enabled ? "1" : "0", automation.triggerKind.rawValue, automation.cronExpression ?? "",
                automation.command, automation.workingDirectory, automation.timeoutSeconds.map(String.init) ?? "",
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
        guard row.count >= 13 else { return nil }
        guard let triggerKind = AutomationTriggerKind(rawValue: row[3]) else { return nil }
        guard let concurrencyPolicy = AutomationConcurrencyPolicy(rawValue: row[8]) else { return nil }
        guard let missedRunPolicy = AutomationMissedRunPolicy(rawValue: row[9]) else { return nil }
        guard let createdAt = date(fromEpoch: row[11]), let updatedAt = date(fromEpoch: row[12]) else { return nil }
        return Automation(
            id: row[0], name: row[1], enabled: row[2] == "1", triggerKind: triggerKind, cronExpression: row[4].isEmpty ? nil : row[4],
            command: row[5], workingDirectory: row[6], timeoutSeconds: row[7].isEmpty ? nil : Int(row[7]), concurrencyPolicy: concurrencyPolicy,
            missedRunPolicy: missedRunPolicy, nextFireTime: date(fromEpoch: row[10]), createdAt: createdAt, updatedAt: updatedAt)
    }

    // MARK: - Automation runs

    private static let automationRunColumns = """
        id, automation_id, status, skip_reason, trigger_kind, exit_code, terminal_session_id, started_at, ended_at, created_at
        """

    public func insertAutomationRun(_ run: AutomationRun) throws {
        try execute(
            sql: """
                INSERT INTO automation_runs(
                  id, automation_id, status, skip_reason, trigger_kind, exit_code, terminal_session_id, started_at, ended_at, created_at
                )
                VALUES (?, ?, ?, NULLIF(?, ''), ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?)
                """,
            bindings: [
                run.id, run.automationID, run.status.rawValue, run.skipReason?.rawValue ?? "", run.trigger.rawValue,
                run.exitCode.map(String.init) ?? "", run.terminalSessionID ?? "", run.startedAt.map(Self.epochString) ?? "",
                run.endedAt.map(Self.epochString) ?? "", Self.epochString(run.createdAt),
            ])
    }

    /// Updates the mutable fields of a run row. Every field is written from the passed value, so the caller
    /// composes the full desired state (e.g. terminal state + exit code + ended_at) in one update.
    public func updateAutomationRun(
        id: String, status: AutomationRunStatus, skipReason: AutomationRunSkipReason?, exitCode: Int?, terminalSessionID: String?,
        startedAt: Date?, endedAt: Date?
    ) throws {
        try execute(
            sql: """
                UPDATE automation_runs
                SET status = ?, skip_reason = NULLIF(?, ''), exit_code = NULLIF(?, ''), terminal_session_id = NULLIF(?, ''),
                    started_at = NULLIF(?, ''), ended_at = NULLIF(?, '')
                WHERE id = ?
                """,
            bindings: [
                status.rawValue, skipReason?.rawValue ?? "", exitCode.map(String.init) ?? "", terminalSessionID ?? "",
                startedAt.map(Self.epochString) ?? "", endedAt.map(Self.epochString) ?? "", id,
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
        guard row.count >= 10 else { return nil }
        guard let status = AutomationRunStatus(rawValue: row[2]) else { return nil }
        guard let trigger = AutomationRunTrigger(rawValue: row[4]) else { return nil }
        guard let createdAt = date(fromEpoch: row[9]) else { return nil }
        return AutomationRun(
            id: row[0], automationID: row[1], status: status, skipReason: row[3].isEmpty ? nil : AutomationRunSkipReason(rawValue: row[3]),
            trigger: trigger, exitCode: row[5].isEmpty ? nil : Int(row[5]), terminalSessionID: row[6].isEmpty ? nil : row[6],
            startedAt: date(fromEpoch: row[7]), endedAt: date(fromEpoch: row[8]), createdAt: createdAt)
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

    /// Deletes the `terminal_sessions` row for a session id — used to remove an ended automation-attributed
    /// session from the product once its artifacts have been captured.
    public func deleteTerminalSession(sessionID: String) throws {
        try execute(sql: "DELETE FROM terminal_sessions WHERE session_id = ?", bindings: [sessionID])
    }
}
