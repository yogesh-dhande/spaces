import Foundation
import XCTest
import spacesdatabase

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// Behavior coverage for the automations schema upgrade (the v13→v14 step, reached here from a v7
/// database that first climbs every intermediate migration): the `terminal_sessions` rebuild that makes
/// `workspace_id` optional and adds `automation_run_id`, plus the new `automations`/`automation_runs`
/// tables. Asserts every existing terminal-session row is carried forward untouched (workspace_id
/// intact, new column NULL), the unique `root_directory` constraint survives the rebuild, and a
/// workspace-less session can now be written.
final class TerminalSessionsSchemaMigrationTests: XCTestCase {
    func testMigrationFromV7PreservesTerminalSessionsAndAddsAutomationSurface() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v7.db").path
        try createV7Database(at: dbPath)

        // Opening the database runs every migration from v7 through the automations step in place.
        let database = try SpacesSQLiteDatabase(path: dbPath)

        XCTAssertEqual(try scalar(database, "SELECT current_version FROM migration_state"), "\(DatabaseSchema.currentVersion)")

        // Every seeded row is carried forward, with workspace_id intact and automation_run_id NULL.
        XCTAssertEqual(try scalar(database, "SELECT COUNT(*) FROM terminal_sessions"), "3")
        XCTAssertEqual(try scalar(database, "SELECT COUNT(*) FROM terminal_sessions WHERE automation_run_id IS NOT NULL"), "0")
        XCTAssertEqual(try scalar(database, "SELECT workspace_id FROM terminal_sessions WHERE session_id = 'session-full'"), "ws-1")
        XCTAssertEqual(try scalar(database, "SELECT title FROM terminal_sessions WHERE session_id = 'session-full'"), "night's run ✨")
        XCTAssertEqual(try scalar(database, "SELECT user_title FROM terminal_sessions WHERE session_id = 'session-full'"), "Renamed")
        // Edge values survive: NULL command and NULL user_title are preserved as NULL, not coerced.
        XCTAssertEqual(try scalar(database, "SELECT command IS NULL FROM terminal_sessions WHERE session_id = 'session-null-cmd'"), "1")
        XCTAssertEqual(try scalar(database, "SELECT user_title IS NULL FROM terminal_sessions WHERE session_id = 'session-null-cmd'"), "1")
        XCTAssertEqual(try scalar(database, "SELECT workspace_id FROM terminal_sessions WHERE session_id = 'session-null-cmd'"), "ws-2")
        XCTAssertEqual(try scalar(database, "SELECT workspace_id FROM terminal_sessions WHERE session_id = 'session-third'"), "ws-3")

        // The new automation tables exist.
        XCTAssertEqual(try scalar(database, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'automations'"), "1")
        XCTAssertEqual(try scalar(database, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'automation_runs'"), "1")

        // The unique root_directory constraint survives the rebuild.
        XCTAssertThrowsError(
            try database.execute(
                sql: """
                    INSERT INTO terminal_sessions(session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title,
                      working_directory, shell, command, created_at)
                    VALUES ('dup', '/root/full', 'ghosttyEmbedded', 'persistent', 'ws-9', 'shell', 'Dup', '/root/full', '/bin/zsh', NULL, 'now')
                    """))

        // workspace_id is now nullable: a workspace-less session (e.g. an automation run) can be written.
        try database.execute(
            sql: """
                INSERT INTO terminal_sessions(session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title,
                  working_directory, shell, command, created_at, automation_run_id)
                VALUES ('session-automation', '/root/automation', 'ghosttyEmbedded', 'persistent', NULL, 'automation', 'Nightly',
                  '/root/automation', '/bin/zsh', 'backup.sh', 'now', 'run-1')
                """)
        XCTAssertEqual(try scalar(database, "SELECT workspace_id IS NULL FROM terminal_sessions WHERE session_id = 'session-automation'"), "1")
        XCTAssertEqual(try scalar(database, "SELECT automation_run_id FROM terminal_sessions WHERE session_id = 'session-automation'"), "run-1")
    }

    private func scalar(_ database: SpacesSQLiteDatabase, _ sql: String) throws -> String? { try database.queryRow(sql: sql)?.first }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Seeds a schema-v7 database: the `migration_state` marker at 7 and the v7-shape `terminal_sessions`
    /// table (`workspace_id NOT NULL`, no `automation_run_id`) populated with rows carrying edge values —
    /// an apostrophe/unicode title, and NULL command and user_title.
    private func createV7Database(at path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            XCTFail("Failed opening fixture database at \(path)")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE migration_state (current_version INTEGER NOT NULL);
            INSERT INTO migration_state(current_version) VALUES (7);
            CREATE TABLE terminal_sessions (
              session_id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL UNIQUE,
              backend TEXT NOT NULL,
              lifetime_policy TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              kind TEXT NOT NULL DEFAULT 'shell',
              title TEXT NOT NULL,
              user_title TEXT,
              working_directory TEXT NOT NULL,
              shell TEXT NOT NULL,
              command TEXT,
              created_at TEXT NOT NULL
            );
            INSERT INTO terminal_sessions(session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, user_title,
              working_directory, shell, command, created_at)
            VALUES ('session-full', '/root/full', 'ghosttyEmbedded', 'persistent', 'ws-1', 'agent', 'night''s run ✨', 'Renamed',
              '/root/full', '/bin/zsh', 'codex', 'now');
            INSERT INTO terminal_sessions(session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, user_title,
              working_directory, shell, command, created_at)
            VALUES ('session-null-cmd', '/root/nullcmd', 'ghosttyEmbedded', 'persistent', 'ws-2', 'shell', 'Shell', NULL,
              '/root/nullcmd', '/bin/zsh', NULL, 'now');
            INSERT INTO terminal_sessions(session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, user_title,
              working_directory, shell, command, created_at)
            VALUES ('session-third', '/root/third', 'ghosttyEmbedded', 'persistent', 'ws-3', 'process', 'Server', NULL,
              '/root/third', '/bin/zsh', 'npm run dev', 'now');
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v7 fixture: \(message)")
            return
        }
    }
}
