import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
    public func setWorkspaceBrowserSessions(workspaceID: String, sessions: [BrowserSession]) throws {
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_browser_sessions WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, session) in sessions.enumerated() {
                try execute(
                    sql: """
                        INSERT INTO workspace_browser_sessions(workspace_id, name, url, order_index)
                        VALUES (?, ?, ?, ?)
                        """,
                    bindings: [workspaceID, session.name ?? "", session.url ?? "", String(index)])
            }
        }
    }

    public func workspaceBrowserSessions(workspaceID: String) throws -> [BrowserSession] {
        let rows = try queryRows(
            sql: """
                SELECT name, url
                FROM workspace_browser_sessions
                WHERE workspace_id = ?
                ORDER BY order_index
                """, bindings: [workspaceID])
        return rows.map { row in
            BrowserSession(name: row[0].isEmpty ? nil : row[0], url: row[1].isEmpty ? nil : row[1])
        }
    }
}
