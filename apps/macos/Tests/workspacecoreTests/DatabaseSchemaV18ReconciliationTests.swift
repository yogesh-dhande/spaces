import Foundation
import XCTest
import spacesterminalcore

@testable import spacesdatabase
@testable import workspacecore

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// v18 was released with two additive shapes on divergent branches. These fixtures exercise the user
/// data those branches could already contain, then verify the v18→v19 reconciliation keeps it usable
/// while adding the other branch's behavior.
final class DatabaseSchemaV18ReconciliationTests: XCTestCase {
    func testMainV18PreservesBracketedPasteStateAndAddsUsableReviewComments() throws {
        let dbURL = try makeV18Database(shape: .main)
        let store = try SQLiteStore(path: dbURL.path)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: dbURL.deletingLastPathComponent().appendingPathComponent("runtime").path,
        ]) {
            let state = try TerminalSessionPersistence.readRuntimeState(paths: TerminalSessionPaths(rootDirectory: "/tmp/existing"))
            XCTAssertTrue(state.bracketedPasteActive, "the runtime state persisted before the upgrade remains observable")
        }

        try store.upsertReviewComment(comment(id: "new-comment", body: "Added after upgrade"))
        XCTAssertEqual(try store.reviewCommentDrafts(workspaceID: "workspace").map(\.body), ["Added after upgrade"])
    }

    func testCodePaneV18PreservesReviewCommentsAndAddsWritableBracketedPasteState() throws {
        let dbURL = try makeV18Database(shape: .codePane)
        let store = try SQLiteStore(path: dbURL.path)

        XCTAssertEqual(try store.reviewCommentDrafts(workspaceID: "workspace").map(\.body), ["Saved before upgrade"])
        try store.upsertReviewComment(comment(id: "existing-comment", body: "Edited after upgrade"))
        XCTAssertEqual(try store.reviewComment(id: "existing-comment")?.body, "Edited after upgrade")

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: dbURL.deletingLastPathComponent().appendingPathComponent("runtime").path,
        ]) {
            let paths = TerminalSessionPaths(rootDirectory: "/tmp/existing")
            let before = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertFalse(before.bracketedPasteActive)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: before.sessionID, backend: before.backend, servicePID: before.servicePID, childPID: before.childPID,
                    state: before.state, updatedAt: "after", bracketedPasteActive: true), paths: paths)
            XCTAssertTrue(try TerminalSessionPersistence.readRuntimeState(paths: paths).bracketedPasteActive)
        }
    }

    private enum V18Shape { case main, codePane }

    private func makeV18Database(shape: V18Shape) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("spaces.db")
        let runtimeColumn = shape == .main ? ", bracketed_paste_active INTEGER NOT NULL DEFAULT 0" : ""
        let runtimeSeed =
            shape == .main
            ? ", bracketed_paste_active) VALUES ('existing', '/tmp/existing', 'ghostty-embedded', 1, 'running', 'now', 1);"
            : ") VALUES ('existing', '/tmp/existing', 'ghostty-embedded', 1, 'running', 'now');"
        let comments =
            shape == .codePane
            ? """
            CREATE TABLE workspace_review_comments (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, file_path TEXT NOT NULL, side TEXT NOT NULL,
              line_number INTEGER NOT NULL, line_text TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, sent_at TEXT,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );
            INSERT INTO workspace_review_comments(id, workspace_id, file_path, side, line_number, line_text, body, created_at, updated_at, revision, sent_at)
            VALUES ('existing-comment', 'workspace', 'src/app.swift', 'new', 4, 'let value = 1', 'Saved before upgrade', 'then', 'then', 0, '');
            """ : ""
        try execute(
            at: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (18);
                CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, dir TEXT NOT NULL UNIQUE, is_git INTEGER NOT NULL);
                CREATE TABLE workspaces (
                  id TEXT PRIMARY KEY, project_id TEXT NOT NULL, dir TEXT NOT NULL, is_default INTEGER NOT NULL, is_running INTEGER NOT NULL,
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                );
                INSERT INTO projects(id, name, dir, is_git) VALUES ('project', 'Project', '/tmp/project', 1);
                INSERT INTO workspaces(id, project_id, dir, is_default, is_running) VALUES ('workspace', 'project', '/tmp/project', 1, 0);
                CREATE TABLE terminal_sessions (session_id TEXT PRIMARY KEY, root_directory TEXT NOT NULL UNIQUE);
                INSERT INTO terminal_sessions(session_id, root_directory) VALUES ('existing', '/tmp/existing');
                CREATE TABLE terminal_runtime_states (
                  session_id TEXT PRIMARY KEY, root_directory TEXT NOT NULL UNIQUE, backend TEXT NOT NULL, service_pid INTEGER NOT NULL,
                  child_pid INTEGER, title TEXT, working_directory TEXT, columns INTEGER, rows INTEGER, state TEXT NOT NULL, updated_at TEXT NOT NULL,
                  exited_at TEXT, foreground_pid INTEGER, foreground_executable_path TEXT, foreground_executable_name TEXT,
                  foreground_argv_json TEXT, foreground_detected_agent_kind TEXT, foreground_display_label TEXT,
                  foreground_display_command TEXT, bell_at TEXT\(runtimeColumn)
                );
                INSERT INTO terminal_runtime_states(session_id, root_directory, backend, service_pid, state, updated_at\(runtimeSeed)
                \(comments)
                """)
        return dbURL
    }

    private func comment(id: String, body: String) -> WorkspaceReviewCommentRecord {
        WorkspaceReviewCommentRecord(
            id: id, workspaceID: "workspace", filePath: "src/app.swift", side: .new, lineNumber: 4, lineText: "let value = 1", body: body,
            createdAt: "now", updatedAt: "now", revision: 0, sentAt: nil)
    }

    private func execute(at dbURL: URL, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let handle else { throw NSError(domain: "spaces.tests", code: 1) }
        defer { sqlite3_close(handle) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            defer { if let errorMessage { sqlite3_free(errorMessage) } }
            throw NSError(
                domain: "spaces.tests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))])
        }
    }
}
