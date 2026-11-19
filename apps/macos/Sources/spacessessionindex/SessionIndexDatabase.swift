import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// One connection to the index database, opened read-write by the refresh pass or read-only by searches.
///
/// Separate from `ReadOnlySQLiteDatabase`, which is deliberately unable to create or write a file: this
/// type owns the index file Spaces itself creates. A connection is not thread-safe; `AgentSessionIndex`
/// serializes the users of each one.
final class SessionIndexDatabase {
    private let handle: OpaquePointer
    private static let busyTimeoutMilliseconds: Int32 = 5000

    init(path: String, readOnly: Bool) throws {
        if !readOnly { try Self.restrictToOwner(path) }
        var opened: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &opened, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            if let opened { sqlite3_close(opened) }
            throw AgentSessionReadError.sqlite(message)
        }
        handle = opened
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
    }

    deinit { sqlite3_close(handle) }

    /// The index holds the text of every prompt and reply, so it is owner-only whatever the umask. The
    /// file is created 0600 before SQLite opens it because SQLite gives the `-wal` and `-shm` files the
    /// main file's mode; a file or sidecar left by an earlier build with wider permissions is tightened
    /// in place rather than rebuilt.
    private static func restrictToOwner(_ path: String) throws {
        let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw AgentSessionReadError.cannotOpen(path) }
        close(descriptor)
        for suffix in ["", "-wal", "-shm"] where chmod(path + suffix, 0o600) != 0 && errno != ENOENT {
            throw AgentSessionReadError.cannotOpen(path + suffix)
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func execute(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() } }

    func prepare(_ sql: String) throws -> SessionIndexStatement {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw error() }
        return SessionIndexStatement(statement: prepared, database: self)
    }

    func userVersion() throws -> Int64 {
        let statement = try prepare("PRAGMA user_version")
        return try statement.step() ? statement.int64(0) : 0
    }

    func hasTable(_ name: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE name = ?1")
        statement.bind(1, .text(name))
        return try statement.step()
    }

    fileprivate func error() -> AgentSessionReadError { .sqlite(String(cString: sqlite3_errmsg(handle))) }
}

enum SessionIndexValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

final class SessionIndexStatement {
    private let statement: OpaquePointer
    /// Held strongly so the connection outlives its statements: closing a connection with unfinalized
    /// statements leaves it open.
    private let database: SessionIndexDatabase
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(statement: OpaquePointer, database: SessionIndexDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit { sqlite3_finalize(statement) }

    /// Clears the bindings and rewinds the statement so it can run again.
    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    /// Binds `value` to the 1-based parameter `index`.
    func bind(_ index: Int32, _ value: SessionIndexValue) {
        switch value {
        case .int(let value): sqlite3_bind_int64(statement, index, value)
        case .double(let value): sqlite3_bind_double(statement, index, value)
        case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
        case .null: sqlite3_bind_null(statement, index)
        }
    }

    /// Advances to the next row; false once the statement is done.
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.error()
        }
    }

    /// Runs a statement that returns no rows, then rewinds it.
    func run(_ values: [SessionIndexValue] = []) throws {
        for (offset, value) in values.enumerated() { bind(Int32(offset + 1), value) }
        defer { reset() }
        while try step() {}
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
}
