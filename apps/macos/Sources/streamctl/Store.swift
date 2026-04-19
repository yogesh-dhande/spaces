import Foundation
import SQLite3

public final class SQLiteStore {
    private let db: OpaquePointer
    private let schemaVersion = 6
    private let busyTimeoutMS: Int32 = 5000
    private let busyRetryAttempts = 10
    private let busyRetryDelaySeconds: TimeInterval = 0.02

    public init(path: String) throws {
        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, openFlags, nil) != SQLITE_OK {
            throw NSError(domain: "muxy.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed opening sqlite db at \(path)"])
        }
        guard let handle else { throw NSError(domain: "muxy.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "DB handle is nil"]) }
        db = handle
        guard sqlite3_busy_timeout(db, busyTimeoutMS) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed configuring sqlite busy timeout: \(message)"])
        }
        try configureConnectionPragmas()
        try rebuildSchemaIfNeeded()
    }

    deinit { sqlite3_close(db) }

    public func upsert(project: ProjectRecord) throws {
        try execute(
            sql: """
                INSERT INTO projects(id, name, dir, is_git, default_branch, setup_script, stop_script)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  dir = excluded.dir,
                  is_git = excluded.is_git,
                  default_branch = excluded.default_branch,
                  setup_script = excluded.setup_script,
                  stop_script = excluded.stop_script
                """,
            bindings: [
                project.id, project.name, project.dir, project.isGitRepo ? "1" : "0", project.defaultBranch ?? "", project.setupScript ?? "",
                project.stopScript ?? "",
            ])
        try execute(sql: "DELETE FROM project_port_definitions WHERE project_id = ?", bindings: [project.id])
        for (index, definition) in project.ports.enumerated() {
            try execute(
                sql: "INSERT INTO project_port_definitions(project_id, name, order_index) VALUES (?, ?, ?)",
                bindings: [project.id, definition.name, String(index)])
        }
        try execute(sql: "DELETE FROM project_processes WHERE project_id = ?", bindings: [project.id])
        for (index, process) in project.processes.enumerated() {
            try execute(
                sql: "INSERT INTO project_processes(id, project_id, name, command, on_exit, order_index) VALUES (?, ?, ?, ?, ?, ?)",
                bindings: [UUID().uuidString, project.id, process.name ?? "", process.command, process.onExit.rawValue, String(index)])
        }
        try execute(sql: "DELETE FROM project_status_checks WHERE project_id = ?", bindings: [project.id])
        for (index, check) in project.statusChecks.enumerated() {
            try execute(
                sql: """
                    INSERT INTO project_status_checks(id, project_id, name, process, command, interval, timeout, on_fail, order_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                bindings: [
                    UUID().uuidString, project.id, check.name ?? "", check.process, check.command, String(check.interval), String(check.timeout),
                    check.onFail.rawValue, String(index),
                ])
        }
        try execute(sql: "DELETE FROM project_browser_sessions WHERE project_id = ?", bindings: [project.id])
        for (index, session) in project.browserSessions.enumerated() {
            try execute(
                sql: "INSERT INTO project_browser_sessions(id, project_id, name, url, order_index) VALUES (?, ?, ?, ?, ?)",
                bindings: [UUID().uuidString, project.id, session.name ?? "", session.url ?? "", String(index)])
        }
    }

    public func project(id: String) throws -> ProjectRecord? {
        guard
            let row = try queryRow(
                sql: "SELECT id, name, dir, is_git, default_branch, setup_script, stop_script FROM projects WHERE id = ?", bindings: [id])
        else { return nil }
        return try decodeProjectWithTemplates(row: row)
    }

    public func project(dir: String) throws -> ProjectRecord? {
        guard
            let row = try queryRow(
                sql: "SELECT id, name, dir, is_git, default_branch, setup_script, stop_script FROM projects WHERE dir = ?", bindings: [dir])
        else { return nil }
        return try decodeProjectWithTemplates(row: row)
    }

    public func projects() throws -> [ProjectRecord] {
        let rows = try queryRows(sql: "SELECT id, name, dir, is_git, default_branch, setup_script, stop_script FROM projects ORDER BY name")
        return try rows.compactMap { try decodeProjectWithTemplates(row: $0) }
    }

    public func deleteProject(id: String) throws {
        try execute(sql: "DELETE FROM windows WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
        try execute(sql: "DELETE FROM workspace_settings WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
        try execute(sql: "DELETE FROM workspace_processes WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
        try execute(sql: "DELETE FROM workspace_terminal_windows WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
        try execute(sql: "DELETE FROM workspace_status_checks WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
        try execute(
            sql: "DELETE FROM workspace_browser_sessions WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
        try execute(
            sql:
                "DELETE FROM status_results WHERE process_id IN (SELECT id FROM running_processes WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?))",
            bindings: [id])
        try execute(sql: "DELETE FROM running_processes WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
        try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
        try execute(
            sql: "DELETE FROM workspace_port_definitions WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
        try execute(sql: "DELETE FROM workspaces WHERE project_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM project_port_definitions WHERE project_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM project_processes WHERE project_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM project_terminal_windows WHERE project_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM project_status_checks WHERE project_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM project_browser_sessions WHERE project_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM ignored_worktrees WHERE project_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM projects WHERE id = ?", bindings: [id])
    }

    public func upsert(workspace: WorkspaceRecord) throws {
        try execute(
            sql: """
                INSERT INTO workspaces(id, project_id, title, dir, dirname, branch, target_branch, is_default, is_archived, is_active, is_running, last_launched_at, tooltip)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  title = excluded.title,
                  dir = excluded.dir,
                  dirname = excluded.dirname,
                  branch = excluded.branch,
                  target_branch = excluded.target_branch,
                  is_default = excluded.is_default,
                  is_archived = excluded.is_archived,
                  is_active = excluded.is_active,
                  is_running = excluded.is_running,
                  last_launched_at = excluded.last_launched_at,
                  tooltip = excluded.tooltip
                """,
            bindings: [
                workspace.id, workspace.projectID, workspace.title, workspace.dir, workspace.dirname ?? "", workspace.branch ?? "",
                workspace.targetBranch ?? "", workspace.isDefault ? "1" : "0", workspace.isArchived ? "1" : "0", workspace.isActive ? "1" : "0",
                workspace.isRunning ? "1" : "0", workspace.lastLaunchedAt ?? "", workspace.tooltip ?? "",
            ])
        try execute(sql: "DELETE FROM ignored_worktrees WHERE worktree_dir = ?", bindings: [workspace.dir])
    }

    public func workspace(id: String) throws -> WorkspaceRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, project_id, title, dir, dirname, branch, target_branch, is_default, is_archived, is_active, is_running, last_launched_at, tooltip
                    FROM workspaces WHERE id = ?
                    """, bindings: [id])
        else { return nil }
        return decodeWorkspace(row: row)
    }

    public func workspace(projectID: String, name: String) throws -> WorkspaceRecord? { try workspace(projectID: projectID, title: name) }

    public func workspace(projectID: String, title: String) throws -> WorkspaceRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, project_id, title, dir, dirname, branch, target_branch, is_default, is_archived, is_active, is_running, last_launched_at, tooltip
                    FROM workspaces WHERE project_id = ? AND title = ?
                    """, bindings: [projectID, title])
        else { return nil }
        return decodeWorkspace(row: row)
    }

    public func workspace(dir: String) throws -> WorkspaceRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, project_id, title, dir, dirname, branch, target_branch, is_default, is_archived, is_active, is_running, last_launched_at, tooltip
                    FROM workspaces WHERE dir = ?
                    """, bindings: [dir])
        else { return nil }
        return decodeWorkspace(row: row)
    }

    public func workspaces(projectID: String, includeArchived: Bool = false) throws -> [WorkspaceRecord] {
        let rows = try queryRows(
            sql: """
                SELECT id, project_id, title, dir, dirname, branch, target_branch, is_default, is_archived, is_active, is_running, last_launched_at, tooltip
                FROM workspaces
                WHERE project_id = ? AND (? = '1' OR is_archived = 0)
                ORDER BY is_default DESC, title
                """, bindings: [projectID, includeArchived ? "1" : "0"])
        return rows.compactMap { decodeWorkspace(row: $0) }
    }

    public func deleteWorkspace(id: String) throws {
        let deletedWorkspace = try workspace(id: id)
        try execute(sql: "DELETE FROM windows WHERE workspace_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM workspace_settings WHERE workspace_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM workspace_processes WHERE workspace_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM workspace_terminal_windows WHERE workspace_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM workspace_status_checks WHERE workspace_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM workspace_browser_sessions WHERE workspace_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM status_results WHERE process_id IN (SELECT id FROM running_processes WHERE workspace_id = ?)", bindings: [id])
        try execute(sql: "DELETE FROM running_processes WHERE workspace_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM workspace_port_definitions WHERE workspace_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM workspaces WHERE id = ?", bindings: [id])
        if let deletedWorkspace { try markIgnoredWorktree(path: deletedWorkspace.dir, projectID: deletedWorkspace.projectID) }
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

    public func updateWorkspaceActive(id: String, isActive: Bool) throws {
        try execute(sql: "UPDATE workspaces SET is_active = ? WHERE id = ?", bindings: [isActive ? "1" : "0", id])
    }

    public func updateWorkspaceTooltip(id: String, tooltip: String?) throws {
        try execute(sql: "UPDATE workspaces SET tooltip = ? WHERE id = ?", bindings: [tooltip ?? "", id])
    }

    public func updateWorkspaceTitle(id: String, title: String) throws {
        try execute(sql: "UPDATE workspaces SET title = ? WHERE id = ?", bindings: [title, id])
    }

    public func updateWorkspaceBranch(id: String, branch: String?) throws {
        try execute(sql: "UPDATE workspaces SET branch = ? WHERE id = ?", bindings: [branch ?? "", id])
    }

    public func updateWorkspaceDirname(id: String, dirname: String?) throws {
        try execute(sql: "UPDATE workspaces SET dirname = ? WHERE id = ?", bindings: [dirname ?? "", id])
    }

    public func updateWorkspaceName(id: String, name: String) throws {
        try execute(sql: "UPDATE workspaces SET title = ? WHERE id = ?", bindings: [name, id])
    }

    public func setWorkspacePorts(workspaceID: String, ports: [Int], names: [String] = []) throws {
        try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id = ?", bindings: [workspaceID])
        for (index, port) in ports.enumerated() {
            let name = index < names.count ? names[index] : ""
            try execute(
                sql: "INSERT INTO workspace_ports(workspace_id, port_index, port_number, port_name) VALUES (?, ?, ?, ?)",
                bindings: [workspaceID, String(index), String(port), name])
        }
    }

    public func workspacePorts(workspaceID: String) throws -> [Int] {
        let rows = try queryRows(sql: "SELECT port_number FROM workspace_ports WHERE workspace_id = ? ORDER BY port_index", bindings: [workspaceID])
        return rows.compactMap { Int($0.first ?? "") }
    }

    public func workspacePortsNamed(workspaceID: String) throws -> [(port: Int, name: String)] {
        let rows = try queryRows(
            sql: "SELECT port_number, port_name FROM workspace_ports WHERE workspace_id = ? ORDER BY port_index", bindings: [workspaceID])
        return rows.compactMap { row in
            guard let port = Int(row[0]) else { return nil }
            return (port: port, name: row[1])
        }
    }

    public func setWorkspacePortDefinitions(workspaceID: String, definitions: [PortDefinition]) throws {
        try execute(sql: "DELETE FROM workspace_port_definitions WHERE workspace_id = ?", bindings: [workspaceID])
        for (index, definition) in definitions.enumerated() {
            try execute(
                sql: "INSERT INTO workspace_port_definitions(workspace_id, name, order_index) VALUES (?, ?, ?)",
                bindings: [workspaceID, definition.name, String(index)])
        }
    }

    public func workspacePortDefinitions(workspaceID: String) throws -> [PortDefinition] {
        let rows = try queryRows(
            sql: "SELECT name FROM workspace_port_definitions WHERE workspace_id = ? ORDER BY order_index", bindings: [workspaceID])
        return rows.map { PortDefinition(name: $0[0]) }
    }

    public func setWorkspaceProcesses(workspaceID: String, processes: [ProcessTemplate]) throws {
        try execute(sql: "DELETE FROM workspace_processes WHERE workspace_id = ?", bindings: [workspaceID])
        for (index, process) in processes.enumerated() {
            try execute(
                sql: """
                    INSERT INTO workspace_processes(id, workspace_id, name, command, on_exit, order_index)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, bindings: [UUID().uuidString, workspaceID, process.name ?? "", process.command, process.onExit.rawValue, String(index)])
        }
    }

    public func workspaceProcesses(workspaceID: String) throws -> [ProcessTemplate] {
        let rows = try queryRows(
            sql: """
                SELECT name, command, on_exit
                FROM workspace_processes
                WHERE workspace_id = ?
                ORDER BY order_index
                """, bindings: [workspaceID])
        return rows.map { row in
            let name = row[0].isEmpty ? nil : row[0]
            return ProcessTemplate(name: name, command: row[1], onExit: ProcessExitAction(rawValue: row[2]) ?? .none)
        }
    }

    public func setWorkspaceStatusChecks(workspaceID: String, checks: [StatusCheckDefinition]) throws {
        try execute(sql: "DELETE FROM workspace_status_checks WHERE workspace_id = ?", bindings: [workspaceID])
        for (index, check) in checks.enumerated() {
            try execute(
                sql: """
                    INSERT INTO workspace_status_checks(id, workspace_id, name, process, command, interval, timeout, on_exit, on_fail, order_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                bindings: [
                    UUID().uuidString, workspaceID, check.name ?? "", check.process, check.command, String(check.interval), String(check.timeout),
                    "none", check.onFail.rawValue, String(index),
                ])
        }
    }

    public func workspaceStatusChecks(workspaceID: String) throws -> [StatusCheckDefinition] {
        let rows = try queryRows(
            sql: """
                SELECT name, process, command, interval, timeout, on_fail
                FROM workspace_status_checks
                WHERE workspace_id = ?
                ORDER BY order_index
                """, bindings: [workspaceID])
        return rows.map { row in
            StatusCheckDefinition(
                name: row[0].isEmpty ? nil : row[0], process: row[1], command: row[2],
                interval: Int(row[3]) ?? PollingConstants.statusCheckDefaultInterval,
                timeout: Int(row[4]) ?? PollingConstants.statusCheckDefaultTimeout, onFail: OnFailAction(rawValue: row[5]) ?? .none)
        }
    }

    public func setWorkspaceBrowserSessions(workspaceID: String, sessions: [BrowserSession]) throws {
        try execute(sql: "DELETE FROM workspace_browser_sessions WHERE workspace_id = ?", bindings: [workspaceID])
        for (index, session) in sessions.enumerated() {
            let extractedWindowID = session.extractedWindow.map { String($0.windowID) } ?? ""
            let extractedWindowValid = (session.extractedWindow?.isValid ?? false) ? "1" : "0"
            let extractedTargetURL = session.extractedWindow?.targetURL ?? ""
            try execute(
                sql: """
                    INSERT INTO workspace_browser_sessions(id, workspace_id, name, url, extracted_target_url, extracted_window_id, extracted_window_valid, order_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                bindings: [
                    UUID().uuidString, workspaceID, session.name ?? "", session.url ?? "", extractedTargetURL, extractedWindowID,
                    extractedWindowValid, String(index),
                ])
        }
    }

    public func workspaceSettingsExists(workspaceID: String) throws -> Bool {
        let rows = try queryRows(sql: "SELECT workspace_id FROM workspace_settings WHERE workspace_id = ?", bindings: [workspaceID])
        return !rows.isEmpty
    }

    public func workspaceStopScript(workspaceID: String) throws -> String? {
        let rows = try queryRows(sql: "SELECT stop_script FROM workspace_settings WHERE workspace_id = ?", bindings: [workspaceID])
        guard let raw = rows.first?.first else { return nil }
        return raw.isEmpty ? nil : raw
    }

    public func workspaceSetupState(workspaceID: String) throws -> WorkspaceSetupState? {
        let rows = try queryRows(
            sql: "SELECT setup_status, setup_error, setup_started_at, setup_finished_at FROM workspace_settings WHERE workspace_id = ?",
            bindings: [workspaceID])
        guard let row = rows.first, row.count >= 4 else { return nil }
        let rawStatus = row[0].isEmpty ? WorkspaceSetupStatus.succeeded.rawValue : row[0]
        let status = WorkspaceSetupStatus(rawValue: rawStatus) ?? .succeeded
        let errorMessage = row[1].isEmpty ? nil : row[1]
        let startedAt = row[2].isEmpty ? nil : row[2]
        let finishedAt = row[3].isEmpty ? nil : row[3]
        return WorkspaceSetupState(status: status, errorMessage: errorMessage, startedAt: startedAt, finishedAt: finishedAt)
    }

    public func setWorkspaceSetupState(
        workspaceID: String, status: WorkspaceSetupStatus, errorMessage: String? = nil, startedAt: String? = nil, finishedAt: String? = nil
    ) throws {
        try execute(
            sql: """
                INSERT INTO workspace_settings(workspace_id, updated_at, setup_status, setup_error, setup_started_at, setup_finished_at)
                VALUES (?, '', ?, ?, ?, ?)
                ON CONFLICT(workspace_id) DO UPDATE SET
                  setup_status = excluded.setup_status,
                  setup_error = excluded.setup_error,
                  setup_started_at = excluded.setup_started_at,
                  setup_finished_at = excluded.setup_finished_at
                """, bindings: [workspaceID, status.rawValue, errorMessage ?? "", startedAt ?? "", finishedAt ?? ""])
    }

    public func setWorkspaceStopScript(workspaceID: String, stopScript: String?) throws {
        try execute(
            sql: """
                INSERT INTO workspace_settings(workspace_id, updated_at, stop_script)
                VALUES (?, '', ?)
                ON CONFLICT(workspace_id) DO UPDATE SET stop_script = excluded.stop_script
                """, bindings: [workspaceID, stopScript ?? ""])
    }

    public func touchWorkspaceSettings(workspaceID: String, updatedAt: String) throws {
        try execute(
            sql: """
                INSERT INTO workspace_settings(workspace_id, updated_at)
                VALUES (?, ?)
                ON CONFLICT(workspace_id) DO UPDATE SET updated_at = excluded.updated_at
                """, bindings: [workspaceID, updatedAt])
    }

    public func workspaceBrowserSessions(workspaceID: String) throws -> [BrowserSession] {
        let rows = try queryRows(
            sql: """
                SELECT name, url, extracted_target_url, extracted_window_id, extracted_window_valid
                FROM workspace_browser_sessions
                WHERE workspace_id = ?
                ORDER BY order_index
                """, bindings: [workspaceID])
        return rows.map { row in
            let name = row[0].isEmpty ? nil : row[0]
            let url = row[1].isEmpty ? nil : row[1]
            let extractedTargetURL = row[2]
            let extractedWindowID = Int(row[3])
            let extractedWindowValid = row[4] == "1"
            let extractedWindow: ExtractedBrowserWindowMapping?
            if let extractedWindowID, !extractedTargetURL.isEmpty {
                extractedWindow = ExtractedBrowserWindowMapping(
                    targetURL: extractedTargetURL, windowID: extractedWindowID, isValid: extractedWindowValid)
            } else {
                extractedWindow = nil
            }
            return BrowserSession(name: name, url: url, extractedWindow: extractedWindow)
        }
    }

    public func releaseWorkspacePorts(workspaceID: String) throws {
        try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id = ?", bindings: [workspaceID])
    }

    public func upsert(runningProcess: RunningProcessRecord) throws {
        try execute(
            sql: """
                INSERT INTO running_processes(
                  id, workspace_id, template_name, command, terminal_app, window_id, iterm_session_id, iterm_tab_index,
                  tmux_window_id, pid, status, log_path, last_output_at, started_at, exited_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  template_name = excluded.template_name,
                  command = excluded.command,
                  terminal_app = excluded.terminal_app,
                  window_id = excluded.window_id,
                  iterm_session_id = excluded.iterm_session_id,
                  iterm_tab_index = excluded.iterm_tab_index,
                  tmux_window_id = excluded.tmux_window_id,
                  pid = excluded.pid,
                  status = excluded.status,
                  log_path = excluded.log_path,
                  last_output_at = excluded.last_output_at,
                  started_at = excluded.started_at,
                  exited_at = excluded.exited_at
                """,
            bindings: [
                runningProcess.id, runningProcess.workspaceID, runningProcess.templateName, runningProcess.command, runningProcess.terminalApp ?? "",
                runningProcess.windowID.map(String.init) ?? "", runningProcess.itermSessionID ?? "",
                runningProcess.itermTabIndex.map(String.init) ?? "", runningProcess.tmuxWindowID ?? "",
                runningProcess.pid.map(String.init) ?? "", runningProcess.status.rawValue, runningProcess.logPath ?? "",
                runningProcess.lastOutputAt ?? "", runningProcess.startedAt ?? "", runningProcess.exitedAt ?? "",
            ])
    }

    public func runningProcesses(workspaceID: String) throws -> [RunningProcessRecord] {
        let rows = try queryRows(
            sql: """
                SELECT id, workspace_id, template_name, command, terminal_app, window_id, iterm_session_id, iterm_tab_index, tmux_window_id, pid, status, log_path, last_output_at, started_at, exited_at
                FROM running_processes WHERE workspace_id = ?
                ORDER BY started_at
                """, bindings: [workspaceID])
        return rows.compactMap { decodeRunningProcess(row: $0) }
    }

    public func deleteRunningProcess(id: String) throws {
        try execute(sql: "DELETE FROM status_results WHERE process_id = ?", bindings: [id])
        try execute(sql: "DELETE FROM running_processes WHERE id = ?", bindings: [id])
    }

    public func deleteRunningProcesses(workspaceID: String) throws {
        try execute(sql: "DELETE FROM running_processes WHERE workspace_id = ?", bindings: [workspaceID])
    }

    public func upsert(statusResult: StatusResult) throws {
        try execute(
            sql: """
                INSERT INTO status_results(process_id, check_name, status, message, last_run_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(process_id, check_name) DO UPDATE SET
                  status = excluded.status,
                  message = excluded.message,
                  last_run_at = excluded.last_run_at
                """,
            bindings: [
                statusResult.processID, statusResult.checkName, statusResult.status.rawValue, statusResult.message ?? "",
                statusResult.lastRunAt ?? "",
            ])
    }

    public func markStatusResultsAsFailed(processID: String) throws {
        try execute(
            sql: "UPDATE status_results SET status = '\(StatusCheckStatus.failed.rawValue)', message = 'Process exited' WHERE process_id = ?",
            bindings: [processID])
    }

    public func statusResults(processID: String) throws -> [StatusResult] {
        let rows = try queryRows(
            sql: "SELECT process_id, check_name, status, message, last_run_at FROM status_results WHERE process_id = ?", bindings: [processID])
        return rows.map { row in
            StatusResult(
                processID: row[0], checkName: row[1], status: StatusCheckStatus(rawValue: row[2]) ?? .failed, message: row[3].isEmpty ? nil : row[3],
                lastRunAt: row[4].isEmpty ? nil : row[4])
        }
    }

    public func upsert(window: WindowRecord) throws {
        try execute(
            sql: """
                INSERT INTO windows(
                  id, workspace_id, app, title, target_url, window_id, iterm_session_id, iterm_tab_index, tmux_window_id, role, order_index, last_seen_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  app = excluded.app,
                  title = excluded.title,
                  target_url = excluded.target_url,
                  window_id = excluded.window_id,
                  iterm_session_id = excluded.iterm_session_id,
                  iterm_tab_index = excluded.iterm_tab_index,
                  tmux_window_id = excluded.tmux_window_id,
                  role = excluded.role,
                  order_index = excluded.order_index,
                  last_seen_at = excluded.last_seen_at
                """,
            bindings: [
                window.id, window.workspaceID, window.app, window.title ?? "", window.targetURL ?? "", window.windowID.map(String.init) ?? "",
                window.itermSessionID ?? "", window.itermTabIndex.map(String.init) ?? "", window.tmuxWindowID ?? "", window.role,
                String(window.orderIndex), window.lastSeenAt,
            ])
    }

    public func windows(workspaceID: String) throws -> [WindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT id, workspace_id, app, title, target_url, window_id, iterm_session_id, iterm_tab_index, tmux_window_id, role, order_index, last_seen_at
                FROM windows WHERE workspace_id = ?
                ORDER BY order_index
                """, bindings: [workspaceID])
        return rows.compactMap { decodeWindow(row: $0) }
    }

    public func windows(windowID: Int) throws -> [WindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT id, workspace_id, app, title, target_url, window_id, iterm_session_id, iterm_tab_index, tmux_window_id, role, order_index, last_seen_at
                FROM windows
                WHERE window_id = ?
                ORDER BY last_seen_at DESC, order_index
                """, bindings: [String(windowID)])
        return rows.compactMap { decodeWindow(row: $0) }
    }

    public func workspaceID(windowID: Int) throws -> String? {
        let row = try queryRow(
            sql: "SELECT workspace_id FROM windows WHERE window_id = ? ORDER BY last_seen_at DESC LIMIT 1", bindings: [String(windowID)])
        return row?.first
    }

    public func workspaceIDForAgentWindow(yabaiWindowID: Int) throws -> String? {
        let row = try queryRow(
            sql: """
                SELECT workspace_id
                FROM agent_windows
                WHERE yabai_window_id = ? OR window_id = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """, bindings: [String(yabaiWindowID), String(yabaiWindowID)])
        return row?.first
    }

    public func deleteWindows(workspaceID: String) throws { try execute(sql: "DELETE FROM windows WHERE workspace_id = ?", bindings: [workspaceID]) }

    public func deleteWindow(id: String) throws { try execute(sql: "DELETE FROM windows WHERE id = ?", bindings: [id]) }

    public func setting(key: String) throws -> String? {
        let rows = try queryRows(sql: "SELECT value FROM settings WHERE key = ?", bindings: [key])
        guard let value = rows.first?.first else { return nil }
        return value
    }

    public func setSetting(key: String, value: String?) throws {
        if let value {
            try execute(
                sql: "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", bindings: [key, value])
        } else {
            try execute(sql: "DELETE FROM settings WHERE key = ?", bindings: [key])
        }
    }

    public func appConfig() throws -> AppConfig {
        let editor = try setting(key: SettingsKey.appEditor).flatMap { EditorPreference(rawValue: $0) }
        let start = try setting(key: SettingsKey.appPortRangeStart).flatMap(Int.init) ?? 20000
        let end = try setting(key: SettingsKey.appPortRangeEnd).flatMap(Int.init) ?? 30000
        let portRange = (start <= 0 || end <= 0 || end <= start) ? PortRange(start: 20000, end: 30000) : PortRange(start: start, end: end)
        return AppConfig(editor: editor, portRange: portRange)
    }

    public func setAppConfig(_ config: AppConfig) throws {
        try setSetting(key: SettingsKey.appEditor, value: config.editor?.rawValue)
        try setSetting(key: SettingsKey.appPortRangeStart, value: String(config.portRange.start))
        try setSetting(key: SettingsKey.appPortRangeEnd, value: String(config.portRange.end))
    }

    // MARK: - Agent Windows

    public func upsertAgentWindow(_ record: AgentWindowRecord) throws {
        try execute(
            sql: """
                INSERT INTO agent_windows(
                  id, workspace_id, provider, label, iterm_session_id, tmux_window_id, codex_thread_id, window_id, status, created_at, updated_at, yabai_window_id
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  workspace_id = excluded.workspace_id,
                  provider = excluded.provider,
                  label = excluded.label,
                  iterm_session_id = excluded.iterm_session_id,
                  tmux_window_id = excluded.tmux_window_id,
                  codex_thread_id = excluded.codex_thread_id,
                  window_id = excluded.window_id,
                  status = excluded.status,
                  updated_at = excluded.updated_at,
                  yabai_window_id = excluded.yabai_window_id
                """,
            bindings: [
                record.id, record.workspaceID, record.provider.rawValue, record.label ?? "", record.itermSessionID ?? "", record.tmuxWindowID ?? "",
                record.codexThreadID ?? "", record.windowID.map(String.init) ?? "", record.status.rawValue, record.createdAt, record.updatedAt,
                record.yabaiWindowID.map(String.init) ?? "",
            ])
    }

    public func agentWindows(workspaceID: String) throws -> [AgentWindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT id, workspace_id, provider, label, iterm_session_id, tmux_window_id, codex_thread_id, window_id, status, created_at, updated_at, yabai_window_id
                FROM agent_windows WHERE workspace_id = ?
                ORDER BY created_at
                """, bindings: [workspaceID])
        return rows.compactMap { decodeAgentWindow(row: $0) }
    }

    public func agentWindow(workspaceID: String, itermSessionID: String) throws -> AgentWindowRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, workspace_id, provider, label, iterm_session_id, tmux_window_id, codex_thread_id, window_id, status, created_at, updated_at, yabai_window_id
                    FROM agent_windows WHERE workspace_id = ? AND iterm_session_id = ?
                    """, bindings: [workspaceID, itermSessionID])
        else { return nil }
        return decodeAgentWindow(row: row)
    }

    public func agentWindow(workspaceID: String, tmuxWindowID: String) throws -> AgentWindowRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, workspace_id, provider, label, iterm_session_id, tmux_window_id, codex_thread_id, window_id, status, created_at, updated_at, yabai_window_id
                    FROM agent_windows WHERE workspace_id = ? AND tmux_window_id = ?
                    """, bindings: [workspaceID, tmuxWindowID])
        else { return nil }
        return decodeAgentWindow(row: row)
    }

    public func agentWindowsByProvider(workspaceID: String, provider: AgentProvider) throws -> [AgentWindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT id, workspace_id, provider, label, iterm_session_id, tmux_window_id, codex_thread_id, window_id, status, created_at, updated_at, yabai_window_id
                FROM agent_windows WHERE workspace_id = ? AND provider = ?
                ORDER BY created_at
                """, bindings: [workspaceID, provider.rawValue])
        return rows.compactMap { decodeAgentWindow(row: $0) }
    }

    public func updateAgentWindowStatus(id: String, status: AgentWindowStatus, updatedAt: String) throws {
        try execute(sql: "UPDATE agent_windows SET status = ?, updated_at = ? WHERE id = ?", bindings: [status.rawValue, updatedAt, id])
    }

    public func deleteAgentWindows(workspaceID: String) throws {
        try execute(sql: "DELETE FROM agent_windows WHERE workspace_id = ?", bindings: [workspaceID])
    }

    public func deleteAgentWindow(id: String) throws { try execute(sql: "DELETE FROM agent_windows WHERE id = ?", bindings: [id]) }

    public func deleteAgentWindowsByProvider(workspaceID: String, provider: AgentProvider) throws {
        try execute(sql: "DELETE FROM agent_windows WHERE workspace_id = ? AND provider = ?", bindings: [workspaceID, provider.rawValue])
    }

    private func decodeAgentWindow(row: [String]) -> AgentWindowRecord? {
        guard row.count >= 12 else { return nil }
        guard let provider = AgentProvider(rawValue: row[2]) else { return nil }
        let status = AgentWindowStatus(rawValue: row[8]) ?? .idle
        let yabaiWindowID = row.count > 11 ? (row[11].isEmpty ? nil : Int(row[11])) : nil
        return AgentWindowRecord(
            id: row[0], workspaceID: row[1], provider: provider, label: row[3].isEmpty ? nil : row[3], itermSessionID: row[4].isEmpty ? nil : row[4],
            tmuxWindowID: row[5].isEmpty ? nil : row[5], codexThreadID: row[6].isEmpty ? nil : row[6],
            windowID: row[7].isEmpty ? nil : Int(row[7]), yabaiWindowID: yabaiWindowID, status: status, createdAt: row[9], updatedAt: row[10])
    }

    private func createSchema() throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS projects (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              dir TEXT NOT NULL UNIQUE,
              is_git INTEGER NOT NULL,
              default_branch TEXT,
              setup_script TEXT,
              stop_script TEXT
            );

            CREATE TABLE IF NOT EXISTS project_port_definitions (
              project_id TEXT NOT NULL,
              name TEXT NOT NULL,
              order_index INTEGER NOT NULL,
              PRIMARY KEY (project_id, order_index)
            );

            CREATE TABLE IF NOT EXISTS project_processes (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              name TEXT,
              command TEXT NOT NULL,
              on_exit TEXT NOT NULL DEFAULT 'none',
              order_index INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS project_terminal_windows (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              name TEXT NOT NULL,
              command TEXT,
              order_index INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS project_status_checks (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              name TEXT,
              process TEXT NOT NULL,
              command TEXT NOT NULL,
              interval INTEGER NOT NULL,
              timeout INTEGER NOT NULL,
              on_fail TEXT NOT NULL,
              order_index INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS project_browser_sessions (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              name TEXT,
              url TEXT,
              order_index INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspaces (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              title TEXT NOT NULL,
              dir TEXT NOT NULL,
              dirname TEXT,
              branch TEXT,
              target_branch TEXT,
              is_default INTEGER NOT NULL,
              is_archived INTEGER NOT NULL,
              is_active INTEGER NOT NULL DEFAULT 1,
              is_running INTEGER NOT NULL,
              last_launched_at TEXT,
              tooltip TEXT,
              UNIQUE(project_id, title)
            );

            CREATE TABLE IF NOT EXISTS workspace_ports (
              workspace_id TEXT NOT NULL,
              port_index INTEGER NOT NULL,
              port_number INTEGER NOT NULL,
              port_name TEXT NOT NULL DEFAULT '',
              PRIMARY KEY (workspace_id, port_index)
            );

            CREATE TABLE IF NOT EXISTS workspace_port_definitions (
              workspace_id TEXT NOT NULL,
              name TEXT NOT NULL,
              order_index INTEGER NOT NULL,
              PRIMARY KEY (workspace_id, order_index)
            );

            CREATE TABLE IF NOT EXISTS workspace_settings (
              workspace_id TEXT PRIMARY KEY,
              updated_at TEXT NOT NULL,
              stop_script TEXT,
              setup_status TEXT NOT NULL DEFAULT 'succeeded',
              setup_error TEXT,
              setup_started_at TEXT,
              setup_finished_at TEXT
            );

            CREATE TABLE IF NOT EXISTS workspace_processes (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              name TEXT,
              command TEXT NOT NULL,
              on_exit TEXT NOT NULL DEFAULT 'none',
              order_index INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspace_terminal_windows (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              name TEXT NOT NULL,
              command TEXT,
              order_index INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspace_status_checks (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              name TEXT,
              process TEXT NOT NULL,
              command TEXT NOT NULL,
              interval INTEGER NOT NULL,
              timeout INTEGER NOT NULL,
              on_exit TEXT NOT NULL DEFAULT 'none',
              on_fail TEXT NOT NULL DEFAULT 'none',
              order_index INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspace_browser_sessions (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              name TEXT,
              url TEXT,
              extracted_target_url TEXT,
              extracted_window_id INTEGER,
              extracted_window_valid INTEGER NOT NULL DEFAULT 0,
              order_index INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS running_processes (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              template_name TEXT NOT NULL,
              command TEXT NOT NULL,
              terminal_app TEXT,
              window_id INTEGER,
              iterm_session_id TEXT,
              iterm_tab_index INTEGER,
              tmux_window_id TEXT,
              pid INTEGER,
              status TEXT NOT NULL,
              log_path TEXT,
              last_output_at TEXT,
              started_at TEXT,
              exited_at TEXT
            );

            CREATE TABLE IF NOT EXISTS status_results (
              process_id TEXT NOT NULL,
              check_name TEXT NOT NULL,
              status TEXT NOT NULL,
              message TEXT,
              last_run_at TEXT,
              PRIMARY KEY (process_id, check_name)
            );

            CREATE TABLE IF NOT EXISTS windows (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              app TEXT NOT NULL,
              title TEXT,
              target_url TEXT,
              window_id INTEGER,
              iterm_session_id TEXT,
              iterm_tab_index INTEGER,
              tmux_window_id TEXT,
              role TEXT NOT NULL,
              order_index INTEGER,
              last_seen_at TEXT
            );

            CREATE TABLE IF NOT EXISTS settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS ignored_worktrees (
              worktree_dir TEXT PRIMARY KEY,
              project_id TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS agent_windows (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              provider TEXT NOT NULL,
              label TEXT,
              iterm_session_id TEXT,
              tmux_window_id TEXT,
              codex_thread_id TEXT,
              window_id INTEGER,
              status TEXT NOT NULL DEFAULT 'idle',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              yabai_window_id INTEGER
            );

            CREATE TABLE IF NOT EXISTS schema_version (
              version INTEGER NOT NULL
            );
            """
        try executeBatch(sql: sql)
    }

    private func rebuildSchemaIfNeeded() throws {
        try createSchema()
        try applyAdditiveMigrations()
        let currentVersion = try schemaVersionValue()
        if currentVersion != schemaVersion { try setSchemaVersion(schemaVersion) }
    }

    private func schemaVersionValue() throws -> Int? {
        do {
            let rows = try queryRows(sql: "SELECT version FROM schema_version")
            guard let raw = rows.first?.first, let value = Int(raw) else { return nil }
            return value
        } catch { return nil }
    }

    private func setSchemaVersion(_ version: Int) throws {
        try execute(sql: "DELETE FROM schema_version", bindings: [])
        try execute(sql: "INSERT INTO schema_version(version) VALUES (?)", bindings: [String(version)])
    }

    private func applyAdditiveMigrations() throws {
        try ensureColumnExists(table: "projects", name: "setup_script", definition: "setup_script TEXT")
        try ensureColumnExists(table: "projects", name: "stop_script", definition: "stop_script TEXT")
        try ensureColumnExists(table: "project_processes", name: "on_exit", definition: "on_exit TEXT NOT NULL DEFAULT 'none'")
        try execute(
            sql: """
                CREATE TABLE IF NOT EXISTS project_terminal_windows (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT,
                  order_index INTEGER NOT NULL
                )
                """, bindings: [])
        try ensureColumnExists(table: "project_status_checks", name: "on_fail", definition: "on_fail TEXT NOT NULL DEFAULT 'none'")
        try ensureColumnExists(table: "workspace_processes", name: "on_exit", definition: "on_exit TEXT NOT NULL DEFAULT 'none'")
        try execute(
            sql: """
                CREATE TABLE IF NOT EXISTS workspace_terminal_windows (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT,
                  order_index INTEGER NOT NULL
                )
                """, bindings: [])
        try ensureColumnExists(table: "workspace_status_checks", name: "on_exit", definition: "on_exit TEXT NOT NULL DEFAULT 'none'")
        try ensureColumnExists(table: "workspace_status_checks", name: "on_fail", definition: "on_fail TEXT NOT NULL DEFAULT 'none'")
        try ensureColumnExists(table: "workspace_ports", name: "port_name", definition: "port_name TEXT NOT NULL DEFAULT ''")
        try ensureColumnExists(table: "workspaces", name: "dirname", definition: "dirname TEXT")
        try ensureColumnExists(table: "workspaces", name: "branch", definition: "branch TEXT")
        try ensureColumnExists(table: "workspaces", name: "target_branch", definition: "target_branch TEXT")
        try ensureColumnExists(table: "workspaces", name: "tooltip", definition: "tooltip TEXT")
        try ensureColumnExists(table: "workspaces", name: "is_active", definition: "is_active INTEGER NOT NULL DEFAULT 1")
        try execute(sql: "UPDATE workspaces SET is_active = 1 WHERE is_active IS NULL", bindings: [])
        let workspaceColumns = try queryRows(sql: "PRAGMA table_info(workspaces)").compactMap { $0.count > 1 ? $0[1] : nil }
        if !workspaceColumns.contains("title") {
            try ensureColumnExists(table: "workspaces", name: "title", definition: "title TEXT NOT NULL DEFAULT ''")
        }
        if workspaceColumns.contains("name") { try execute(sql: "UPDATE workspaces SET title = name WHERE title = ''", bindings: []) }
        try execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_workspaces_project_title_unique ON workspaces(project_id, title)", bindings: [])
        try ensureColumnExists(table: "project_browser_sessions", name: "name", definition: "name TEXT")
        try ensureColumnExists(table: "workspace_browser_sessions", name: "name", definition: "name TEXT")
        try ensureColumnExists(table: "workspace_browser_sessions", name: "extracted_target_url", definition: "extracted_target_url TEXT")
        try ensureColumnExists(table: "workspace_browser_sessions", name: "extracted_window_id", definition: "extracted_window_id INTEGER")
        try ensureColumnExists(
            table: "workspace_browser_sessions", name: "extracted_window_valid", definition: "extracted_window_valid INTEGER NOT NULL DEFAULT 0")
        try ensureColumnExists(table: "workspace_settings", name: "setup_status", definition: "setup_status TEXT NOT NULL DEFAULT 'succeeded'")
        try ensureColumnExists(table: "workspace_settings", name: "setup_error", definition: "setup_error TEXT")
        try ensureColumnExists(table: "workspace_settings", name: "setup_started_at", definition: "setup_started_at TEXT")
        try ensureColumnExists(table: "workspace_settings", name: "setup_finished_at", definition: "setup_finished_at TEXT")
        try execute(sql: "UPDATE workspace_settings SET setup_status = 'succeeded' WHERE COALESCE(setup_status, '') = ''", bindings: [])
        try ensureColumnExists(table: "status_results", name: "message", definition: "message TEXT")
        try ensureColumnExists(table: "status_results", name: "last_run_at", definition: "last_run_at TEXT")
        try ensureColumnExists(table: "running_processes", name: "last_output_at", definition: "last_output_at TEXT")
        try ensureColumnExists(table: "running_processes", name: "started_at", definition: "started_at TEXT")
        try ensureColumnExists(table: "running_processes", name: "exited_at", definition: "exited_at TEXT")
        try ensureColumnExists(table: "running_processes", name: "iterm_session_id", definition: "iterm_session_id TEXT")
        try ensureColumnExists(table: "running_processes", name: "iterm_tab_index", definition: "iterm_tab_index INTEGER")
        try ensureColumnExists(table: "running_processes", name: "tmux_window_id", definition: "tmux_window_id TEXT")
        try ensureColumnExists(table: "windows", name: "iterm_session_id", definition: "iterm_session_id TEXT")
        try ensureColumnExists(table: "windows", name: "iterm_tab_index", definition: "iterm_tab_index INTEGER")
        try ensureColumnExists(table: "windows", name: "tmux_window_id", definition: "tmux_window_id TEXT")
        try ensureColumnExists(table: "agent_windows", name: "tmux_window_id", definition: "tmux_window_id TEXT")
        try ensureColumnExists(table: "agent_windows", name: "yabai_window_id", definition: "yabai_window_id INTEGER")
        // Legacy Codex desktop records cannot be focused once terminal-only agent support is enabled.
        try execute(sql: "DELETE FROM agent_windows WHERE provider = 'codex'", bindings: [])
        // Migrate legacy color-based status values to semantic names
        try execute(sql: "UPDATE status_results SET status = 'passed' WHERE status = 'green'", bindings: [])
        try execute(sql: "UPDATE status_results SET status = 'failed' WHERE status = 'red'", bindings: [])
    }

    private func ensureColumnExists(table: String, name: String, definition: String) throws {
        let existing = try queryRows(sql: "PRAGMA table_info(\(table))").compactMap { $0.count > 1 ? $0[1] : nil }
        if existing.contains(name) { return }
        try execute(sql: "ALTER TABLE \(table) ADD COLUMN \(definition)", bindings: [])
    }

    private func decodeProjectWithTemplates(row: [String]) throws -> ProjectRecord? {
        guard row.count >= 7 else { return nil }
        let id = row[0]
        let ports = try queryRows(sql: "SELECT name FROM project_port_definitions WHERE project_id = ? ORDER BY order_index", bindings: [id]).map {
            PortDefinition(name: $0[0])
        }
        let processes = try queryRows(
            sql: "SELECT name, command, on_exit FROM project_processes WHERE project_id = ? ORDER BY order_index", bindings: [id]
        ).map { row in ProcessTemplate(name: row[0].isEmpty ? nil : row[0], command: row[1], onExit: ProcessExitAction(rawValue: row[2]) ?? .none) }
        let statusChecks = try queryRows(
            sql: "SELECT name, process, command, interval, timeout, on_fail FROM project_status_checks WHERE project_id = ? ORDER BY order_index",
            bindings: [id]
        ).map { row in
            StatusCheckDefinition(
                name: row[0].isEmpty ? nil : row[0], process: row[1], command: row[2],
                interval: Int(row[3]) ?? PollingConstants.statusCheckDefaultInterval,
                timeout: Int(row[4]) ?? PollingConstants.statusCheckDefaultTimeout, onFail: OnFailAction(rawValue: row[5]) ?? .none)
        }
        let browserSessions = try queryRows(
            sql: "SELECT name, url FROM project_browser_sessions WHERE project_id = ? ORDER BY order_index", bindings: [id]
        ).map { row in BrowserSession(name: row[0].isEmpty ? nil : row[0], url: row[1].isEmpty ? nil : row[1]) }
        return ProjectRecord(
            id: id, name: row[1], dir: row[2], isGitRepo: row[3] == "1", defaultBranch: row[4].isEmpty ? nil : row[4],
            setupScript: row[5].isEmpty ? nil : row[5], stopScript: row[6].isEmpty ? nil : row[6], ports: ports, processes: processes,
            statusChecks: statusChecks, browserSessions: browserSessions)
    }

    private func decodeWorkspace(row: [String]) -> WorkspaceRecord? {
        guard row.count >= 13 else { return nil }
        return WorkspaceRecord(
            id: row[0], projectID: row[1], name: row[2], dir: row[3], dirname: row[4].isEmpty ? nil : row[4], branch: row[5].isEmpty ? nil : row[5],
            targetBranch: row[6].isEmpty ? nil : row[6], isDefault: row[7] == "1", isArchived: row[8] == "1", isActive: row[9] != "0",
            isRunning: row[10] == "1", lastLaunchedAt: row[11].isEmpty ? nil : row[11], tooltip: row[12].isEmpty ? nil : row[12])
    }

    private func decodeRunningProcess(row: [String]) -> RunningProcessRecord? {
        guard row.count >= 15 else { return nil }
        return RunningProcessRecord(
            id: row[0], workspaceID: row[1], templateName: row[2], command: row[3], terminalApp: row[4].isEmpty ? nil : row[4], windowID: Int(row[5]),
            itermSessionID: row[6].isEmpty ? nil : row[6], itermTabIndex: Int(row[7]), tmuxWindowID: row[8].isEmpty ? nil : row[8],
            pid: Int(row[9]), status: RunningProcessState(rawValue: row[10]) ?? .running, logPath: row[11].isEmpty ? nil : row[11],
            lastOutputAt: row[12].isEmpty ? nil : row[12], startedAt: row[13].isEmpty ? nil : row[13], exitedAt: row[14].isEmpty ? nil : row[14])
    }

    private func decodeWindow(row: [String]) -> WindowRecord? {
        guard row.count >= 12 else { return nil }
        return WindowRecord(
            id: row[0], workspaceID: row[1], app: row[2], title: row[3].isEmpty ? nil : row[3], targetURL: row[4].isEmpty ? nil : row[4],
            windowID: Int(row[5]), itermSessionID: row[6].isEmpty ? nil : row[6], itermTabIndex: Int(row[7]),
            tmuxWindowID: row[8].isEmpty ? nil : row[8], role: row[9], orderIndex: Int(row[10]) ?? 0, lastSeenAt: row[11])
    }

    private func executeBatch(sql: String) throws {
        var attempts = 0
        while true {
            let result = sqlite3_exec(db, sql, nil, nil, nil)
            if result == SQLITE_OK { return }
            if isBusyOrLocked(result), attempts < busyRetryAttempts {
                attempts += 1
                Thread.sleep(forTimeInterval: busyRetryDelaySeconds)
                continue
            }
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.store", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func execute(sql: String, bindings: [Any]) throws {
        let statement = try prepareStatement(sql: sql, errorCode: 3)
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        if try stepWithRetry(statement: statement) != SQLITE_DONE {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.store", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func queryRow(sql: String, bindings: [Any] = []) throws -> [String]? {
        let statement = try prepareStatement(sql: sql, errorCode: 5)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = try stepWithRetry(statement: statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.store", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return extractRow(statement: statement)
    }

    private func queryRows(sql: String, bindings: [Any] = []) throws -> [[String]] {
        let statement = try prepareStatement(sql: sql, errorCode: 7)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [[String]] = []
        while true {
            let result = try stepWithRetry(statement: statement)
            if result == SQLITE_ROW {
                rows.append(extractRow(statement: statement))
                continue
            }
            if result == SQLITE_DONE { break }
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.store", code: 8, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return rows
    }

    private func configureConnectionPragmas() throws {
        try executeBatch(sql: "PRAGMA journal_mode=WAL;")
        try executeBatch(sql: "PRAGMA synchronous=NORMAL;")
        try executeBatch(sql: "PRAGMA foreign_keys=ON;")
    }

    private func prepareStatement(sql: String, errorCode: Int) throws -> OpaquePointer {
        var attempts = 0
        while true {
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            if result == SQLITE_OK, let statement { return statement }
            if isBusyOrLocked(result), attempts < busyRetryAttempts {
                attempts += 1
                Thread.sleep(forTimeInterval: busyRetryDelaySeconds)
                continue
            }
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.store", code: errorCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func stepWithRetry(statement: OpaquePointer) throws -> Int32 {
        var attempts = 0
        while true {
            let result = sqlite3_step(statement)
            if isBusyOrLocked(result), attempts < busyRetryAttempts {
                attempts += 1
                Thread.sleep(forTimeInterval: busyRetryDelaySeconds)
                continue
            }
            return result
        }
    }

    private func isBusyOrLocked(_ code: Int32) -> Bool { code == SQLITE_BUSY || code == SQLITE_LOCKED }

    private func extractRow(statement: OpaquePointer) -> [String] {
        let columnCount = Int(sqlite3_column_count(statement))
        var row: [String] = []
        row.reserveCapacity(columnCount)
        for idx in 0..<columnCount {
            let text = sqlite3_column_text(statement, Int32(idx))
            row.append(text.map { String(cString: $0) } ?? "")
        }
        return row
    }

    private func bind(_ bindings: [Any], to statement: OpaquePointer) throws {
        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, slot, text, -1, sqliteTransient)
            default: throw NSError(domain: "muxy.store", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unsupported binding type"])
            }
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
