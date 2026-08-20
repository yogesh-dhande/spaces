import XCTest

@testable import spacesdatabase
@testable import spacesterminalcore
@testable import workspacecore

#if os(Linux)
    import CSQLite3
    import Glibc
#else
    import Darwin
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

private final class StoreOpenErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ error: Error) {
        lock.lock()
        messages.append(error.localizedDescription)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

final class StoreTests: XCTestCase {

    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

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
        XCTAssertTrue(projectColumns.contains("is_hidden"))
        XCTAssertFalse(workspaceColumns.contains("host_id"))
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
        XCTAssertTrue(runtimeTargetColumns.contains("type"))
        XCTAssertTrue(runtimeTargetColumns.contains("tracking_id"))
        XCTAssertTrue(runtimeTargetColumns.contains("updated_at"))
        XCTAssertFalse(runtimeTargetColumns.contains("native_id"))
        XCTAssertFalse(runtimeTargetColumns.contains("provider"))
        XCTAssertFalse(runtimeTargetColumns.contains("container_id"))
        XCTAssertTrue(agentSessionColumns.contains("runtime_target_id"))
        XCTAssertTrue(agentSessionColumns.contains("terminal_session_id"))
        XCTAssertTrue(agentSessionColumns.contains("session_key"))
        XCTAssertTrue(agentSessionColumns.contains("user_label"))
        XCTAssertFalse(agentSessionColumns.contains("claimed_launcher_id"))
        XCTAssertFalse(agentSessionColumns.contains("claimed_launcher_name"))
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

    // Upgrading a profile that already holds ended sessions must not cost them their replayable final
    // frame: a session whose stored payload carries a frame still reports one afterwards, a session whose
    // payload carries none still reports none, and both payloads survive byte-for-byte.
    func testUpgradeKeepsEndedSessionsFinalRenderAvailability() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let withFramePayload =
            #"{"sessionID":"with-frame","reason":"terminated","emittedAt":"2026-07-19T00:00:00Z","title":"t","workingDirectory":"/tmp","renderUpdate":"AAECAw=="}"#
        let withoutFramePayload =
            #"{"sessionID":"without-frame","reason":"terminated","emittedAt":"2026-07-19T00:00:00Z","title":"t","workingDirectory":"/tmp"}"#
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (7);
                CREATE TABLE terminal_remote_session_states (
                  session_id TEXT PRIMARY KEY,
                  root_directory TEXT NOT NULL UNIQUE,
                  payload_json TEXT NOT NULL
                );
                INSERT INTO terminal_remote_session_states(session_id, root_directory, payload_json)
                VALUES ('with-frame', '/tmp/sessions/with-frame', '\(withFramePayload)'),
                       ('without-frame', '/tmp/sessions/without-frame', '\(withoutFramePayload)');
                """)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: root.appendingPathComponent("runtime", isDirectory: true).path,
        ]) {
            _ = try SQLiteStore(path: dbURL.path)

            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
            XCTAssertEqual(try TerminalSessionPersistence.sessionIDsWithFinalRender(), ["with-frame"])
            XCTAssertEqual(
                try readSingleText(dbURL: dbURL, sql: "SELECT payload_json FROM terminal_remote_session_states WHERE session_id = 'with-frame'"),
                withFramePayload)
            XCTAssertEqual(
                try readSingleText(dbURL: dbURL, sql: "SELECT payload_json FROM terminal_remote_session_states WHERE session_id = 'without-frame'"),
                withoutFramePayload)
        }
    }

    // Upgrading a profile that already holds live terminal sessions must carry each session forward
    // whole, and a session that predates bell tracking must report no bell: the bell timestamp is what
    // raises an alert, so a synthesized one would greet the user with an alert they never earned.
    /// A v10 profile carrying archived workspaces — including one with notes and its own settings, ports,
    /// and agent rows — upgrades by dropping exactly those workspaces and nothing else. Everything live has
    /// to survive intact, since archiving is the only thing that removes a workspace.
    func testUpgradeDeletesArchivedWorkspacesAndKeepsLiveOnes() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let liveDir = root.appendingPathComponent("live", isDirectory: true).path
        let archivedDir = root.appendingPathComponent("archived", isDirectory: true).path
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (10);
                CREATE TABLE projects (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  dir TEXT NOT NULL UNIQUE,
                  is_git_repo INTEGER NOT NULL,
                  default_branch TEXT
                );
                CREATE TABLE workspaces (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  dir TEXT NOT NULL,
                  dirname TEXT,
                  branch TEXT,
                  base_branch TEXT,
                  is_default INTEGER NOT NULL,
                  is_archived INTEGER NOT NULL,
                  is_hidden INTEGER NOT NULL DEFAULT 0,
                  is_running INTEGER NOT NULL,
                  last_launched_at TEXT,
                  notes TEXT,
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                );
                CREATE UNIQUE INDEX workspaces_project_branch_active_unique
                ON workspaces(project_id, branch)
                WHERE length(branch) > 0 AND is_archived = 0;
                CREATE TABLE workspace_settings (
                  workspace_id TEXT PRIMARY KEY,
                  stop_script TEXT,
                  updated_at TEXT NOT NULL,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                );
                CREATE TABLE ignored_worktrees (
                  worktree_dir TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                );
                INSERT INTO projects(id, name, dir, is_git_repo, default_branch)
                  VALUES ('project', 'Project', '\(root.path)', 1, 'main');
                INSERT INTO workspaces(id, project_id, dir, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, notes)
                  VALUES ('live', 'project', '\(liveDir)', 'live', 'feature', 'main', 0, 0, 0, 0, 'live notes');
                INSERT INTO workspaces(id, project_id, dir, dirname, branch, base_branch, is_default, is_archived, is_hidden, is_running, notes)
                  VALUES ('archived', 'project', '\(archivedDir)', 'archived', 'retired', 'main', 0, 1, 0, 0, 'archived notes');
                INSERT INTO workspace_settings(workspace_id, stop_script, updated_at)
                  VALUES ('live', 'echo live', '2026-07-31T00:00:00Z');
                INSERT INTO workspace_settings(workspace_id, stop_script, updated_at)
                  VALUES ('archived', 'echo archived', '2026-07-31T00:00:00Z');
                """)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: root.appendingPathComponent("runtime", isDirectory: true).path,
        ]) {
            let store = try SQLiteStore(path: dbURL.path)

            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
            XCTAssertNil(try store.workspace(id: "archived"), "an archived workspace is dropped by the upgrade")
            let live = try XCTUnwrap(store.workspace(id: "live"), "a live workspace must survive the upgrade untouched")
            XCTAssertEqual(live.branch, "feature")
            XCTAssertEqual(live.baseBranch, "main")
            XCTAssertEqual(live.dirname, "live")
            XCTAssertEqual(live.notes, "live notes")
            XCTAssertEqual(try store.workspaces(projectID: "project").map(\.id), ["live"])
            XCTAssertEqual(try store.workspaceStopScript(workspaceID: "live"), "echo live")
            XCTAssertEqual(
                try readSingleInteger(dbURL: dbURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'ignored_worktrees'"), 0,
                "the upgrade drops the ignored-worktree table with the archived model")
            XCTAssertEqual(
                try readSingleInteger(dbURL: dbURL, sql: "SELECT COUNT(*) FROM workspace_settings WHERE workspace_id = 'archived'"), 0,
                "the dropped workspace takes its settings with it")

            // The freed branch name is immediately usable again by a new workspace.
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: "reuse", projectID: "project", dir: archivedDir, dirname: "reuse", branch: "retired", baseBranch: "main", isDefault: false,
                    isRunning: false, lastLaunchedAt: nil))
            XCTAssertEqual(try store.workspace(id: "reuse")?.branch, "retired")
        }
    }

    func testUpgradeKeepsRuntimeSessionsAndReportsNoBell() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let sessionRoot = URL(fileURLWithPath: root.appendingPathComponent("sessions/legacy", isDirectory: true).path, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (8);
                CREATE TABLE terminal_runtime_states (
                  session_id TEXT PRIMARY KEY,
                  root_directory TEXT NOT NULL UNIQUE,
                  backend TEXT NOT NULL,
                  service_pid INTEGER NOT NULL,
                  child_pid INTEGER,
                  title TEXT,
                  working_directory TEXT,
                  columns INTEGER,
                  rows INTEGER,
                  state TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  exited_at TEXT,
                  foreground_pid INTEGER,
                  foreground_executable_path TEXT,
                  foreground_executable_name TEXT,
                  foreground_argv_json TEXT,
                  foreground_detected_agent_kind TEXT,
                  foreground_display_label TEXT,
                  foreground_display_command TEXT
                );
                INSERT INTO terminal_runtime_states(
                  session_id, root_directory, backend, service_pid, child_pid, title, working_directory, columns, rows, state, updated_at
                ) VALUES (
                  'legacy-session', '\(sessionRoot.path)', 'ghostty-embedded', 4242, 99, 'legacy title', '/tmp/legacy', 100, 40, 'running',
                  '2026-07-19T00:00:00Z'
                );
                """)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: root.appendingPathComponent("runtime", isDirectory: true).path,
        ]) {
            _ = try SQLiteStore(path: dbURL.path)

            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: TerminalSessionPaths(rootDirectory: sessionRoot.path))
            XCTAssertEqual(runtimeState.sessionID, "legacy-session")
            XCTAssertEqual(runtimeState.title, "legacy title")
            XCTAssertEqual(runtimeState.workingDirectory, "/tmp/legacy")
            XCTAssertEqual(runtimeState.childPID, 99)
            XCTAssertEqual(runtimeState.state, .running)
            XCTAssertNil(runtimeState.bellAt)
        }
    }

    /// A v12 profile carrying configured agent launchers upgrades by dropping both launcher tables and
    /// the two claim columns, while every agent session it holds — including a renamed one — survives with
    /// the name it answers to. Configured coding agents no longer exist, so nothing reads that data; the
    /// live agent rows are the whole feature now.
    func testUpgradeDropsAgentLaunchersAndKeepsAgentSessions() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (12);
                CREATE TABLE projects (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  dir TEXT NOT NULL UNIQUE,
                  is_git INTEGER NOT NULL,
                  default_branch TEXT,
                  setup_script TEXT,
                  stop_script TEXT
                );
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
                CREATE TABLE runtime_targets (
                  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, type TEXT NOT NULL, name TEXT, detail TEXT,
                  app TEXT NOT NULL, tracking_id TEXT, order_index INTEGER NOT NULL, updated_at TEXT NOT NULL
                );
                CREATE TABLE project_agent_launchers (
                  project_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, command TEXT NOT NULL, order_index INTEGER NOT NULL,
                  PRIMARY KEY (project_id, order_index)
                );
                CREATE TABLE workspace_agent_launchers (
                  workspace_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, command TEXT NOT NULL, order_index INTEGER NOT NULL,
                  PRIMARY KEY (workspace_id, order_index)
                );
                CREATE TABLE agent_sessions (
                  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL, label TEXT,
                  status TEXT NOT NULL DEFAULT 'idle', runtime_target_id TEXT, terminal_session_id TEXT, session_key TEXT,
                  claimed_launcher_id TEXT, claimed_launcher_name TEXT, note TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                  detected_agent_kind TEXT, user_label TEXT
                );
                INSERT INTO projects(id, name, dir, is_git, default_branch, setup_script, stop_script)
                  VALUES ('project', 'Project', '\(root.path)', 1, 'main', '', '');
                INSERT INTO workspaces(id, project_id, dir, dirname, branch, base_branch, is_default, is_hidden, is_running, last_launched_at, notes)
                  VALUES ('workspace', 'project', '\(root.path)/ws', 'ws', 'feature', 'main', 0, 0, 0, '', '');
                INSERT INTO project_agent_launchers(project_id, id, name, command, order_index)
                  VALUES ('project', 'launcher-codex', 'Codex', 'codex', 0);
                INSERT INTO workspace_agent_launchers(workspace_id, id, name, command, order_index)
                  VALUES ('workspace', 'launcher-codex', 'Codex', 'codex', 0);
                INSERT INTO agent_sessions(
                  id, workspace_id, provider, label, status, terminal_session_id, claimed_launcher_id, claimed_launcher_name, note,
                  created_at, updated_at, detected_agent_kind, user_label)
                  VALUES ('agent-claimed', 'workspace', 'spaces', 'Codex', 'spinning', 'session-1', 'launcher-codex', 'Codex', 'carried',
                          'now', 'now', 'codex', NULL);
                INSERT INTO agent_sessions(
                  id, workspace_id, provider, label, status, terminal_session_id, note, created_at, updated_at, detected_agent_kind, user_label)
                  VALUES ('agent-renamed', 'workspace', 'spaces', 'Claude Code CLI', 'waiting', 'session-2', NULL, 'now', 'now', 'claude',
                          'Reviewer');
                """)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: root.appendingPathComponent("runtime", isDirectory: true).path,
        ]) {
            let store = try SQLiteStore(path: dbURL.path)

            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
            for table in ["project_agent_launchers", "workspace_agent_launchers"] {
                XCTAssertEqual(
                    try readSingleInteger(dbURL: dbURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'"), 0,
                    "the upgrade drops \(table)")
            }
            let agentSessionColumns = try readTableColumns(dbURL: dbURL, table: "agent_sessions")
            XCTAssertFalse(agentSessionColumns.contains("claimed_launcher_id"))
            XCTAssertFalse(agentSessionColumns.contains("claimed_launcher_name"))

            let agents = try store.agentWindows(workspaceID: "workspace")
            XCTAssertEqual(agents.map(\.id).sorted(), ["agent-claimed", "agent-renamed"])
            let claimed = try XCTUnwrap(agents.first { $0.id == "agent-claimed" })
            XCTAssertEqual(claimed.effectiveLabel, "Codex")
            XCTAssertEqual(claimed.status, .spinning)
            XCTAssertEqual(claimed.note, "carried")
            XCTAssertEqual(claimed.detectedAgentKind, "codex")
            XCTAssertEqual(claimed.terminalTrackingID, "session-1")
            let renamed = try XCTUnwrap(agents.first { $0.id == "agent-renamed" })
            XCTAssertEqual(renamed.effectiveLabel, "Reviewer")
            XCTAssertEqual(renamed.label, "Claude Code CLI")
        }
    }

    /// A v15 profile predates project-level hiding, so every project it carries has to come forward
    /// visible with its configuration intact, and hiding must work on it immediately afterwards.
    func testUpgradeFromV15CarriesProjectsForwardVisible() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let projectDir = root.appendingPathComponent("project", isDirectory: true).path
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (15);
                -- Every v15 database carries `automations` (the v13→v14 step creates it), and later steps
                -- alter it, so the fixture declares it in its v15 shape rather than describing a database
                -- version 15 never produced.
                CREATE TABLE automations (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  enabled INTEGER NOT NULL DEFAULT 1,
                  trigger_kind TEXT NOT NULL,
                  cron_expression TEXT,
                  kind TEXT NOT NULL DEFAULT 'script',
                  script TEXT NOT NULL,
                  agent_command TEXT,
                  agent_prompt TEXT,
                  workspace_id TEXT NOT NULL,
                  timeout_seconds INTEGER,
                  concurrency_policy TEXT NOT NULL,
                  missed_run_policy TEXT NOT NULL,
                  next_fire_time REAL,
                  created_at REAL NOT NULL,
                  updated_at REAL NOT NULL,
                  anchor_time_zone_identifier TEXT
                );
                CREATE TABLE projects (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  dir TEXT NOT NULL UNIQUE,
                  is_git INTEGER NOT NULL,
                  default_branch TEXT,
                  setup_script TEXT,
                  stop_script TEXT
                );
                CREATE TABLE project_services (
                  id TEXT NOT NULL,
                  project_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  PRIMARY KEY (project_id, order_index),
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                );
                CREATE TABLE project_processes (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT,
                  command TEXT NOT NULL,
                  on_exit TEXT NOT NULL DEFAULT 'none',
                  order_index INTEGER NOT NULL,
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                );
                CREATE TABLE project_browser_sessions (
                  project_id TEXT NOT NULL,
                  name TEXT,
                  url TEXT,
                  order_index INTEGER NOT NULL,
                  PRIMARY KEY (project_id, order_index),
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                );
                INSERT INTO projects(id, name, dir, is_git, default_branch, setup_script, stop_script)
                  VALUES ('project', 'Project', '\(projectDir)', 1, 'main', 'echo setup', 'echo stop');
                INSERT INTO project_services(id, project_id, name, order_index) VALUES ('port-api', 'project', 'api', 0);
                """)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: root.appendingPathComponent("runtime", isDirectory: true).path,
        ]) {
            let store = try SQLiteStore(path: dbURL.path)

            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
            let migrated = try XCTUnwrap(store.project(id: "project"), "an existing project must survive the upgrade")
            XCTAssertFalse(migrated.isHidden, "a project that predates the flag comes forward visible")
            XCTAssertEqual(migrated.name, "Project")
            XCTAssertEqual(migrated.defaultBranch, "main")
            XCTAssertEqual(migrated.setupScript, "echo setup")
            XCTAssertEqual(migrated.stopScript, "echo stop")
            XCTAssertEqual(migrated.ports.map(\.name), ["api"])

            try store.updateProjectHidden(id: "project", isHidden: true)
            XCTAssertEqual(try store.project(id: "project")?.isHidden, true)
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

    /// A profile database several schema versions behind this build, carrying one row the upgrade must
    /// preserve.
    private static let legacyProfileSchemaSQL = """
        CREATE TABLE migration_state (current_version INTEGER NOT NULL);
        INSERT INTO migration_state(current_version) VALUES (4);
        CREATE TABLE agent_pending_notifications (
          id TEXT PRIMARY KEY,
          subscriber_terminal_session_id TEXT NOT NULL,
          agent_session_id TEXT NOT NULL,
          message TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        INSERT INTO agent_pending_notifications(
          id, subscriber_terminal_session_id, agent_session_id, message, created_at
        ) VALUES ('pending-1', 'subscriber-1', 'agent-1', 'preserve me', '2026-07-15T00:00:00Z');
        CREATE TABLE agent_sessions (
          id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL, label TEXT,
          status TEXT NOT NULL DEFAULT 'idle', runtime_target_id TEXT, terminal_session_id TEXT, session_key TEXT,
          claimed_launcher_id TEXT, claimed_launcher_name TEXT, note TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE agent_subscriptions (
          subscriber_terminal_session_id TEXT NOT NULL,
          agent_session_id TEXT NOT NULL,
          created_at TEXT NOT NULL,
          PRIMARY KEY (subscriber_terminal_session_id, agent_session_id),
          FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE
        );
        """

    /// An instance-lock record naming a schema target other than this build's. Produced directly
    /// because `TerminalServiceInstanceLock.acquire` declares this build's target by construction,
    /// while an older daemon declares its own — or, from before the declaration existed, none.
    private struct ForeignSchemaInstanceLockRecord: Codable {
        let pid: Int32
        let token: String
        let schemaTarget: Int?
    }

    private func writeInstanceLock(pid: Int32, schemaTarget: Int?, path: String) throws {
        let record = ForeignSchemaInstanceLockRecord(pid: pid, token: UUID().uuidString, schemaTarget: schemaTarget)
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: path))
    }

    // A newer direct helper must not move the profile schema out from under the daemon that owns the
    // live terminal sessions: an owner whose lock record declares no schema this build can open is that
    // older daemon, and the helper refuses immediately rather than waiting for work that is not coming.
    // Once that daemon hands off in place, the owning process may migrate and the existing data must
    // carry forward.
    func testRunningDaemonExclusivelyOwnsProfileMigration() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        try runSQLiteExec(dbURL: dbURL, sql: Self.legacyProfileSchemaSQL)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeURL.path,
        ]) {
            let externalDaemon = Process()
            externalDaemon.executableURL = URL(fileURLWithPath: "/bin/sleep")
            externalDaemon.arguments = ["30"]
            externalDaemon.standardOutput = FileHandle.nullDevice
            externalDaemon.standardError = FileHandle.nullDevice
            try externalDaemon.run()
            defer {
                if externalDaemon.isRunning { externalDaemon.terminate() }
                externalDaemon.waitUntilExit()
            }

            let lockPath = try TerminalServicePaths.instanceLockPath()
            let launchLockPath = try TerminalServicePaths.launchLockPath()
            let rawLaunchDescriptor = open(launchLockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            let competingLaunchDescriptor = try XCTUnwrap(rawLaunchDescriptor >= 0 ? rawLaunchDescriptor : nil)
            defer { close(competingLaunchDescriptor) }
            let competingLockCandidate = root.appendingPathComponent("competing-daemon.lock")
            try Data("candidate".utf8).write(to: competingLockCandidate)
            try ProfileDatabaseMigrationGuard.withMigrationAuthorization(databasePath: dbURL.path) {
                XCTAssertEqual(flock(competingLaunchDescriptor, LOCK_EX | LOCK_NB), -1)
                XCTAssertEqual(errno, EWOULDBLOCK, "Daemon startup must wait on the profile launch lock while migration is authorized.")
                XCTAssertEqual(link(competingLockCandidate.path, lockPath), -1)
                XCTAssertEqual(errno, EEXIST, "A daemon must not acquire the instance lock while migration is authorized.")
            }
            XCTAssertEqual(flock(competingLaunchDescriptor, LOCK_EX | LOCK_NB), 0, "Daemon startup must proceed after migration finishes.")
            XCTAssertEqual(flock(competingLaunchDescriptor, LOCK_UN), 0)
            XCTAssertEqual(link(competingLockCandidate.path, lockPath), 0, "The migration lock must be released after the schema work finishes.")
            try FileManager.default.removeItem(atPath: lockPath)

            try writeInstanceLock(pid: externalDaemon.processIdentifier, schemaTarget: DatabaseSchema.currentVersion - 1, path: lockPath)
            let refusalStarted = Date()
            XCTAssertThrowsError(try SQLiteStore(path: dbURL.path)) { error in
                XCTAssertTrue(error.localizedDescription.contains("while spacesd (pid \(externalDaemon.processIdentifier)) owns this profile"))
                XCTAssertTrue(error.localizedDescription.contains("maintains schema version \(DatabaseSchema.currentVersion - 1)"))
                XCTAssertTrue(error.localizedDescription.contains("this build needs schema version \(DatabaseSchema.currentVersion)"))
                XCTAssertTrue(error.localizedDescription.contains("spaces daemon apply-update"))
            }
            XCTAssertLessThan(
                Date().timeIntervalSince(refusalStarted), 1,
                "The owner's lock record already names the boundary, so the refusal must not wait on schema work that is not coming.")

            // A daemon from before the declaration existed names no schema at all, which is the same
            // refusal: it is older than any build that reads the declaration.
            try FileManager.default.removeItem(atPath: lockPath)
            try writeInstanceLock(pid: externalDaemon.processIdentifier, schemaTarget: nil, path: lockPath)
            XCTAssertThrowsError(try SQLiteStore(path: dbURL.path)) { error in
                XCTAssertTrue(error.localizedDescription.contains("maintains an earlier schema"))
                XCTAssertTrue(error.localizedDescription.contains("spaces daemon apply-update"))
            }
            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), 4)
            XCTAssertEqual(
                try readSingleText(dbURL: dbURL, sql: "SELECT message FROM agent_pending_notifications WHERE id = 'pending-1'"), "preserve me")

            try FileManager.default.removeItem(atPath: lockPath)
            let daemonLock = try TerminalServiceInstanceLock.acquire(path: lockPath)
            _ = try SQLiteStore(path: dbURL.path)
            withExtendedLifetime(daemonLock) {}

            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
            XCTAssertEqual(
                try readSingleText(dbURL: dbURL, sql: "SELECT message FROM agent_pending_notifications WHERE id = 'pending-1'"), "preserve me")
        }
    }

    // A daemon that has just taken the instance lock is doing the schema work it took that lock to do,
    // and its lock record declares the schema version it will record. A helper opening the profile
    // database in that window sees the same behind-schema database an older daemon would present, so
    // that declaration is what tells it to wait for the owner's result rather than report a version
    // boundary that does not exist.
    func testHelperWaitsForBootingDaemonToRecordProfileSchema() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        try runSQLiteExec(dbURL: dbURL, sql: Self.legacyProfileSchemaSQL)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeURL.path,
        ]) {
            let externalDaemon = Process()
            externalDaemon.executableURL = URL(fileURLWithPath: "/bin/sleep")
            externalDaemon.arguments = ["30"]
            externalDaemon.standardOutput = FileHandle.nullDevice
            externalDaemon.standardError = FileHandle.nullDevice
            try externalDaemon.run()
            defer {
                if externalDaemon.isRunning { externalDaemon.terminate() }
                externalDaemon.waitUntilExit()
            }

            let lockPath = try TerminalServicePaths.instanceLockPath()
            let externalLock = try TerminalServiceInstanceLock.acquire(path: lockPath, processID: externalDaemon.processIdentifier)
            defer { externalLock.release() }

            // Stands in for the owning daemon's own schema work: it holds the instance lock, so it
            // migrates directly rather than through the guard.
            let helperEnteredGuard = DispatchSemaphore(value: 0)
            let ownerMigrationError = LockedBox<Error?>(nil)
            let ownerFinished = DispatchSemaphore(value: 0)
            let owner = Thread {
                helperEnteredGuard.wait()
                Thread.sleep(forTimeInterval: 0.2)
                do { _ = try SpacesSQLiteDatabase(path: dbURL.path) } catch { ownerMigrationError.set(error) }
                ownerFinished.signal()
            }
            owner.start()

            let started = Date()
            helperEnteredGuard.signal()
            _ = try SQLiteStore(path: dbURL.path)
            let waited = Date().timeIntervalSince(started)

            XCTAssertEqual(ownerFinished.wait(timeout: .now() + 5), .success)
            XCTAssertNil(ownerMigrationError.get())
            XCTAssertGreaterThanOrEqual(waited, 0.15, "The helper must wait for the owner's schema work instead of refusing it.")
            XCTAssertEqual(
                try TerminalServiceInstanceLock.activeOwnerProcessID(path: lockPath), externalDaemon.processIdentifier,
                "The waiting helper must leave profile ownership with the daemon.")
            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
            XCTAssertEqual(
                try readSingleText(dbURL: dbURL, sql: "SELECT message FROM agent_pending_notifications WHERE id = 'pending-1'"), "preserve me")
        }
    }

    // The wait is bounded by the owner staying alive, not by a duration: an owner that exits before
    // recording its schema version leaves the profile to whoever takes the lock next, and the waiting
    // helper is exactly that process.
    func testHelperTakesOverProfileMigrationWhenOwningDaemonExitsBeforeRecordingSchema() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        try runSQLiteExec(dbURL: dbURL, sql: Self.legacyProfileSchemaSQL)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeURL.path,
        ]) {
            let externalDaemon = Process()
            externalDaemon.executableURL = URL(fileURLWithPath: "/bin/sleep")
            externalDaemon.arguments = ["30"]
            externalDaemon.standardOutput = FileHandle.nullDevice
            externalDaemon.standardError = FileHandle.nullDevice
            try externalDaemon.run()
            defer {
                if externalDaemon.isRunning { externalDaemon.terminate() }
                externalDaemon.waitUntilExit()
            }

            let lockPath = try TerminalServicePaths.instanceLockPath()
            let externalLock = try TerminalServiceInstanceLock.acquire(path: lockPath, processID: externalDaemon.processIdentifier)
            defer { externalLock.release() }

            let helperEnteredGuard = DispatchSemaphore(value: 0)
            let owner = Thread {
                helperEnteredGuard.wait()
                Thread.sleep(forTimeInterval: 0.2)
                externalDaemon.terminate()
                externalDaemon.waitUntilExit()
            }
            owner.start()

            helperEnteredGuard.signal()
            _ = try SQLiteStore(path: dbURL.path)

            XCTAssertNil(
                try TerminalServiceInstanceLock.activeOwnerProcessID(path: lockPath),
                "The helper must take the abandoned profile, do the schema work, and release the lock again.")
            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
            XCTAssertEqual(
                try readSingleText(dbURL: dbURL, sql: "SELECT message FROM agent_pending_notifications WHERE id = 'pending-1'"), "preserve me")
        }
    }

    // A live owner that declares this build's schema but never records it is wedged, not a version
    // boundary. The ceiling exists so that helper stops eventually, and what it reports must send the
    // caller back to the daemon already doing the work rather than to the update remedy.
    func testHelperReportsOwningDaemonStillPreparingSchemaWhenWaitCeilingExpires() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        try runSQLiteExec(dbURL: dbURL, sql: Self.legacyProfileSchemaSQL)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeURL.path,
        ]) {
            let externalDaemon = Process()
            externalDaemon.executableURL = URL(fileURLWithPath: "/bin/sleep")
            externalDaemon.arguments = ["30"]
            externalDaemon.standardOutput = FileHandle.nullDevice
            externalDaemon.standardError = FileHandle.nullDevice
            try externalDaemon.run()
            defer {
                if externalDaemon.isRunning { externalDaemon.terminate() }
                externalDaemon.waitUntilExit()
            }

            let lockPath = try TerminalServicePaths.instanceLockPath()
            let externalLock = try TerminalServiceInstanceLock.acquire(path: lockPath, processID: externalDaemon.processIdentifier)
            defer { externalLock.release() }

            var migrationRan = false
            XCTAssertThrowsError(
                try ProfileDatabaseMigrationGuard.withMigrationAuthorization(databasePath: dbURL.path, ownerWaitCeiling: 0.2) { migrationRan = true }
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("still being prepared by spacesd (pid \(externalDaemon.processIdentifier))"),
                    error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("retry once it finishes"), error.localizedDescription)
                XCTAssertFalse(
                    error.localizedDescription.contains("apply-update"),
                    "The daemon being waited on is already the one that should do this work, so the update remedy would be wrong.")
            }
            XCTAssertFalse(migrationRan)
            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), 4)
        }
    }

    // A newer owner commits each step of its upgrade in its own transaction, so this build's schema
    // version appears in the profile while that daemon is still rewriting past it. The helper must wait
    // for the version the owner declared rather than the first version it could open, or it reads a
    // database mid-migration and never reaches the rejection a newer schema is owed.
    func testHelperWaitsPastItsOwnSchemaVersionForNewerOwnersDeclaredTarget() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        try runSQLiteExec(dbURL: dbURL, sql: Self.legacyProfileSchemaSQL)
        let ownerTarget = DatabaseSchema.currentVersion + 1

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeURL.path,
        ]) {
            let externalDaemon = Process()
            externalDaemon.executableURL = URL(fileURLWithPath: "/bin/sleep")
            externalDaemon.arguments = ["30"]
            externalDaemon.standardOutput = FileHandle.nullDevice
            externalDaemon.standardError = FileHandle.nullDevice
            try externalDaemon.run()
            defer {
                if externalDaemon.isRunning { externalDaemon.terminate() }
                externalDaemon.waitUntilExit()
            }

            let lockPath = try TerminalServicePaths.instanceLockPath()
            try writeInstanceLock(pid: externalDaemon.processIdentifier, schemaTarget: ownerTarget, path: lockPath)
            defer { try? FileManager.default.removeItem(atPath: lockPath) }

            let helperEnteredGuard = DispatchSemaphore(value: 0)
            let ownerError = LockedBox<Error?>(nil)
            let owner = Thread {
                helperEnteredGuard.wait()
                Thread.sleep(forTimeInterval: 0.15)
                do {
                    // The step of the owner's upgrade that lands on this build's version, committed on
                    // the way to the owner's own.
                    try self.runSQLiteExec(dbURL: dbURL, sql: "UPDATE migration_state SET current_version = \(DatabaseSchema.currentVersion);")
                    Thread.sleep(forTimeInterval: 0.25)
                    try self.runSQLiteExec(dbURL: dbURL, sql: "UPDATE migration_state SET current_version = \(ownerTarget);")
                } catch { ownerError.set(error) }
            }
            owner.start()

            let started = Date()
            helperEnteredGuard.signal()
            XCTAssertThrowsError(try SQLiteStore(path: dbURL.path)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unsupported database schema version \(ownerTarget)"), error.localizedDescription)
            }
            let waited = Date().timeIntervalSince(started)

            XCTAssertNil(ownerError.get())
            XCTAssertGreaterThanOrEqual(
                waited, 0.3, "The helper must not stop at its own version while the owner is still upgrading the database past it.")
            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), ownerTarget)
        }
    }

    func testConcurrentHelperThreadsShareOneProfileMigration() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("spaces.db")
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        try runSQLiteExec(dbURL: dbURL, sql: Self.legacyProfileSchemaSQL)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeURL.path,
        ]) {
            let errors = StoreOpenErrors()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in do { _ = try SQLiteStore(path: dbURL.path) } catch { errors.append(error) } }

            XCTAssertEqual(errors.all, [])
            XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("backups"), includingPropertiesForKeys: nil).count, 1)
        }
    }

    func testCurrentSchemaRejectsBlankPortNamesAtDatabaseLevel() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("port-name-constraints.db")
        _ = try SQLiteStore(path: dbURL.path)

        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                INSERT INTO projects(id, name, dir, is_git) VALUES ('project-1', 'Project', '/tmp/project', 0);
                INSERT INTO workspaces(id, project_id, dir, is_default, is_hidden, is_running)
                VALUES ('workspace-1', 'project-1', '/tmp/project/feature', 0, 0, 0);
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

    func testNewerSchemaIsRejectedBeforeDaemonMigrationAuthorization() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("newer-schema.db")
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        let newerVersion = DatabaseSchema.currentVersion + 1
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (\(newerVersion));
                """)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: dbURL.path, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeURL.path,
        ]) {
            let externalDaemon = Process()
            externalDaemon.executableURL = URL(fileURLWithPath: "/bin/sleep")
            externalDaemon.arguments = ["30"]
            externalDaemon.standardOutput = FileHandle.nullDevice
            externalDaemon.standardError = FileHandle.nullDevice
            try externalDaemon.run()
            defer {
                if externalDaemon.isRunning { externalDaemon.terminate() }
                externalDaemon.waitUntilExit()
            }
            let daemonLock = try TerminalServiceInstanceLock.acquire(
                path: try TerminalServicePaths.instanceLockPath(), processID: externalDaemon.processIdentifier)
            defer { daemonLock.release() }

            XCTAssertThrowsError(try SQLiteStore(path: dbURL.path)) { error in
                XCTAssertEqual(error.localizedDescription, "Unsupported database schema version \(newerVersion) at \(dbURL.path).")
                XCTAssertFalse(error.localizedDescription.contains("apply-update"))
            }
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
            databasePath: dbURL.path, databaseHandle: handle, readExistingTables: { ["migration_state", "migration_log"] },
            readSchemaVersion: { try self.readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state") },
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

    func testMigratorRechecksSchemaAfterMigrationAuthorizationWait() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("authorization-wait.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (1);
                """)
        let handle = try openSQLiteHandle(dbURL: dbURL)
        defer { sqlite3_close(handle) }
        let stepApplications = LockedBox(0)
        let migrator = DatabaseMigrator(
            currentSchemaVersion: 2,
            steps: [
                DatabaseMigrationStep(fromVersion: 1, toVersion: 2, description: "should already be applied", requiresBackup: false) { _ in
                    stepApplications.set(stepApplications.get() + 1)
                }
            ], backupManager: DatabaseBackupManager(databaseURL: dbURL))

        try migrator.migrateIfNeeded(
            databasePath: dbURL.path, databaseHandle: handle, readExistingTables: { ["migration_state"] },
            readSchemaVersion: { try self.readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state") },
            createFreshSchema: {}, setSchemaVersion: { _ in }, withTransaction: { try $0() }, validateIntegrity: {},
            withMigrationAuthorization: { migration in
                // Represents another process completing the migration before this waiter receives
                // authorization. The migrator must adopt version 2 rather than replaying its v1 snapshot.
                try self.runSQLiteExec(dbURL: dbURL, sql: "UPDATE migration_state SET current_version = 2;")
                try migration()
            })

        XCTAssertEqual(stepApplications.get(), 0)
        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), 2)
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
                databasePath: dbURL.path, databaseHandle: handle, readExistingTables: { ["migration_state", "widgets"] },
                readSchemaVersion: { try self.readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state") },
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
                    ports: [ServiceDefinition(name: " ")], processes: [], browserSessions: [])))
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
                    ports: [ServiceDefinition(name: "api"), ServiceDefinition(name: "api")], processes: [], browserSessions: [])))
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

    // Tests an outer withTransaction wrapping two mutations that each internally open
    // their own withImmediateTransaction commits once and persists both writes.
    func testNestedTransactionCommitsBothStoreMutations() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        try store.upsert(project: project)
        let workspaceA = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, dir: project.dir)

        try store.withTransaction {
            try store.upsert(workspace: workspaceA)
            try store.upsert(workspace: workspaceB)
        }

        XCTAssertNotNil(try store.workspace(id: workspaceA.id))
        XCTAssertNotNil(try store.workspace(id: workspaceB.id))
    }

    // Tests an error thrown out of the outer withTransaction rolls back every write
    // made inside it, including ones already returned by inner transactions.
    func testOuterTransactionErrorRollsBackAllStoreMutations() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        try store.upsert(project: project)
        let workspaceA = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, dir: project.dir)

        struct OuterFailure: Error {}
        XCTAssertThrowsError(
            try store.withTransaction {
                try store.upsert(workspace: workspaceA)
                try store.upsert(workspace: workspaceB)
                throw OuterFailure()
            }
        ) { XCTAssertTrue($0 is OuterFailure) }

        XCTAssertNil(try store.workspace(id: workspaceA.id))
        XCTAssertNil(try store.workspace(id: workspaceB.id))
    }

    // Tests savepoint semantics: an inner transaction that throws is rolled back to its
    // savepoint, and when the body catches the error and continues, the outer commit
    // still persists the writes made before and after the failed inner step.
    func testInnerTransactionFailureCaughtLeavesOuterWritesIntact() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)

        try store.withTransaction {
            try store.upsert(workspace: workspace)
            // Duplicate process IDs fail inside setWorkspaceProcesses' own transaction,
            // which rolls back only to its savepoint and leaves the outer intact.
            XCTAssertThrowsError(
                try store.setWorkspaceProcesses(
                    workspaceID: workspace.id,
                    processes: [
                        ProcessTemplate(id: "dup", name: "api", command: "npm run api"),
                        ProcessTemplate(id: "dup", name: "web", command: "npm run web"),
                    ]))
            try store.updateWorkspaceHidden(id: workspace.id, isHidden: true)
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, true)
        XCTAssertTrue(try store.workspaceProcesses(workspaceID: workspace.id).isEmpty)
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
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: sessionID, pid: nil, status: .exited, logPath: nil, lastOutputAt: nil,
                startedAt: "2026-06-04T14:23:10Z", exitedAt: "2026-06-04T14:23:23Z"))

        let loaded = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        let runtimeTargetID = try XCTUnwrap(loaded.runtimeTargetID)
        try store.deleteWindow(id: runtimeTargetID)

        let reloaded = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertNil(reloaded.runtimeTargetID)
        XCTAssertEqual(reloaded.terminalApp, TerminalHost.spaces.appName)
        XCTAssertEqual(reloaded.terminalTrackingID, sessionID)
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
                sessionKey: "thread-123", status: .done, createdAt: "2026-02-25T00:00:00Z", updatedAt: "2026-02-25T00:00:01Z"))

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
        XCTAssertTrue(try store.workspaces(projectID: project.id).isEmpty)
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
        let updated = try store.workspace(id: workspace.id)
        XCTAssertEqual(updated?.isRunning, true)
        XCTAssertEqual(updated?.lastLaunchedAt, "2026-01-01T00:00:00Z")

        XCTAssertNil(try store.setting(key: "key"))
        try store.setSetting(key: "key", value: "value")
        XCTAssertEqual(try store.setting(key: "key"), "value")
        try store.setSetting(key: "key", value: nil)
        XCTAssertNil(try store.setting(key: "key"))
    }

    // Tests that a workspace's isHidden flag round-trips through updateWorkspaceHidden in both directions.
    func testUpdateWorkspaceHiddenRoundTrips() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, false)

        try store.updateWorkspaceHidden(id: workspace.id, isHidden: true)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, true)

        try store.updateWorkspaceHidden(id: workspace.id, isHidden: false)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, false)
    }

    // Tests that a project's isHidden flag round-trips through updateProjectHidden in both directions, and
    // that it is independent of its workspaces' own hidden flags.
    func testUpdateProjectHiddenRoundTrips() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        XCTAssertEqual(try store.project(id: project.id)?.isHidden, false)

        try store.updateProjectHidden(id: project.id, isHidden: true)
        XCTAssertEqual(try store.project(id: project.id)?.isHidden, true)
        XCTAssertEqual(try store.project(dir: project.dir)?.isHidden, true)
        XCTAssertEqual(try store.projects().first(where: { $0.id == project.id })?.isHidden, true)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, false, "hiding a project leaves its workspaces' own flag alone")

        try store.updateProjectHidden(id: project.id, isHidden: false)
        XCTAssertEqual(try store.project(id: project.id)?.isHidden, false)
    }

    // A hidden project survives a re-upsert of the same record, which is what every project settings save
    // performs: the flag is daemon-owned state, not part of the configuration the upsert rewrites.
    func testUpsertPreservesProjectHiddenState() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        try store.upsert(project: project)
        try store.updateProjectHidden(id: project.id, isHidden: true)

        var reloaded = try XCTUnwrap(store.project(id: project.id))
        reloaded.setupScript = "echo setup"
        try store.upsert(project: reloaded)

        let updated = try XCTUnwrap(store.project(id: project.id))
        XCTAssertTrue(updated.isHidden)
        XCTAssertEqual(updated.setupScript, "echo setup")
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
            id: "default", projectID: aProject.id, dir: aDir, dirname: nil, branch: nil, isDefault: true, isRunning: false, lastLaunchedAt: nil)
        let secondWorkspace = WorkspaceRecord(
            id: "second", projectID: aProject.id, dir: aDir, dirname: nil, branch: nil, baseBranch: "develop", isDefault: false, isRunning: false,
            lastLaunchedAt: nil)
        try store.upsert(workspace: secondWorkspace)
        try store.upsert(workspace: defaultWorkspace)

        XCTAssertEqual(try store.workspace(id: "second")?.id, "second")
        XCTAssertEqual(try store.workspace(id: "second")?.baseBranch, "develop")
        XCTAssertEqual(Set(try store.workspaces(projectID: aProject.id).map(\.id)), Set(["default", "second"]))
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
                id: id, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: sessionID, sessionKey: nil, status: .spinning,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))

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
                id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "review-agent", terminalTrackingID: sessionID, sessionKey: nil,
                status: .done, createdAt: "2026-06-04T14:23:10Z", updatedAt: "2026-06-04T14:25:06Z"))

        let loaded = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        let runtimeTargetID = try XCTUnwrap(loaded.runtimeTargetID)
        try store.deleteWindow(id: runtimeTargetID)

        let reloaded = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertNil(reloaded.runtimeTargetID)
        XCTAssertEqual(reloaded.terminalTrackingID, sessionID)
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
                sessionKey: nil, status: .idle, createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspaceB.id, provider: .spaces, label: "codex", terminalTrackingID: "session-b",
                sessionKey: nil, status: .spinning, createdAt: "2026-01-01T00:00:02Z", updatedAt: "2026-01-01T00:00:02Z"))

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
                id: idA, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "session-a", sessionKey: nil, status: .idle,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: idB, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "session-b", sessionKey: nil, status: .idle,
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
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s1", sessionKey: nil,
                status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s2", sessionKey: nil,
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
                id: id, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s1", sessionKey: nil, status: .idle,
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

    // Tests that the batched `*ByWorkspace` reads (used to eliminate the N+1 on the device overview
    // hot path) return exactly the same records, in the same order, as calling the per-workspace API
    // for each workspace — including empty results for a workspace with no rows.
    func testBatchByWorkspaceReadsMatchPerWorkspaceReads() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let ws1 = makeWorkspaceRecord(id: "ws1", projectID: project.id, dir: try makeTempDirectory().path, branch: "one")
        let ws2 = makeWorkspaceRecord(id: "ws2", projectID: project.id, dir: try makeTempDirectory().path, branch: "two")
        let ws3 = makeWorkspaceRecord(id: "ws3", projectID: project.id, dir: try makeTempDirectory().path, branch: "three")
        try store.upsert(project: project)
        for workspace in [ws1, ws2, ws3] { try store.upsert(workspace: workspace) }

        // ws1: two running processes and two agents with distinct order keys, ports, and a setup state.
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "p1b", workspaceID: ws1.id, templateName: "web", command: "npm run web", terminalApp: "Spaces", terminalTrackingID: "sess-web",
                pid: 2, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "2026-01-01T00:00:02Z", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "p1a", workspaceID: ws1.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", terminalTrackingID: "sess-api",
                pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "2026-01-01T00:00:01Z", exitedAt: nil))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "a1b", workspaceID: ws1.id, provider: .spaces, label: "Second", terminalTrackingID: "agent-2", sessionKey: nil, status: .idle,
                createdAt: "2026-01-01T00:00:02Z", updatedAt: "2026-01-01T00:00:02Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "a1a", workspaceID: ws1.id, provider: .spaces, label: "First", terminalTrackingID: "agent-1", sessionKey: nil, status: .idle,
                createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z"))
        try store.setWorkspacePorts(workspaceID: ws1.id, ports: [3000, 3001], names: ["api", "web"])
        try store.setWorkspaceSetupState(
            workspaceID: ws1.id, status: .failed, errorMessage: "boom", startedAt: "2026-01-01T00:00:00Z", finishedAt: "2026-01-01T00:00:05Z",
            exitCode: 7, logPath: "/tmp/ws1.log")

        // ws2: a single running process, agent, an extra standalone browser window, and ports — but no
        // setup-state row, so it must be absent from the batched setup-state map.
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "p2", workspaceID: ws2.id, templateName: "worker", command: "run worker", terminalApp: "Spaces",
                terminalTrackingID: "sess-worker", pid: 3, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "2026-01-02T00:00:00Z",
                exitedAt: "2026-01-02T00:01:00Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "a2", workspaceID: ws2.id, provider: .spaces, label: "Solo", terminalTrackingID: "agent-solo", sessionKey: nil, status: .idle,
                createdAt: "2026-01-02T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z"))
        try store.upsert(
            window: WindowRecord(
                id: "w2-browser", workspaceID: ws2.id, app: "Google Chrome", title: "Docs", role: "browser", orderIndex: 500, lastSeenAt: "now"))
        try store.setWorkspacePorts(workspaceID: ws2.id, ports: [4000], names: ["admin"])

        let runningByWorkspace = try store.runningProcessesByWorkspace()
        let agentsByWorkspace = try store.agentWindowsByWorkspace()
        let windowsByWorkspace = try store.windowsByWorkspace()
        let portsByWorkspace = try store.workspacePortsNamedByWorkspace()
        let setupByWorkspace = try store.workspaceSetupStateByWorkspace()

        for workspace in [ws1, ws2, ws3] {
            XCTAssertEqual(
                (runningByWorkspace[workspace.id] ?? []).map(\.id), try store.runningProcesses(workspaceID: workspace.id).map(\.id),
                "running processes mismatch for \(workspace.id)")
            XCTAssertEqual(
                (agentsByWorkspace[workspace.id] ?? []).map(\.id), try store.agentWindows(workspaceID: workspace.id).map(\.id),
                "agent windows mismatch for \(workspace.id)")
            XCTAssertEqual(
                (windowsByWorkspace[workspace.id] ?? []).map(\.id), try store.windows(workspaceID: workspace.id).map(\.id),
                "windows mismatch for \(workspace.id)")
            XCTAssertEqual(
                (portsByWorkspace[workspace.id] ?? []).map { "\($0.port):\($0.name)" },
                try store.workspacePortsNamed(workspaceID: workspace.id).map { "\($0.port):\($0.name)" }, "ports mismatch for \(workspace.id)")
            let batchedSetup = setupByWorkspace[workspace.id]
            let perWorkspaceSetup = try store.workspaceSetupState(workspaceID: workspace.id)
            XCTAssertEqual(batchedSetup?.status, perWorkspaceSetup?.status, "setup status mismatch for \(workspace.id)")
            XCTAssertEqual(batchedSetup?.errorMessage, perWorkspaceSetup?.errorMessage, "setup error mismatch for \(workspace.id)")
            XCTAssertEqual(batchedSetup?.exitCode, perWorkspaceSetup?.exitCode, "setup exit code mismatch for \(workspace.id)")
            XCTAssertEqual(batchedSetup?.logPath, perWorkspaceSetup?.logPath, "setup log path mismatch for \(workspace.id)")
        }

        // ws1 keeps its distinct ordering; ws3 has no rows in any batch and no setup-state entry.
        XCTAssertEqual(runningByWorkspace[ws1.id]?.map(\.id), ["p1a", "p1b"])
        XCTAssertEqual(agentsByWorkspace[ws1.id]?.map(\.id), ["a1a", "a1b"])
        XCTAssertNil(runningByWorkspace[ws3.id])
        XCTAssertNil(agentsByWorkspace[ws3.id])
        XCTAssertNil(windowsByWorkspace[ws3.id])
        XCTAssertNil(portsByWorkspace[ws3.id])
        XCTAssertNil(setupByWorkspace[ws2.id])
        XCTAssertNil(setupByWorkspace[ws3.id])
        XCTAssertEqual(setupByWorkspace[ws1.id]?.status, .failed)
    }

    // Tests workspace lookup by directory by arranging representative inputs and asserting the expected result.
    func testWorkspaceLookupByDirectory() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let workspace1Dir = try makeTempDirectory().path
        let workspace2Dir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace1 = WorkspaceRecord(
            id: "ws1", projectID: project.id, dir: workspace1Dir, dirname: "feature-1", branch: "feature-1", isDefault: false, isRunning: false,
            lastLaunchedAt: nil)
        let workspace2 = WorkspaceRecord(
            id: "ws2", projectID: project.id, dir: workspace2Dir, dirname: "feature-2", branch: "feature-2", isDefault: false, isRunning: false,
            lastLaunchedAt: nil)
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

    func testStoreRejectsDuplicateWorkspaceBranchWithinProject() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        try store.upsert(project: project)
        let branch = "feature-branch"
        let first = WorkspaceRecord(
            id: "ws-1", projectID: project.id, dir: try makeTempDirectory().path, dirname: "feature-1", branch: branch, isDefault: false,
            isRunning: false, lastLaunchedAt: nil)
        let second = WorkspaceRecord(
            id: "ws-2", projectID: project.id, dir: try makeTempDirectory().path, dirname: "feature-2", branch: branch, isDefault: false,
            isRunning: false, lastLaunchedAt: nil)
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
