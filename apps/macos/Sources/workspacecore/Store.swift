import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

public final class SQLiteStore {
    private let db: OpaquePointer
    private let databasePath: String
    private let busyTimeoutMS: Int32 = 5000
    private let busyRetryAttempts = 10
    private let busyRetryDelaySeconds: TimeInterval = 0.02

    public init(path: String) throws {
        databasePath = path
        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, openFlags, nil) != SQLITE_OK {
            throw NSError(domain: "spaces.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed opening sqlite db at \(path)"])
        }
        guard let handle else { throw NSError(domain: "spaces.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "DB handle is nil"]) }
        db = handle
        guard sqlite3_busy_timeout(db, busyTimeoutMS) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "spaces.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed configuring sqlite busy timeout: \(message)"])
        }
        try configureConnectionPragmas()
        try initializeSchema()
    }

    deinit { sqlite3_close(db) }

    func withImmediateTransaction<T>(_ body: () throws -> T) throws -> T {
        try executeBatch(sql: "BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try executeBatch(sql: "COMMIT;")
            return value
        } catch {
            try? executeBatch(sql: "ROLLBACK;")
            throw error
        }
    }

    public func upsert(project: ProjectRecord) throws {
        let normalizedPortDefinitions = try validatedPortDefinitions(project.ports)
        try withImmediateTransaction {
            try execute(
                sql: """
                    INSERT INTO projects(id, name, dir, is_git, default_branch, is_collapsed, setup_script, stop_script)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      name = excluded.name,
                      dir = excluded.dir,
                      is_git = excluded.is_git,
                      default_branch = excluded.default_branch,
                      is_collapsed = excluded.is_collapsed,
                      setup_script = excluded.setup_script,
                      stop_script = excluded.stop_script
                    """,
                bindings: [
                    project.id, project.name, project.dir, project.isGitRepo ? "1" : "0", project.defaultBranch ?? "",
                    project.isCollapsed ? "1" : "0", project.setupScript ?? "", project.stopScript ?? "",
                ])
            try execute(sql: "DELETE FROM project_port_definitions WHERE project_id = ?", bindings: [project.id])
            for (index, definition) in normalizedPortDefinitions.enumerated() {
                try execute(
                    sql: "INSERT INTO project_port_definitions(id, project_id, name, order_index) VALUES (?, ?, ?, ?)",
                    bindings: [definition.id, project.id, definition.name, String(index)])
            }
            try execute(sql: "DELETE FROM project_processes WHERE project_id = ?", bindings: [project.id])
            for (index, process) in project.processes.enumerated() {
                try execute(
                    sql: "INSERT INTO project_processes(id, project_id, name, command, on_exit, order_index) VALUES (?, ?, ?, ?, ?, ?)",
                    bindings: [process.id, project.id, process.name ?? "", process.command, process.onExit.rawValue, String(index)])
            }
            try execute(sql: "DELETE FROM project_browser_sessions WHERE project_id = ?", bindings: [project.id])
            for (index, session) in project.browserSessions.enumerated() {
                try execute(
                    sql: "INSERT INTO project_browser_sessions(project_id, name, url, order_index) VALUES (?, ?, ?, ?)",
                    bindings: [project.id, session.name ?? "", session.url ?? "", String(index)])
            }
            try execute(sql: "DELETE FROM project_agent_launchers WHERE project_id = ?", bindings: [project.id])
            for (index, launcher) in project.agentLaunchers.enumerated() {
                try execute(
                    sql: "INSERT INTO project_agent_launchers(project_id, id, name, command, order_index) VALUES (?, ?, ?, ?, ?)",
                    bindings: [project.id, launcher.id, launcher.name, launcher.command, String(index)])
            }
        }
    }

    public func project(id: String) throws -> ProjectRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, name, dir, is_git, default_branch, is_collapsed, setup_script, stop_script
                    FROM projects
                    WHERE id = ?
                    """, bindings: [id])
        else { return nil }
        return try decodeProjectWithTemplates(row: row)
    }

    public func project(dir: String) throws -> ProjectRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, name, dir, is_git, default_branch, is_collapsed, setup_script, stop_script
                    FROM projects
                    WHERE dir = ?
                    """, bindings: [dir])
        else { return nil }
        return try decodeProjectWithTemplates(row: row)
    }

    public func projects() throws -> [ProjectRecord] {
        let rows = try queryRows(
            sql: """
                SELECT id, name, dir, is_git, default_branch, is_collapsed, setup_script, stop_script
                FROM projects
                ORDER BY name
                """)
        return try rows.compactMap { try decodeProjectWithTemplates(row: $0) }
    }

    public func deleteProject(id: String) throws {
        try withImmediateTransaction {
            try execute(
                sql:
                    "DELETE FROM runtime_target_events WHERE runtime_target_id IN (SELECT id FROM runtime_targets WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?))",
                bindings: [id])
            try execute(
                sql:
                    "DELETE FROM agent_session_events WHERE agent_session_id IN (SELECT id FROM agent_sessions WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?))",
                bindings: [id])
            try execute(sql: "DELETE FROM agent_sessions WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(sql: "DELETE FROM runtime_targets WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(sql: "DELETE FROM workspace_settings WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(sql: "DELETE FROM workspace_processes WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(
                sql: "DELETE FROM workspace_browser_sessions WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(
                sql: "DELETE FROM workspace_agent_launchers WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(sql: "DELETE FROM running_processes WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(
                sql: "DELETE FROM workspace_port_definitions WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(sql: "DELETE FROM workspaces WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM project_port_definitions WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM project_processes WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM project_browser_sessions WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM project_agent_launchers WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM ignored_worktrees WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM projects WHERE id = ?", bindings: [id])
        }
    }

    public func upsert(workspace: WorkspaceRecord) throws {
        try withImmediateTransaction {
            try execute(
                sql: """
                    INSERT INTO workspaces(id, project_id, title, dir, runtime_path, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, notes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      title = excluded.title,
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
                    workspace.id, workspace.projectID, workspace.title, workspace.dir, workspace.runtimePath, workspace.dirname ?? "",
                    workspace.branch ?? "", workspace.baseBranch ?? "", workspace.isDefault ? "1" : "0", workspace.isArchived ? "1" : "0",
                    workspace.isHidden ? "1" : "0", workspace.isRunning ? "1" : "0", workspace.lastLaunchedAt ?? "", workspace.notes ?? "",
                ])
            try execute(sql: "DELETE FROM ignored_worktrees WHERE worktree_dir = ?", bindings: [workspace.dir])
        }
    }

    public func workspace(id: String) throws -> WorkspaceRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, project_id, title, dir, runtime_path, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, notes
                    FROM workspaces WHERE id = ?
                    """, bindings: [id])
        else { return nil }
        return decodeWorkspace(row: row)
    }

    public func workspace(projectID: String, title: String) throws -> WorkspaceRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, project_id, title, dir, runtime_path, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, notes
                    FROM workspaces WHERE project_id = ? AND title = ?
                    """, bindings: [projectID, title])
        else { return nil }
        return decodeWorkspace(row: row)
    }

    public func workspace(dir: String) throws -> WorkspaceRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT id, project_id, title, dir, runtime_path, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, notes
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
                SELECT id, project_id, title, dir, runtime_path, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, notes
                FROM workspaces
                WHERE project_id = ? AND (? = '1' OR is_archived = 0)
                ORDER BY is_default DESC, title
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
            try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM workspace_port_definitions WHERE workspace_id = ?", bindings: [id])
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

    public func upsert(spacesDevice: SpacesDeviceRecord) throws {
        guard spacesDevice.isLocal else {
            throw WorkspaceError.invalidArgument(message: "Remote device records are not stored in this daemon database.")
        }
    }

    public func spacesDevice(id: String) throws -> SpacesDeviceRecord? { id == SpacesDeviceRecord.localDeviceID ? SpacesDeviceRecord.local() : nil }

    public func spacesDevices() throws -> [SpacesDeviceRecord] { [SpacesDeviceRecord.local()] }

    public func deleteSpacesDevice(id: String) throws {
        guard id != SpacesDeviceRecord.localDeviceID else {
            throw WorkspaceError.invalidArgument(message: "The local device record cannot be removed.")
        }
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

    public func updateProjectCollapsed(id: String, isCollapsed: Bool) throws {
        try execute(sql: "UPDATE projects SET is_collapsed = ? WHERE id = ?", bindings: [isCollapsed ? "1" : "0", id])
    }

    public func updateWorkspaceName(id: String, name: String) throws {
        try execute(sql: "UPDATE workspaces SET title = ? WHERE id = ?", bindings: [name, id])
    }

    public func setWorkspacePorts(workspaceID: String, ports: [Int], names: [String] = [], definitionIDs: [String] = []) throws {
        let normalizedNames = try validatedPortNames(names, expectedCount: ports.count)
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, port) in ports.enumerated() {
                let name = normalizedNames[index]
                let definitionID = index < definitionIDs.count ? definitionIDs[index] : ""
                try execute(
                    sql: "INSERT INTO workspace_ports(workspace_id, port_index, port_number, port_name, definition_id) VALUES (?, ?, ?, ?, ?)",
                    bindings: [workspaceID, String(index), String(port), name, definitionID])
            }
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

    public func workspacePortsAssigned(workspaceID: String) throws -> [(definitionID: String, port: Int, name: String)] {
        let rows = try queryRows(
            sql: "SELECT definition_id, port_number, port_name FROM workspace_ports WHERE workspace_id = ? ORDER BY port_index",
            bindings: [workspaceID])
        return rows.compactMap { row in
            guard row.count >= 3, let port = Int(row[1]) else { return nil }
            return (definitionID: row[0], port: port, name: row[2])
        }
    }

    public func setWorkspacePortDefinitions(workspaceID: String, definitions: [PortDefinition]) throws {
        let normalizedDefinitions = try validatedPortDefinitions(definitions)
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_port_definitions WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, definition) in normalizedDefinitions.enumerated() {
                try execute(
                    sql: "INSERT INTO workspace_port_definitions(id, workspace_id, name, order_index) VALUES (?, ?, ?, ?)",
                    bindings: [definition.id, workspaceID, definition.name, String(index)])
            }
        }
    }

    public func workspacePortDefinitions(workspaceID: String) throws -> [PortDefinition] {
        let rows = try queryRows(
            sql: "SELECT id, name FROM workspace_port_definitions WHERE workspace_id = ? ORDER BY order_index", bindings: [workspaceID])
        return rows.compactMap { row in
            guard row.count >= 2 else { return nil }
            return PortDefinition(id: row[0].isEmpty ? UUID().uuidString : row[0], name: row[1])
        }
    }

    private func validatedPortDefinitions(_ definitions: [PortDefinition]) throws -> [PortDefinition] {
        try definitions.map { definition in
            let trimmedName = try validatedPortName(definition.name)
            return PortDefinition(id: definition.id, name: trimmedName)
        }
    }

    private func validatedPortNames(_ names: [String], expectedCount: Int) throws -> [String] {
        guard names.count == expectedCount else {
            throw NSError(
                domain: "spaces.store", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected \(expectedCount) port names for \(expectedCount) stored ports, got \(names.count)."])
        }
        return try names.map(validatedPortName)
    }

    private func validatedPortName(_ name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(domain: "spaces.store", code: 2, userInfo: [NSLocalizedDescriptionKey: "Port name is required."])
        }
        return trimmedName
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

    public func setWorkspaceBrowserSessions(workspaceID: String, sessions: [BrowserSession]) throws {
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_browser_sessions WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, session) in sessions.enumerated() {
                let extractedWindowID = session.extractedWindow.map { String($0.windowID) } ?? ""
                let extractedWindowValid = (session.extractedWindow?.isValid ?? false) ? "1" : "0"
                let extractedTargetURL = session.extractedWindow?.targetURL ?? ""
                try execute(
                    sql: """
                        INSERT INTO workspace_browser_sessions(workspace_id, name, url, extracted_target_url, extracted_window_id, extracted_window_valid, order_index)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    bindings: [
                        workspaceID, session.name ?? "", session.url ?? "", extractedTargetURL, extractedWindowID, extractedWindowValid,
                        String(index),
                    ])
            }
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
            try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id = ?", bindings: [workspaceID])
            try execute(sql: "DELETE FROM workspace_port_definitions WHERE workspace_id = ?", bindings: [workspaceID])
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

    public func releaseWorkspacePorts(workspaceID: String) throws {
        try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id = ?", bindings: [workspaceID])
    }

    public func upsert(runningProcess: RunningProcessRecord) throws {
        let runtimeTargetID =
            try runningProcess.runtimeTargetID
            ?? matchingRuntimeTargetID(
                workspaceID: runningProcess.workspaceID, trackingID: runningProcess.terminalTrackingID, windowID: runningProcess.windowID)
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
                  COALESCE(rt.window_id, ''),
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

    public func upsert(window: WindowRecord) throws {
        try withImmediateTransaction {
            let targetType = window.role == "browser" ? "browser" : "terminal"
            let hasExistingTargetID =
                (try queryRow(sql: "SELECT id FROM runtime_targets WHERE id = ? AND workspace_id = ?", bindings: [window.id, window.workspaceID]))
                != nil
            let runtimeTargetID =
                if targetType == "terminal" {
                    if hasExistingTargetID {
                        window.id
                    } else {
                        try matchingRuntimeTargetID(workspaceID: window.workspaceID, trackingID: window.terminalTrackingID, windowID: window.windowID)
                            ?? window.id
                    }
                } else { window.id }
            let baseBindings: [Any] = [
                runtimeTargetID, window.workspaceID, targetType, window.name ?? "", window.detail ?? "", window.app,
                window.windowID.map(String.init) ?? "", window.terminalNativeID ?? window.terminalTrackingID ?? "", String(window.orderIndex),
                window.lastSeenAt, window.lastSeenAt,
            ]
            try execute(
                sql: """
                    INSERT INTO runtime_targets(
                      id, workspace_id, type, name, detail, app, window_id, tracking_id, order_index, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      workspace_id = excluded.workspace_id,
                      type = excluded.type,
                      name = excluded.name,
                      detail = excluded.detail,
                      app = excluded.app,
                      window_id = excluded.window_id,
                      tracking_id = excluded.tracking_id,
                      order_index = excluded.order_index,
                      updated_at = excluded.updated_at
                    """, bindings: baseBindings)
            if targetType == "terminal" {
                try execute(sql: "DELETE FROM browser_targets WHERE runtime_target_id = ?", bindings: [runtimeTargetID])
            } else {
                try execute(sql: "UPDATE runtime_targets SET tracking_id = '' WHERE id = ?", bindings: [runtimeTargetID])
                try execute(
                    sql: """
                        INSERT INTO browser_targets(runtime_target_id, target_url, resolved_url)
                        VALUES (?, ?, ?)
                        ON CONFLICT(runtime_target_id) DO UPDATE SET
                          target_url = excluded.target_url,
                          resolved_url = excluded.resolved_url
                        """, bindings: [runtimeTargetID, window.targetURL ?? "", window.detail ?? ""])
            }
        }
    }

    public func windows(workspaceID: String) throws -> [WindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT
                  rt.id,
                  rt.workspace_id,
                  rt.app,
                  rt.name,
                  rt.detail,
                  COALESCE(bt.target_url, ''),
                  rt.window_id,
                  COALESCE(rt.tracking_id, ''),
                  CASE WHEN rt.type = 'browser' THEN 'browser' ELSE 'terminal' END,
                  rt.order_index,
                  rt.updated_at
                FROM runtime_targets rt
                LEFT JOIN browser_targets bt ON bt.runtime_target_id = rt.id
                WHERE rt.workspace_id = ?
                ORDER BY rt.order_index
                """, bindings: [workspaceID])
        return rows.compactMap { decodeWindow(row: $0) }
    }

    public func windows(windowID: Int) throws -> [WindowRecord] {
        let rows = try queryRows(
            sql: """
                SELECT
                  rt.id,
                  rt.workspace_id,
                  rt.app,
                  rt.name,
                  rt.detail,
                  COALESCE(bt.target_url, ''),
                  rt.window_id,
                  COALESCE(rt.tracking_id, ''),
                  CASE WHEN rt.type = 'browser' THEN 'browser' ELSE 'terminal' END,
                  rt.order_index,
                  rt.updated_at
                FROM runtime_targets rt
                LEFT JOIN browser_targets bt ON bt.runtime_target_id = rt.id
                WHERE rt.window_id = ?
                ORDER BY rt.updated_at DESC, rt.order_index
                """, bindings: [String(windowID)])
        return rows.compactMap { decodeWindow(row: $0) }
    }

    public func workspaceID(windowID: Int) throws -> String? {
        let row = try queryRow(
            sql: "SELECT workspace_id FROM runtime_targets WHERE window_id = ? ORDER BY updated_at DESC LIMIT 1", bindings: [String(windowID)])
        return row?.first
    }

    public func workspaceIDForTerminalSession(_ sessionID: String) throws -> String? {
        let row = try queryRow(
            sql: """
                SELECT workspace_id
                FROM (
                  SELECT rt.workspace_id, rt.updated_at AS resolved_at, rt.order_index AS resolved_order, 0 AS source_priority
                  FROM runtime_targets rt
                  WHERE rt.tracking_id = ?

                  UNION ALL

                  SELECT rp.workspace_id, COALESCE(rt.updated_at, rp.exited_at, rp.last_output_at, rp.started_at, '') AS resolved_at,
                         COALESCE(rt.order_index, 100000) AS resolved_order, 1 AS source_priority
                  FROM running_processes rp
                  LEFT JOIN runtime_targets rt ON rt.id = rp.runtime_target_id
                  WHERE rp.terminal_session_id = ?

                  UNION ALL

                  SELECT agent_sessions.workspace_id, COALESCE(runtime_targets.updated_at, agent_sessions.updated_at, agent_sessions.created_at) AS resolved_at,
                         COALESCE(runtime_targets.order_index, 200000) AS resolved_order, 2 AS source_priority
                  FROM agent_sessions
                  LEFT JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                  WHERE agent_sessions.terminal_session_id = ?

                  UNION ALL

                  SELECT terminal_sessions.workspace_id, terminal_sessions.created_at AS resolved_at, 300000 AS resolved_order, 3 AS source_priority
                  FROM terminal_sessions
                  WHERE terminal_sessions.session_id = ?
                    AND terminal_sessions.workspace_id IS NOT NULL
                )
                ORDER BY source_priority, resolved_at DESC, resolved_order
                LIMIT 1
                """, bindings: [sessionID, sessionID, sessionID, sessionID])
        return row?.first
    }

    public func workspaceIDForAgentWindow(yabaiWindowID: Int) throws -> String? {
        let row = try queryRow(
            sql: """
                SELECT agent_sessions.workspace_id
                FROM agent_sessions
                JOIN runtime_targets ON runtime_targets.id = agent_sessions.runtime_target_id
                WHERE runtime_targets.window_id = ?
                ORDER BY agent_sessions.updated_at DESC
                LIMIT 1
                """, bindings: [String(yabaiWindowID)])
        return row?.first
    }

    public func deleteWindows(workspaceID: String) throws {
        try execute(sql: "DELETE FROM runtime_targets WHERE workspace_id = ?", bindings: [workspaceID])
    }

    public func deleteWindow(id: String) throws { try execute(sql: "DELETE FROM runtime_targets WHERE id = ?", bindings: [id]) }

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
                  COALESCE(runtime_targets.window_id, ''),
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
                      COALESCE(runtime_targets.window_id, ''),
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
                  COALESCE(runtime_targets.window_id, ''),
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

    private func decodeAgentWindow(row: [String]) -> AgentWindowRecord? {
        guard row.count >= 17 else { return nil }
        guard let provider = AgentProvider(rawValue: row[2]) else { return nil }
        let terminalSessionID = row[10].isEmpty ? nil : row[10]
        let status = AgentWindowStatus(rawValue: row[14]) ?? .idle
        let terminalTarget = decodeTerminalTarget(
            runtimeTargetID: row[4], app: row[5].isEmpty && terminalSessionID != nil ? TerminalHost.spaces.appName : row[5], name: row[6],
            detail: row[7], windowID: row[8], trackingID: row[9].isEmpty ? row[10] : row[9])
        return AgentWindowRecord(
            id: row[0], workspaceID: row[1], provider: provider, label: row[3].isEmpty ? nil : row[3], runtimeTargetID: row[4].isEmpty ? nil : row[4],
            terminalTarget: terminalTarget, sessionKey: row[11].isEmpty ? nil : row[11], claimedLauncherID: row[12].isEmpty ? nil : row[12],
            claimedLauncherName: row[13].isEmpty ? nil : row[13], status: status, createdAt: row[15], updatedAt: row[16])
    }

    private func spacesAgentTerminalSessionID(_ record: AgentWindowRecord) -> String? {
        guard record.provider == .spaces, let terminalTrackingID = record.terminalTrackingID, !terminalTrackingID.isEmpty else { return nil }
        return terminalTrackingID
    }

    private func createSchema() throws { try executeBatch(sql: DatabaseSchema.latestSchemaSQL) }

    private func initializeSchema() throws {
        let migrator = DatabaseMigrator(
            currentSchemaVersion: DatabaseSchema.currentVersion, steps: DatabaseSchema.migrationSteps,
            backupManager: DatabaseBackupManager(databaseURL: URL(fileURLWithPath: databasePath)))
        try migrator.migrateIfNeeded(
            existingTables: try userTableNames(), schemaVersion: try schemaVersionValue(), databasePath: databasePath, databaseHandle: db,
            createFreshSchema: { try self.createSchema() }, setSchemaVersion: { try self.setSchemaVersion($0) },
            withTransaction: { try self.withImmediateTransaction($0) }, validateIntegrity: { try self.validateIntegrity() })
    }

    private func schemaVersionValue() throws -> Int? {
        do {
            let rows = try queryRows(sql: "SELECT current_version FROM migration_state")
            guard let raw = rows.first?.first, let value = Int(raw) else { return nil }
            return value
        } catch { return nil }
    }

    private func setSchemaVersion(_ version: Int) throws {
        try execute(sql: "DELETE FROM migration_state", bindings: [])
        try execute(sql: "INSERT INTO migration_state(current_version) VALUES (?)", bindings: [String(version)])
    }

    private func userTableNames() throws -> [String] {
        try queryRows(
            sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """
        ).compactMap(\.first)
    }

    private func validateIntegrity() throws {
        guard let row = try queryRow(sql: "PRAGMA integrity_check"), row.first == "ok" else {
            throw NSError(domain: "spaces.store", code: 45, userInfo: [NSLocalizedDescriptionKey: "PRAGMA integrity_check failed"])
        }
    }

    private func decodeProjectWithTemplates(row: [String]) throws -> ProjectRecord? {
        guard row.count >= 8 else { return nil }
        let id = row[0]
        let portRows = try queryRows(sql: "SELECT id, name FROM project_port_definitions WHERE project_id = ? ORDER BY order_index", bindings: [id])
        let ports = portRows.map { row in PortDefinition(id: row[0].isEmpty ? UUID().uuidString : row[0], name: row[1]) }
        let processes = try queryRows(
            sql: "SELECT id, name, command, on_exit FROM project_processes WHERE project_id = ? ORDER BY order_index", bindings: [id]
        ).map { row in
            ProcessTemplate(
                id: row[0].isEmpty ? UUID().uuidString : row[0], name: row[1].isEmpty ? nil : row[1], command: row[2],
                onExit: ProcessExitAction(rawValue: row[3]) ?? .none)
        }
        let browserSessions = try queryRows(
            sql: "SELECT name, url FROM project_browser_sessions WHERE project_id = ? ORDER BY order_index", bindings: [id]
        ).map { row in BrowserSession(name: row[0].isEmpty ? nil : row[0], url: row[1].isEmpty ? nil : row[1]) }
        let agentLaunchers = try queryRows(
            sql: "SELECT id, name, command FROM project_agent_launchers WHERE project_id = ? ORDER BY order_index", bindings: [id]
        ).map { row in AgentLauncher(id: row[0].isEmpty ? UUID().uuidString : row[0], name: row[1], command: row[2]) }
        return ProjectRecord(
            id: id, name: row[1], dir: row[2], isGitRepo: row[3] == "1", defaultBranch: row[4].isEmpty ? nil : row[4], isCollapsed: row[5] == "1",
            setupScript: row[6].isEmpty ? nil : row[6], stopScript: row[7].isEmpty ? nil : row[7], ports: ports, processes: processes,
            browserSessions: browserSessions, agentLaunchers: agentLaunchers)
    }

    private func decodeWorkspace(row: [String]) -> WorkspaceRecord? {
        guard row.count >= 14 else { return nil }
        return WorkspaceRecord(
            id: row[0], projectID: row[1], title: row[2], dir: row[3], runtimePath: row[4].isEmpty ? row[3] : row[4],
            dirname: row[5].isEmpty ? nil : row[5], branch: row[6].isEmpty ? nil : row[6], baseBranch: row[7].isEmpty ? nil : row[7],
            isDefault: row[8] == "1", isArchived: row[9] == "1", isHidden: row[10] != "0", isRunning: row[11] == "1",
            lastLaunchedAt: row[12].isEmpty ? nil : row[12], notes: row[13].isEmpty ? nil : row[13])
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func decodeRunningProcess(row: [String]) -> RunningProcessRecord? {
        guard row.count >= 18 else { return nil }
        let terminalSessionID = row[11].isEmpty ? nil : row[11]
        let terminalApp = row[6].isEmpty && terminalSessionID != nil ? TerminalHost.spaces.appName : row[6]
        let terminalTarget = decodeTerminalTarget(
            runtimeTargetID: row[5], app: terminalApp, name: row[7], detail: row[8], windowID: row[9], trackingID: row[10].isEmpty ? row[11] : row[10]
        )
        return RunningProcessRecord(
            id: row[0], workspaceID: row[1], templateID: row[2].isEmpty ? nil : row[2], templateName: row[3], command: row[4],
            runtimeTargetID: row[5].isEmpty ? nil : row[5], terminalApp: terminalApp.isEmpty ? nil : terminalApp, terminalTarget: terminalTarget,
            pid: Int(row[12]), status: RunningProcessState(rawValue: row[13]) ?? .running, logPath: row[14].isEmpty ? nil : row[14],
            lastOutputAt: row[15].isEmpty ? nil : row[15], startedAt: row[16].isEmpty ? nil : row[16], exitedAt: row[17].isEmpty ? nil : row[17])
    }

    private func spacesTerminalSessionID(terminalApp: String?, terminalTrackingID: String?) -> String? {
        guard terminalApp == TerminalHost.spaces.appName, let terminalTrackingID, !terminalTrackingID.isEmpty else { return nil }
        return terminalTrackingID
    }

    private func decodeTerminalTarget(runtimeTargetID: String, app: String, name: String, detail: String, windowID: String, trackingID: String)
        -> TerminalTargetRecord?
    {
        guard !runtimeTargetID.isEmpty || !app.isEmpty || !trackingID.isEmpty || !windowID.isEmpty else { return nil }
        return TerminalTargetRecord(
            runtimeTargetID: runtimeTargetID.isEmpty ? nil : runtimeTargetID, windowID: Int(windowID),
            trackingID: trackingID.isEmpty ? nil : trackingID)
    }

    private func decodeWindow(row: [String]) -> WindowRecord? {
        guard row.count >= 11 else { return nil }
        return WindowRecord(
            id: row[0], workspaceID: row[1], app: row[2], name: row[3].isEmpty ? nil : row[3], detail: row[4].isEmpty ? nil : row[4],
            targetURL: row[5].isEmpty ? nil : row[5], windowID: Int(row[6]), terminalTrackingID: row[7].isEmpty ? nil : row[7],
            terminalNativeID: row[7].isEmpty ? nil : row[7], role: row[8], orderIndex: Int(row[9]) ?? 0, lastSeenAt: row[10])
    }

    private func ensureRuntimeTargetForRunningProcess(_ process: RunningProcessRecord, runtimeTargetID: String?) throws -> String? {
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

    private func ensureRuntimeTargetForAgentWindow(_ record: AgentWindowRecord) throws -> String? {
        let runtimeTargetID =
            try record.runtimeTargetID
            ?? matchingRuntimeTargetID(
                workspaceID: record.workspaceID, trackingID: record.terminalTrackingID, windowID: record.yabaiWindowID ?? record.windowID)
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

    private func preservesExistingTerminalMetadata(for record: AgentWindowRecord) throws -> Bool {
        if let sessionID = spacesAgentTerminalSessionID(record), let kind = try terminalSessionKind(sessionID: sessionID) { return kind == .shell }
        return record.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && record.claimedLauncherName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func terminalSessionKind(sessionID: String) throws -> TerminalSessionKind? {
        let row = try queryRow(sql: "SELECT kind FROM terminal_sessions WHERE session_id = ? LIMIT 1", bindings: [sessionID])
        guard let rawKind = row?.first, !rawKind.isEmpty else { return nil }
        return TerminalSessionKind(rawValue: rawKind)
    }

    private func nextRuntimeTargetOrderIndex(existing: [WindowRecord], role: String, orderOffset: Int) -> Int {
        let roleWindows = existing.filter { $0.role == role }
        let maxIndex = roleWindows.map(\.orderIndex).max() ?? (orderOffset - 1)
        return maxIndex + 1
    }

    private func matchingRuntimeTargetID(workspaceID: String, trackingID: String?, windowID: Int?) throws -> String? {
        let rows = try queryRows(
            sql: """
                SELECT
                  rt.id,
                  COALESCE(rt.tracking_id, ''),
                  COALESCE(rt.window_id, ''),
                  rt.updated_at
                FROM runtime_targets rt
                WHERE rt.workspace_id = ?
                  AND rt.type = 'terminal'
                ORDER BY rt.updated_at DESC
                """, bindings: [workspaceID])

        func firstMatch(_ predicate: ([String]) -> Bool) -> String? { rows.first(where: predicate)?.first }

        if let trackingID, !trackingID.isEmpty, let match = firstMatch({ $0[1] == trackingID }) { return match }
        let hasExplicitTerminalIdentity = trackingID?.isEmpty == false
        if !hasExplicitTerminalIdentity, let windowID, let match = firstMatch({ $0[2] == String(windowID) }) { return match }
        return nil
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
            throw NSError(domain: "spaces.store", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func execute(sql: String, bindings: [Any]) throws {
        let statement = try prepareStatement(sql: sql, errorCode: 3)
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        if try stepWithRetry(statement: statement) != SQLITE_DONE {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.store", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
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
            throw NSError(domain: "spaces.store", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
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
            throw NSError(domain: "spaces.store", code: 8, userInfo: [NSLocalizedDescriptionKey: message])
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
            throw NSError(domain: "spaces.store", code: errorCode, userInfo: [NSLocalizedDescriptionKey: message])
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
            default: throw NSError(domain: "spaces.store", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unsupported binding type"])
            }
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension Array { fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
