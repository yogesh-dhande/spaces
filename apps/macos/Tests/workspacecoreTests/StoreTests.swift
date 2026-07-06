import XCTest

@testable import spacesdatabase
@testable import workspacecore

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

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
        let workspacePortColumns = try readTableColumns(dbURL: dbURL, table: "workspace_service_ports")
        let workspaceServiceDefinitionColumns = try readTableColumns(dbURL: dbURL, table: "workspace_services")
        let projectServiceDefinitionColumns = try readTableColumns(dbURL: dbURL, table: "project_services")
        let workspaceProcessColumns = try readTableColumns(dbURL: dbURL, table: "workspace_processes")
        let projectProcessColumns = try readTableColumns(dbURL: dbURL, table: "project_processes")
        let runningProcessColumns = try readTableColumns(dbURL: dbURL, table: "running_processes")
        let workspaceBrowserSessionColumns = try readTableColumns(dbURL: dbURL, table: "workspace_browser_sessions")
        let projectBrowserSessionColumns = try readTableColumns(dbURL: dbURL, table: "project_browser_sessions")
        let workspaceAgentLauncherColumns = try readTableColumns(dbURL: dbURL, table: "workspace_agent_launchers")
        let projectAgentLauncherColumns = try readTableColumns(dbURL: dbURL, table: "project_agent_launchers")
        let runtimeTargetColumns = try readTableColumns(dbURL: dbURL, table: "runtime_targets")
        let browserTargetColumns = try readTableColumns(dbURL: dbURL, table: "browser_targets")
        let agentSessionColumns = try readTableColumns(dbURL: dbURL, table: "agent_sessions")
        let terminalSessionColumns = try readTableColumns(dbURL: dbURL, table: "terminal_sessions")
        let terminalRuntimeStateColumns = try readTableColumns(dbURL: dbURL, table: "terminal_runtime_states")
        let terminalClientColumns = try readTableColumns(dbURL: dbURL, table: "terminal_clients")
        let terminalAttachmentColumns = try readTableColumns(dbURL: dbURL, table: "terminal_attachments")
        let terminalRemoteStateColumns = try readTableColumns(dbURL: dbURL, table: "terminal_remote_session_states")
        let workspaceForeignKeys = try readSingleInteger(dbURL: dbURL, sql: "SELECT COUNT(*) FROM pragma_foreign_key_list('workspaces')")
        XCTAssertEqual(version, DatabaseSchema.currentVersion)
        XCTAssertFalse(workspaceColumns.contains("title"))
        XCTAssertTrue(workspaceColumns.contains("notes"))
        XCTAssertTrue(workspaceColumns.contains("is_hidden"))
        XCTAssertFalse(workspaceColumns.contains("host_id"))
        XCTAssertTrue(workspaceColumns.contains("runtime_path"))
        XCTAssertFalse(workspaceColumns.contains("compute_host_override_id"))
        XCTAssertFalse(projectColumns.contains("is_collapsed"))
        XCTAssertFalse(projectColumns.contains("default_compute_host_id"))
        XCTAssertFalse(workspaceProcessColumns.contains("execution_mode"))
        XCTAssertFalse(projectProcessColumns.contains("execution_mode"))
        XCTAssertTrue(runningProcessColumns.contains("template_id"))
        XCTAssertTrue(runningProcessColumns.contains("terminal_session_id"))
        XCTAssertFalse(runningProcessColumns.contains("terminal_app"))
        XCTAssertFalse(runningProcessColumns.contains("window_id"))
        XCTAssertFalse(runningProcessColumns.contains("terminal_tracking_id"))
        XCTAssertFalse(runningProcessColumns.contains("terminal_native_id"))
        XCTAssertFalse(runningProcessColumns.contains("terminal_container_id"))
        XCTAssertFalse(runningProcessColumns.contains("iterm_tab_index"))
        XCTAssertFalse(runningProcessColumns.contains("tmux_window_id"))
        XCTAssertFalse(workspaceSettingsColumns.contains("updated_at"))
        XCTAssertTrue(workspaceSettingsColumns.contains("setup_exit_code"))
        XCTAssertTrue(workspaceSettingsColumns.contains("setup_log_path"))
        XCTAssertTrue(workspacePortColumns.contains("service_id"))
        XCTAssertTrue(workspaceServiceDefinitionColumns.contains("id"))
        XCTAssertTrue(projectServiceDefinitionColumns.contains("id"))
        XCTAssertFalse(workspaceBrowserSessionColumns.contains("id"))
        XCTAssertFalse(workspaceBrowserSessionColumns.contains("extracted_window_id"))
        XCTAssertFalse(workspaceBrowserSessionColumns.contains("extracted_window_valid"))
        XCTAssertFalse(workspaceBrowserSessionColumns.contains("extracted_target_url"))
        XCTAssertFalse(projectBrowserSessionColumns.contains("id"))
        XCTAssertTrue(workspaceAgentLauncherColumns.contains("id"))
        XCTAssertTrue(projectAgentLauncherColumns.contains("id"))
        XCTAssertTrue(runtimeTargetColumns.contains("type"))
        XCTAssertTrue(runtimeTargetColumns.contains("tracking_id"))
        XCTAssertTrue(runtimeTargetColumns.contains("updated_at"))
        XCTAssertFalse(runtimeTargetColumns.contains("native_id"))
        XCTAssertFalse(runtimeTargetColumns.contains("provider"))
        XCTAssertFalse(runtimeTargetColumns.contains("container_id"))
        XCTAssertTrue(browserTargetColumns.contains("resolved_url"))
        XCTAssertTrue(agentSessionColumns.contains("runtime_target_id"))
        XCTAssertTrue(agentSessionColumns.contains("terminal_session_id"))
        XCTAssertTrue(agentSessionColumns.contains("session_key"))
        XCTAssertTrue(agentSessionColumns.contains("claimed_launcher_id"))
        XCTAssertTrue(agentSessionColumns.contains("claimed_launcher_name"))
        XCTAssertTrue(terminalSessionColumns.contains("root_directory"))
        XCTAssertTrue(terminalSessionColumns.contains("workspace_id"))
        XCTAssertTrue(terminalSessionColumns.contains("kind"))
        XCTAssertTrue(terminalRuntimeStateColumns.contains("foreground_pid"))
        XCTAssertTrue(terminalRuntimeStateColumns.contains("foreground_executable_path"))
        XCTAssertTrue(terminalRuntimeStateColumns.contains("foreground_executable_name"))
        XCTAssertTrue(terminalRuntimeStateColumns.contains("foreground_argv_json"))
        XCTAssertTrue(terminalRuntimeStateColumns.contains("foreground_detected_agent_kind"))
        XCTAssertTrue(terminalRuntimeStateColumns.contains("foreground_display_label"))
        XCTAssertTrue(terminalRuntimeStateColumns.contains("foreground_display_command"))
        XCTAssertTrue(terminalClientColumns.contains("lease_refreshed_at"))
        XCTAssertTrue(terminalAttachmentColumns.contains("detached_at"))
        XCTAssertTrue(terminalRemoteStateColumns.contains("payload_json"))
        XCTAssertFalse(agentSessionColumns.contains("terminal_target_id"))
        XCTAssertFalse(agentSessionColumns.contains("terminal_tracking_id"))
        XCTAssertFalse(agentSessionColumns.contains("terminal_native_id"))
        XCTAssertEqual(workspaceForeignKeys, 1)
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "compute_hosts"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "windows"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "agent_windows"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "terminal_targets"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "project_status_checks"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "workspace_status_checks"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "status_results"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "workspace_compute_bindings"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    func testOldSchemaVersionFailsClosed() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("old-schema.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (0);
                """)

        XCTAssertThrowsError(try SQLiteStore(path: dbURL.path)) { error in
            XCTAssertEqual(
                error.localizedDescription, "No migration step exists from schema version 0; cannot reach version \(DatabaseSchema.currentVersion).")
        }
    }

    // Any database at a released schema version must reach the current version by applying every
    // intermediate step serially — the step list may never skip a version.
    func testMigrationStepsFormOneSerialChainToCurrentVersion() {
        var version = 1
        while version < DatabaseSchema.currentVersion {
            guard let step = DatabaseSchema.migrationSteps.first(where: { $0.fromVersion == version }) else {
                return XCTFail("No migration step from schema version \(version)")
            }
            XCTAssertEqual(step.toVersion, version + 1, "Step from \(version) must move exactly one version forward")
            version = step.toVersion
        }
    }

    // Tests opening a current-version database is a no-op by arranging a fresh current DB and asserting no migration backup is created on reopen.
    func testOpeningCurrentVersionDoesNotCreateMigrationBackup() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("current.db")

        _ = try SQLiteStore(path: dbURL.path)
        _ = try SQLiteStore(path: dbURL.path)

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    func testCurrentSchemaRejectsBlankPortNamesAtDatabaseLevel() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("port-name-constraints.db")
        _ = try SQLiteStore(path: dbURL.path)

        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                INSERT INTO projects(id, name, dir, is_git) VALUES ('project-1', 'Project', '/tmp/project', 0);
                INSERT INTO workspaces(id, project_id, dir, runtime_path, is_default, is_archived, is_hidden, is_running)
                VALUES ('workspace-1', 'project-1', '/tmp/project/feature', '/tmp/project/feature', 0, 0, 0, 0);
                """)

        XCTAssertThrowsError(
            try runSQLiteExec(
                dbURL: dbURL, sql: "INSERT INTO project_services(id, project_id, name, order_index) VALUES ('ppd-1', 'project-1', ' ', 0);"))
        XCTAssertThrowsError(
            try runSQLiteExec(
                dbURL: dbURL, sql: "INSERT INTO workspace_services(id, workspace_id, name, order_index) VALUES ('wpd-1', 'workspace-1', char(10), 0);"
            ))
        XCTAssertThrowsError(
            try runSQLiteExec(
                dbURL: dbURL,
                sql:
                    "INSERT INTO workspace_service_ports(workspace_id, service_index, port, service_name, service_id) VALUES ('workspace-1', 0, 3000, char(9), 'wpd-1');"
            ))
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
            currentSchemaVersion: 4,
            steps: [
                DatabaseMigrationStep(fromVersion: 1, toVersion: 2, description: "one", requiresBackup: true) { db in
                    _ = sqlite3_exec(db, "INSERT INTO migration_log(entry) VALUES ('1-2');", nil, nil, nil)
                },
                DatabaseMigrationStep(fromVersion: 2, toVersion: 3, description: "two", requiresBackup: true) { db in
                    _ = sqlite3_exec(db, "INSERT INTO migration_log(entry) VALUES ('2-3');", nil, nil, nil)
                },
                DatabaseMigrationStep(fromVersion: 3, toVersion: 4, description: "three", requiresBackup: true) { db in
                    _ = sqlite3_exec(db, "INSERT INTO migration_log(entry) VALUES ('3-4');", nil, nil, nil)
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

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), 4)
        XCTAssertEqual(
            try readRows(dbURL: dbURL, sql: "SELECT entry FROM migration_log ORDER BY rowid").compactMap { $0.first ?? nil }, ["1-2", "2-3", "3-4"])
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
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 3001], names: ["api", "web"])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [3000, 3001])
        let named = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(named[0].name, "api")
        XCTAssertEqual(named[1].name, "web")
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [4000], names: ["admin"])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [4000])
        let namedAfter = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(namedAfter[0].name, "admin")

        let processes = [ProcessTemplate(name: "api", command: "npm run api"), ProcessTemplate(command: "npm run worker")]
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: processes)
        let storedProcesses = try store.workspaceProcesses(workspaceID: workspace.id)
        XCTAssertEqual(storedProcesses.count, 2)
        XCTAssertEqual(storedProcesses[0].name, "api")
        XCTAssertEqual(storedProcesses[1].name, nil)

        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(name: "checkout", url: "https://example.com"), BrowserSession()])
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].name, "checkout")
        XCTAssertEqual(sessions[0].url, "https://example.com")

        let codexLauncher = AgentLauncher(id: "launcher-codex", name: "Codex", command: "codex")
        let claudeLauncher = AgentLauncher(id: "launcher-claude", name: "Claude", command: "claude")
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [codexLauncher, claudeLauncher])
        let launchers = try store.workspaceAgentLaunchers(workspaceID: workspace.id)
        XCTAssertEqual(launchers, [codexLauncher, claudeLauncher])
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

        let definitions = [ServiceDefinition(name: "frontend"), ServiceDefinition(name: "api")]
        try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: definitions)
        let storedDefs = try store.workspaceServiceDefinitions(workspaceID: workspace.id)
        XCTAssertEqual(storedDefs.count, 2)
        XCTAssertEqual(storedDefs[0].name, "frontend")
        XCTAssertEqual(storedDefs[1].name, "api")

        try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: [ServiceDefinition(name: "db")])
        XCTAssertEqual(try store.workspaceServiceDefinitions(workspaceID: workspace.id).count, 1)
        XCTAssertEqual(try store.workspaceServiceDefinitions(workspaceID: workspace.id)[0].name, "db")
    }

    func testStoreRejectsBlankPortNames() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        XCTAssertThrowsError(
            try store.upsert(
                project: ProjectRecord(
                    id: project.id, name: project.name, dir: project.dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil,
                    ports: [ServiceDefinition(name: " ")], processes: [], browserSessions: [], agentLaunchers: [])))
        XCTAssertThrowsError(try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: [ServiceDefinition(name: "\n")]))
        XCTAssertThrowsError(try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["\t"]))
    }

    func testStoreRejectsDuplicateServiceNames() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        XCTAssertThrowsError(
            try store.upsert(
                project: ProjectRecord(
                    id: project.id, name: project.name, dir: project.dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil,
                    ports: [ServiceDefinition(name: "api"), ServiceDefinition(name: "api")], processes: [], browserSessions: [], agentLaunchers: [])))
        XCTAssertThrowsError(
            try store.setWorkspaceServiceDefinitions(
                workspaceID: workspace.id, definitions: [ServiceDefinition(name: "api"), ServiceDefinition(name: "api")]))
        XCTAssertThrowsError(try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 3001], names: ["api", "api"]))
    }

    // Tests a delete-and-reinsert logical write is atomic by arranging a duplicate-ID failure and asserting the original child rows survive unchanged.
    func testSetWorkspaceProcessesRollsBackReplacementOnFailure() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
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

    // Tests project records remain daemon-owned data without client sidebar state.
    func testProjectRoundTripDoesNotRequireSidebarState() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("project-round-trip.db")
        let store = try SQLiteStore(path: dbURL.path)
        let project = makeProjectRecord(id: "p1", dir: "/tmp/project")
        try store.upsert(project: project)

        XCTAssertEqual(try store.project(id: "p1")?.name, "Project")
        XCTAssertEqual(try store.project(id: "p1")?.dir, "/tmp/project")
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
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let processID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces",
                terminalTrackingID: "session-abc", pid: 1234, status: .running, logPath: "/tmp/api.log", lastOutputAt: "2026-01-01T00:00:00Z",
                startedAt: "2026-01-01T00:00:00Z", exitedAt: nil))

        var processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0].status, .running)
        XCTAssertEqual(processes[0].terminalTrackingID, "session-abc")

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: nil, terminalTarget: nil,
                pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "2026-01-01T00:00:00Z", exitedAt: "2026-01-01T00:01:00Z"))
        processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes[0].status, .exited)

        let firstWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Browser", role: "browser", orderIndex: 0,
            lastSeenAt: "now")
        let secondWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, title: "Terminal", role: "terminal", orderIndex: 1,
            lastSeenAt: "now")
        try store.upsert(window: firstWindow)
        try store.upsert(window: secondWindow)

        let storedWindows = try store.windows(workspaceID: workspace.id)
        XCTAssertEqual(storedWindows.count, 3)
        XCTAssertEqual(storedWindows[0].name, "Browser")
        XCTAssertEqual(storedWindows[0].detail, nil)
        XCTAssertEqual(storedWindows.first(where: { $0.id == firstWindow.id })?.roleValue, .browser)
        XCTAssertEqual(storedWindows.first(where: { $0.id == secondWindow.id })?.roleValue, .terminal)
        XCTAssertTrue(storedWindows.contains(where: { $0.name == "Terminal" }))
        try store.deleteWindow(id: firstWindow.id)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).count, 2)
        try store.deleteWindows(workspaceID: workspace.id)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testSpacesRunningProcessKeepsSessionIDAfterRuntimeTargetIsDeleted() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "spaces-process-session"
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: workspace.id, templateName: "docs-watch", command: "sleep 300",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil, status: .exited,
                logPath: nil, lastOutputAt: nil, startedAt: "2026-06-04T14:23:10Z", exitedAt: "2026-06-04T14:23:23Z"))

        let loaded = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        let runtimeTargetID = try XCTUnwrap(loaded.runtimeTargetID)
        try store.deleteWindow(id: runtimeTargetID)

        let reloaded = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertNil(reloaded.runtimeTargetID)
        XCTAssertEqual(reloaded.terminalApp, TerminalHost.spaces.appName)
        XCTAssertEqual(reloaded.terminalTrackingID, sessionID)
        XCTAssertEqual(reloaded.terminalNativeID, sessionID)
        XCTAssertEqual(try store.workspaceIDForTerminalSession(sessionID), workspace.id)
    }

    func testWorkspaceIDForTerminalSessionResolvesPreservedAgentSessionIDAfterRuntimeTargetIsDeleted() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "spaces-agent-session"
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID,
                codexThreadID: "thread-123", status: .done, createdAt: "2026-02-25T00:00:00Z", updatedAt: "2026-02-25T00:00:01Z"))

        let loaded = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        let runtimeTargetID = try XCTUnwrap(loaded.runtimeTargetID)
        try store.deleteWindow(id: runtimeTargetID)

        XCTAssertEqual(try store.workspaceIDForTerminalSession(sessionID), workspace.id)
    }

    func testWorkspaceIDForTerminalSessionResolvesWorkspaceOwnedTerminalRow() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces-test.db")
        let store = try SQLiteStore(path: dbURL.path)
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "workspace-owned-shell-session"
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                INSERT INTO terminal_sessions(
                  session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, working_directory, shell, created_at
                )
                VALUES(
                  '\(sessionID)', '/tmp/workspace-owned-shell-session', 'ghostty-embedded', 'persistent',
                  '\(workspace.id)', 'shell', 'shell', '\(workspace.dir)', '/bin/zsh', '2026-06-11T00:00:00Z'
                );
                """)

        XCTAssertEqual(try store.workspaceIDForTerminalSession(sessionID), workspace.id)
    }

    // Every terminal session is now workspace-owned, so the v11->v12 migration drops any
    // surviving NULL-workspace terminal_sessions row (a transient session record, not a
    // project/workspace) while preserving workspace-owned rows intact.
    func testV11ToV12MigrationDropsNullWorkspaceTerminalSessionsAndKeepsOwnedOnes() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("v11.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (11);
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
                  created_at TEXT NOT NULL
                );
                INSERT INTO terminal_sessions(
                  session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, working_directory, shell, created_at
                )
                VALUES(
                  'session-owned', '/tmp/session-owned', 'ghostty-embedded', 'persistent', 'workspace-1', 'shell', 'shell', '/tmp/work',
                  '/bin/zsh', '2026-06-11T00:00:00Z'
                );
                INSERT INTO terminal_sessions(
                  session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, working_directory, shell, created_at
                )
                VALUES(
                  'session-standalone', '/tmp/session-standalone', 'ghostty-embedded', 'persistent', NULL, 'shell', 'shell', '/tmp/other',
                  '/bin/zsh', '2026-06-11T00:00:00Z'
                );
                """)

        _ = try SQLiteStore(path: dbURL.path)

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
        let sessionIDs = try readRows(dbURL: dbURL, sql: "SELECT session_id FROM terminal_sessions ORDER BY session_id").compactMap {
            $0.first ?? nil
        }
        XCTAssertEqual(sessionIDs, ["session-owned"])
        let terminalSessionColumns = try readTableColumns(dbURL: dbURL, table: "terminal_sessions")
        XCTAssertTrue(terminalSessionColumns.contains("workspace_id"))
        XCTAssertThrowsError(
            try runSQLiteExec(
                dbURL: dbURL,
                sql: """
                    INSERT INTO terminal_sessions(
                      session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, working_directory, shell, created_at
                    )
                    VALUES('session-new-null', '/tmp/session-new-null', 'ghostty-embedded', 'persistent', NULL, 'shell', 'shell', '/tmp/new',
                      '/bin/zsh', '2026-06-11T00:00:01Z');
                    """))
    }

    // Tests delete workspace removes dependent rows by arranging representative inputs and asserting the expected result.
    func testDeleteWorkspaceRemovesDependentRows() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let processID = UUID().uuidString
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["api"])
        try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: [ServiceDefinition(name: "api")])
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(command: "echo one")])
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "https://example.com")])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "one", command: "echo one", terminalApp: nil, terminalTarget: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "term", role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        try store.deleteWorkspace(id: workspace.id)

        XCTAssertNil(try store.workspace(id: workspace.id))
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspaceServiceDefinitions(workspaceID: workspace.id).isEmpty)
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
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
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
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["api"])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: nil, role: "browser", orderIndex: 0, lastSeenAt: "now")
        )

        try store.deleteProject(id: project.id)

        XCTAssertNil(try store.project(id: project.id))
        XCTAssertTrue(try store.workspaces(projectID: project.id, includeArchived: true).isEmpty)
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    // Tests workspace and setting state updates persist by arranging representative inputs and asserting the expected result.
    func testWorkspaceAndSettingStateUpdatesPersist() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
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
            id: "default", projectID: aProject.id, dir: aDir, dirname: nil, branch: nil, isDefault: true, isArchived: false, isRunning: false,
            lastLaunchedAt: nil)
        let archivedWorkspace = WorkspaceRecord(
            id: "archived", projectID: aProject.id, dir: aDir, dirname: nil, branch: nil, baseBranch: "develop", isDefault: false, isArchived: true,
            isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: archivedWorkspace)
        try store.upsert(workspace: defaultWorkspace)

        XCTAssertEqual(try store.workspace(id: "archived")?.id, "archived")
        XCTAssertEqual(try store.workspace(id: "archived")?.baseBranch, "develop")
        XCTAssertEqual(try store.workspaces(projectID: aProject.id, includeArchived: false).map(\.id), ["default"])
        XCTAssertEqual(Set(try store.workspaces(projectID: aProject.id, includeArchived: true).map(\.id)), Set(["default", "archived"]))
    }

    // Tests delete running process and delete running processes by arranging representative inputs and asserting the expected result.
    func testDeleteRunningProcessAndDeleteRunningProcesses() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: firstID, workspaceID: workspace.id, templateName: "first", command: "echo first", terminalApp: nil, terminalTarget: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: secondID, workspaceID: workspace.id, templateName: "second", command: "echo second", terminalApp: nil, terminalTarget: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
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
            ports: [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")],
            processes: [ProcessTemplate(name: "api", command: "npm run api"), ProcessTemplate(command: "npm run worker")],
            browserSessions: [BrowserSession(name: "frontend", url: "https://localhost:3000")])

        try store.upsert(project: project)

        let loaded = try store.project(id: dir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.setupScript, "echo setup")
        XCTAssertEqual(loaded?.stopScript, "echo stop")
        XCTAssertEqual(loaded?.ports.count, 2)
        XCTAssertEqual(loaded?.ports[0].name, "api")
        XCTAssertEqual(loaded?.ports[1].name, "web")
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
            id: dir, name: "project", dir: dir, isGitRepo: false, defaultBranch: nil, ports: [ServiceDefinition(name: "oldport")])
        try store.upsert(project: project)

        project.ports = [ServiceDefinition(name: "newport"), ServiceDefinition(name: "extra")]
        project.setupScript = "echo updated"
        try store.upsert(project: project)

        let loaded = try store.project(id: dir)
        XCTAssertEqual(loaded?.ports.count, 2)
        XCTAssertEqual(loaded?.ports[0].name, "newport")
        XCTAssertEqual(loaded?.setupScript, "echo updated")
    }

    // Tests delete project cascades template tables by arranging representative inputs and asserting the expected result.
    func testDeleteProjectCascadesTemplateTables() throws {
        let store = try makeTemporaryStore()
        let dir = try makeTempDirectory().path
        let project = ProjectRecord(
            id: dir, name: "project", dir: dir, isGitRepo: false, defaultBranch: nil, ports: [ServiceDefinition(name: "port")],
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
        let p1 = ProjectRecord(id: dir1, name: "alpha", dir: dir1, isGitRepo: false, defaultBranch: nil, ports: [ServiceDefinition(name: "port1")])
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

    // Tests agent window lookup by terminal session ID returns the matching record by arranging representative inputs and asserting the expected result.
    func testAgentWindowLookupByTerminalSessionID() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "session-abc"
        let id = UUID().uuidString
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: id, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: sessionID, codexThreadID: nil,
                status: .spinning, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))

        let found = try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID)
        XCTAssertEqual(found?.id, id)
        XCTAssertEqual(found?.terminalTrackingID, sessionID)
        XCTAssertNil(try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: "nonexistent"))
    }

    func testSpacesAgentKeepsSessionIDAfterRuntimeTargetIsDeleted() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "spaces-agent-session"
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "review-agent", terminalTrackingID: sessionID,
                terminalNativeID: sessionID, codexThreadID: nil, status: .done, createdAt: "2026-06-04T14:23:10Z", updatedAt: "2026-06-04T14:25:06Z"))

        let loaded = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        let runtimeTargetID = try XCTUnwrap(loaded.runtimeTargetID)
        try store.deleteWindow(id: runtimeTargetID)

        let reloaded = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertNil(reloaded.runtimeTargetID)
        XCTAssertEqual(reloaded.terminalTrackingID, sessionID)
        XCTAssertEqual(reloaded.terminalNativeID, sessionID)
        XCTAssertEqual(try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID)?.id, "agent-1")
    }

    // Tests agentWindowsByProvider returns only records from the requested workspace/provider by arranging representative inputs and asserting the expected result.
    func testAgentWindowsByProviderFiltersCorrectly() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.upsert(workspace: workspaceB)

        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "claude", terminalTrackingID: "session-a",
                codexThreadID: nil, status: .idle, createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspaceB.id, provider: .spaces, label: "codex", terminalTrackingID: "session-b",
                codexThreadID: nil, status: .spinning, createdAt: "2026-01-01T00:00:02Z", updatedAt: "2026-01-01T00:00:02Z"))

        let agentWindows = try store.agentWindowsByProvider(workspaceID: workspace.id, provider: .spaces)
        XCTAssertEqual(agentWindows.count, 1)
        XCTAssertEqual(agentWindows[0].provider, .spaces)
        XCTAssertEqual(agentWindows[0].terminalTrackingID, "session-a")
    }

    // Tests deleteAgentWindow removes a single record by arranging representative inputs and asserting the expected result.
    func testDeleteAgentWindowRemovesSingleRecord() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let idA = UUID().uuidString
        let idB = UUID().uuidString
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: idA, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "session-a", codexThreadID: nil, status: .idle,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: idB, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "session-b", codexThreadID: nil, status: .idle,
                createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z"))

        try store.deleteAgentWindow(id: idA)
        let remaining = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, idB)
    }

    // Tests deleteAgentWindowsByProvider removes terminal-agent rows for the workspace by arranging representative inputs and asserting the expected result.
    func testDeleteAgentWindowsByProviderRemovesOnlyMatchingProvider() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s1", codexThreadID: nil,
                status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s2", codexThreadID: nil,
                status: .spinning, createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z"))

        try store.deleteAgentWindowsByProvider(workspaceID: workspace.id, provider: .spaces)
        let all = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertTrue(all.isEmpty)
    }

    // Tests updateAgentWindowStatus persists the new status by arranging representative inputs and asserting the expected result.
    func testUpdateAgentWindowStatusPersistsNewStatus() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let id = UUID().uuidString
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: id, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s1", codexThreadID: nil, status: .idle,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))

        try store.updateAgentWindowStatus(id: id, status: .done, updatedAt: "2026-01-01T00:01:00Z")
        let updated = try store.agentWindows(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .done)
    }

    // Tests workspaceSetupState persists all fields by arranging representative inputs and asserting the expected result.
    func testWorkspaceSetupStateRoundTrip() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        // No setup state yet.
        XCTAssertNil(try store.workspaceSetupState(workspaceID: workspace.id))

        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .running, errorMessage: nil, startedAt: "2026-01-01T00:00:00Z", finishedAt: nil, exitCode: nil,
            logPath: "/tmp/setup.log")
        let running = try store.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(running?.status, .running)
        XCTAssertNil(running?.errorMessage)
        XCTAssertNil(running?.exitCode)
        XCTAssertEqual(running?.logPath, "/tmp/setup.log")

        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .failed, errorMessage: "setup failed", startedAt: "2026-01-01T00:00:00Z",
            finishedAt: "2026-01-01T00:00:05Z", exitCode: 42, logPath: "/tmp/setup-failed.log")
        let failed = try store.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.errorMessage, "setup failed")
        XCTAssertEqual(failed?.finishedAt, "2026-01-01T00:00:05Z")
        XCTAssertEqual(failed?.exitCode, 42)
        XCTAssertEqual(failed?.logPath, "/tmp/setup-failed.log")
    }

    // Tests workspace lookup by directory by arranging representative inputs and asserting the expected result.
    func testWorkspaceLookupByDirectory() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let workspace1Dir = try makeTempDirectory().path
        let workspace2Dir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace1 = WorkspaceRecord(
            id: "ws1", projectID: project.id, dir: workspace1Dir, dirname: "feature-1", branch: "feature-1", isDefault: false, isArchived: false,
            isRunning: false, lastLaunchedAt: nil)
        let workspace2 = WorkspaceRecord(
            id: "ws2", projectID: project.id, dir: workspace2Dir, dirname: "feature-2", branch: "feature-2", isDefault: false, isArchived: false,
            isRunning: false, lastLaunchedAt: nil)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace1)
        try store.upsert(workspace: workspace2)
        let found1 = try store.workspace(dir: workspace1Dir)
        XCTAssertEqual(found1?.id, "ws1")
        XCTAssertEqual(found1?.displayName, "feature-1")
        XCTAssertEqual(found1?.dir, workspace1Dir)
        let found2 = try store.workspace(dir: workspace2Dir)
        XCTAssertEqual(found2?.id, "ws2")
        XCTAssertEqual(found2?.displayName, "feature-2")
        let notFound = try store.workspace(dir: "/nonexistent/path")
        XCTAssertNil(notFound)
    }

    func testWorkspaceLookupByDirectoryPrefersActiveWorkspaceOverArchivedDuplicate() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let workspaceDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let archived = WorkspaceRecord(
            id: "archived", projectID: project.id, dir: workspaceDir, dirname: nil, branch: nil, isDefault: false, isArchived: true, isRunning: false,
            lastLaunchedAt: nil)
        let active = WorkspaceRecord(
            id: "active", projectID: project.id, dir: workspaceDir, dirname: nil, branch: nil, isDefault: false, isArchived: false, isRunning: false,
            lastLaunchedAt: nil)
        try store.upsert(project: project)
        try store.upsert(workspace: archived)
        try store.upsert(workspace: active)

        let found = try store.workspace(dir: workspaceDir)
        XCTAssertEqual(found?.id, "active")
    }

    func testStoreRejectsDuplicateWorkspaceBranchWithinProject() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        try store.upsert(project: project)
        let branch = "feature-branch"
        let first = WorkspaceRecord(
            id: "ws-1", projectID: project.id, dir: try makeTempDirectory().path, dirname: "feature-1", branch: branch, isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let second = WorkspaceRecord(
            id: "ws-2", projectID: project.id, dir: try makeTempDirectory().path, dirname: "feature-2", branch: branch, isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: first)

        XCTAssertThrowsError(try store.upsert(workspace: second))
    }

    // Tests updateWorkspaceBranch persists the new branch value by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceBranchPersists() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: try makeTempDirectory().path)
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
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: try makeTempDirectory().path)
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

    // Tests setAppConfig round-trips a valid port range through the settings store.
    func testSetAppConfigRoundTripsPortRange() throws {
        let store = try makeTemporaryStore()
        try store.setAppConfig(AppConfig(portRange: PortRange(start: 10000, end: 15000)))
        let config = try store.appConfig()
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

    private func tableExists(dbURL: URL, table: String) throws -> Bool {
        try readSingleInteger(dbURL: dbURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'") == 1
    }
}
