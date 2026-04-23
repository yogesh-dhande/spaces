import SQLite3
import XCTest

@testable import streamctl

final class StoreTests: XCTestCase {
    // Tests a fresh store bootstraps the current schema and version by arranging an empty DB path and asserting the resulting shape.
    func testFreshStoreBootstrapsCurrentSchema() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("fresh.db")

        _ = try SQLiteStore(path: dbURL.path)

        let version = try readSingleInteger(dbURL: dbURL, sql: "SELECT version FROM schema_version")
        let workspaceColumns = try readTableColumns(dbURL: dbURL, table: "workspaces")
        let projectColumns = try readTableColumns(dbURL: dbURL, table: "projects")
        let workspaceSettingsColumns = try readTableColumns(dbURL: dbURL, table: "workspace_settings")
        let workspaceStatusColumns = try readTableColumns(dbURL: dbURL, table: "workspace_status_checks")
        let windowColumns = try readTableColumns(dbURL: dbURL, table: "windows")
        XCTAssertEqual(version, 1)
        XCTAssertTrue(workspaceColumns.contains("title"))
        XCTAssertTrue(workspaceColumns.contains("is_active"))
        XCTAssertTrue(projectColumns.contains("is_collapsed"))
        XCTAssertFalse(workspaceSettingsColumns.contains("updated_at"))
        XCTAssertFalse(workspaceStatusColumns.contains("on_exit"))
        XCTAssertTrue(windowColumns.contains("name"))
        XCTAssertTrue(windowColumns.contains("detail"))
        XCTAssertTrue(try readTableColumns(dbURL: dbURL, table: "project_terminal_windows").isEmpty)
        XCTAssertTrue(try readTableColumns(dbURL: dbURL, table: "workspace_terminal_windows").isEmpty)
    }

    // Tests v6 migration preserves live data while removing dead schema by arranging a representative v6 DB and asserting the current v1 result.
    func testSchemaMigrationFromV6ToCurrentSchemaPreservesData() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("v6.db")
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
                CREATE TABLE project_terminal_windows (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT,
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
                  is_active INTEGER NOT NULL DEFAULT 1,
                  is_running INTEGER NOT NULL,
                  last_launched_at TEXT,
                  tooltip TEXT,
                  UNIQUE(project_id, title)
                );
                CREATE TABLE workspace_settings (
                  workspace_id TEXT PRIMARY KEY,
                  updated_at TEXT NOT NULL,
                  stop_script TEXT,
                  setup_status TEXT NOT NULL DEFAULT 'succeeded',
                  setup_error TEXT,
                  setup_started_at TEXT,
                  setup_finished_at TEXT
                );
                CREATE TABLE workspace_status_checks (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT,
                  process TEXT NOT NULL,
                  command TEXT NOT NULL,
                  interval INTEGER NOT NULL,
                  timeout INTEGER NOT NULL,
                  on_exit TEXT NOT NULL DEFAULT 'none',
                  on_fail TEXT NOT NULL DEFAULT 'none',
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE workspace_terminal_windows (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT,
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE schema_version (version INTEGER NOT NULL);
                INSERT INTO projects(id, name, dir, is_git, default_branch, is_collapsed, setup_script, stop_script)
                VALUES ('project-1', 'Project', '/tmp/project', 0, '', 0, '', '');
                INSERT INTO workspaces(id, project_id, title, dir, dirname, branch, target_branch, is_default, is_archived, is_active, is_running, last_launched_at, tooltip)
                VALUES ('workspace-1', 'project-1', 'feature', '/tmp/project/feature', 'feature', 'feature', 'main', 0, 0, 1, 0, '', '');
                INSERT INTO workspace_settings(workspace_id, updated_at, stop_script, setup_status, setup_error, setup_started_at, setup_finished_at)
                VALUES ('workspace-1', '2026-01-01T00:00:00Z', 'echo stop', 'failed', 'boom', 'start', 'end');
                INSERT INTO workspace_status_checks(id, workspace_id, name, process, command, interval, timeout, on_exit, on_fail, order_index)
                VALUES ('workspace-check', 'workspace-1', 'api health', 'api', 'echo ok', 10, 3, 'none', 'restart', 0);
                INSERT INTO project_terminal_windows(id, project_id, name, command, order_index)
                VALUES ('project-term', 'project-1', 'dev', 'echo dev', 0);
                INSERT INTO workspace_terminal_windows(id, workspace_id, name, command, order_index)
                VALUES ('workspace-term', 'workspace-1', 'dev', 'echo dev', 0);
                INSERT INTO schema_version(version) VALUES (6);
                """)

        let store = try SQLiteStore(path: dbURL.path)
        let workspaceStatusColumns = try readTableColumns(dbURL: dbURL, table: "workspace_status_checks")
        let workspaceSettingsColumns = try readTableColumns(dbURL: dbURL, table: "workspace_settings")
        let version = try readSingleInteger(dbURL: dbURL, sql: "SELECT version FROM schema_version")

        XCTAssertEqual(version, 1)
        XCTAssertTrue(workspaceStatusColumns.contains("on_fail"))
        XCTAssertFalse(workspaceStatusColumns.contains("on_exit"))
        XCTAssertFalse(workspaceSettingsColumns.contains("updated_at"))
        XCTAssertTrue(try readTableColumns(dbURL: dbURL, table: "project_terminal_windows").isEmpty)
        XCTAssertTrue(try readTableColumns(dbURL: dbURL, table: "workspace_terminal_windows").isEmpty)

        XCTAssertEqual(try store.workspaceStopScript(workspaceID: "workspace-1"), "echo stop")
        let setupState = try store.workspaceSetupState(workspaceID: "workspace-1")
        XCTAssertEqual(setupState?.status, .failed)
        XCTAssertEqual(setupState?.errorMessage, "boom")
        XCTAssertEqual(setupState?.startedAt, "start")
        XCTAssertEqual(setupState?.finishedAt, "end")
        let workspaceChecks = try store.workspaceStatusChecks(workspaceID: "workspace-1")
        XCTAssertEqual(workspaceChecks.count, 1)
        XCTAssertEqual(workspaceChecks.first?.onFail, .restart)
    }

    // Tests unsupported schema versions fail fast by arranging an older DB version and asserting initialization rejects it.
    func testUnsupportedSchemaVersionFailsFast() throws {
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
                CREATE TABLE workspaces (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  title TEXT NOT NULL,
                  dir TEXT NOT NULL,
                  is_default INTEGER NOT NULL,
                  is_archived INTEGER NOT NULL,
                  is_running INTEGER NOT NULL,
                  UNIQUE(project_id, title)
                );
                CREATE TABLE schema_version (version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES (5);
                """)

        XCTAssertThrowsError(try SQLiteStore(path: dbURL.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported database schema version 5"))
        }
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

        let checks = [
            StatusCheckDefinition(
                name: "api health", process: "api", command: "curl -f http://localhost:$PORT0/health", interval: 10, timeout: 3, onFail: .notify),
            StatusCheckDefinition(process: "worker", command: "echo ok", interval: 60, timeout: 5, onFail: .restart),
        ]
        try store.setWorkspaceStatusChecks(workspaceID: workspace.id, checks: checks)
        let storedChecks = try store.workspaceStatusChecks(workspaceID: workspace.id)
        XCTAssertEqual(storedChecks.count, 2)
        XCTAssertEqual(storedChecks[0].onFail, .notify)
        XCTAssertEqual(storedChecks[1].onFail, .restart)

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
        let unlockThread = Thread {
            Thread.sleep(forTimeInterval: 0.2)
            _ = sqlite3_exec(lockDB, "COMMIT;", nil, nil, nil)
        }
        unlockThread.start()

        XCTAssertNoThrow(try store.setSetting(key: "lock-test", value: "ok"))
        XCTAssertEqual(try store.setting(key: "lock-test"), "ok")
    }

    // Tests running processes status results and windows round trip by arranging representative inputs and asserting the expected result.
    func testRunningProcessesStatusResultsAndWindowsRoundTrip() throws {
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

        try store.upsert(
            statusResult: StatusResult(processID: processID, checkName: "health", status: .passed, message: "ok", lastRunAt: "2026-01-01T00:00:00Z"))
        try store.upsert(
            statusResult: StatusResult(
                processID: processID, checkName: "health", status: .failed, message: "failed", lastRunAt: "2026-01-01T00:02:00Z"))
        let results = try store.statusResults(processID: processID)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .failed)
        XCTAssertEqual(results[0].message, "failed")

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
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id, checks: [StatusCheckDefinition(process: "one", command: "echo ok", interval: 10, timeout: 2)])
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "https://example.com")])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "one", command: "echo one", terminalApp: nil, windowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(statusResult: StatusResult(processID: processID, checkName: "health", status: .passed, message: nil, lastRunAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "term", windowID: 77, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))

        try store.deleteWorkspace(id: workspace.id)

        XCTAssertNil(try store.workspace(id: workspace.id))
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspacePortDefinitions(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspaceProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspaceStatusChecks(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspaceBrowserSessions(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.statusResults(processID: processID).isEmpty)
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
        try store.upsert(statusResult: StatusResult(processID: firstID, checkName: "first", status: .passed, message: nil, lastRunAt: nil))

        try store.deleteRunningProcess(id: firstID)
        XCTAssertTrue(try store.statusResults(processID: firstID).isEmpty)
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
            statusChecks: [StatusCheckDefinition(name: "health", process: "api", command: "curl /health", interval: 10, timeout: 3, onFail: .notify)],
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
        XCTAssertEqual(loaded?.statusChecks.count, 1)
        XCTAssertEqual(loaded?.statusChecks[0].name, "health")
        XCTAssertEqual(loaded?.statusChecks[0].onFail, .notify)
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
                id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "claude", terminalTrackingID: "session-a", codexThreadID: nil,
                windowID: nil, yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspaceB.id, provider: .iterm2, label: "codex", terminalTrackingID: "session-b", codexThreadID: nil,
                windowID: nil, yabaiWindowID: nil, status: .spinning, createdAt: "2026-01-01T00:00:02Z", updatedAt: "2026-01-01T00:00:02Z"))

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

    // Tests markStatusResultsAsFailed updates all results for a process by arranging representative inputs and asserting the expected result.
    func testMarkStatusResultsAsFailedUpdatesAllResults() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let processID = UUID().uuidString
        try store.upsert(statusResult: StatusResult(processID: processID, checkName: "health", status: .passed, message: "ok", lastRunAt: "now"))
        try store.upsert(statusResult: StatusResult(processID: processID, checkName: "ready", status: .passed, message: "ready", lastRunAt: "now"))

        try store.markStatusResultsAsFailed(processID: processID)
        let results = try store.statusResults(processID: processID)
        XCTAssertTrue(results.allSatisfy { $0.status == .failed })
        XCTAssertTrue(results.allSatisfy { $0.message == "Process exited" })
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
            throw NSError(domain: "muxy.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed opening test sqlite db"])
        }
        defer { sqlite3_close(db) }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.tests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func readSingleInteger(dbURL: URL, sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "muxy.tests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed opening test sqlite db"])
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.tests", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "muxy.tests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing row for query: \(sql)"])
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func readSingleText(dbURL: URL, sql: String) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "muxy.tests", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed opening test sqlite db"])
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.tests", code: 9, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
            throw NSError(domain: "muxy.tests", code: 10, userInfo: [NSLocalizedDescriptionKey: "Missing row for query: \(sql)"])
        }
        return String(cString: raw)
    }

    private func readTableColumns(dbURL: URL, table: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "muxy.tests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed opening test sqlite db"])
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "muxy.tests", code: 7, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }

        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(statement, 1) else { continue }
            columns.append(String(cString: namePtr))
        }
        return columns
    }
}
