import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// Reads the schema version a database already records, without opening it for schema work.
///
/// A process that is waiting on *another* process's schema work needs the version that process has
/// committed so far, and it must not create, migrate, or otherwise change the file while it waits.
/// `SpacesSQLiteDatabase` cannot answer that: opening it runs the migrator, which is exactly the work
/// the waiter has been refused.
public enum DatabaseSchemaVersionReader {
    /// Returns the version recorded in `migration_state`, or `nil` while the database records none —
    /// the file is missing, the marker table has not been created yet, or the row is not written yet.
    /// A database another process is still creating looks exactly like that, and so does one whose
    /// migration transaction is in flight, so `nil` means "not recorded yet" rather than a fault.
    public static func recordedVersion(atPath path: String) -> Int? {
        var handle: OpaquePointer?
        // Opened read-write, and without `SQLITE_OPEN_CREATE`, so a database that does not exist yet
        // reads as "no version" instead of being conjured into existence here. Read-only would be the
        // narrower intent but cannot open a WAL database whose shared-memory index is absent.
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT current_version FROM migration_state", -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
