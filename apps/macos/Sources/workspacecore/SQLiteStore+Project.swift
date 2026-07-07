import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
    /// Canonical column order for a full `projects` row read; reused by every SELECT and by the
    /// INSERT below since both list the same 7 columns in the same order.
    private static let projectColumns = "id, name, dir, is_git, default_branch, setup_script, stop_script"

    public func upsert(project: ProjectRecord) throws {
        let normalizedServiceDefinitions = try validatedServiceDefinitions(project.ports)
        try withImmediateTransaction {
            try execute(
                sql: """
                    INSERT INTO projects(\(Self.projectColumns))
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
            try execute(sql: "DELETE FROM project_services WHERE project_id = ?", bindings: [project.id])
            for (index, definition) in normalizedServiceDefinitions.enumerated() {
                try execute(
                    sql: "INSERT INTO project_services(id, project_id, name, order_index) VALUES (?, ?, ?, ?)",
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
                    SELECT \(Self.projectColumns)
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
                    SELECT \(Self.projectColumns)
                    FROM projects
                    WHERE dir = ?
                    """, bindings: [dir])
        else { return nil }
        return try decodeProjectWithTemplates(row: row)
    }

    public func projects() throws -> [ProjectRecord] {
        let rows = try queryRows(
            sql: """
                SELECT \(Self.projectColumns)
                FROM projects
                ORDER BY name
                """)
        return try rows.compactMap { try decodeProjectWithTemplates(row: $0) }
    }

    public func deleteProject(id: String) throws {
        try withImmediateTransaction {
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
            try execute(
                sql: "DELETE FROM workspace_service_ports WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(sql: "DELETE FROM workspace_services WHERE workspace_id IN (SELECT id FROM workspaces WHERE project_id = ?)", bindings: [id])
            try execute(sql: "DELETE FROM workspaces WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM project_services WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM project_processes WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM project_browser_sessions WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM project_agent_launchers WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM ignored_worktrees WHERE project_id = ?", bindings: [id])
            try execute(sql: "DELETE FROM projects WHERE id = ?", bindings: [id])
        }
    }

    func decodeProjectWithTemplates(row: [String]) throws -> ProjectRecord? {
        guard row.count >= 7 else { return nil }
        let id = row[0]
        let portRows = try queryRows(sql: "SELECT id, name FROM project_services WHERE project_id = ? ORDER BY order_index", bindings: [id])
        let ports = portRows.map { row in ServiceDefinition(id: row[0].isEmpty ? UUID().uuidString : row[0], name: row[1]) }
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
            id: id, name: row[1], dir: row[2], isGitRepo: row[3] == "1", defaultBranch: row[4].isEmpty ? nil : row[4],
            setupScript: row[5].isEmpty ? nil : row[5], stopScript: row[6].isEmpty ? nil : row[6], ports: ports, processes: processes,
            browserSessions: browserSessions, agentLaunchers: agentLaunchers)
    }
}
