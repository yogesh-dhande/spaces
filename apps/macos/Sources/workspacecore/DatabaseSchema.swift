import Foundation
import SQLite3

enum DatabaseSchema {
    static let currentVersion = 4

    static let migrationSteps: [DatabaseMigrationStep] = [
        DatabaseMigrationStep(
            fromVersion: 1, toVersion: 2, description: "Add foreign keys and cascade rules to persisted child tables", requiresBackup: true,
            apply: { db in try migrateV1ToV2(db: db) }),
        DatabaseMigrationStep(
            fromVersion: 2, toVersion: 3, description: "Rename workspace tooltip metadata to notes", requiresBackup: true,
            apply: { db in try migrateV2ToV3(db: db) }),
        DatabaseMigrationStep(
            fromVersion: 3, toVersion: 4, description: "Add process execution modes", requiresBackup: true, apply: { db in try migrateV3ToV4(db: db) }
        ),
    ]

    static let latestSchemaSQL = """
        CREATE TABLE IF NOT EXISTS projects (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          dir TEXT NOT NULL UNIQUE,
          is_git INTEGER NOT NULL,
          default_branch TEXT,
          is_collapsed INTEGER NOT NULL DEFAULT 0,
          setup_script TEXT,
          stop_script TEXT
        );

        CREATE TABLE IF NOT EXISTS project_port_definitions (
          id TEXT NOT NULL,
          project_id TEXT NOT NULL,
          name TEXT NOT NULL,
          order_index INTEGER NOT NULL,
          PRIMARY KEY (project_id, order_index),
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS project_processes (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          name TEXT,
          command TEXT NOT NULL,
          on_exit TEXT NOT NULL DEFAULT 'none',
          execution_mode TEXT NOT NULL DEFAULT 'direct',
          order_index INTEGER NOT NULL,
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS project_status_checks (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          name TEXT,
          process TEXT NOT NULL,
          command TEXT NOT NULL,
          interval INTEGER NOT NULL,
          timeout INTEGER NOT NULL,
          on_fail TEXT NOT NULL,
          order_index INTEGER NOT NULL,
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS project_browser_sessions (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          name TEXT,
          url TEXT,
          order_index INTEGER NOT NULL,
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS project_agent_launchers (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          name TEXT NOT NULL,
          command TEXT NOT NULL,
          order_index INTEGER NOT NULL,
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspaces (
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
          notes TEXT,
          UNIQUE(project_id, title),
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspace_ports (
          workspace_id TEXT NOT NULL,
          port_index INTEGER NOT NULL,
          port_number INTEGER NOT NULL,
          port_name TEXT NOT NULL DEFAULT '',
          definition_id TEXT NOT NULL DEFAULT '',
          PRIMARY KEY (workspace_id, port_index),
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspace_port_definitions (
          id TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          name TEXT NOT NULL,
          order_index INTEGER NOT NULL,
          PRIMARY KEY (workspace_id, order_index),
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspace_settings (
          workspace_id TEXT PRIMARY KEY,
          stop_script TEXT,
          setup_status TEXT NOT NULL DEFAULT 'succeeded',
          setup_error TEXT,
          setup_started_at TEXT,
          setup_finished_at TEXT,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspace_processes (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          name TEXT,
          command TEXT NOT NULL,
          on_exit TEXT NOT NULL DEFAULT 'none',
          execution_mode TEXT NOT NULL DEFAULT 'direct',
          order_index INTEGER NOT NULL,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspace_status_checks (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          name TEXT,
          process TEXT NOT NULL,
          command TEXT NOT NULL,
          interval INTEGER NOT NULL,
          timeout INTEGER NOT NULL,
          on_fail TEXT NOT NULL DEFAULT 'none',
          order_index INTEGER NOT NULL,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspace_browser_sessions (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          name TEXT,
          url TEXT,
          extracted_target_url TEXT,
          extracted_window_id INTEGER,
          extracted_window_valid INTEGER NOT NULL DEFAULT 0,
          order_index INTEGER NOT NULL,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspace_agent_launchers (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          name TEXT NOT NULL,
          command TEXT NOT NULL,
          order_index INTEGER NOT NULL,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS running_processes (
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
          exited_at TEXT,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS status_results (
          process_id TEXT NOT NULL,
          check_name TEXT NOT NULL,
          status TEXT NOT NULL,
          message TEXT,
          last_run_at TEXT,
          PRIMARY KEY (process_id, check_name),
          FOREIGN KEY (process_id) REFERENCES running_processes(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS windows (
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
          last_seen_at TEXT,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS ignored_worktrees (
          worktree_dir TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS agent_windows (
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
          yabai_window_id INTEGER,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS migration_state (
          current_version INTEGER NOT NULL
        );
        """

    private static func migrateV1ToV2(db: OpaquePointer) throws {
        try rebuildTable(
            db: db, tableName: "workspaces",
            createSQL: """
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
                  UNIQUE(project_id, title),
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO workspaces(id, project_id, title, dir, dirname, branch, target_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, tooltip)
                SELECT id, project_id, title, dir, dirname, branch, target_branch, is_default, is_archived, is_hidden, is_running, last_launched_at, tooltip
                FROM workspaces_v1
                """)

        try rebuildTable(
            db: db, tableName: "project_port_definitions",
            createSQL: """
                CREATE TABLE project_port_definitions (
                  id TEXT NOT NULL,
                  project_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  PRIMARY KEY (project_id, order_index),
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO project_port_definitions(id, project_id, name, order_index)
                SELECT id, project_id, name, order_index FROM project_port_definitions_v1
                """)

        try rebuildTable(
            db: db, tableName: "project_processes",
            createSQL: """
                CREATE TABLE project_processes (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT,
                  command TEXT NOT NULL,
                  on_exit TEXT NOT NULL DEFAULT 'none',
                  order_index INTEGER NOT NULL,
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO project_processes(id, project_id, name, command, on_exit, order_index)
                SELECT id, project_id, name, command, on_exit, order_index FROM project_processes_v1
                """)

        try rebuildTable(
            db: db, tableName: "project_status_checks",
            createSQL: """
                CREATE TABLE project_status_checks (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT,
                  process TEXT NOT NULL,
                  command TEXT NOT NULL,
                  interval INTEGER NOT NULL,
                  timeout INTEGER NOT NULL,
                  on_fail TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO project_status_checks(id, project_id, name, process, command, interval, timeout, on_fail, order_index)
                SELECT id, project_id, name, process, command, interval, timeout, on_fail, order_index FROM project_status_checks_v1
                """)

        try rebuildTable(
            db: db, tableName: "project_browser_sessions",
            createSQL: """
                CREATE TABLE project_browser_sessions (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT,
                  url TEXT,
                  order_index INTEGER NOT NULL,
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO project_browser_sessions(id, project_id, name, url, order_index)
                SELECT id, project_id, name, url, order_index FROM project_browser_sessions_v1
                """)

        try rebuildTable(
            db: db, tableName: "project_agent_launchers",
            createSQL: """
                CREATE TABLE project_agent_launchers (
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO project_agent_launchers(id, project_id, name, command, order_index)
                SELECT id, project_id, name, command, order_index FROM project_agent_launchers_v1
                """)

        try rebuildTable(
            db: db, tableName: "workspace_ports",
            createSQL: """
                CREATE TABLE workspace_ports (
                  workspace_id TEXT NOT NULL,
                  port_index INTEGER NOT NULL,
                  port_number INTEGER NOT NULL,
                  port_name TEXT NOT NULL DEFAULT '',
                  definition_id TEXT NOT NULL DEFAULT '',
                  PRIMARY KEY (workspace_id, port_index),
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO workspace_ports(workspace_id, port_index, port_number, port_name, definition_id)
                SELECT workspace_id, port_index, port_number, port_name, definition_id FROM workspace_ports_v1
                """)

        try rebuildTable(
            db: db, tableName: "workspace_port_definitions",
            createSQL: """
                CREATE TABLE workspace_port_definitions (
                  id TEXT NOT NULL,
                  workspace_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  PRIMARY KEY (workspace_id, order_index),
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO workspace_port_definitions(id, workspace_id, name, order_index)
                SELECT id, workspace_id, name, order_index FROM workspace_port_definitions_v1
                """)

        try rebuildTable(
            db: db, tableName: "workspace_settings",
            createSQL: """
                CREATE TABLE workspace_settings (
                  workspace_id TEXT PRIMARY KEY,
                  stop_script TEXT,
                  setup_status TEXT NOT NULL DEFAULT 'succeeded',
                  setup_error TEXT,
                  setup_started_at TEXT,
                  setup_finished_at TEXT,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO workspace_settings(workspace_id, stop_script, setup_status, setup_error, setup_started_at, setup_finished_at)
                SELECT workspace_id, stop_script, setup_status, setup_error, setup_started_at, setup_finished_at FROM workspace_settings_v1
                """)

        try rebuildTable(
            db: db, tableName: "workspace_processes",
            createSQL: """
                CREATE TABLE workspace_processes (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT,
                  command TEXT NOT NULL,
                  on_exit TEXT NOT NULL DEFAULT 'none',
                  order_index INTEGER NOT NULL,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO workspace_processes(id, workspace_id, name, command, on_exit, order_index)
                SELECT id, workspace_id, name, command, on_exit, order_index FROM workspace_processes_v1
                """)

        try rebuildTable(
            db: db, tableName: "workspace_status_checks",
            createSQL: """
                CREATE TABLE workspace_status_checks (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT,
                  process TEXT NOT NULL,
                  command TEXT NOT NULL,
                  interval INTEGER NOT NULL,
                  timeout INTEGER NOT NULL,
                  on_fail TEXT NOT NULL DEFAULT 'none',
                  order_index INTEGER NOT NULL,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO workspace_status_checks(id, workspace_id, name, process, command, interval, timeout, on_fail, order_index)
                SELECT id, workspace_id, name, process, command, interval, timeout, on_fail, order_index FROM workspace_status_checks_v1
                """)

        try rebuildTable(
            db: db, tableName: "workspace_browser_sessions",
            createSQL: """
                CREATE TABLE workspace_browser_sessions (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT,
                  url TEXT,
                  extracted_target_url TEXT,
                  extracted_window_id INTEGER,
                  extracted_window_valid INTEGER NOT NULL DEFAULT 0,
                  order_index INTEGER NOT NULL,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO workspace_browser_sessions(id, workspace_id, name, url, extracted_target_url, extracted_window_id, extracted_window_valid, order_index)
                SELECT id, workspace_id, name, url, extracted_target_url, extracted_window_id, extracted_window_valid, order_index FROM workspace_browser_sessions_v1
                """)

        try rebuildTable(
            db: db, tableName: "workspace_agent_launchers",
            createSQL: """
                CREATE TABLE workspace_agent_launchers (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  command TEXT NOT NULL,
                  order_index INTEGER NOT NULL,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO workspace_agent_launchers(id, workspace_id, name, command, order_index)
                SELECT id, workspace_id, name, command, order_index FROM workspace_agent_launchers_v1
                """)

        try rebuildTable(
            db: db, tableName: "running_processes",
            createSQL: """
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
                  exited_at TEXT,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO running_processes(id, workspace_id, template_name, command, terminal_app, window_id, terminal_tracking_id, terminal_native_id, iterm_tab_index, tmux_window_id, pid, status, log_path, last_output_at, started_at, exited_at)
                SELECT id, workspace_id, template_name, command, terminal_app, window_id, terminal_tracking_id, terminal_native_id, iterm_tab_index, tmux_window_id, pid, status, log_path, last_output_at, started_at, exited_at FROM running_processes_v1
                """)

        try rebuildTable(
            db: db, tableName: "status_results",
            createSQL: """
                CREATE TABLE status_results (
                  process_id TEXT NOT NULL,
                  check_name TEXT NOT NULL,
                  status TEXT NOT NULL,
                  message TEXT,
                  last_run_at TEXT,
                  PRIMARY KEY (process_id, check_name),
                  FOREIGN KEY (process_id) REFERENCES running_processes(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO status_results(process_id, check_name, status, message, last_run_at)
                SELECT process_id, check_name, status, message, last_run_at FROM status_results_v1
                """)

        try rebuildTable(
            db: db, tableName: "windows",
            createSQL: """
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
                  last_seen_at TEXT,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO windows(id, workspace_id, app, name, detail, target_url, window_id, terminal_tracking_id, terminal_native_id, iterm_tab_index, tmux_window_id, role, order_index, last_seen_at)
                SELECT id, workspace_id, app, name, detail, target_url, window_id, terminal_tracking_id, terminal_native_id, iterm_tab_index, tmux_window_id, role, order_index, last_seen_at FROM windows_v1
                """)

        try rebuildTable(
            db: db, tableName: "ignored_worktrees",
            createSQL: """
                CREATE TABLE ignored_worktrees (
                  worktree_dir TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL,
                  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO ignored_worktrees(worktree_dir, project_id)
                SELECT worktree_dir, project_id FROM ignored_worktrees_v1
                """)

        try rebuildTable(
            db: db, tableName: "agent_windows",
            createSQL: """
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
                  yabai_window_id INTEGER,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                )
                """,
            copySQL: """
                INSERT INTO agent_windows(id, workspace_id, provider, label, terminal_tracking_id, terminal_native_id, tmux_window_id, codex_thread_id, window_id, status, created_at, updated_at, yabai_window_id)
                SELECT id, workspace_id, provider, label, terminal_tracking_id, terminal_native_id, tmux_window_id, codex_thread_id, window_id, status, created_at, updated_at, yabai_window_id FROM agent_windows_v1
                """)
    }

    private static func migrateV3ToV4(db: OpaquePointer) throws {
        try exec(db: db, sql: "ALTER TABLE project_processes ADD COLUMN execution_mode TEXT NOT NULL DEFAULT 'direct';")
        try exec(db: db, sql: "ALTER TABLE workspace_processes ADD COLUMN execution_mode TEXT NOT NULL DEFAULT 'direct';")
    }

    private static func exec(db: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.store", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func migrateV2ToV3(db: OpaquePointer) throws { try execute(db: db, sql: "ALTER TABLE workspaces RENAME COLUMN tooltip TO notes;") }

    private static func rebuildTable(db: OpaquePointer, tableName: String, createSQL: String, copySQL: String, previousVersionSuffix: String = "v1")
        throws
    {
        try execute(db: db, sql: "ALTER TABLE \(tableName) RENAME TO \(tableName)_\(previousVersionSuffix);")
        try execute(db: db, sql: createSQL)
        try execute(db: db, sql: copySQL)
        try execute(db: db, sql: "DROP TABLE \(tableName)_\(previousVersionSuffix);")
    }

    private static func execute(db: OpaquePointer, sql: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.store", code: 44, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
