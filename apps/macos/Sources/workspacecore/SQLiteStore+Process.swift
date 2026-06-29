import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
    public func upsert(runningProcess: RunningProcessRecord) throws {
        let runtimeTargetID =
            try runningProcess.runtimeTargetID
            ?? matchingRuntimeTargetID(workspaceID: runningProcess.workspaceID, trackingID: runningProcess.terminalTrackingID)
        let resolvedRuntimeTargetID = try ensureRuntimeTargetForRunningProcess(runningProcess, runtimeTargetID: runtimeTargetID)
        let terminalSessionID = spacesTerminalSessionID(
            terminalApp: runningProcess.terminalApp, terminalTrackingID: runningProcess.terminalTrackingID)
        try execute(
            sql: """
                    INSERT INTO running_processes(
                      id, workspace_id, template_id, template_name, command, runtime_target_id, terminal_session_id, pid, status, log_path, last_output_at, started_at, exited_at
                    )
                    VALUES (?, ?, NULLIF(?, ''), ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      template_id = COALESCE(excluded.template_id, running_processes.template_id),
                      template_name = excluded.template_name,
                      command = excluded.command,
                      runtime_target_id = excluded.runtime_target_id,
                      terminal_session_id = COALESCE(excluded.terminal_session_id, running_processes.terminal_session_id),
                      pid = excluded.pid,
                      status = excluded.status,
                      log_path = excluded.log_path,
                      last_output_at = excluded.last_output_at,
                      started_at = excluded.started_at,
                      exited_at = excluded.exited_at
                """,
            bindings: [
                runningProcess.id, runningProcess.workspaceID, runningProcess.templateID ?? "", runningProcess.templateName, runningProcess.command,
                resolvedRuntimeTargetID ?? "", terminalSessionID ?? "", runningProcess.pid.map(String.init) ?? "", runningProcess.status.rawValue,
                runningProcess.logPath ?? "", runningProcess.lastOutputAt ?? "", runningProcess.startedAt ?? "", runningProcess.exitedAt ?? "",
            ])
    }

    public func runningProcesses(workspaceID: String) throws -> [RunningProcessRecord] {
        let rows = try queryRows(
            sql: """
                SELECT
                  rp.id,
                  rp.workspace_id,
                  COALESCE(rp.template_id, ''),
                  rp.template_name,
                  rp.command,
                  COALESCE(rp.runtime_target_id, ''),
                  COALESCE(rt.app, ''),
                  COALESCE(rt.name, ''),
                  COALESCE(rt.detail, ''),
                  COALESCE(rt.tracking_id, ''),
                  COALESCE(rp.terminal_session_id, ''),
                  COALESCE(rp.pid, ''),
                  rp.status,
                  COALESCE(rp.log_path, ''),
                  COALESCE(rp.last_output_at, ''),
                  COALESCE(rp.started_at, ''),
                  COALESCE(rp.exited_at, '')
                FROM running_processes rp
                LEFT JOIN runtime_targets rt ON rt.id = rp.runtime_target_id
                WHERE rp.workspace_id = ?
                ORDER BY started_at
                """, bindings: [workspaceID])
        return rows.compactMap { decodeRunningProcess(row: $0) }
    }

    public func deleteRunningProcess(id: String) throws {
        try withImmediateTransaction { try execute(sql: "DELETE FROM running_processes WHERE id = ?", bindings: [id]) }
    }

    public func deleteRunningProcesses(workspaceID: String) throws {
        try execute(sql: "DELETE FROM running_processes WHERE workspace_id = ?", bindings: [workspaceID])
    }

    func decodeRunningProcess(row: [String]) -> RunningProcessRecord? {
        guard row.count >= 17 else { return nil }
        let terminalSessionID = row[10].isEmpty ? nil : row[10]
        let terminalApp = row[6].isEmpty && terminalSessionID != nil ? TerminalHost.spaces.appName : row[6]
        let resolvedTrackingID = row[9].isEmpty ? row[10] : row[9]
        // The captured desktop window belongs to the linked runtime target (row[5]); a process
        // detached from its target has none, so its window ID resolves to nil.
        let terminalTarget = decodeTerminalTarget(
            runtimeTargetID: row[5], app: terminalApp, name: row[7], detail: row[8],
            windowID: overlaidWindowID(workspaceID: row[1], runtimeTargetID: row[5].isEmpty ? nil : row[5]), trackingID: resolvedTrackingID)
        return RunningProcessRecord(
            id: row[0], workspaceID: row[1], templateID: row[2].isEmpty ? nil : row[2], templateName: row[3], command: row[4],
            runtimeTargetID: row[5].isEmpty ? nil : row[5], terminalApp: terminalApp.isEmpty ? nil : terminalApp, terminalTarget: terminalTarget,
            pid: Int(row[11]), status: RunningProcessState(rawValue: row[12]) ?? .running, logPath: row[13].isEmpty ? nil : row[13],
            lastOutputAt: row[14].isEmpty ? nil : row[14], startedAt: row[15].isEmpty ? nil : row[15], exitedAt: row[16].isEmpty ? nil : row[16])
    }

    func spacesTerminalSessionID(terminalApp: String?, terminalTrackingID: String?) -> String? {
        guard terminalApp == TerminalHost.spaces.appName, let terminalTrackingID, !terminalTrackingID.isEmpty else { return nil }
        return terminalTrackingID
    }

    func ensureRuntimeTargetForRunningProcess(_ process: RunningProcessRecord, runtimeTargetID: String?) throws -> String? {
        guard let terminalTarget = process.terminalTarget else { return runtimeTargetID }
        let targetID = runtimeTargetID ?? terminalTarget.runtimeTargetID ?? process.id
        let existingWindows = try windows(workspaceID: process.workspaceID)
        let existingWindow = existingWindows.first(where: { $0.id == targetID })
        let now = ISO8601DateFormatter().string(from: Date())
        try upsert(
            window: WindowRecord(
                id: targetID, workspaceID: process.workspaceID, app: process.terminalApp ?? TerminalHost.spaces.appName, name: process.templateName,
                detail: process.command, targetURL: nil, windowID: terminalTarget.windowID, terminalTrackingID: terminalTarget.trackingID,
                terminalNativeID: terminalTarget.trackingID, role: "terminal",
                orderIndex: existingWindow?.orderIndex ?? nextRuntimeTargetOrderIndex(existing: existingWindows, role: "terminal", orderOffset: 100),
                lastSeenAt: now))
        return targetID
    }
}
