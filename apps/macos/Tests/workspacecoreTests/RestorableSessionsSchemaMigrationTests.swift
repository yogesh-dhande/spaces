import Foundation
import XCTest
import spacesdatabase
import spacesterminalcore

@testable import workspacecore

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// Behavior coverage for the v20→v21 step: `terminal_sessions.launch_command` is added (NULL on every
/// row that predates it, since nothing recorded a raw command for it to relaunch), and the
/// `restorable_sessions` table is created so a capture can be written once the daemon starts recording
/// unfinished agent sessions.
final class RestorableSessionsSchemaMigrationTests: XCTestCase {
    func testMigrationFromV20PreservesTerminalSessionsAndEnablesRestorableSessions() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v20.db").path
        try createV20Database(at: dbPath)

        // Opening the profile runs the v20→v21 step in place.
        let store = try SQLiteStore(path: dbPath)
        let database = try SpacesSQLiteDatabase(path: dbPath)

        XCTAssertEqual(try scalar(database, "SELECT current_version FROM migration_state"), "\(DatabaseSchema.currentVersion)")

        // The pre-existing session row reads back with every value intact.
        XCTAssertEqual(try scalar(database, "SELECT COUNT(*) FROM terminal_sessions"), "1")
        XCTAssertEqual(try scalar(database, "SELECT workspace_id FROM terminal_sessions WHERE session_id = 'session-1'"), "ws-1")
        XCTAssertEqual(try scalar(database, "SELECT kind FROM terminal_sessions WHERE session_id = 'session-1'"), "agent")
        XCTAssertEqual(try scalar(database, "SELECT title FROM terminal_sessions WHERE session_id = 'session-1'"), "Codex run")
        XCTAssertEqual(try scalar(database, "SELECT user_title FROM terminal_sessions WHERE session_id = 'session-1'"), "Renamed run")
        XCTAssertEqual(try scalar(database, "SELECT working_directory FROM terminal_sessions WHERE session_id = 'session-1'"), "/root/ws1")
        XCTAssertEqual(try scalar(database, "SELECT command FROM terminal_sessions WHERE session_id = 'session-1'"), "codex --wrapped")
        XCTAssertEqual(try scalar(database, "SELECT created_at FROM terminal_sessions WHERE session_id = 'session-1'"), "2026-08-01T00:00:00Z")

        // Its new launch_command column is NULL: it predates the column, so it has nothing recorded to
        // relaunch and is correctly never offered as restorable.
        XCTAssertEqual(try scalar(database, "SELECT launch_command IS NULL FROM terminal_sessions WHERE session_id = 'session-1'"), "1")

        // An upgraded profile holds an offer for a session in the workspace it carried forward, and
        // reads it back whole.
        try store.replaceRestorableSessions(
            generation: "gen-1", capturedAt: "2026-09-11T00:00:00Z",
            captures: [
                RestorableSessionCapture(
                    sessionID: "session-1", workspaceID: "ws-1", agentKind: .codex, agentSessionKey: "conv-1",
                    launchCommand: "codex \"fix the bug\"", workingDirectory: "/root/ws1", title: "Codex run")
            ])

        let offered = try store.restorableSessions()
        XCTAssertEqual(offered.map(\.sessionID), ["session-1"])
        XCTAssertEqual(offered.first?.agentSessionKey, "conv-1")
        XCTAssertEqual(offered.first?.launchCommand, "codex \"fix the bug\"")
        XCTAssertEqual(offered.first?.agentKind, .codex)
    }

    private func scalar(_ database: SpacesSQLiteDatabase, _ sql: String) throws -> String? { try database.queryRow(sql: sql)?.first }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Seeds a schema-v20 database: the `migration_state` marker at 20, and the frozen v20 shape of
    /// `projects`, `workspaces`, and `terminal_sessions` (the last without `launch_command`, which the
    /// step under test adds), populated with one project, one workspace, and one agent session that
    /// predates the column.
    private func createV20Database(at path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            XCTFail("Failed opening fixture database at \(path)")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE migration_state (current_version INTEGER NOT NULL);
            INSERT INTO migration_state(current_version) VALUES (20);

            CREATE TABLE projects (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              dir TEXT NOT NULL UNIQUE,
              is_git INTEGER NOT NULL,
              default_branch TEXT,
              setup_script TEXT,
              stop_script TEXT,
              is_hidden INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO projects(id, name, dir, is_git, is_hidden) VALUES ('project-1', 'Project', '/root', 1, 0);

            CREATE TABLE workspaces (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              dir TEXT NOT NULL,
              dirname TEXT,
              branch TEXT,
              base_branch TEXT,
              is_default INTEGER NOT NULL,
              is_hidden INTEGER NOT NULL DEFAULT 0,
              is_running INTEGER NOT NULL,
              last_launched_at TEXT,
              notes TEXT,
              FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            );
            INSERT INTO workspaces(id, project_id, dir, is_default, is_running) VALUES ('ws-1', 'project-1', '/root/ws1', 1, 0);

            CREATE TABLE terminal_sessions (
              session_id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL UNIQUE,
              backend TEXT NOT NULL,
              lifetime_policy TEXT NOT NULL,
              workspace_id TEXT,
              kind TEXT NOT NULL DEFAULT 'shell',
              title TEXT NOT NULL,
              user_title TEXT,
              working_directory TEXT NOT NULL,
              shell TEXT NOT NULL,
              command TEXT,
              created_at TEXT NOT NULL,
              automation_run_id TEXT
            );
            INSERT INTO terminal_sessions(session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, user_title,
              working_directory, shell, command, created_at)
            VALUES ('session-1', '/root/ws1', 'ghosttyEmbedded', 'persistent', 'ws-1', 'agent', 'Codex run', 'Renamed run',
              '/root/ws1', '/bin/zsh', 'codex --wrapped', '2026-08-01T00:00:00Z');
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v20 fixture: \(message)")
            return
        }
    }
}
