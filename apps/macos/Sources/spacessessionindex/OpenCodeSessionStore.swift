import Foundation
import spacesterminalcore

/// opencode's store: the `session`, `message` and `part` tables of `opencode.db`.
///
/// A session's `parent_id` links the child sessions opencode creates for subagents (`@explore`); they are
/// folded into their root session, whose key is the one `opencode -s` resumes. Text comes from `text`
/// parts of user and assistant messages, skipping parts opencode marks `synthetic` (editor context it
/// injects) or `ignored`. An assistant text part is read only once it has a `time.end`, because the part
/// row is rewritten while the reply streams.
///
/// `opencode run` creates its session with permission rules that deny the interactive `question` tool; a
/// session carrying that rule is a one-shot run. A session still titled with the placeholder opencode
/// assigns at creation (`New session - <timestamp>`) has no title yet.
public struct OpenCodeSessionStore: Sendable {
    public let databasePath: String

    public init(databasePath: String) { self.databasePath = databasePath }

    private static let placeholderTitlePrefixes = ["New session - ", "Child session - "]

    public func discover() throws -> [AgentSessionSource] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        let database = try ReadOnlySQLiteDatabase(path: databasePath)

        var parents: [String: String?] = [:]
        var updatedAt: [String: Int64] = [:]
        try database.query("SELECT id, parent_id, time_updated FROM session") { row in
            guard let id = row.text(0) else { return }
            // `updateValue`: assigning a nil parent through the subscript would remove the entry.
            parents.updateValue(row.text(1), forKey: id)
            updatedAt[id] = row.int64(2)
        }
        var bytes: [String: Int64] = [:]
        for table in ["message", "part"] {
            try database.query("SELECT session_id, SUM(LENGTH(CAST(data AS BLOB))) FROM \(table) GROUP BY session_id") { row in
                guard let sessionID = row.text(0) else { return }
                bytes[sessionID, default: 0] += row.int64(1)
            }
        }

        var size: [String: Int64] = [:]
        var modified: [String: Int64] = [:]
        for id in parents.keys {
            let root = Self.root(of: id, parents: parents)
            size[root, default: 0] += bytes[id] ?? 0
            modified[root] = max(modified[root] ?? 0, updatedAt[id] ?? 0)
        }
        return parents.compactMap { id, parent in
            guard parent == nil else { return nil }
            return AgentSessionSource(
                agent: .opencode, id: id, sessionKey: id, files: [], sizeBytes: size[id] ?? 0,
                lastModified: AgentSessionTimestamp.date(epochMilliseconds: modified[id]) ?? .distantPast)
        }
    }

    /// Reads the text of `sessionID` (a root session, with its child sessions) written after `watermark`.
    /// Metadata is always reported in full: a session's title changes without any new part.
    public func read(sessionID: String, sinceWatermark watermark: Int64) throws -> AgentSessionReadResult {
        let database = try ReadOnlySQLiteDatabase(path: databasePath)
        var accumulator = SessionReadAccumulator()

        var found = false
        try database.query("SELECT title, directory, permission, time_updated FROM session WHERE id = ?1", [.text(sessionID)]) { row in
            found = true
            if let title = row.text(0), !Self.placeholderTitlePrefixes.contains(where: title.hasPrefix) { accumulator.metadata.title = title }
            accumulator.metadata.workingDirectory = row.text(1)
            accumulator.metadata.isOneShot = Self.deniesQuestionTool(permissionJSON: row.text(2))
            accumulator.noteActivity(AgentSessionTimestamp.date(epochMilliseconds: row.int64(3)))
        }
        guard found else { throw AgentSessionReadError.sqlite("no session \(sessionID)") }

        var nextWatermark = watermark
        try database.query(
            """
            WITH RECURSIVE tree(id) AS (
                SELECT ?1 UNION ALL SELECT s.id FROM session s JOIN tree ON s.parent_id = tree.id
            )
            SELECT p.session_id, p.time_updated, p.data, m.data
            FROM part p JOIN message m ON m.id = p.message_id
            WHERE p.session_id IN (SELECT id FROM tree) AND p.time_updated > ?2
            ORDER BY p.time_created, p.id
            """, [.text(sessionID), .int(watermark)]
        ) { row in
            let updated = row.int64(1)
            nextWatermark = max(nextWatermark, updated)
            guard let part = Self.object(row.text(2)), let message = Self.object(row.text(3)), part.string("type") == "text",
                part.bool("synthetic") != true, part.bool("ignored") != true, let text = part.string("text"),
                let role = AgentSessionMessage.Role(rawValue: message.string("role") ?? "")
            else { return }
            if role == .assistant, part.object("time")?.int64("end") == nil { return }
            accumulator.addMessage(
                role, text: text, timestamp: AgentSessionTimestamp.date(epochMilliseconds: updated), isSessionOwnPrompt: row.text(0) == sessionID,
                originSessionID: row.text(0))
        }
        return accumulator.result(nextState: .watermark(nextWatermark))
    }

    private static func root(of id: String, parents: [String: String?]) -> String {
        var current = id
        var seen: Set<String> = [id]
        while let parent = parents[current] ?? nil, seen.insert(parent).inserted, parents[parent] != nil { current = parent }
        return current
    }

    private static func object(_ json: String?) -> JSONObject? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    private static func deniesQuestionTool(permissionJSON: String?) -> Bool {
        guard let data = permissionJSON?.data(using: .utf8), let rules = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return false
        }
        return rules.compactMap { $0 as? JSONObject }.contains { $0.string("permission") == "question" && $0.string("action") == "deny" }
    }
}
