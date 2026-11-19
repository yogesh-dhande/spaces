import Foundation
import spacesterminalcore

@testable import spacessessionindex

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// A throwaway home directory with the agents' stores inside it, plus an index file beside it.
final class SessionIndexTestHome {
    let root: URL
    let locations: AgentSessionStoreLocations
    let indexURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spacessessionindex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        locations = AgentSessionStoreLocations(home: root.appendingPathComponent("home", isDirectory: true))
        indexURL = root.appendingPathComponent("index/sessions.db")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeIndex(batchSessionLimit: Int = 100) throws -> AgentSessionIndex {
        try AgentSessionIndex(indexURL: indexURL, locations: locations, batchSessionLimit: batchSessionLimit)
    }

    // MARK: - Fixtures

    /// Copies every fixture store into the home, as an installation of all six agents would have.
    func installAllFixtureStores() throws {
        try copyFixture("claude/projects", to: locations.claudeCodeProjects)
        try copyFixture("codex/sessions", to: locations.codexSessions)
        try copyFixture("codex/session_index.jsonl", to: locations.codexSessionIndex)
        try copyFixture("copilot/session-state", to: locations.copilotSessionState)
        try copyFixture("pi/sessions", to: locations.piSessions)
        try copyFixture("amp/threads", to: locations.ampThreads)
        try installOpenCodeFixture()
    }

    func copyFixture(_ relativePath: String, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SessionFixtures.url(relativePath), to: destination)
    }

    func installOpenCodeFixture() throws {
        let path = locations.openCodeDatabase.path
        try FileManager.default.createDirectory(at: locations.openCodeDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withOpenCodeDatabase { handle in
            let sql = try String(contentsOf: SessionFixtures.url("opencode/opencode.sql"), encoding: .utf8)
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw TestError.sqlite(path) }
        }
    }

    func withOpenCodeDatabase(_ body: (OpaquePointer?) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(locations.openCodeDatabase.path, &handle) == SQLITE_OK else { throw TestError.sqlite(locations.openCodeDatabase.path) }
        defer { sqlite3_close(handle) }
        try body(handle)
    }

    enum TestError: Error { case sqlite(String) }

    // MARK: - Claude Code

    func claudeTranscript(project: String = "-work-app", session: String) -> URL {
        locations.claudeCodeProjects.appendingPathComponent(project, isDirectory: true).appendingPathComponent("\(session).jsonl")
    }

    /// Writes a Claude Code transcript of alternating user and assistant lines and returns its URL.
    @discardableResult func writeClaudeSession(
        _ session: String, texts: [String], startingAt start: Date = Date(timeIntervalSince1970: 1_768_000_000), oneShot: Bool = false,
        title: String? = nil
    ) throws -> URL {
        let url = claudeTranscript(session: session)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = texts.enumerated().map { offset, text in
            Self.claudeLine(role: offset % 2 == 0 ? "user" : "assistant", text: text, at: start.addingTimeInterval(Double(offset)), oneShot: oneShot)
        }
        if let title { lines.append(#"{"type":"ai-title","aiTitle":"\#(title)"}"#) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try setModified(start.addingTimeInterval(Double(texts.count)), of: url)
        return url
    }

    static func claudeLine(role: String, text: String, at date: Date, oneShot: Bool = false) -> String {
        let content = role == "user" ? jsonString(text) : #"[{"type":"text","text":\#(jsonString(text))}]"#
        return
            #"{"type":"\#(role)","message":{"role":"\#(role)","content":\#(content)},"timestamp":"\#(iso8601(date))","entrypoint":"\#(oneShot ? "sdk-cli" : "cli")","cwd":"/work/app"}"#
    }

    // MARK: - Codex

    func codexRollout(thread: String, compressed: Bool = false) -> URL {
        locations.codexSessions.appendingPathComponent("2026/01/10", isDirectory: true).appendingPathComponent(
            "rollout-2026-01-10T10-00-00-\(thread).jsonl" + (compressed ? ".zst" : ""))
    }

    func codexArchivedRollout(thread: String, compressed: Bool = false) -> URL {
        locations.codexArchivedSessions.appendingPathComponent("rollout-2026-01-10T10-00-00-\(thread).jsonl" + (compressed ? ".zst" : ""))
    }

    /// Writes a plain rollout holding one prompt and returns its URL; the directory is created.
    @discardableResult func writeCodexRollout(at url: URL, thread: String, prompt: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try
            (Self.codexMetaLine(thread: thread) + "\n"
            + Self.codexMessageLine(kind: "UserMessage", text: prompt, at: Date(timeIntervalSince1970: 1_768_000_001)) + "\n").write(
                to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func codexMetaLine(thread: String, source: String = "cli") -> String {
        #"{"timestamp":"2026-01-10T10:00:00.100Z","type":"session_meta","payload":{"id":"\#(thread)","cwd":"/work/api","source":"\#(source)"}}"#
    }

    static func codexMessageLine(kind: String, text: String, at date: Date) -> String {
        #"{"timestamp":"\#(iso8601(date))","type":"event_msg","payload":{"type":"item_completed","item":{"type":"\#(kind)","content":[{"type":"text","text":\#(jsonString(text))}]}}}"#
    }

    // MARK: - Files

    func append(_ text: String, to url: URL) throws { try SessionFixtures.append(text, to: url) }

    func setModified(_ date: Date, of url: URL) throws { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }

    // MARK: - Index inspection

    /// Rows in the index's turn table: one per indexed turn, so duplicates show up as extra rows.
    func indexedTurnRowCount() throws -> Int {
        let database = try SessionIndexDatabase(path: indexURL.path, readOnly: true)
        let statement = try database.prepare("SELECT COUNT(*) FROM turns")
        return try statement.step() ? Int(statement.int64(0)) : 0
    }

    static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
