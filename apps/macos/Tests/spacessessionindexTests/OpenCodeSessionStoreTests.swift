import Foundation
import Testing
import spacesterminalcore

@testable import spacessessionindex

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

@Suite struct OpenCodeSessionStoreTests {
    /// A database built from the SQL fixture: the real opencode schema plus synthetic sessions.
    private func makeStore() throws -> (OpenCodeSessionStore, path: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spacessessionindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("opencode.db").path
        let sql = try String(contentsOf: SessionFixtures.url("opencode/opencode.sql"), encoding: .utf8)
        var handle: OpaquePointer?
        try #require(sqlite3_open(path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        return (OpenCodeSessionStore(databasePath: path), path)
    }

    @Test func discoveryListsRootSessionsAndFoldsChildSessionsIntoThem() throws {
        let (store, _) = try makeStore()
        let sources = try store.discover()
        #expect(Set(sources.map(\.id)) == ["ses_root1", "ses_run1", "ses_new1"])
        let root = try #require(sources.first { $0.id == "ses_root1" })
        #expect(root.files.isEmpty)
        #expect(root.sessionKey == "ses_root1")
        #expect(CodingAgent.resumeCommand(launchCommand: "opencode", sessionKey: root.sessionKey) == "opencode -s ses_root1")
        // The latest update among the root and its child session.
        #expect(root.lastModified == Date(timeIntervalSince1970: 1_768_000_060))
    }

    @Test func sizeCountsTheBytesOfMessageAndPartRowsIncludingChildSessions() throws {
        let (store, path) = try makeStore()
        let root = try #require(try store.discover().first { $0.id == "ses_root1" })
        var expected: Int64 = 0
        var handle: OpaquePointer?
        try #require(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = """
            SELECT (SELECT SUM(LENGTH(CAST(data AS BLOB))) FROM message WHERE session_id IN ('ses_root1','ses_child1'))
                 + (SELECT SUM(LENGTH(CAST(data AS BLOB))) FROM part WHERE session_id IN ('ses_root1','ses_child1'))
            """
        try #require(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        expected = sqlite3_column_int64(statement, 0)
        #expect(root.sizeBytes == expected)
        #expect(root.sizeBytes > 0)
    }

    @Test func onlyUserAndCompletedAssistantTextIsSearchable() throws {
        let (store, _) = try makeStore()
        let result = try store.read(sessionID: "ses_root1", sinceWatermark: 0)
        #expect(
            SessionFixtures.texts(result) == [
                "Why does the login test flake? ferret-prompt", "Because of a race in the fixture. heron-reply",
                "Look at the auth module. child-briefing-marker", "The auth module is fine. child-finding-marker",
            ])
    }

    @Test func childSessionTextIsSearchableAsTheRootButIsNotItsFirstPrompt() throws {
        let (store, _) = try makeStore()
        let metadata = try store.read(sessionID: "ses_root1", sinceWatermark: 0).metadata
        #expect(metadata.firstUserPrompt == "Why does the login test flake? ferret-prompt")
        #expect(metadata.title == "Fix flaky login test")
        #expect(metadata.workingDirectory == "/Users/test/web")
        #expect(metadata.isOneShot == false)
    }

    @Test func aPlaceholderTitleMeansNoTitleYet() throws {
        let (store, _) = try makeStore()
        #expect(try store.read(sessionID: "ses_new1", sinceWatermark: 0).metadata.title == nil)
    }

    @Test func runModeSessionsAreOneShot() throws {
        let (store, _) = try makeStore()
        #expect(try store.read(sessionID: "ses_run1", sinceWatermark: 0).metadata.isOneShot)
        #expect(try store.read(sessionID: "ses_new1", sinceWatermark: 0).metadata.isOneShot == false)
    }

    @Test func aWatermarkReturnsOnlyRowsUpdatedAfterIt() throws {
        let (store, path) = try makeStore()
        let first = try store.read(sessionID: "ses_root1", sinceWatermark: 0)
        guard case .watermark(let watermark) = first.nextState else {
            Issue.record("expected a watermark")
            return
        }
        #expect(try store.read(sessionID: "ses_root1", sinceWatermark: watermark).messages.isEmpty)

        // opencode finishes the streaming reply: the part row is rewritten with an end time.
        var handle: OpaquePointer?
        try #require(sqlite3_open(path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let update = """
            UPDATE part SET time_updated = 1768000070000,
              data = '{"type":"text","text":"streaming-partial-marker done","time":{"start":1768000009000,"end":1768000070000}}'
            WHERE id = 'prt_06'
            """
        try #require(sqlite3_exec(handle, update, nil, nil, nil) == SQLITE_OK)

        let second = try store.read(sessionID: "ses_root1", sinceWatermark: watermark)
        #expect(SessionFixtures.texts(second) == ["streaming-partial-marker done"])
        #expect(second.nextState == .watermark(1_768_000_070_000))
    }

    @Test func readingNeverModifiesTheDatabase() throws {
        let (store, path) = try makeStore()
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try store.discover()
        _ = try store.read(sessionID: "ses_root1", sinceWatermark: 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    }

    @Test func aMissingDatabaseHasNoSessions() throws {
        #expect(try OpenCodeSessionStore(databasePath: "/nonexistent/opencode.db").discover().isEmpty)
    }
}
