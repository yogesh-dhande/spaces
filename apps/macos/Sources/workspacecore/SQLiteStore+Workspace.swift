import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
    public func upsert(workspace: WorkspaceRecord) throws {
        try withImmediateTransaction {
            try execute(
                sql: """
                    INSERT INTO workspaces(id, project_id, dir, runtime_path, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, notes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      dir = excluded.dir,
                      runtime_path = excluded.runtime_path,
                      dirname = excluded.dirname,
                      branch = excluded.branch,
                      base_branch = excluded.base_branch,
                      is_default = excluded.is_default,
                      is_archived = excluded.is_archived,
                      is_hidden = excluded.is_hidden,
                      is_running = excluded.is_running,
                      last_launched_at = excluded.last_launched_at,
                      notes = excluded.notes
                    """,
                bindings: [
                    workspace.id, workspace.projectID, workspace.dir, workspace.runtimePath, workspace.dirname ?? "", workspace.branch ?? "",
                    workspace.baseBranch ?? "", workspace.isDefault ? "1" : "0", workspace.isArchived ? "1" : "0", workspace.isHidden ? "1" : "0",
                    workspace.isRunning ? "1" : "0", workspace.lastLaunchedAt ?? "", workspace.notes ?? "",
                ])
            try execute(sql: "DELETE FROM ignored_worktrees WHERE worktree_dir = ?", bindings: [workspace.dir])
        }
    }

    public func workspace(id: String) throws -> WorkspaceRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, project_id, dir, runtime_path, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, notes
                    FROM workspaces WHERE id = ?
                    """, bindings: [id])
        else { return nil }
        return decodeWorkspace(row: row)
    }

    public func workspace(dir: String) throws -> WorkspaceRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, project_id, dir, runtime_path, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, notes
                    FROM workspaces
                    WHERE dir = ?
                    ORDER BY is_archived ASC
                    LIMIT 1
                    """, bindings: [dir])
        else { return nil }
        return decodeWorkspace(row: row)
    }

    public func workspaces(projectID: String, includeArchived: Bool = false) throws -> [WorkspaceRecord] {
        let rows = try queryRows(
            sql: """
                SELECT id, project_id, dir, runtime_path, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, notes
                FROM workspaces
                WHERE project_id = ? AND (? = '1' OR is_archived = 0)
                ORDER BY is_default DESC, branch
                """, bindings: [projectID, includeArchived ? "1" : "0"])
        return rows.compactMap { decodeWorkspace(row: $0) }
    }

    public func deleteWorkspace(id: String) throws {
        let deletedWorkspace = try workspace(id: id)
        try withImmediateTransaction {
            try execute(
                sql: "DELETE FROM runtime_target_events WHERE runtime_target_id IN (SELECT id FROM runtime_targets WHERE workspace_id = ?)",
                bindings: [id])
            try execute(
                sql: "DELETE FROM agent_session_events WHERE agent_session_id IN (SELECT id FROM agent_sessions WHERE workspace_id = ?)",
                bindings: [id])
            try execute(sql: "DELETE FROM agent_sessions WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM runtime_targets WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM workspace_settings WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM workspace_processes WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM workspace_browser_sessions WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM workspace_agent_launchers WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM running_processes WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM workspace_service_ports WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM workspace_services WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM workspaces WHERE id = ?", bindings: [id])
            if let deletedWorkspace { try markIgnoredWorktree(path: deletedWorkspace.dir, projectID: deletedWorkspace.projectID) }
        }
    }

    public func markIgnoredWorktree(path: String, projectID: String) throws {
        try execute(
            sql: """
                INSERT INTO ignored_worktrees(worktree_dir, project_id)
                VALUES (?, ?)
                ON CONFLICT(worktree_dir) DO UPDATE SET project_id = excluded.project_id
                """, bindings: [path, projectID])
    }

    public func isIgnoredWorktree(path: String) throws -> Bool {
        let rows = try queryRows(sql: "SELECT worktree_dir FROM ignored_worktrees WHERE worktree_dir = ?", bindings: [path])
        return !rows.isEmpty
    }

    public func updateWorkspaceRunning(id: String, isRunning: Bool, launchedAt: String?) throws {
        try execute(
            sql: """
                UPDATE workspaces
                SET is_running = ?, last_launched_at = ?
                WHERE id = ?
                """, bindings: [isRunning ? "1" : "0", launchedAt ?? "", id])
    }

    public func updateWorkspaceArchived(id: String, isArchived: Bool) throws {
        try execute(sql: "UPDATE workspaces SET is_archived = ? WHERE id = ?", bindings: [isArchived ? "1" : "0", id])
    }

    public func updateWorkspaceHidden(id: String, isHidden: Bool) throws {
        try execute(sql: "UPDATE workspaces SET is_hidden = ? WHERE id = ?", bindings: [isHidden ? "1" : "0", id])
    }

    public func updateWorkspaceNotes(id: String, notes: String?) throws {
        try execute(sql: "UPDATE workspaces SET notes = ? WHERE id = ?", bindings: [notes ?? "", id])
    }

    public func updateWorkspaceBranch(id: String, branch: String?) throws {
        try execute(sql: "UPDATE workspaces SET branch = ? WHERE id = ?", bindings: [branch ?? "", id])
    }

    public func updateWorkspaceDirname(id: String, dirname: String?) throws {
        try execute(sql: "UPDATE workspaces SET dirname = ? WHERE id = ?", bindings: [dirname ?? "", id])
    }

    public func setWorkspaceProcesses(workspaceID: String, processes: [ProcessTemplate]) throws {
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_processes WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, process) in processes.enumerated() {
                try execute(
                    sql: """
                        INSERT INTO workspace_processes(id, workspace_id, name, command, on_exit, order_index)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, bindings: [process.id, workspaceID, process.name ?? "", process.command, process.onExit.rawValue, String(index)])
            }
        }
    }

    public func workspaceProcesses(workspaceID: String) throws -> [ProcessTemplate] {
        let rows = try queryRows(
            sql: """
                SELECT id, name, command, on_exit
                FROM workspace_processes
                WHERE workspace_id = ?
                ORDER BY order_index
                """, bindings: [workspaceID])
        return rows.map { row in
            let id = row[0].isEmpty ? UUID().uuidString : row[0]
            let name = row[1].isEmpty ? nil : row[1]
            return ProcessTemplate(id: id, name: name, command: row[2], onExit: ProcessExitAction(rawValue: row[3]) ?? .none)
        }
    }

    public func setWorkspaceAgentLaunchers(workspaceID: String, launchers: [AgentLauncher]) throws {
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_agent_launchers WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, launcher) in launchers.enumerated() {
                try execute(
                    sql: """
                        INSERT INTO workspace_agent_launchers(workspace_id, id, name, command, order_index)
                        VALUES (?, ?, ?, ?, ?)
                        """, bindings: [workspaceID, launcher.id, launcher.name, launcher.command, String(index)])
            }
        }
    }

    public func workspaceSettingsExists(workspaceID: String) throws -> Bool {
        let rows = try queryRows(sql: "SELECT workspace_id FROM workspace_settings WHERE workspace_id = ?", bindings: [workspaceID])
        return !rows.isEmpty
    }

    public func deleteWorkspaceConfiguration(workspaceID: String) throws {
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_settings WHERE workspace_id = ?", bindings: [workspaceID])
            try execute(sql: "DELETE FROM workspace_processes WHERE workspace_id = ?", bindings: [workspaceID])
            try execute(sql: "DELETE FROM workspace_browser_sessions WHERE workspace_id = ?", bindings: [workspaceID])
            try execute(sql: "DELETE FROM workspace_agent_launchers WHERE workspace_id = ?", bindings: [workspaceID])
            try execute(sql: "DELETE FROM workspace_service_ports WHERE workspace_id = ?", bindings: [workspaceID])
            try execute(sql: "DELETE FROM workspace_services WHERE workspace_id = ?", bindings: [workspaceID])
        }
    }

    public func workspaceStopScript(workspaceID: String) throws -> String? {
        let rows = try queryRows(sql: "SELECT stop_script FROM workspace_settings WHERE workspace_id = ?", bindings: [workspaceID])
        guard let raw = rows.first?.first else { return nil }
        return raw.isEmpty ? nil : raw
    }

    public func workspaceSetupState(workspaceID: String) throws -> WorkspaceSetupState? {
        let rows = try queryRows(
            sql: """
                SELECT setup_status, setup_error, setup_started_at, setup_finished_at, setup_exit_code, setup_log_path
                FROM workspace_settings
                WHERE workspace_id = ?
                """, bindings: [workspaceID])
        guard let row = rows.first, row.count >= 6 else { return nil }
        let rawStatus = row[0].isEmpty ? WorkspaceSetupStatus.succeeded.rawValue : row[0]
        let status = WorkspaceSetupStatus(rawValue: rawStatus) ?? .succeeded
        let errorMessage = row[1].isEmpty ? nil : row[1]
        let startedAt = row[2].isEmpty ? nil : row[2]
        let finishedAt = row[3].isEmpty ? nil : row[3]
        let exitCode = row[4].isEmpty ? nil : Int(row[4])
        let logPath = row[5].isEmpty ? nil : row[5]
        return WorkspaceSetupState(
            status: status, errorMessage: errorMessage, startedAt: startedAt, finishedAt: finishedAt, exitCode: exitCode, logPath: logPath)
    }

    public func setWorkspaceSetupState(
        workspaceID: String, status: WorkspaceSetupStatus, errorMessage: String? = nil, startedAt: String? = nil, finishedAt: String? = nil,
        exitCode: Int? = nil, logPath: String? = nil
    ) throws {
        try execute(
            sql: """
                INSERT INTO workspace_settings(workspace_id, setup_status, setup_error, setup_started_at, setup_finished_at, setup_exit_code, setup_log_path)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(workspace_id) DO UPDATE SET
                  setup_status = excluded.setup_status,
                  setup_error = excluded.setup_error,
                  setup_started_at = excluded.setup_started_at,
                  setup_finished_at = excluded.setup_finished_at,
                  setup_exit_code = excluded.setup_exit_code,
                  setup_log_path = excluded.setup_log_path
                """,
            bindings: [
                workspaceID, status.rawValue, errorMessage ?? "", startedAt ?? "", finishedAt ?? "", exitCode.map(String.init) ?? "", logPath ?? "",
            ])
    }

    public func setWorkspaceStopScript(workspaceID: String, stopScript: String?) throws {
        try execute(
            sql: """
                INSERT INTO workspace_settings(workspace_id, stop_script)
                VALUES (?, ?)
                ON CONFLICT(workspace_id) DO UPDATE SET stop_script = excluded.stop_script
                """, bindings: [workspaceID, stopScript ?? ""])
    }

    public func touchWorkspaceSettings(workspaceID: String, updatedAt _: String) throws {
        try execute(
            sql: """
                INSERT INTO workspace_settings(workspace_id)
                VALUES (?)
                ON CONFLICT(workspace_id) DO NOTHING
                """, bindings: [workspaceID])
    }

    public func workspaceAgentLaunchers(workspaceID: String) throws -> [AgentLauncher] {
        let rows = try queryRows(
            sql: """
                SELECT id, name, command
                FROM workspace_agent_launchers
                WHERE workspace_id = ?
                ORDER BY order_index
                """, bindings: [workspaceID])
        return rows.map { AgentLauncher(id: $0[0].isEmpty ? UUID().uuidString : $0[0], name: $0[1], command: $0[2]) }
    }

    func decodeWorkspace(row: [String]) -> WorkspaceRecord? {
        guard row.count >= 13 else { return nil }
        return WorkspaceRecord(
            id: row[0], projectID: row[1], dir: row[2], runtimePath: row[3].isEmpty ? row[2] : row[3], dirname: row[4].isEmpty ? nil : row[4],
            branch: row[5].isEmpty ? nil : row[5], baseBranch: row[6].isEmpty ? nil : row[6], isDefault: row[7] == "1", isArchived: row[8] == "1",
            isHidden: row[9] != "0", isRunning: row[10] == "1", lastLaunchedAt: row[11].isEmpty ? nil : row[11],
            notes: row[12].isEmpty ? nil : row[12])
    }
}
