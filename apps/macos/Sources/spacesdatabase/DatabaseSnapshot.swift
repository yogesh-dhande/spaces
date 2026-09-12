import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// Whole-database copies, and edits applied to a copy.
///
/// Both operations exist for one caller shape: something that has to read a database another process is
/// serving and then work on the result without that process ever noticing. `SpacesSQLiteDatabase` cannot
/// serve it, because opening a database through that wrapper migrates it to the schema version the running
/// build declares.
public enum DatabaseSnapshot {
    public static let errorDomain = "spaces.database.snapshot"

    /// Copies the database at `sourcePath` to `destinationPath` through SQLite's online backup API.
    ///
    /// The source is opened READ-ONLY and SQLite itself drives the copy page by page, so a database whose
    /// owning process is running is copied without checkpointing its WAL, moving its files, or taking a
    /// write lock on it. The copy carries every committed transaction and no partial one. Copying the
    /// `.db`, `-wal`, and `-shm` files by hand promises none of that: the committed content of a WAL
    /// database lives across two files that are changing while they are read.
    ///
    /// `SQLITE_BUSY`/`SQLITE_LOCKED` from a step is a writer holding the source, not a failure: SQLite
    /// restarts the copy from the beginning on the next step, so the loop sleeps and steps again.
    ///
    /// The copy lands in the source's journal mode, because the backup copies page 1 verbatim and the file
    /// header is what declares WAL, so it is taken out of WAL afterwards and the sidecars that mode leaves
    /// behind are removed: what the caller gets is one self-contained file where a WAL database is three.
    /// The product's own open sets `journal_mode=WAL` again, so the copy runs on WAL from the moment a
    /// daemon or client opens it.
    public static func copy(from sourcePath: String, to destinationPath: String) throws {
        try backUp(from: sourcePath, to: destinationPath)
        try switchToDeleteJournalMode(atPath: destinationPath)
        try removeWALSidecars(atPath: destinationPath)
    }

    private static func backUp(from sourcePath: String, to destinationPath: String) throws {
        var sourceHandle: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &sourceHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let sourceHandle else {
            let message = sourceHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed opening \(sourcePath) for reading"
            if let sourceHandle { sqlite3_close(sourceHandle) }
            throw error(code: 1, message: message)
        }
        defer { sqlite3_close(sourceHandle) }

        var destinationHandle: OpaquePointer?
        let destinationFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(destinationPath, &destinationHandle, destinationFlags, nil) == SQLITE_OK, let destinationHandle else {
            let message = destinationHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed opening \(destinationPath) for writing"
            if let destinationHandle { sqlite3_close(destinationHandle) }
            throw error(code: 2, message: message)
        }
        defer { sqlite3_close(destinationHandle) }

        guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
            throw error(code: 3, message: String(cString: sqlite3_errmsg(destinationHandle)))
        }

        while true {
            let result = sqlite3_backup_step(backup, -1)
            if result == SQLITE_DONE { break }
            if result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED {
                sqlite3_sleep(20)
                continue
            }
            let message = String(cString: sqlite3_errmsg(destinationHandle))
            sqlite3_backup_finish(backup)
            throw error(code: 4, message: message)
        }
        sqlite3_backup_finish(backup)
    }

    /// Takes the database at `path` out of WAL mode, and insists that it left.
    ///
    /// `PRAGMA journal_mode` reports the mode the database ends up in rather than failing when it cannot
    /// change it, so the result row is the only thing that says whether the switch happened. A caller that
    /// only checked the status would leave a WAL database behind believing it had one file.
    private static func switchToDeleteJournalMode(atPath path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed opening \(path)"
            if let handle { sqlite3_close(handle) }
            throw error(code: 11, message: message)
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA journal_mode = DELETE;", -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw error(code: 12, message: message)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw error(code: 13, message: "PRAGMA journal_mode on \(path) reported nothing: \(String(cString: sqlite3_errmsg(handle)))")
        }
        let mode = String(cString: text).lowercased()
        guard mode == "delete" else { throw error(code: 14, message: "\(path) stayed in \(mode) journal mode instead of leaving it for delete.") }
    }

    /// Removes the `-wal` and `-shm` files beside a database that has left WAL mode.
    ///
    /// Leaving WAL checkpoints and deletes the `-wal`, but the `-shm` survives it on macOS, and a file the
    /// caller was promised is self-contained is not self-contained with a sidecar beside it. Both are inert
    /// by the time this runs: the mode has been read back as `delete`, which is what makes them leftovers
    /// rather than state, and the database is a copy nothing else has opened.
    private static func removeWALSidecars(atPath path: String) throws {
        for sidecar in ["\(path)-wal", "\(path)-shm"] where FileManager.default.fileExists(atPath: sidecar) {
            try FileManager.default.removeItem(atPath: sidecar)
        }
    }

    /// Runs `sql` against the database file at `path`, which must already exist.
    ///
    /// Opened READWRITE without `SQLITE_OPEN_CREATE`, so a path that names no database fails loudly
    /// instead of quietly producing an empty one. Foreign keys are enforced, matching the connection every
    /// product write goes through, so a delete cascades exactly as it would in the running product.
    public static func applyStatements(_ sql: String, toDatabaseAt path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed opening \(path) for writing"
            if let handle { sqlite3_close(handle) }
            throw error(code: 5, message: message)
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_busy_timeout(handle, 5000) == SQLITE_OK else {
            throw error(code: 6, message: "Failed configuring sqlite busy timeout: \(String(cString: sqlite3_errmsg(handle)))")
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, "PRAGMA foreign_keys=ON;\n\(sql)", nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard status == SQLITE_OK else {
            throw error(code: 7, message: errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// The user tables the database at `path` holds.
    ///
    /// A snapshot carries whatever schema the build that wrote it declared, which is not necessarily the
    /// schema this build declares, so a caller editing a snapshot asks what is actually there rather than
    /// assuming its own table list.
    ///
    /// Opened READWRITE even though it only reads. A read-only connection cannot open a WAL database that
    /// has no `-shm` beside it, because recreating that shared-memory file is a write, and a freshly copied
    /// database is exactly that case. The caller owns the file it is asking about, so writable is the
    /// honest mode; `SQLITE_OPEN_CREATE` is still withheld so a path that names no database fails loudly.
    public static func tableNames(inDatabaseAt path: String) throws -> Set<String> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed opening \(path)"
            if let handle { sqlite3_close(handle) }
            throw error(code: 8, message: message)
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw error(code: 9, message: message)
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error(code: 10, message: String(cString: sqlite3_errmsg(handle))) }
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            names.insert(String(cString: text))
        }
        return names
    }

    private static func error(code: Int, message: String) -> NSError {
        NSError(domain: errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
