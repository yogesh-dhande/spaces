import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// A read-only connection to a database another program owns and is writing to.
///
/// `SpacesSQLiteDatabase` is not used because it creates the file, applies Spaces' schema and migrations,
/// and opens read-write; none of that may happen to an agent's own store. A reader of a WAL database
/// never blocks its writer, and the busy timeout only lets a checkpoint finish.
final class ReadOnlySQLiteDatabase {
    enum Binding {
        case int(Int64)
        case text(String)
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
    }

    private let handle: OpaquePointer
    private static let busyTimeoutMilliseconds: Int32 = 2000

    init(path: String) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            if let opened { sqlite3_close(opened) }
            throw AgentSessionReadError.sqlite(message)
        }
        handle = opened
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
    }

    deinit { sqlite3_close(handle) }

    func query(_ sql: String, _ bindings: [Binding] = [], row: (Row) throws -> Void) throws {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw AgentSessionReadError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            let slot = Int32(index + 1)
            switch binding {
            case .int(let value): sqlite3_bind_int64(statement, slot, value)
            case .text(let value): sqlite3_bind_text(statement, slot, value, -1, Self.transient)
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw AgentSessionReadError.sqlite(String(cString: sqlite3_errmsg(handle))) }
            try row(Row(statement: statement))
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
