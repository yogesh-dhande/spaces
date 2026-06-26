import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
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
}
