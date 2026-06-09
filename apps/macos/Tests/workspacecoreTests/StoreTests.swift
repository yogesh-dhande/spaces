import SQLite3
import XCTest

@testable import spacesdatabase
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
        let workspacePortColumns = try readTableColumns(dbURL: dbURL, table: "workspace_ports")
        let workspacePortDefinitionColumns = try readTableColumns(dbURL: dbURL, table: "workspace_port_definitions")
        let projectPortDefinitionColumns = try readTableColumns(dbURL: dbURL, table: "project_port_definitions")
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
        XCTAssertTrue(workspaceColumns.contains("title"))
        XCTAssertTrue(workspaceColumns.contains("notes"))
        XCTAssertTrue(workspaceColumns.contains("is_hidden"))
        XCTAssertTrue(projectColumns.contains("is_collapsed"))
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
        XCTAssertTrue(workspacePortColumns.contains("definition_id"))
        XCTAssertTrue(workspacePortDefinitionColumns.contains("id"))
        XCTAssertTrue(projectPortDefinitionColumns.contains("id"))
        XCTAssertFalse(workspaceBrowserSessionColumns.contains("id"))
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
        XCTAssertFalse(agentSessionColumns.contains("yabai_window_id"))
        XCTAssertEqual(workspaceForeignKeys, 1)
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "windows"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "agent_windows"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "terminal_targets"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "project_status_checks"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "workspace_status_checks"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "status_results"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    func testVersionEightDatabaseDropsLegacyExternalTerminalStorage() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("v8-legacy-terminal-cleanup.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE running_processes (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  template_id TEXT,
                  template_name TEXT NOT NULL,
                  command TEXT NOT NULL,
                  runtime_target_id TEXT,
                  terminal_session_id TEXT,
                  terminal_app TEXT,
                  window_id INTEGER,
                  terminal_tracking_id TEXT,
                  terminal_native_id TEXT,
                  terminal_container_id TEXT,
                  iterm_tab_index INTEGER,
                  tmux_window_id TEXT,
                  pid INTEGER,
                  status TEXT NOT NULL,
                  log_path TEXT,
                  last_output_at TEXT,
                  started_at TEXT,
                  exited_at TEXT
                );
                CREATE TABLE runtime_targets (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  name TEXT,
                  detail TEXT,
                  app TEXT NOT NULL,
                  window_id INTEGER,
                  native_id TEXT,
                  provider TEXT,
                  container_id TEXT,
                  tracking_id TEXT,
                  order_index INTEGER NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE agent_sessions (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  label TEXT,
                  status TEXT NOT NULL DEFAULT 'idle',
                  runtime_target_id TEXT,
                  terminal_target_id TEXT,
                  terminal_session_id TEXT,
                  terminal_tracking_id TEXT,
                  terminal_native_id TEXT,
                  yabai_window_id INTEGER,
                  session_key TEXT,
                  claimed_launcher_id TEXT,
                  claimed_launcher_name TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE terminal_targets (id TEXT PRIMARY KEY);
                CREATE TABLE windows (id TEXT PRIMARY KEY);
                CREATE TABLE agent_windows (id TEXT PRIMARY KEY);
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO runtime_targets(
                  id, workspace_id, type, name, detail, app, window_id, native_id, provider, container_id, tracking_id, order_index, created_at, updated_at
                )
                VALUES (
                  'runtime-1', 'workspace-1', 'terminal', 'api', 'npm run api', 'Spaces', 44, 'native-1', 'spaces', 'container-1',
                  'session-1', 10, '2026-01-01T00:00:00Z', '2026-01-01T00:00:01Z'
                );
                INSERT INTO running_processes(
                  id, workspace_id, template_id, template_name, command, runtime_target_id, terminal_session_id, terminal_app, window_id,
                  terminal_tracking_id, terminal_native_id, terminal_container_id, iterm_tab_index, tmux_window_id, status, started_at
                )
                VALUES (
                  'process-1', 'workspace-1', 'template-1', 'api', 'npm run api', 'runtime-1', 'session-1', 'Spaces', 44,
                  'session-1', 'native-1', 'container-1', 2, 'tmux-1', 'running', '2026-01-01T00:00:00Z'
                );
                INSERT INTO agent_sessions(
                  id, workspace_id, provider, label, status, runtime_target_id, terminal_target_id, terminal_session_id, terminal_tracking_id,
                  terminal_native_id, yabai_window_id, session_key, claimed_launcher_id, claimed_launcher_name, created_at, updated_at
                )
                VALUES (
                  'agent-1', 'workspace-1', 'spaces', 'Codex', 'idle', 'runtime-1', 'terminal-target-1', 'session-1', 'session-1',
                  'native-1', 44, 'thread-1', 'launcher-1', 'Codex', '2026-01-01T00:00:00Z', '2026-01-01T00:00:01Z'
                );
                INSERT INTO migration_state(current_version) VALUES (8);
                """)

        _ = try SQLiteStore(path: dbURL.path)

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
        let runningProcessColumns = try readTableColumns(dbURL: dbURL, table: "running_processes")
        XCTAssertFalse(runningProcessColumns.contains("terminal_app"))
        XCTAssertFalse(runningProcessColumns.contains("window_id"))
        XCTAssertFalse(runningProcessColumns.contains("terminal_tracking_id"))
        XCTAssertFalse(runningProcessColumns.contains("terminal_native_id"))
        XCTAssertFalse(runningProcessColumns.contains("terminal_container_id"))
        XCTAssertFalse(runningProcessColumns.contains("iterm_tab_index"))
        XCTAssertFalse(runningProcessColumns.contains("tmux_window_id"))
        let runtimeTargetColumns = try readTableColumns(dbURL: dbURL, table: "runtime_targets")
        XCTAssertFalse(runtimeTargetColumns.contains("native_id"))
        XCTAssertFalse(runtimeTargetColumns.contains("provider"))
        XCTAssertFalse(runtimeTargetColumns.contains("container_id"))
        let agentSessionColumns = try readTableColumns(dbURL: dbURL, table: "agent_sessions")
        XCTAssertFalse(agentSessionColumns.contains("terminal_target_id"))
        XCTAssertFalse(agentSessionColumns.contains("terminal_tracking_id"))
        XCTAssertFalse(agentSessionColumns.contains("terminal_native_id"))
        XCTAssertFalse(agentSessionColumns.contains("yabai_window_id"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "terminal_targets"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "windows"))
        XCTAssertFalse(try tableExists(dbURL: dbURL, table: "agent_windows"))
        XCTAssertEqual(
            try readRows(
                dbURL: dbURL,
                sql: "SELECT id, workspace_id, template_id, template_name, runtime_target_id, terminal_session_id FROM running_processes"),
            [["process-1", "workspace-1", "template-1", "api", "runtime-1", "session-1"]])
        XCTAssertEqual(
            try readRows(dbURL: dbURL, sql: "SELECT id, workspace_id, type, app, window_id, tracking_id FROM runtime_targets"),
            [["runtime-1", "workspace-1", "terminal", "Spaces", "44", "session-1"]])
        XCTAssertEqual(
            try readRows(
                dbURL: dbURL, sql: "SELECT id, workspace_id, provider, label, runtime_target_id, terminal_session_id, session_key FROM agent_sessions"
            ), [["agent-1", "workspace-1", "spaces", "Codex", "runtime-1", "session-1", "thread-1"]])
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

    func testVersionOneDatabaseMigratesTerminalTablesWithoutDroppingProjects() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("v1-terminal-migration.db")
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
                  notes TEXT
                );
                CREATE TABLE workspace_processes (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT,
                  command TEXT NOT NULL,
                  on_exit TEXT NOT NULL DEFAULT 'none',
                  execution_mode TEXT NOT NULL DEFAULT 'direct',
                  order_index INTEGER NOT NULL
                );
                CREATE TABLE running_processes (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  template_name TEXT NOT NULL,
                  command TEXT NOT NULL,
                  runtime_target_id TEXT,
                  pid INTEGER,
                  status TEXT NOT NULL,
                  log_path TEXT,
                  last_output_at TEXT,
                  started_at TEXT,
                  exited_at TEXT
                );
                CREATE TABLE project_agent_launchers (
                  project_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  PRIMARY KEY (project_id, order_index)
                );
                CREATE TABLE workspace_agent_launchers (
                  workspace_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  PRIMARY KEY (workspace_id, order_index)
                );
                CREATE TABLE agent_sessions (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  label TEXT,
                  status TEXT NOT NULL DEFAULT 'idle',
                  runtime_target_id TEXT,
                  session_key TEXT,
                  claimed_launcher_name TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO projects(id, name, dir, is_git, is_collapsed) VALUES ('project-1', 'Project', '/tmp/project', 1, 0);
                INSERT INTO workspaces(id, project_id, title, dir, is_default, is_archived, is_running)
                VALUES ('workspace-1', 'project-1', 'feature', '/tmp/project/feature', 0, 0, 1);
                INSERT INTO workspace_processes(id, workspace_id, name, command, order_index)
                VALUES ('process-template-1', 'workspace-1', 'frontend', 'npm run dev', 0);
                INSERT INTO running_processes(id, workspace_id, template_name, command, status)
                VALUES ('process-runtime-1', 'workspace-1', 'frontend', 'npm run dev', 'running');
                INSERT INTO project_agent_launchers(project_id, name, command, order_index)
                VALUES ('project-1', 'Codex', 'codex', 0);
                INSERT INTO workspace_agent_launchers(workspace_id, name, command, order_index)
                VALUES ('workspace-1', 'Codex', 'codex', 0);
                INSERT INTO agent_sessions(id, workspace_id, provider, label, status, claimed_launcher_name, created_at, updated_at)
                VALUES ('agent-1', 'workspace-1', 'codex', 'Codex', 'idle', 'Codex', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
                INSERT INTO migration_state(current_version) VALUES (1);
                """)

        _ = try SQLiteStore(path: dbURL.path)

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
        XCTAssertTrue(try tableExists(dbURL: dbURL, table: "terminal_sessions"))
        XCTAssertTrue(try tableExists(dbURL: dbURL, table: "terminal_clients"))
        XCTAssertTrue(try tableExists(dbURL: dbURL, table: "terminal_remote_session_states"))
        XCTAssertEqual(try readSingleText(dbURL: dbURL, sql: "SELECT name FROM projects WHERE id = 'project-1'"), "Project")
        XCTAssertEqual(
            try readSingleText(dbURL: dbURL, sql: "SELECT template_id FROM running_processes WHERE id = 'process-runtime-1'"), "process-template-1")
        let workspaceAgentLauncherID = try readSingleText(
            dbURL: dbURL, sql: "SELECT id FROM workspace_agent_launchers WHERE workspace_id = 'workspace-1' AND name = 'Codex'")
        XCTAssertFalse(workspaceAgentLauncherID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(
            try readSingleText(dbURL: dbURL, sql: "SELECT claimed_launcher_id FROM agent_sessions WHERE id = 'agent-1'"), workspaceAgentLauncherID)
        XCTAssertFalse(
            try readSingleText(dbURL: dbURL, sql: "SELECT id FROM project_agent_launchers WHERE project_id = 'project-1' AND name = 'Codex'")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    func testVersionFiveDatabaseMigratesTerminalSessionOwnershipMetadata() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("v5-terminal-ownership-migration.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE terminal_sessions (
                  session_id TEXT PRIMARY KEY,
                  root_directory TEXT NOT NULL UNIQUE,
                  backend TEXT NOT NULL,
                  lifetime_policy TEXT NOT NULL,
                  title TEXT NOT NULL,
                  working_directory TEXT NOT NULL,
                  shell TEXT NOT NULL,
                  command TEXT,
                  created_at TEXT NOT NULL
                );
                CREATE TABLE running_processes (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  terminal_session_id TEXT,
                  started_at TEXT,
                  exited_at TEXT,
                  last_output_at TEXT
                );
                CREATE TABLE agent_sessions (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  terminal_session_id TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE runtime_targets (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  app TEXT NOT NULL,
                  tracking_id TEXT,
                  order_index INTEGER NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO terminal_sessions(session_id, root_directory, backend, lifetime_policy, title, working_directory, shell, created_at)
                VALUES
                  ('process-session', '/tmp/process-session', 'ghosttyEmbedded', 'persistent', 'process', '/tmp/process', '/bin/zsh', '2026-01-01T00:00:00Z'),
                  ('agent-session', '/tmp/agent-session', 'ghosttyEmbedded', 'persistent', 'agent', '/tmp/agent', '/bin/zsh', '2026-01-01T00:00:00Z'),
                  ('runtime-session', '/tmp/runtime-session', 'ghosttyEmbedded', 'persistent', 'runtime', '/tmp/runtime', '/bin/zsh', '2026-01-01T00:00:00Z'),
                  ('unowned-session', '/tmp/unowned-session', 'ghosttyEmbedded', 'persistent', 'unowned', '/tmp/unowned', '/bin/zsh', '2026-01-01T00:00:00Z');
                INSERT INTO running_processes(id, workspace_id, terminal_session_id, started_at)
                VALUES ('process-1', 'workspace-process', 'process-session', '2026-01-01T00:00:02Z');
                INSERT INTO agent_sessions(id, workspace_id, provider, terminal_session_id, created_at, updated_at)
                VALUES ('agent-1', 'workspace-agent', 'spaces', 'agent-session', '2026-01-01T00:00:01Z', '2026-01-01T00:00:03Z');
                INSERT INTO runtime_targets(id, workspace_id, type, app, tracking_id, order_index, updated_at)
                VALUES
                  ('target-process', 'workspace-wrong-process', 'terminal', 'Spaces', 'process-session', 0, '2026-01-01T00:00:04Z'),
                  ('target-agent', 'workspace-wrong-agent', 'terminal', 'Spaces', 'agent-session', 1, '2026-01-01T00:00:04Z'),
                  ('target-runtime', 'workspace-runtime', 'terminal', 'Spaces', 'runtime-session', 2, '2026-01-01T00:00:04Z');
                INSERT INTO migration_state(current_version) VALUES (5);
                """)

        _ = try SQLiteStore(path: dbURL.path)

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
        let terminalSessionColumns = try readTableColumns(dbURL: dbURL, table: "terminal_sessions")
        XCTAssertTrue(terminalSessionColumns.contains("workspace_id"))
        XCTAssertTrue(terminalSessionColumns.contains("kind"))
        XCTAssertEqual(
            try readRows(dbURL: dbURL, sql: "SELECT session_id, COALESCE(workspace_id, ''), kind FROM terminal_sessions ORDER BY session_id"),
            [
                ["agent-session", "workspace-agent", "agent"], ["process-session", "workspace-process", "process"],
                ["runtime-session", "workspace-runtime", "shell"], ["unowned-session", "", "shell"],
            ])
    }

    func testVersionSixDatabaseMigratesWorkspaceSetupResultMetadata() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("v6-setup-result-migration.db")
        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                CREATE TABLE workspace_settings (
                  workspace_id TEXT PRIMARY KEY,
                  stop_script TEXT,
                  setup_status TEXT NOT NULL DEFAULT 'succeeded',
                  setup_error TEXT,
                  setup_started_at TEXT,
                  setup_finished_at TEXT
                );
                INSERT INTO workspace_settings(workspace_id, setup_status, setup_error, setup_started_at, setup_finished_at)
                VALUES ('workspace-1', 'failed', 'old failure', '2026-01-01T00:00:00Z', '2026-01-01T00:00:05Z');
                CREATE TABLE migration_state (current_version INTEGER NOT NULL);
                INSERT INTO migration_state(current_version) VALUES (6);
                """)

        _ = try SQLiteStore(path: dbURL.path)

        XCTAssertEqual(try readSingleInteger(dbURL: dbURL, sql: "SELECT current_version FROM migration_state"), DatabaseSchema.currentVersion)
        let workspaceSettingsColumns = try readTableColumns(dbURL: dbURL, table: "workspace_settings")
        XCTAssertTrue(workspaceSettingsColumns.contains("setup_exit_code"))
        XCTAssertTrue(workspaceSettingsColumns.contains("setup_log_path"))
        XCTAssertEqual(
            try readRows(
                dbURL: dbURL,
                sql: """
                    SELECT setup_status, setup_error, setup_started_at, setup_finished_at,
                           COALESCE(setup_exit_code, ''), COALESCE(setup_log_path, '')
                    FROM workspace_settings
                    WHERE workspace_id = 'workspace-1'
                    """), [["failed", "old failure", "2026-01-01T00:00:00Z", "2026-01-01T00:00:05Z", "", ""]])
    }

    func testCurrentSchemaRejectsBlankPortNamesAtDatabaseLevel() throws {
        let root = try makeTempDirectory()
        let dbURL = root.appendingPathComponent("port-name-constraints.db")
        _ = try SQLiteStore(path: dbURL.path)

        try runSQLiteExec(
            dbURL: dbURL,
            sql: """
                INSERT INTO projects(id, name, dir, is_git, is_collapsed) VALUES ('project-1', 'Project', '/tmp/project', 0, 0);
                INSERT INTO workspaces(id, project_id, title, dir, is_default, is_archived, is_hidden, is_running)
                VALUES ('workspace-1', 'project-1', 'feature', '/tmp/project/feature', 0, 0, 0, 0);
                """)

        XCTAssertThrowsError(
            try runSQLiteExec(
                dbURL: dbURL, sql: "INSERT INTO project_port_definitions(id, project_id, name, order_index) VALUES ('ppd-1', 'project-1', ' ', 0);"))
        XCTAssertThrowsError(
            try runSQLiteExec(
                dbURL: dbURL,
                sql: "INSERT INTO workspace_port_definitions(id, workspace_id, name, order_index) VALUES ('wpd-1', 'workspace-1', char(10), 0);"))
        XCTAssertThrowsError(
            try runSQLiteExec(
                dbURL: dbURL,
                sql:
                    "INSERT INTO workspace_ports(workspace_id, port_index, port_number, port_name, definition_id) VALUES ('workspace-1', 0, 3000, char(9), 'wpd-1');"
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
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 3001], names: ["API_PORT", "WEB_PORT"])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [3000, 3001])
        let named = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(named[0].name, "API_PORT")
        XCTAssertEqual(named[1].name, "WEB_PORT")
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [4000], names: ["ADMIN_PORT"])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [4000])
        let namedAfter = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(namedAfter[0].name, "ADMIN_PORT")

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

        let codexLauncher = AgentLauncher(id: "launcher-codex", name: "Codex", command: "codex")
        let claudeLauncher = AgentLauncher(id: "launcher-claude", name: "Claude", command: "claude")
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [codexLauncher, claudeLauncher])
        let launchers = try store.workspaceAgentLaunchers(workspaceID: workspace.id)
        XCTAssertEqual(launchers, [codexLauncher, claudeLauncher])
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

    func testStoreRejectsBlankPortNames() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        XCTAssertThrowsError(
            try store.upsert(
                project: ProjectRecord(
                    id: project.id, name: project.name, dir: project.dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil,
                    ports: [PortDefinition(name: " ")], processes: [], browserSessions: [], agentLaunchers: [])))
        XCTAssertThrowsError(try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: [PortDefinition(name: "\n")]))
        XCTAssertThrowsError(try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["\t"]))
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
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", windowID: 9001,
                terminalTrackingID: "session-abc", pid: 1234, status: .running, logPath: "/tmp/api.log", lastOutputAt: "2026-01-01T00:00:00Z",
                startedAt: "2026-01-01T00:00:00Z", exitedAt: nil))

        var processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0].status, .running)
        XCTAssertEqual(processes[0].windowID, 9001)
        XCTAssertEqual(processes[0].terminalTrackingID, "session-abc")

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
            id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, title: "Terminal", windowID: 43, role: "terminal",
            orderIndex: 1, lastSeenAt: "now")
        try store.upsert(window: firstWindow)
        try store.upsert(window: secondWindow)

        XCTAssertEqual(try store.workspaceID(windowID: 42), workspace.id)
        let storedWindows = try store.windows(workspaceID: workspace.id)
        XCTAssertEqual(storedWindows.count, 3)
        XCTAssertEqual(storedWindows[0].name, "Browser")
        XCTAssertEqual(storedWindows[0].detail, nil)
        XCTAssertTrue(storedWindows.contains(where: { $0.name == "Terminal" }))
        try store.deleteWindow(id: firstWindow.id)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).count, 2)
        try store.deleteWindows(workspaceID: workspace.id)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testSpacesRunningProcessKeepsSessionIDAfterRuntimeTargetIsDeleted() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "spaces-process-session"
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: workspace.id, templateName: "docs-watch", command: "sleep 300",
                terminalApp: TerminalHost.spaces.appName, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil,
                status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "2026-06-04T14:23:10Z", exitedAt: "2026-06-04T14:23:23Z"))

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

    // Tests agent-window yabai lookup resolves a workspace by arranging a stored agent window and asserting the lookup result.
    func testWorkspaceIDForAgentWindowResolvesByYabaiWindowID() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature-agent", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "session-123",
                codexThreadID: "thread-123", windowID: nil, yabaiWindowID: 4242, status: .spinning, createdAt: "2026-02-25T00:00:00Z",
                updatedAt: "2026-02-25T00:00:01Z"))

        XCTAssertEqual(try store.workspaceIDForAgentWindow(yabaiWindowID: 4242), workspace.id)
    }

    func testWorkspaceIDForTerminalSessionResolvesPreservedAgentSessionIDAfterRuntimeTargetIsDeleted() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature-agent", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "spaces-agent-session"
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID,
                codexThreadID: "thread-123", windowID: nil, status: .done, createdAt: "2026-02-25T00:00:00Z", updatedAt: "2026-02-25T00:00:01Z"))

        let loaded = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        let runtimeTargetID = try XCTUnwrap(loaded.runtimeTargetID)
        try store.deleteWindow(id: runtimeTargetID)

        XCTAssertEqual(try store.workspaceIDForTerminalSession(sessionID), workspace.id)
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
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["API_PORT"])
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: [PortDefinition(name: "API_PORT")])
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(command: "echo one")])
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "https://example.com")])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "one", command: "echo one", terminalApp: nil, windowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "term", windowID: 77, role: "terminal", orderIndex: 0,
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
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["API_PORT"])
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

        XCTAssertEqual(try store.workspace(projectID: aProject.id, title: "feature")?.id, "archived")
        XCTAssertEqual(try store.workspace(projectID: aProject.id, title: "feature")?.targetBranch, "develop")
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
                id: UUID().uuidString, workspaceID: workspaceA.id, app: "Spaces", title: "shell-a", windowID: windowID, role: "terminal",
                orderIndex: 0, lastSeenAt: "2026-01-01T00:00:01Z"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspaceB.id, app: "Spaces", title: "shell-b", windowID: windowID, role: "terminal",
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

    // Tests agent window lookup by terminal session ID returns the matching record by arranging representative inputs and asserting the expected result.
    func testAgentWindowLookupByTerminalSessionID() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "session-abc"
        let id = UUID().uuidString
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: id, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: sessionID, codexThreadID: nil, windowID: nil,
                yabaiWindowID: nil, status: .spinning, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))

        let found = try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID)
        XCTAssertEqual(found?.id, id)
        XCTAssertEqual(found?.terminalTrackingID, sessionID)
        XCTAssertNil(try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: "nonexistent"))
    }

    func testSpacesAgentKeepsSessionIDAfterRuntimeTargetIsDeleted() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = "spaces-agent-session"
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "review-agent", terminalTrackingID: sessionID,
                terminalNativeID: sessionID, codexThreadID: nil, windowID: nil, yabaiWindowID: nil, status: .done, createdAt: "2026-06-04T14:23:10Z",
                updatedAt: "2026-06-04T14:25:06Z"))

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
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: project.dir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, title: "feature-b", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.upsert(workspace: workspaceB)

        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "claude", terminalTrackingID: "session-a",
                codexThreadID: nil, windowID: nil, yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:01Z",
                updatedAt: "2026-01-01T00:00:01Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspaceB.id, provider: .spaces, label: "codex", terminalTrackingID: "session-b",
                codexThreadID: nil, windowID: nil, yabaiWindowID: nil, status: .spinning, createdAt: "2026-01-01T00:00:02Z",
                updatedAt: "2026-01-01T00:00:02Z"))

        let agentWindows = try store.agentWindowsByProvider(workspaceID: workspace.id, provider: .spaces)
        XCTAssertEqual(agentWindows.count, 1)
        XCTAssertEqual(agentWindows[0].provider, .spaces)
        XCTAssertEqual(agentWindows[0].terminalTrackingID, "session-a")
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
                id: idA, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "session-a", codexThreadID: nil, windowID: nil,
                yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: idB, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "session-b", codexThreadID: nil, windowID: nil,
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
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s1", codexThreadID: nil,
                windowID: nil, yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s2", codexThreadID: nil,
                windowID: nil, yabaiWindowID: nil, status: .spinning, createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z"))

        try store.deleteAgentWindowsByProvider(workspaceID: workspace.id, provider: .spaces)
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
                id: id, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s1", codexThreadID: nil, windowID: nil,
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

    func testWorkspaceLookupByDirectoryPrefersActiveWorkspaceOverArchivedDuplicate() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let workspaceDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let archived = WorkspaceRecord(
            id: "archived", projectID: project.id, title: "feature-old", dir: workspaceDir, dirname: nil, branch: nil, isDefault: false,
            isArchived: true, isRunning: false, lastLaunchedAt: nil)
        let active = WorkspaceRecord(
            id: "active", projectID: project.id, title: "feature-new", dir: workspaceDir, dirname: nil, branch: nil, isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
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
            id: "ws-1", projectID: project.id, title: "feature-1", dir: try makeTempDirectory().path, dirname: "feature-1", branch: branch,
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let second = WorkspaceRecord(
            id: "ws-2", projectID: project.id, title: "feature-2", dir: try makeTempDirectory().path, dirname: "feature-2", branch: branch,
            isDefault: false, isArchived: true, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: first)

        XCTAssertThrowsError(try store.upsert(workspace: second))
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

    private func tableExists(dbURL: URL, table: String) throws -> Bool {
        try readSingleInteger(dbURL: dbURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'") == 1
    }
}
