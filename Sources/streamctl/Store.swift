import Foundation
import SQLite3

public final class SQLiteStore {
    private let db: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String) throws {
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK {
            throw NSError(domain: "agentmux.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed opening sqlite db at \(path)"])
        }
        guard let handle else {
            throw NSError(domain: "agentmux.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "DB handle is nil"])
        }
        db = handle
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    public func upsert(project: Project) throws {
        let payload = try encoder.encode(project)
        try execute(
            sql: "INSERT INTO projects(id, name, payload) VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET id=excluded.id, payload=excluded.payload",
            bindings: [project.id.uuidString, project.name, payload]
        )
    }

    public func upsert(stream: Stream) throws {
        let payload = try encoder.encode(stream)
        try execute(
            sql: "INSERT INTO streams(id, project_id, name, worktree_path, payload) VALUES (?, ?, ?, ?, ?) ON CONFLICT(project_id, name) DO UPDATE SET id=excluded.id, worktree_path=excluded.worktree_path, payload=excluded.payload",
            bindings: [stream.id.uuidString, stream.projectID.uuidString, stream.name, stream.worktreePath, payload]
        )

        // Ensure runtime state exists for stream tracking.
        try execute(
            sql: "INSERT INTO stream_runtime(stream_id, project_id, is_active, activated_at, deactivated_at) VALUES (?, ?, 0, NULL, NULL) ON CONFLICT(stream_id) DO NOTHING",
            bindings: [stream.id.uuidString, stream.projectID.uuidString]
        )
    }

    public func project(named name: String) throws -> Project? {
        guard let data = try queryOneBlob(sql: "SELECT payload FROM projects WHERE name = ?", bindings: [name]) else {
            return nil
        }
        return try decoder.decode(Project.self, from: data)
    }

    public func stream(projectID: UUID, name: String) throws -> Stream? {
        guard let data = try queryOneBlob(
            sql: "SELECT payload FROM streams WHERE project_id = ? AND name = ?",
            bindings: [projectID.uuidString, name]
        ) else {
            return nil
        }
        return try decoder.decode(Stream.self, from: data)
    }

    public func stream(id: UUID) throws -> Stream? {
        guard let data = try queryOneBlob(
            sql: "SELECT payload FROM streams WHERE id = ?",
            bindings: [id.uuidString]
        ) else {
            return nil
        }
        return try decoder.decode(Stream.self, from: data)
    }

    public func projects() throws -> [Project] {
        let blobs = try queryBlobColumn(sql: "SELECT payload FROM projects ORDER BY name")
        return try blobs.map { try decoder.decode(Project.self, from: $0) }
    }

    public func fullStreams(projectID: UUID) throws -> [Stream] {
        let blobs = try queryBlobColumn(
            sql: "SELECT payload FROM streams WHERE project_id = ? ORDER BY name",
            bindings: [projectID.uuidString]
        )
        return try blobs.map { try decoder.decode(Stream.self, from: $0) }
    }

    public func windowIdentity(streamID: UUID) throws -> StreamWindowIdentity? {
        guard let data = try queryOneBlob(
            sql: "SELECT payload FROM stream_window_identity WHERE stream_id = ?",
            bindings: [streamID.uuidString]
        ) else {
            return nil
        }
        return try decoder.decode(StreamWindowIdentity.self, from: data)
    }

    public func upsert(windowIdentity: StreamWindowIdentity) throws {
        let payload = try encoder.encode(windowIdentity)
        try execute(
            sql: """
            INSERT INTO stream_window_identity(stream_id, payload)
            VALUES (?, ?)
            ON CONFLICT(stream_id) DO UPDATE SET payload = excluded.payload
            """,
            bindings: [windowIdentity.streamID.uuidString, payload]
        )
    }

    public func deleteStream(id: UUID) throws {
        try execute(sql: "DELETE FROM stream_window_identity WHERE stream_id = ?", bindings: [id.uuidString])
        try execute(sql: "DELETE FROM stream_runtime WHERE stream_id = ?", bindings: [id.uuidString])
        try execute(sql: "DELETE FROM streams WHERE id = ?", bindings: [id.uuidString])
    }

    public func deleteProject(name: String) throws {
        try execute(
            sql: """
            DELETE FROM stream_window_identity
            WHERE stream_id IN (
              SELECT id FROM streams
              WHERE project_id = (SELECT id FROM projects WHERE name = ?)
            )
            """,
            bindings: [name]
        )
        try execute(
            sql: "DELETE FROM stream_runtime WHERE project_id = (SELECT id FROM projects WHERE name = ?)",
            bindings: [name]
        )
        try execute(
            sql: "DELETE FROM streams WHERE project_id = (SELECT id FROM projects WHERE name = ?)",
            bindings: [name]
        )
        try execute(sql: "DELETE FROM projects WHERE name = ?", bindings: [name])
    }

    public func streams(projectID: UUID) throws -> [StreamSummary] {
        let blobs = try queryBlobColumn(
            sql: "SELECT payload FROM streams WHERE project_id = ? ORDER BY name",
            bindings: [projectID.uuidString]
        )
        return try blobs.compactMap { data in
            let stream = try decoder.decode(Stream.self, from: data)
            let active = (try? isStreamActive(streamID: stream.id)) ?? false
            return StreamSummary(
                name: stream.name,
                worktreePath: stream.worktreePath,
                isActive: active,
                displayIndex: stream.displayIndex,
                spaceIndex: stream.spaceIndex
            )
        }
    }

    public func markActive(stream: Stream) throws {
        try execute(
            sql: """
            INSERT INTO stream_runtime(stream_id, project_id, is_active, activated_at, deactivated_at)
            VALUES (?, ?, 1, datetime('now'), NULL)
            ON CONFLICT(stream_id) DO UPDATE SET
              is_active = 1,
              activated_at = datetime('now'),
              deactivated_at = NULL
            """,
            bindings: [stream.id.uuidString, stream.projectID.uuidString]
        )
    }

    public func markInactive(stream: Stream) throws {
        try execute(
            sql: """
            INSERT INTO stream_runtime(stream_id, project_id, is_active, activated_at, deactivated_at)
            VALUES (?, ?, 0, NULL, datetime('now'))
            ON CONFLICT(stream_id) DO UPDATE SET
              is_active = 0,
              deactivated_at = datetime('now')
            """,
            bindings: [stream.id.uuidString, stream.projectID.uuidString]
        )
    }

    private func isStreamActive(streamID: UUID) throws -> Bool {
        let rows = try queryRows(
            sql: "SELECT COALESCE(is_active, 0) FROM stream_runtime WHERE stream_id = ?",
            bindings: [streamID.uuidString]
        )
        guard let first = rows.first, let raw = first.first else {
            return false
        }
        return raw == "1"
    }

    public func activeStreams() throws -> [ActiveStreamSummary] {
        let rows = try queryRows(
            sql: """
            SELECT r.stream_id, COALESCE(r.activated_at, ''), p.name
            FROM stream_runtime r
            JOIN streams s ON s.id = r.stream_id
            JOIN projects p ON p.id = s.project_id
            WHERE r.is_active = 1
            ORDER BY p.name, s.name
            """
        )

        return try rows.compactMap { row in
            guard row.count >= 3, let streamID = UUID(uuidString: row[0]) else {
                return nil
            }
            guard let stream = try stream(id: streamID) else { return nil }
            return ActiveStreamSummary(
                projectName: row[2],
                streamName: stream.name,
                worktreePath: stream.worktreePath,
                activatedAt: row[1],
                displayIndex: stream.displayIndex,
                spaceIndex: stream.spaceIndex
            )
        }
    }

    private func createSchema() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS projects (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          payload BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS streams (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          name TEXT NOT NULL,
          worktree_path TEXT NOT NULL,
          payload BLOB NOT NULL,
          UNIQUE(project_id, name)
        );

        CREATE TABLE IF NOT EXISTS stream_runtime (
          stream_id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 0,
          activated_at TEXT,
          deactivated_at TEXT
        );

        CREATE TABLE IF NOT EXISTS stream_window_identity (
          stream_id TEXT PRIMARY KEY,
          payload BLOB NOT NULL
        );

        """
        try executeBatch(sql: sql)
    }

    private func executeBatch(sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "agentmux.store", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func execute(sql: String, bindings: [Any]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "agentmux.store", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "agentmux.store", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func queryOneBlob(sql: String, bindings: [Any]) throws -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "agentmux.store", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        let result = sqlite3_step(statement)
        guard result != SQLITE_DONE else {
            return nil
        }
        guard result == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "agentmux.store", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let blob = sqlite3_column_blob(statement, 0)
        let length = sqlite3_column_bytes(statement, 0)
        guard let blob else {
            return nil
        }
        return Data(bytes: blob, count: Int(length))
    }

    private func queryRows(sql: String, bindings: [Any] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "agentmux.store", code: 7, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        let columnCount = Int(sqlite3_column_count(statement))
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            row.reserveCapacity(columnCount)
            for idx in 0..<columnCount {
                let text = sqlite3_column_text(statement, Int32(idx))
                row.append(text.map { String(cString: $0) } ?? "")
            }
            rows.append(row)
        }
        return rows
    }

    private func queryBlobColumn(sql: String, bindings: [Any] = []) throws -> [Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "agentmux.store", code: 9, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var rows: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let blob = sqlite3_column_blob(statement, 0)
            let length = sqlite3_column_bytes(statement, 0)
            guard let blob else { continue }
            rows.append(Data(bytes: blob, count: Int(length)))
        }
        return rows
    }

    private func bind(_ bindings: [Any], to statement: OpaquePointer) throws {
        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case let text as String:
                sqlite3_bind_text(statement, slot, text, -1, SQLITE_TRANSIENT)
            case let data as Data:
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, slot, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                }
            default:
                throw NSError(domain: "agentmux.store", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unsupported binding type"])
            }
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
