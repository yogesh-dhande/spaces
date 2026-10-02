import Foundation
import spacesdevicecore

/// Alert state the device holds for every client: dismissed alert keys and Come Back Later flags. Writes
/// go through `withImmediateTransaction`, so each commit raises the database-change signal that pushes a
/// fresh overview to paired clients.
extension SQLiteStore {
    public func alertDismissalKeys() throws -> Set<String> {
        Set(try queryRows(sql: "SELECT alert_key FROM alert_dismissals").compactMap(\.first))
    }

    public func comeBackLaterFlags() throws -> [SpacesDeviceComeBackLaterFlag] {
        try queryRows(sql: "SELECT row_kind, row_id, flagged_at FROM come_back_later_flags ORDER BY flagged_at, row_kind, row_id").compactMap { row in
            guard row.count == 3, let rowKind = SpacesDeviceComeBackLaterRowKind(rawValue: row[0]) else { return nil }
            return SpacesDeviceComeBackLaterFlag(rowKind: rowKind, rowID: row[1], flaggedAt: row[2])
        }
    }

    /// Applies one alert-state change atomically: records `dismissing` (keys already recorded keep their
    /// original time), deletes the flags named by `clearingFlags`, and deletes the stored dismissals named
    /// by `pruning`. The caller decides what each set holds and skips the call when all are empty, so a
    /// change that does nothing writes nothing and raises no signal.
    public func applyAlertStateChange(
        dismissing: [String], dismissedAt: String, clearingFlags: [(rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String)],
        pruning: [String]
    ) throws {
        try withImmediateTransaction {
            for key in dismissing {
                try execute(sql: "INSERT OR IGNORE INTO alert_dismissals(alert_key, dismissed_at) VALUES (?, ?)", bindings: [key, dismissedAt])
            }
            for flag in clearingFlags {
                try execute(sql: "DELETE FROM come_back_later_flags WHERE row_kind = ? AND row_id = ?", bindings: [flag.rowKind.rawValue, flag.rowID])
            }
            for key in pruning { try execute(sql: "DELETE FROM alert_dismissals WHERE alert_key = ?", bindings: [key]) }
        }
    }

    /// Flags a row, or refreshes the time of a flag already on it.
    public func setComeBackLaterFlag(rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String, flaggedAt: String) throws {
        try withImmediateTransaction {
            try execute(
                sql: """
                    INSERT INTO come_back_later_flags(row_kind, row_id, flagged_at) VALUES (?, ?, ?)
                    ON CONFLICT(row_kind, row_id) DO UPDATE SET flagged_at = excluded.flagged_at
                    """, bindings: [rowKind.rawValue, rowID, flaggedAt])
        }
    }
}
