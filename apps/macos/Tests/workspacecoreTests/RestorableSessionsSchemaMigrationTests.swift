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

/// Behavior coverage for the session-restore schema steps: the v20→v21 step adds
/// `terminal_sessions.launch_command` (NULL on every row that predates it, since nothing recorded a raw
/// command for it to relaunch) and creates `restorable_sessions`, and the v21→v22 step adds the columns
/// that record a typed agent's relaunch command.
final class RestorableSessionsSchemaMigrationTests: XCTestCase {
    func testMigrationFromV20PreservesTerminalSessionsAndEnablesRestorableSessions() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v20.db").path
        try createV20Database(at: dbPath)

        // Opening the profile runs the v20→v21 step in place.
        let store = try SQLiteStore(path: dbPath)
        let database = try SpacesSQLiteDatabase(path: dbPath)

        XCTAssertEqual(try scalar(database, "SELECT current_version FROM migration_state"), "\(DatabaseSchema.currentVersion)")

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

        try store.replaceRestorableSessions(
            generation: "gen-1", capturedAt: "2026-09-11T00:00:00Z",
            captures: [
                RestorableSessionCapture(
                    sessionID: "session-1", workspaceID: "ws-1", agentKind: .codex, agentSessionKey: "conv-1", launchCommand: "codex \"fix the bug\"",
                    workingDirectory: "/root/ws1", title: "Codex run")
            ])

        let offered = try store.restorableSessions()
        XCTAssertEqual(offered.map(\.sessionID), ["session-1"])
        XCTAssertEqual(offered.first?.agentSessionKey, "conv-1")
        XCTAssertEqual(offered.first?.launchCommand, "codex \"fix the bug\"")
        XCTAssertEqual(offered.first?.agentKind, .codex)
    }

    /// The v21→v22 step carries an upgraded profile's agent rows forward and leaves them ready to record a
    /// typed agent's relaunch command, which the row had nowhere to keep before.
    func testMigrationFromV21PreservesAgentRowsAndRecordsARelaunchCommand() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v21.db").path
        try createV20Database(at: dbPath)
        try seedV21AgentRow(at: dbPath)

        let store = try SQLiteStore(path: dbPath)
        let database = try SpacesSQLiteDatabase(path: dbPath)

        XCTAssertEqual(try scalar(database, "SELECT current_version FROM migration_state"), "\(DatabaseSchema.currentVersion)")

        let migrated = try XCTUnwrap(try store.agentWindowByTerminalSession(terminalSessionID: "session-1"))
        XCTAssertEqual(migrated.id, "agent-1")
        XCTAssertEqual(migrated.sessionKey, "conv-1")
        XCTAssertEqual(migrated.detectedAgentKind, "codex")
        XCTAssertNil(migrated.launchCommand)

        // The upgraded row records one the moment foreground detection samples it.
        try store.setAgentSessionDetectedForeground(id: "agent-1", kind: nil, launchCommand: #"codex "ship it""#)
        XCTAssertEqual(try store.agentWindowByTerminalSession(terminalSessionID: "session-1")?.launchCommand, #"codex "ship it""#)
    }

    private func scalar(_ database: SpacesSQLiteDatabase, _ sql: String) throws -> String? { try database.queryRow(sql: sql)?.first }

    /// Adds the schema-v21 tables and rows the v20 fixture leaves out (`agent_sessions` and the
    /// `runtime_targets` its reads join against), so the chain reaches v22 with an agent row that predates
    /// the relaunch-command column.
    private func seedV21AgentRow(at path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            XCTFail("Failed opening fixture database at \(path)")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE runtime_targets (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              type TEXT NOT NULL,
              name TEXT,
              detail TEXT,
              app TEXT NOT NULL,
              tracking_id TEXT,
              order_index INTEGER NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE agent_sessions (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              provider TEXT NOT NULL,
              label TEXT,
              user_label TEXT,
              status TEXT NOT NULL DEFAULT 'idle',
              runtime_target_id TEXT,
              terminal_session_id TEXT,
              session_key TEXT,
              note TEXT,
              detected_agent_kind TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            INSERT INTO agent_sessions(id, workspace_id, provider, label, status, terminal_session_id, session_key, detected_agent_kind,
              created_at, updated_at)
            VALUES ('agent-1', 'ws-1', 'spaces', 'codex', 'idle', 'session-1', 'conv-1', 'codex', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v21 fixture: \(message)")
            return
        }
    }

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
