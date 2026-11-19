import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// Writes an opencode database with the `session`, `message` and `part` tables the session reader uses.
enum OpenCodeSyntheticDatabase {
    struct Part {
        let role: String
        /// The reply or prompt text, for a text part.
        let text: String?
        let time: Int64
        /// Output of a tool call, for a part the reader must skip.
        let toolOutput: String?
    }

    struct Session {
        let id: String
        let title: String
        let parts: [Part]
    }

    /// Returns the database file's size.
    static func write(_ sessions: [Session], to url: URL) throws -> Int64 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw BenchError("cannot create \(url.path)") }
        defer { sqlite3_close(handle) }
        let schema = """
            CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL, directory text NOT NULL,
                title text NOT NULL, version text NOT NULL, permission text, time_created integer NOT NULL, time_updated integer NOT NULL);
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL,
                time_updated integer NOT NULL, data text NOT NULL);
            BEGIN;
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { throw BenchError("cannot create opencode schema") }
        var counter = 0
        for session in sessions {
            let first = session.parts.first?.time ?? 0
            let last = session.parts.last?.time ?? 0
            try exec(
                handle,
                "INSERT INTO session VALUES ('\(session.id)', 'prj', NULL, 'slug', '/work/web', '\(session.title)', '1.0', NULL, \(first), \(last))")
            for part in session.parts {
                counter += 1
                let messageData = "{\"role\":\"\(part.role)\",\"time\":{\"created\":\(part.time)}}"
                try exec(handle, "INSERT INTO message VALUES ('msg_\(counter)', '\(session.id)', \(part.time), \(part.time), '\(messageData)')")
                var data: [String: Any] = ["type": "tool", "tool": "bash", "state": ["output": part.toolOutput ?? ""]]
                if let text = part.text {
                    data = ["type": "text", "text": text]
                    if part.role == "assistant" { data["time"] = ["start": part.time, "end": part.time] }
                }
                let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
                try exec(
                    handle, "INSERT INTO part VALUES ('prt_\(counter)', 'msg_\(counter)', '\(session.id)', \(part.time), \(part.time), '\(json)')")
            }
        }
        try exec(handle, "COMMIT")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func exec(_ handle: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw BenchError("sqlite: \(String(cString: sqlite3_errmsg(handle)))") }
    }
}
