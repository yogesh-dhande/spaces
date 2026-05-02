import SQLite3
import XCTest

@testable import workspacecore

private final class SQLiteCommitThread: Thread {
    private let database: OpaquePointer
    private let delay: TimeInterval

    init(database: OpaquePointer, delay: TimeInterval) {
        self.database = database
        self.delay = delay
    }

    override func main() {
        Thread.sleep(forTimeInterval: delay)
        _ = sqlite3_exec(database, "COMMIT;", nil, nil, nil)
    }
}

final class StoreTests: XCTestCase {
    // Tests a fresh store bootstraps the current schema and version by arranging an empty DB path and asserting the resulting shape.
    func testFreshStoreBootstrapsCurrentSchema() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("fresh.db")

        _ = try SQLiteStore(path: dbURL.path)

        let version = try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state")
        let workspaceColumns = try readTableColumns(dbURL: dbURL, table: "workspaces")
        let projectColumns = try readTableColumns(dbURL: dbURL, table: "projects")
        let workspaceSettingsColumns = try readTableColumns(dbURL: dbURL, table: "workspace_settings")
        let workspaceStatusColumns = try readTableColumns(dbURL: dbURL, table: "workspace_status_checks")
        let windowColumns = try readTableColumns(dbURL: dbURL, table: "windows")
        let workspacePortColumns = try readTableColumns(dbURL: dbURL, table: "workspace_ports")
        let workspacePortDefinitionColumns = try readTableColumns(dbURL: dbURL, table: "workspace_port_definitions")
        let projectPortDefinitionColumns = try readTableColumns(dbURL: dbURL, table: "project_port_definitions")
        let workspaceProcessColumns = try readTableColumns(dbURL: dbURL, table: "workspace_processes")
        let projectProcessColumns = try readTableColumns(dbURL: dbURL, table: "project_processes")
        let workspaceForeignKeys = try readSingleInteger(dbURL: dbURL, sql: "SELECT COUNT(*) FROM pragma_foreign_key_list('workspaces')")
        XCTAssertEqual(version, 4)
        XCTAssertTrue(workspaceColumns.contains("title"))
        XCTAssertTrue(workspaceColumns.contains("notes"))
        XCTAssertTrue(workspaceColumns.contains("is_hidden"))
        XCTAssertTrue(projectColumns.contains("is_collapsed"))
        XCTAssertTrue(workspaceProcessColumns.contains("execution_mode"))
        XCTAssertTrue(projectProcessColumns.contains("execution_mode"))
        XCTAssertFalse(workspaceSettingsColumns.contains("updated_at"))
        XCTAssertFalse(workspaceStatusColumns.contains("on_exit"))
        XCTAssertTrue(windowColumns.contains("name"))
        XCTAssertTrue(windowColumns.contains("detail"))
        XCTAssertTrue(workspacePortColumns.contains("definition_id"))
        XCTAssertTrue(workspacePortDefinitionColumns.contains("id"))
        XCTAssertTrue(projectPortDefinitionColumns.contains("id"))
        XCTAssertEqual(workspaceForeignKeys, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    // Tests opening a current-version database is a no-op by arranging a fresh current DB and asserting no migration backup is created on reopen.
    func testOpeningCurrentVersionDoesNotCreateMigrationBackup() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("current.db")

        _ = try SQLiteStore(path: dbURL.path)
        _ = try SQLiteStore(path: dbURL.path)

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    // Tests a released v1 database migrates in place by arranging representative data and asserting current state, backup creation, and integrity validation.
    func testSchemaV1MigratesToCurrentVersionAndPreservesData() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("migrating.db")
        try createSchemaV1Fixture(dbURL: dbURL)

        let store = try SQLiteStore(path: dbURL.path)

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), 4)
        XCTAssertEqual(try readSingleText(dbURL: dbURL, sql: "PRAGMA integrity_check"), "ok")
        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT COUNT(*) FROM pragma_foreign_key_list('workspace_processes')"), 1)
        XCTAssertEqual(try store.projects().count, 1)
        XCTAssertEqual(try store.project(id: "project-1")?.ports.first?.name, "API_PORT")
        XCTAssertEqual(try store.workspace(id: "workspace-1")?.notes, "Feature tooltip")
        XCTAssertEqual(try store.workspaceProcesses(workspaceID: "workspace-1").first?.name, "api")
        XCTAssertEqual(try store.workspaceProcesses(workspaceID: "workspace-1").first?.executionMode, .direct)
        XCTAssertEqual(try store.workspaceBrowserSessions(workspaceID: "workspace-1").first?.url, "https://example.com")
        XCTAssertEqual(try store.agentWindows(workspaceID: "workspace-1").first?.label, "Codex")
        XCTAssertEqual(try store.runningProcesses(workspaceID: "workspace-1").first?.terminalTrackingID, "session-1")

        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].lastPathComponent.contains("-v1-to-v4.sqlite3"))
    }

    // Tests unsupported future schemas fail closed by arranging a DB ahead of the current code and asserting the startup error avoids reset instructions.
    func testUnsupportedSchemaVersionFailsClosed() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("unsupported.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE projects (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  dir TEXT NOT NULL UNIQUE,
                  is_git INTEGER NOT NULL,
                  default_branch TEXT
                );
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (99);
                """)

        XCTAssertThrowsError(try SQLiteStore(path: dbURL.path)) { error in
            XCTAssertEqual(error.localizedDescription, "Unsupported database schema version 99 at \(dbURL.path).")
        }
    }

    // Tests the migrator executes every intermediate step by arranging a direct migrator with two ordered steps and asserting each step runs in sequence.
    func testMigratorRunsIntermediateStepsInOrder() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("ordered.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                CREATE TABLE migration_log (entry TEXT NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (1);
                """)
        let handle = try openSQLiteHandle(dbURL: dbURL)
        defer { sqlite3_close(handle) }

        let migrator = DatabaseMigrator(
            currentSchemaVersion: 3,
            steps: [
                DatabaseMigrationStep(fromVersion: 1, toVersion: 2, description: "one", requiresBackup: true) { db in
                    _ = sqlite3_exec(db, "INSERT INTO migration_log(entry) VALUES ('1-2');", nil, nil, nil)
                },
                DatabaseMigrationStep(fromVersion: 2, toVersion: 3, description: "two", requiresBackup: true) { db in
                    _ = sqlite3_exec(db, "INSERT INTO migration_log(entry) VALUES ('2-3');", nil, nil, nil)
                },
            ],
            backupManager: DatabaseBackupManager(
                databaseURL: dbURL, backupDirectory: root.appendingPathComponent("backups"), retentionLimit: 10,
                dateProvider: { Date(timeIntervalSince1970: 1_000) }))

        try migrator.migrateIfNeeded(
            existingTables: ["migration_state", "migration_log"], schemaVersion: 1, databasePath: dbURL.path, databaseHandle: handle,
            createFreshSchema: {},
            setSchemaVersion: { version in
                XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM migration_state;", nil, nil, nil), SQLITE_OK)
                XCTAssertEqual(sqlite3_exec(handle, "INSERT INTO migration_state(current_version) VALUES (\(version));", nil, nil, nil), SQLITE_OK)
            },
            withTransaction: { body in
                _ = sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil)
                do {
                    try body()
                    _ = sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
                } catch {
                    _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                    throw error
                }
            }, validateIntegrity: { XCTAssertEqual(try self.readSingleText(dbURL: dbURL, sql: "PRAGMA integrity_check"), "ok") })

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), 3)
        XCTAssertEqual(
            try readRows(dbURL: dbURL, sql: "SELECT entry FROM migration_log ORDER BY rowid").compactMap { $0.first ?? nil }, ["1-2", "2-3"])
    }

    // Tests migration failure rolls back the in-flight step by arranging a failing step and asserting schema state and pre-migration backup both remain.
    func testMigrationFailureRollsBackAndPreservesBackup() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("failure.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                CREATE TABLE widgets (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (1);
                INSERT INTO widgets(id, name) VALUES ('widget-1', 'Before');
                """)
        let handle = try openSQLiteHandle(dbURL: dbURL)
        defer { sqlite3_close(handle) }

        let migrator = DatabaseMigrator(
            currentSchemaVersion: 2,
            steps: [
                DatabaseMigrationStep(fromVersion: 1, toVersion: 2, description: "failing", requiresBackup: true) { db in
                    _ = sqlite3_exec(db, "ALTER TABLE widgets ADD COLUMN detail TEXT;", nil, nil, nil)
                    throw NSError(domain: "spaces.tests", code: 99, userInfo: [NSLocalizedDescriptionKey: "Injected failure"])
                }
            ],
            backupManager: DatabaseBackupManager(
                databaseURL: dbURL, backupDirectory: root.appendingPathComponent("backups"), retentionLimit: 10,
                dateProvider: { Date(timeIntervalSince1970: 2_000) }))

        XCTAssertThrowsError(
            try migrator.migrateIfNeeded(
                existingTables: ["migration_state", "widgets"], schemaVersion: 1, databasePath: dbURL.path, databaseHandle: handle,
                createFreshSchema: {},
                setSchemaVersion: { version in
                    XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM migration_state;", nil, nil, nil), SQLITE_OK)
                    XCTAssertEqual(
                        sqlite3_exec(handle, "INSERT INTO migration_state(current_version) VALUES (\(version));", nil, nil, nil), SQLITE_OK)
                },
                withTransaction: { body in
                    _ = sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil)
                    do {
                        try body()
                        _ = sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
                    } catch {
                        _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                        throw error
                    }
                }, validateIntegrity: {})
        ) { error in XCTAssertTrue(error.localizedDescription.contains("Injected failure")) }

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), 1)
        XCTAssertFalse(try readTableColumns(dbURL: dbURL, table: "widgets").contains("detail"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("backups"), includingPropertiesForKeys: nil).count, 1)
    }

    // Tests backup retention keeps the newest snapshots by arranging repeated backups and asserting only the latest ten remain.
    func testMigrationBackupRetentionKeepsNewestTenSnapshots() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("retention.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (1);
                """)
        let handle = try openSQLiteHandle(dbURL: dbURL)
        defer { sqlite3_close(handle) }
        let backupDirectory = root.appendingPathComponent("backups")

        for index in 0..<12 {
            let manager = DatabaseBackupManager(
                databaseURL: dbURL, backupDirectory: backupDirectory, retentionLimit: 10,
                dateProvider: { Date(timeIntervalSince1970: TimeInterval(index)) })
            _ = try manager.createMigrationBackup(sourceHandle: handle, fromVersion: 1, toVersion: 2)
        }

        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil).map(\.lastPathComponent)
            .sorted()
        XCTAssertEqual(backups.count, 10)
        XCTAssertFalse(backups.contains { $0.hasPrefix("1970-01-01T00-00-00Z") })
        XCTAssertFalse(backups.contains { $0.hasPrefix("1970-01-01T00-00-01Z") })
        XCTAssertTrue(backups.contains { $0.hasPrefix("1970-01-01T00-00-11Z") })
    }

    // Tests workspace collections round trip and replacement by arranging representative inputs and asserting the expected result.
    func testWorkspaceCollectionsRoundTripAndReplacement() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 3001], names: ["API_PORT", "WEB_PORT"])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [3000, 3001])
        let named = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(named[0].name, "API_PORT")
        XCTAssertEqual(named[1].name, "WEB_PORT")
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [4000])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [4000])
        let namedAfter = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(namedAfter[0].name, "")

        let processes = [ProcessTemplate(name: "api", command: "npm run api"), ProcessTemplate(command: "npm run worker")]
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: processes)
        let storedProcesses = try store.workspaceProcesses(workspaceID: workspace.id)
        XCTAssertEqual(storedProcesses.count, 2)
        XCTAssertEqual(storedProcesses[0].name, "api")
        XCTAssertEqual(storedProcesses[1].name, nil)

        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(
                    name: "checkout", url: "https://example.com",
                    extractedWindow: ExtractedBrowserWindowMapping(targetURL: "https://example.com", windowID: 303, isValid: true)), BrowserSession(),
            ])
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].name, "checkout")
        XCTAssertEqual(sessions[0].url, "https://example.com")
        XCTAssertEqual(sessions[0].extractedWindow?.targetURL, "https://example.com")

        try store.setWorkspaceAgentLaunchers(
            workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex"), AgentLauncher(name: "Claude", command: "claude")])
        let launchers = try store.workspaceAgentLaunchers(workspaceID: workspace.id)
        XCTAssertEqual(launchers, [AgentLauncher(name: "Codex", command: "codex"), AgentLauncher(name: "Claude", command: "claude")])
        XCTAssertEqual(sessions[0].extractedWindow?.windowID, 303)
        XCTAssertEqual(sessions[0].extractedWindow?.isValid, true)
        XCTAssertNil(sessions[1].name)
        XCTAssertNil(sessions[1].url)

        XCTAssertFalse(try store.workspaceSettingsExists(workspaceID: workspace.id))
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        XCTAssertTrue(try store.workspaceSettingsExists(workspaceID: workspace.id))
        XCTAssertNil(try store.workspaceStopScript(workspaceID: workspace.id))
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo stop")
        XCTAssertEqual(try store.workspaceStopScript(workspaceID: workspace.id), "echo stop")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: nil)
        XCTAssertNil(try store.workspaceStopScript(workspaceID: workspace.id))

        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .failed, errorMessage: "setup failed", startedAt: "start", finishedAt: "end")
        let setupState = try store.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(setupState?.status, .failed)
        XCTAssertEqual(setupState?.errorMessage, "setup failed")
        XCTAssertEqual(setupState?.startedAt, "start")
        XCTAssertEqual(setupState?.finishedAt, "end")

        try store.releaseWorkspacePorts(workspaceID: workspace.id)
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)

        let definitions = [PortDefinition(name: "FRONTEND_PORT"), PortDefinition(name: "API_PORT")]
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: definitions)
        let storedDefs = try store.workspacePortDefinitions(workspaceID: workspace.id)
        XCTAssertEqual(storedDefs.count, 2)
        XCTAssertEqual(storedDefs[0].name, "FRONTEND_PORT")
        XCTAssertEqual(storedDefs[1].name, "API_PORT")

        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: [PortDefinition(name: "DB_PORT")])
        XCTAssertEqual(try store.workspacePortDefinitions(workspaceID: workspace.id).count, 1)
        XCTAssertEqual(try store.workspacePortDefinitions(workspaceID: workspace.id)[0].name, "DB_PORT")
    }

    // Tests a delete-and-reinsert logical write is atomic by arranging a duplicate-ID failure and asserting the original child rows survive unchanged.
    func testSetWorkspaceProcessesRollsBackReplacementOnFailure() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id,
            processes: [
                ProcessTemplate(id: "original-1", name: "api", command: "npm run api"),
                ProcessTemplate(id: "original-2", name: "web", command: "npm run web"),
            ])

        XCTAssertThrowsError(
            try store.setWorkspaceProcesses(
                workspaceID: workspace.id,
                processes: [
                    ProcessTemplate(id: "dup", name: "api", command: "npm run api"), ProcessTemplate(id: "dup", name: "web", command: "npm run web"),
                ]))

        let persisted = try store.workspaceProcesses(workspaceID: workspace.id)
        XCTAssertEqual(persisted.map(\.id), ["original-1", "original-2"])
        XCTAssertEqual(persisted.map(\.command), ["npm run api", "npm run web"])
    }

    // Tests project collapsed state persists on the current schema by arranging a current-store project and asserting round-trip behavior.
    func testProjectCollapsedStatePersists() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("project-collapsed-state.db")
        let store = try SQLiteStore(path: dbURL.path)
        let project = makeProjectRecord(id: "p1", dir: "/tmp/project")
        try store.upsert(project: project)

        XCTAssertEqual(try store.project(id: "p1")?.isCollapsed, false)

        try store.updateProjectCollapsed(id: "p1", isCollapsed: true)
        XCTAssertEqual(try store.project(id: "p1")?.isCollapsed, true)
        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT is_collapsed FROM projects WHERE id = 'p1'"), 1)
    }

    // Tests store write waits for transient database lock and succeeds by arranging an external immediate transaction and asserting write completion.
    func testStoreWriteWaitsForTransientDatabaseLock() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("busy-timeout.db")
        let store = try SQLiteStore(path: dbURL.path)

        var lockDB: OpaquePointer?
        guard sqlite3_open(dbURL.path, &lockDB) == SQLITE_OK, let lockDB else {
            XCTFail("Failed opening lock sqlite handle")
            return
        }
        defer { sqlite3_close(lockDB) }

        XCTAssertEqual(sqlite3_exec(lockDB, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil), SQLITE_OK)
        let unlockThread = SQLiteCommitThread(database: lockDB, delay: 0.2)
        unlockThread.start()

        XCTAssertNoThrow(try store.setSetting(key: "lock-test", value: "ok"))
        XCTAssertEqual(try store.setting(key: "lock-test"), "ok")
    }

    // Tests running processes and windows round trip by arranging representative inputs and asserting the expected result.
    func testRunningProcessesAndWindowsRoundTrip() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let processID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 9001,
                terminalTrackingID: "session-abc", itermTabIndex: 2, pid: 1234, status: .running, logPath: "/tmp/api.log",
                lastOutputAt: "2026-01-01T00:00:00Z", startedAt: "2026-01-01T00:00:00Z", exitedAt: nil))

        var processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0].status, .running)
        XCTAssertEqual(processes[0].windowID, 9001)
        XCTAssertEqual(processes[0].terminalTrackingID, "session-abc")
        XCTAssertEqual(processes[0].itermTabIndex, 2)

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: nil, windowID: nil, pid: nil,
                status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "2026-01-01T00:00:00Z", exitedAt: "2026-01-01T00:01:00Z"))
        processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes[0].status, .exited)
        XCTAssertNil(processes[0].windowID)

        let firstWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Browser", windowID: 42, role: "browser", orderIndex: 0,
            lastSeenAt: "now")
        let secondWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "Terminal", windowID: 43, role: "terminal", orderIndex: 1,
            lastSeenAt: "now")
        try store.upsert(window: firstWindow)
        try store.upsert(window: secondWindow)

        XCTAssertEqual(try store.workspaceID(windowID: 42), workspace.id)
        let storedWindows = try store.windows(workspaceID: workspace.id)
        XCTAssertEqual(storedWindows.count, 2)
        XCTAssertEqual(storedWindows[0].name, "Browser")
        XCTAssertEqual(storedWindows[0].detail, nil)
        XCTAssertEqual(storedWindows[1].name, "Terminal")
        try store.deleteWindow(id: firstWindow.id)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).count, 1)
        try store.deleteWindows(workspaceID: workspace.id)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    // Tests agent-window yabai lookup resolves a workspace by arranging a stored agent window and asserting the lookup result.
    func testWorkspaceIDForAgentWindowResolvesByYabaiWindowID() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature-agent", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Codex CLI", terminalTrackingID: "session-123",
                codexThreadID: "thread-123", windowID: nil, yabaiWindowID: 4242, status: .spinning, createdAt: "2026-02-25T00:00:00Z",
                updatedAt: "2026-02-25T00:00:01Z"))

        XCTAssertEqual(try store.workspaceIDForAgentWindow(yabaiWindowID: 4242), workspace.id)
    }

    // Tests delete workspace removes dependent rows by arranging representative inputs and asserting the expected result.
    func testDeleteWorkspaceRemovesDependentRows() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let processID = UUID().uuidString
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000])
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: [PortDefinition(name: "API_PORT")])
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(command: "echo one")])
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "https://example.com")])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "one", command: "echo one", terminalApp: nil, windowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "term", windowID: 77, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))

        try store.deleteWorkspace(id: workspace.id)

        XCTAssertNil(try store.workspace(id: workspace.id))
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspacePortDefinitions(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspaceProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspaceBrowserSessions(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.isIgnoredWorktree(path: workspace.dir))
    }

    // Tests upsert workspace clears ignored worktree path by arranging representative inputs and asserting the expected result.
    func testUpsertWorkspaceClearsIgnoredWorktreePath() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.markIgnoredWorktree(path: workspace.dir, projectID: project.id)
        XCTAssertTrue(try store.isIgnoredWorktree(path: workspace.dir))

        try store.upsert(workspace: workspace)
        XCTAssertFalse(try store.isIgnoredWorktree(path: workspace.dir))
    }

    // Tests delete project removes project workspaces and dependents by arranging representative inputs and asserting the expected result.
    func testDeleteProjectRemovesProjectWorkspacesAndDependents() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(id: "project-1", dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: nil, windowID: 91, role: "browser", orderIndex: 0,
                lastSeenAt: "now"))

        try store.deleteProject(id: project.id)

        XCTAssertNil(try store.project(id: project.id))
        XCTAssertTrue(try store.workspaces(projectID: project.id, includeArchived: true).isEmpty)
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
        XCTAssertNil(try store.workspaceID(windowID: 91))
    }

    // Tests workspace and setting state updates persist by arranging representative inputs and asserting the expected result.
    func testWorkspaceAndSettingStateUpdatesPersist() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-01-01T00:00:00Z")
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)
        let updated = try store.workspace(id: workspace.id)
        XCTAssertEqual(updated?.isRunning, true)
        XCTAssertEqual(updated?.isArchived, true)
        XCTAssertEqual(updated?.lastLaunchedAt, "2026-01-01T00:00:00Z")

        XCTAssertNil(try store.setting(key: "key"))
        try store.setSetting(key: "key", value: "value")
        XCTAssertEqual(try store.setting(key: "key"), "value")
        try store.setSetting(key: "key", value: nil)
        XCTAssertNil(try store.setting(key: "key"))
    }

    // Tests workspace rename persists the workspace title column by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceNameUpdatesTitleColumn() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("workspace-title.db")
        let store = try SQLiteStore(path: dbURL.path)
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.updateWorkspaceName(id: workspace.id, name: "renamed")

        XCTAssertEqual(try readSingleText(dbURL: dbURL, sql: "SELECT title FROM workspaces WHERE id = '\(workspace.id)'"), "renamed")
    }

    // Tests project and workspace lookup and ordering by arranging representative inputs and asserting the expected result.
    func testProjectAndWorkspaceLookupAndOrdering() throws {
        let store = try makeTemporaryStore()
        let aDir = try makeTempDirectory().path
        let zDir = try makeTempDirectory().path
        let aProject = ProjectRecord(id: "a", name: "A Project", dir: aDir, isGitRepo: false, defaultBranch: nil)
        let zProject = ProjectRecord(id: "z", name: "Z Project", dir: zDir, isGitRepo: true, defaultBranch: "main")
        try store.upsert(project: zProject)
        try store.upsert(project: aProject)

        XCTAssertEqual(try store.project(id: "z")?.dir, zDir)
        XCTAssertEqual(try store.project(dir: aDir)?.name, "A Project")
        XCTAssertEqual(try store.projects().map(\.name), ["A Project", "Z Project"])

        let defaultWorkspace = WorkspaceRecord(
            id: "default", projectID: aProject.id, title: "default", dir: aDir, dirname: nil, branch: nil, isDefault: true, isArchived: false,
            isRunning: false, lastLaunchedAt: nil)
        let archivedWorkspace = WorkspaceRecord(
            id: "archived", projectID: aProject.id, title: "feature", dir: aDir, dirname: nil, branch: nil, targetBranch: "develop", isDefault: false,
            isArchived: true, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: archivedWorkspace)
        try store.upsert(workspace: defaultWorkspace)

        XCTAssertEqual(try store.workspace(projectID: aProject.id, name: "feature")?.id, "archived")
        XCTAssertEqual(try store.workspace(projectID: aProject.id, name: "feature")?.targetBranch, "develop")
        XCTAssertEqual(try store.workspaces(projectID: aProject.id, includeArchived: false).map(\.id), ["default"])
        XCTAssertEqual(Set(try store.workspaces(projectID: aProject.id, includeArchived: true).map(\.id)), Set(["default", "archived"]))
    }

    // Tests delete running process and delete running processes by arranging representative inputs and asserting the expected result.
    func testDeleteRunningProcessAndDeleteRunningProcesses() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: firstID, workspaceID: workspace.id, templateName: "first", command: "echo first", terminalApp: nil, windowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: secondID, workspaceID: workspace.id, templateName: "second", command: "echo second", terminalApp: nil, windowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.deleteRunningProcess(id: firstID)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.id), [secondID])

        try store.deleteRunningProcesses(workspaceID: workspace.id)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests project template fields round trip by arranging representative inputs and asserting the expected result.
    func testProjectTemplateFieldsRoundTrip() throws {
        let store = try makeTemporaryStore()
        let dir = try makeTempDirectory().path
        let project = ProjectRecord(
            id: dir, name: "myproject", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: "echo setup", stopScript: "echo stop",
            ports: [PortDefinition(name: "API_PORT"), PortDefinition(name: "WEB_PORT")],
            processes: [ProcessTemplate(name: "api", command: "npm run api"), ProcessTemplate(command: "npm run worker")],
            browserSessions: [BrowserSession(name: "frontend", url: "https://localhost:3000")])

        try store.upsert(project: project)

        let loaded = try store.project(id: dir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.setupScript, "echo setup")
        XCTAssertEqual(loaded?.stopScript, "echo stop")
        XCTAssertEqual(loaded?.ports.count, 2)
        XCTAssertEqual(loaded?.ports[0].name, "API_PORT")
        XCTAssertEqual(loaded?.ports[1].name, "WEB_PORT")
        XCTAssertEqual(loaded?.processes.count, 2)
        XCTAssertEqual(loaded?.processes[0].name, "api")
        XCTAssertEqual(loaded?.processes[1].name, nil)
        XCTAssertEqual(loaded?.browserSessions.count, 1)
        XCTAssertEqual(loaded?.browserSessions[0].name, "frontend")
        XCTAssertEqual(loaded?.browserSessions[0].url, "https://localhost:3000")
    }

    // Tests project template fields are updated on upsert by arranging representative inputs and asserting the expected result.
    func testProjectTemplateFieldsAreUpdatedOnUpsert() throws {
        let store = try makeTemporaryStore()
        let dir = try makeTempDirectory().path
        var project = ProjectRecord(
            id: dir, name: "project", dir: dir, isGitRepo: false, defaultBranch: nil, ports: [PortDefinition(name: "OLD_PORT")])
        try store.upsert(project: project)

        project.ports = [PortDefinition(name: "NEW_PORT"), PortDefinition(name: "EXTRA_PORT")]
        project.setupScript = "echo updated"
        try store.upsert(project: project)

        let loaded = try store.project(id: dir)
        XCTAssertEqual(loaded?.ports.count, 2)
        XCTAssertEqual(loaded?.ports[0].name, "NEW_PORT")
        XCTAssertEqual(loaded?.setupScript, "echo updated")
    }

    // Tests delete project cascades template tables by arranging representative inputs and asserting the expected result.
    func testDeleteProjectCascadesTemplateTables() throws {
        let store = try makeTemporaryStore()
        let dir = try makeTempDirectory().path
        let project = ProjectRecord(
            id: dir, name: "project", dir: dir, isGitRepo: false, defaultBranch: nil, ports: [PortDefinition(name: "PORT")],
            processes: [ProcessTemplate(command: "echo run")])
        try store.upsert(project: project)

        try store.deleteProject(id: dir)

        XCTAssertNil(try store.project(id: dir))
    }

    // Tests projects list loads all template fields by arranging representative inputs and asserting the expected result.
    func testProjectsListLoadsAllTemplateFields() throws {
        let store = try makeTemporaryStore()
        let dir1 = try makeTempDirectory().path
        let dir2 = try makeTempDirectory().path
        let p1 = ProjectRecord(id: dir1, name: "alpha", dir: dir1, isGitRepo: false, defaultBranch: nil, ports: [PortDefinition(name: "PORT1")])
        let p2 = ProjectRecord(id: dir2, name: "beta", dir: dir2, isGitRepo: false, defaultBranch: nil, processes: [ProcessTemplate(command: "run")])
        try store.upsert(project: p1)
        try store.upsert(project: p2)

        let all = try store.projects()
        XCTAssertEqual(all.count, 2)
        let alpha = try XCTUnwrap(all.first(where: { $0.name == "alpha" }))
        XCTAssertEqual(alpha.ports.count, 1)
        let beta = try XCTUnwrap(all.first(where: { $0.name == "beta" }))
        XCTAssertEqual(beta.processes.count, 1)
    }

    // Tests windows query by window ID returns matching records by arranging representative inputs and asserting the expected result.
    func testWindowsQueryByWindowID() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspaceA = makeWorkspaceRecord(projectID: project.id, title: "ws-a", dir: project.dir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, title: "ws-b", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspaceA)
        try store.upsert(workspace: workspaceB)

        let windowID = 9999
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspaceA.id, app: "iTerm2", title: "shell-a", windowID: windowID, role: "terminal",
                orderIndex: 0, lastSeenAt: "2026-01-01T00:00:01Z"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspaceB.id, app: "iTerm2", title: "shell-b", windowID: windowID, role: "terminal",
                orderIndex: 0, lastSeenAt: "2026-01-01T00:00:02Z"))

        let found = try store.windows(windowID: windowID)
        XCTAssertEqual(found.count, 2)
        // Results ordered by last_seen_at DESC
        XCTAssertEqual(found[0].workspaceID, workspaceB.id)
        XCTAssertEqual(found[1].workspaceID, workspaceA.id)

        let notFound = try store.windows(windowID: 0)
        XCTAssertTrue(notFound.isEmpty)
    }

    // Tests workspace browser sessions with extracted window round trips correctly by arranging representative inputs and asserting the expected result.
    func testWorkspaceBrowserSessionsWithExtractedWindowRoundTrip() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let extractedWindow = ExtractedBrowserWindowMapping(targetURL: "http://localhost:3000", windowID: 501, isValid: true)
        let sessions: [BrowserSession] = [
            BrowserSession(name: "frontend", url: "http://localhost:3000", extractedWindow: extractedWindow),
            BrowserSession(name: "backend", url: "http://localhost:4000", extractedWindow: nil),
        ]
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: sessions)

        let loaded = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "frontend")
        XCTAssertEqual(loaded[0].url, "http://localhost:3000")
        XCTAssertNotNil(loaded[0].extractedWindow)
        XCTAssertEqual(loaded[0].extractedWindow?.windowID, 501)
        XCTAssertEqual(loaded[0].extractedWindow?.targetURL, "http://localhost:3000")
        XCTAssertEqual(loaded[0].extractedWindow?.isValid, true)
        XCTAssertEqual(loaded[1].name, "backend")
        XCTAssertNil(loaded[1].extractedWindow)
    }

    // Tests agent window lookup by iTerm session ID returns the matching record by arranging representative inputs and asserting the expected result.
    func testAgentWindowLookupByItermSessionID() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "session-abc"
        let id = UUID().uuidString
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: id, workspaceID: workspace.id, provider: .iterm2, label: nil, terminalTrackingID: sessionID, codexThreadID: nil, windowID: nil,
                yabaiWindowID: nil, status: .spinning, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))

        let found = try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID)
        XCTAssertEqual(found?.id, id)
        XCTAssertEqual(found?.terminalTrackingID, sessionID)
        XCTAssertNil(try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: "nonexistent"))
    }

    // Tests agentWindowsByProvider returns only records from the requested workspace/provider by arranging representative inputs and asserting the expected result.
    func testAgentWindowsByProviderFiltersCorrectly() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, title: "feature-b", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.upsert(workspace: workspaceB)

        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "claude", terminalTrackingID: "session-a",
                codexThreadID: nil, windowID: nil, yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:01Z",
                updatedAt: "2026-01-01T00:00:01Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspaceB.id, provider: .iterm2, label: "codex", terminalTrackingID: "session-b",
                codexThreadID: nil, windowID: nil, yabaiWindowID: nil, status: .spinning, createdAt: "2026-01-01T00:00:02Z",
                updatedAt: "2026-01-01T00:00:02Z"))

        let itermWindows = try store.agentWindowsByProvider(workspaceID: workspace.id, provider: .iterm2)
        XCTAssertEqual(itermWindows.count, 1)
        XCTAssertEqual(itermWindows[0].provider, .iterm2)
        XCTAssertEqual(itermWindows[0].terminalTrackingID, "session-a")
    }

    // Tests deleteAgentWindow removes a single record by arranging representative inputs and asserting the expected result.
    func testDeleteAgentWindowRemovesSingleRecord() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let idA = UUID().uuidString
        let idB = UUID().uuidString
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: idA, workspaceID: workspace.id, provider: .iterm2, label: nil, terminalTrackingID: "session-a", codexThreadID: nil, windowID: nil,
                yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: idB, workspaceID: workspace.id, provider: .iterm2, label: nil, terminalTrackingID: "session-b", codexThreadID: nil, windowID: nil,
                yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z"))

        try store.deleteAgentWindow(id: idA)
        let remaining = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, idB)
    }

    // Tests deleteAgentWindowsByProvider removes terminal-agent rows for the workspace by arranging representative inputs and asserting the expected result.
    func testDeleteAgentWindowsByProviderRemovesOnlyMatchingProvider() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: nil, terminalTrackingID: "s1", codexThreadID: nil,
                windowID: nil, yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: nil, terminalTrackingID: "s2", codexThreadID: nil,
                windowID: nil, yabaiWindowID: nil, status: .spinning, createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z"))

        try store.deleteAgentWindowsByProvider(workspaceID: workspace.id, provider: .iterm2)
        let all = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertTrue(all.isEmpty)
    }

    // Tests updateAgentWindowStatus persists the new status by arranging representative inputs and asserting the expected result.
    func testUpdateAgentWindowStatusPersistsNewStatus() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let id = UUID().uuidString
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: id, workspaceID: workspace.id, provider: .iterm2, label: nil, terminalTrackingID: "s1", codexThreadID: nil, windowID: nil,
                yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))

        try store.updateAgentWindowStatus(id: id, status: .done, updatedAt: "2026-01-01T00:01:00Z")
        let updated = try store.agentWindows(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .done)
    }

    // Tests workspaceSetupState persists all fields by arranging representative inputs and asserting the expected result.
    func testWorkspaceSetupStateRoundTrip() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        // No setup state yet.
        XCTAssertNil(try store.workspaceSetupState(workspaceID: workspace.id))

        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .running, errorMessage: nil, startedAt: "2026-01-01T00:00:00Z", finishedAt: nil)
        let running = try store.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(running?.status, .running)
        XCTAssertNil(running?.errorMessage)

        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .failed, errorMessage: "setup failed", startedAt: "2026-01-01T00:00:00Z",
            finishedAt: "2026-01-01T00:00:05Z")
        let failed = try store.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.errorMessage, "setup failed")
        XCTAssertEqual(failed?.finishedAt, "2026-01-01T00:00:05Z")
    }

    // Tests workspace lookup by directory by arranging representative inputs and asserting the expected result.
    func testWorkspaceLookupByDirectory() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let workspace1Dir = try makeTempDirectory().path
        let workspace2Dir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace1 = WorkspaceRecord(
            id: "ws1", projectID: project.id, title: "feature-1", dir: workspace1Dir, dirname: "feature-1", branch: "feature-1", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let workspace2 = WorkspaceRecord(
            id: "ws2", projectID: project.id, title: "feature-2", dir: workspace2Dir, dirname: "feature-2", branch: "feature-2", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace1)
        try store.upsert(workspace: workspace2)
        let found1 = try store.workspace(dir: workspace1Dir)
        XCTAssertEqual(found1?.id, "ws1")
        XCTAssertEqual(found1?.title, "feature-1")
        XCTAssertEqual(found1?.dir, workspace1Dir)
        let found2 = try store.workspace(dir: workspace2Dir)
        XCTAssertEqual(found2?.id, "ws2")
        XCTAssertEqual(found2?.title, "feature-2")
        let notFound = try store.workspace(dir: "/nonexistent/path")
        XCTAssertNil(notFound)
    }

    // Tests updateWorkspaceBranch persists the new branch value by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceBranchPersists() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: try makeTempDirectory().path)
        try store.upsert(workspace: workspace)

        try store.updateWorkspaceBranch(id: workspace.id, branch: "feature/new-name")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.branch, "feature/new-name")

        try store.updateWorkspaceBranch(id: workspace.id, branch: nil)
        let afterNil = try store.workspace(id: workspace.id)?.branch
        // Nil branch is stored as empty string and read back as nil or empty.
        XCTAssertTrue(afterNil == nil || afterNil?.isEmpty == true)
    }

    // Tests updateWorkspaceDirname persists the new dirname value by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceDirnamePersists() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: try makeTempDirectory().path)
        try store.upsert(workspace: workspace)

        try store.updateWorkspaceDirname(id: workspace.id, dirname: "new-feature-dir")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.dirname, "new-feature-dir")
    }

    // Tests appConfig falls back to the default port range when stored values are invalid (end <= start).
    func testAppConfigInvalidPortRangeFallsBackToDefault() throws {
        let store = try makeTemporaryStore()
        // Write an invalid range where end < start; appConfig should substitute the default.
        try store.setAppConfig(AppConfig(portRange: PortRange(start: 30000, end: 20000)))
        let config = try store.appConfig()
        XCTAssertEqual(config.portRange.start, 20000)
        XCTAssertEqual(config.portRange.end, 30000)
    }

    // Tests setAppConfig round-trips a valid port range and editor preference through the settings store.
    func testSetAppConfigRoundTripsPortRangeAndEditor() throws {
        let store = try makeTemporaryStore()
        try store.setAppConfig(AppConfig(editor: .cursor, portRange: PortRange(start: 10000, end: 15000)))
        let config = try store.appConfig()
        XCTAssertEqual(config.editor, .cursor)
        XCTAssertEqual(config.portRange.start, 10000)
        XCTAssertEqual(config.portRange.end, 15000)
    }

    private func runSQLiteExec(dbURL: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "spaces.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed opening test sqlite db"])
        }
        defer { sqlite3_close(db) }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.tests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func openSQLiteHandle(dbURL: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed opening test sqlite db"
            if let db { sqlite3_close(db) }
            throw NSError(domain: "spaces.tests", code: 11, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return db
    }

    private func readSingleInteger(dbURL: URL, sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "spaces.tests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed opening test sqlite db"])
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.tests", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "spaces.tests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing row for query: \(sql)"])
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func readSingleText(dbURL: URL, sql: String) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "spaces.tests", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed opening test sqlite db"])
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.tests", code: 9, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
            throw NSError(domain: "spaces.tests", code: 10, userInfo: [NSLocalizedDescriptionKey: "Missing row for query: \(sql)"])
        }
        return String(cString: raw)
    }

    private func readTableColumns(dbURL: URL, table: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "spaces.tests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed opening test sqlite db"])
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.tests", code: 7, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }

        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(statement, 1) else { continue }
            columns.append(String(cString: namePtr))
        }
        return columns
    }

    private func readRows(dbURL: URL, sql: String) throws -> [[String?]] {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "spaces.tests", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed opening test sqlite db"])
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.tests", code: 13, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String?] = []
            for index in 0..<Int(sqlite3_column_count(statement)) {
                if let value = sqlite3_column_text(statement, Int32(index)) { row.append(String(cString: value)) } else { row.append(nil) }
            }
            rows.append(row)
        }
        return rows
    }

    private func createSchemaV1Fixture(dbURL: URL) throws {
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE projects (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  dir TEXT NOT NULL UNIQUE,
                  is_git INTEGER NOT NULL,
                  default_branch TEXT,
                  is_collapsed INTEGER NOT NULL DEFAULT 0,
                  setup_script TEXT,
                  stop_script TEXT
                );
                CREATE TABLE project_port_definitions (
                  id TEXT NOT NULL,
                  project_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  PRIMARY KEY (project_id, order_index)
                );
                CREATE TABLE project_processes (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT,
                  command TEXT NOT NULL,
                  on_exit TEXT NOT NULL DEFAULT 'none',
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE project_status_checks (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT,
                  process TEXT NOT NULL,
                  command TEXT NOT NULL,
                  interval INTEGER NOT NULL,
                  timeout INTEGER NOT NULL,
                  on_fail TEXT NOT NULL,
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE project_browser_sessions (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT,
                  url TEXT,
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE project_agent_launchers (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT NOT NULL,
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE workspaces (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  title TEXT NOT NULL,
                  dir TEXT NOT NULL,
                  dirname TEXT,
                  branch TEXT,
                  target_branch TEXT,
                  is_default INTEGER NOT NULL,
                  is_archived INTEGER NOT NULL,
                  is_hidden INTEGER NOT NULL DEFAULT 0,
                  is_running INTEGER NOT NULL,
                  last_launched_at TEXT,
                  tooltip TEXT,
                  UNIQUE(project_id, title)
                );
                CREATE TABLE workspace_ports (
                  workspace_id TEXT NOT NULL,
                  port_index INTEGER NOT NULL,
                  port_number INTEGER NOT NULL,
                  port_name TEXT NOT NULL DEFAULT '',
                  definition_id TEXT NOT NULL DEFAULT '',
                  PRIMARY KEY (workspace_id, port_index)
                );
                CREATE TABLE workspace_port_definitions (
                  id TEXT NOT NULL,
                  workspace_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  PRIMARY KEY (workspace_id, order_index)
                );
                CREATE TABLE workspace_settings (
                  workspace_id TEXT PRIMARY KEY,
                  stop_script TEXT,
                  setup_status TEXT NOT NULL DEFAULT 'succeeded',
                  setup_error TEXT,
                  setup_started_at TEXT,
                  setup_finished_at TEXT
                );
                CREATE TABLE workspace_processes (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT,
                  command TEXT NOT NULL,
                  on_exit TEXT NOT NULL DEFAULT 'none',
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE workspace_status_checks (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT,
                  process TEXT NOT NULL,
                  command TEXT NOT NULL,
                  interval INTEGER NOT NULL,
                  timeout INTEGER NOT NULL,
                  on_fail TEXT NOT NULL DEFAULT 'none',
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE workspace_browser_sessions (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT,
                  url TEXT,
                  extracted_target_url TEXT,
                  extracted_window_id INTEGER,
                  extracted_window_valid INTEGER NOT NULL DEFAULT 0,
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE workspace_agent_launchers (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT NOT NULL,
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE running_processes (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  template_name TEXT NOT NULL,
                  command TEXT NOT NULL,
                  terminal_app TEXT,
                  window_id INTEGER,
                  terminal_tracking_id TEXT,
                  terminal_native_id TEXT,
                  iterm_tab_index INTEGER,
                  tmux_window_id TEXT,
                  pid INTEGER,
                  status TEXT NOT NULL,
                  log_path TEXT,
                  last_output_at TEXT,
                  started_at TEXT,
                  exited_at TEXT
                );
                CREATE TABLE status_results (
                  process_id TEXT NOT NULL,
                  check_name TEXT NOT NULL,
                  status TEXT NOT NULL,
                  message TEXT,
                  last_run_at TEXT,
                  PRIMARY KEY (process_id, check_name)
                );
                CREATE TABLE windows (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  app TEXT NOT NULL,
                  name TEXT,
                  detail TEXT,
                  target_url TEXT,
                  window_id INTEGER,
                  terminal_tracking_id TEXT,
                  terminal_native_id TEXT,
                  iterm_tab_index INTEGER,
                  tmux_window_id TEXT,
                  role TEXT NOT NULL,
                  order_index INTEGER,
                  last_seen_at TEXT
                );
                CREATE TABLE settings (
                  key TEXT PRIMARY KEY,
                  value TEXT NOT NULL
                );
                CREATE TABLE ignored_worktrees (
                  worktree_dir TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL
                );
                CREATE TABLE agent_windows (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  label TEXT,
                  terminal_tracking_id TEXT,
                  terminal_native_id TEXT,
                  tmux_window_id TEXT,
                  codex_thread_id TEXT,
                  window_id INTEGER,
                  status TEXT NOT NULL DEFAULT 'idle',
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  yabai_window_id INTEGER
                );
                CREATE TABLE migration_state (
                  current_version INTEGER NOT NULL
                );
                INSERT INTO projects(id, name, dir, is_git, default_branch, is_collapsed, setup_script, stop_script)
                VALUES ('project-1', 'Project', '/tmp/project', 1, 'main', 1, 'echo setup', 'echo stop');
                INSERT INTO project_port_definitions(id, project_id, name, order_index)
                VALUES ('project-port-1', 'project-1', 'API_PORT', 0);
                INSERT INTO project_processes(id, project_id, name, command, on_exit, order_index)
                VALUES ('project-process-1', 'project-1', 'api', 'npm run api', 'none', 0);
                INSERT INTO project_status_checks(id, project_id, name, process, command, interval, timeout, on_fail, order_index)
                VALUES ('project-check-1', 'project-1', 'API Health', 'api', 'curl localhost', 10, 5, 'restart', 0);
                INSERT INTO project_browser_sessions(id, project_id, name, url, order_index)
                VALUES ('project-browser-1', 'project-1', 'Docs', 'https://example.com/docs', 0);
                INSERT INTO project_agent_launchers(id, project_id, name, command, order_index)
                VALUES ('project-agent-1', 'project-1', 'Codex', 'codex', 0);
                INSERT INTO workspaces(id, project_id, title, dir, dirname, branch, target_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, tooltip)
                VALUES ('workspace-1', 'project-1', 'feature', '/tmp/project/feature', 'feature', 'feature', 'main', 0, 0, 0, 1, '2026-01-01T00:00:00Z', 'Feature tooltip');
                INSERT INTO workspace_ports(workspace_id, port_index, port_number, port_name, definition_id)
                VALUES ('workspace-1', 0, 3000, 'API_PORT', 'workspace-port-definition-1');
                INSERT INTO workspace_port_definitions(id, workspace_id, name, order_index)
                VALUES ('workspace-port-definition-1', 'workspace-1', 'API_PORT', 0);
                INSERT INTO workspace_settings(workspace_id, stop_script, setup_status, setup_error, setup_started_at, setup_finished_at)
                VALUES ('workspace-1', 'echo stop', 'failed', 'boom', 'start', 'end');
                INSERT INTO workspace_processes(id, workspace_id, name, command, on_exit, order_index)
                VALUES ('workspace-process-1', 'workspace-1', 'api', 'npm run api', 'none', 0);
                INSERT INTO workspace_status_checks(id, workspace_id, name, process, command, interval, timeout, on_fail, order_index)
                VALUES ('workspace-check-1', 'workspace-1', 'API Health', 'api', 'curl localhost', 10, 5, 'restart', 0);
                INSERT INTO workspace_browser_sessions(id, workspace_id, name, url, extracted_target_url, extracted_window_id, extracted_window_valid, order_index)
                VALUES ('workspace-browser-1', 'workspace-1', 'Docs', 'https://example.com', 'https://example.com', 303, 1, 0);
                INSERT INTO workspace_agent_launchers(id, workspace_id, name, command, order_index)
                VALUES ('workspace-agent-1', 'workspace-1', 'Codex', 'codex', 0);
                INSERT INTO running_processes(id, workspace_id, template_name, command, terminal_app, window_id, terminal_tracking_id, terminal_native_id, iterm_tab_index, tmux_window_id, pid, status, log_path, last_output_at, started_at, exited_at)
                VALUES ('running-process-1', 'workspace-1', 'api', 'npm run api', 'iTerm2', 101, 'session-1', 'native-1', 1, '@1', 12345, 'running', '/tmp/api.log', '2026-01-01T00:00:01Z', '2026-01-01T00:00:00Z', '');
                INSERT INTO status_results(process_id, check_name, status, message, last_run_at)
                VALUES ('running-process-1', 'API Health', 'passing', 'ok', '2026-01-01T00:00:02Z');
                INSERT INTO windows(id, workspace_id, app, name, detail, target_url, window_id, terminal_tracking_id, terminal_native_id, iterm_tab_index, tmux_window_id, role, order_index, last_seen_at)
                VALUES ('window-1', 'workspace-1', 'Google Chrome', 'Docs', 'docs', 'https://example.com', 303, '', '', NULL, '', 'browser', 0, '2026-01-01T00:00:03Z');
                INSERT INTO settings(key, value) VALUES ('terminalHost', 'iterm2');
                INSERT INTO ignored_worktrees(worktree_dir, project_id) VALUES ('/tmp/project/ignored', 'project-1');
                INSERT INTO agent_windows(id, workspace_id, provider, label, terminal_tracking_id, terminal_native_id, tmux_window_id, codex_thread_id, window_id, status, created_at, updated_at, yabai_window_id)
                VALUES ('agent-window-1', 'workspace-1', 'iterm2', 'Codex', 'session-1', 'native-1', '', 'thread-1', 101, 'running', '2026-01-01T00:00:00Z', '2026-01-01T00:00:03Z', 101);
                INSERT INTO migration_state(current_version) VALUES (1);
                """)
    }
}
