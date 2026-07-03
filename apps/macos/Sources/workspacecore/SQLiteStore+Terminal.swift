import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
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
                        try matchingRuntimeTargetID(workspaceID: window.workspaceID, trackingID: window.terminalTrackingID) ?? window.id
                    }
                } else { window.id }
            let baseBindings: [Any] = [
                runtimeTargetID, window.workspaceID, targetType, window.name ?? "", window.detail ?? "", window.app,
                window.terminalNativeID ?? window.terminalTrackingID ?? "", String(window.orderIndex), window.lastSeenAt, window.lastSeenAt,
            ]
            try execute(
                sql: """
                    INSERT INTO runtime_targets(
                      id, workspace_id, type, name, detail, app, tracking_id, order_index, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      workspace_id = excluded.workspace_id,
                      type = excluded.type,
                      name = excluded.name,
                      detail = excluded.detail,
                      app = excluded.app,
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

    public func deleteWindows(workspaceID: String) throws {
        try execute(sql: "DELETE FROM runtime_targets WHERE workspace_id = ?", bindings: [workspaceID])
    }

    public func deleteWindow(id: String) throws { try execute(sql: "DELETE FROM runtime_targets WHERE id = ?", bindings: [id]) }

    func decodeWindow(row: [String]) -> WindowRecord? {
        guard row.count >= 10 else { return nil }
        let targetURL = row[5].isEmpty ? nil : row[5]
        let trackingID = row[6].isEmpty ? nil : row[6]
        let role = row[7]
        return WindowRecord(
            id: row[0], workspaceID: row[1], app: row[2], name: row[3].isEmpty ? nil : row[3], detail: row[4].isEmpty ? nil : row[4],
            targetURL: targetURL, terminalTrackingID: trackingID,
            terminalNativeID: trackingID, role: role, orderIndex: Int(row[8]) ?? 0, lastSeenAt: row[9])
    }
}
