import Foundation
import SQLite3

enum DatabaseSchema {
    static let currentVersion = 2

    static let migrationSteps: [DatabaseMigrationStep] = [
        DatabaseMigrationStep(
            fromVersion: 1, toVersion: 2, description: "Add normalized runtime target and agent session tables", requiresBackup: true,
            apply: { db in try migrateV1toV2(db: db) })
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
          name TEXT NOT NULL CHECK (length(trim(name, ' \n\r\t')) > 0),
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

        CREATE TABLE IF NOT EXISTS project_browser_sessions (
          project_id TEXT NOT NULL,
          name TEXT,
          url TEXT,
          order_index INTEGER NOT NULL,
          PRIMARY KEY (project_id, order_index),
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS project_agent_launchers (
          project_id TEXT NOT NULL,
          name TEXT NOT NULL,
          command TEXT NOT NULL,
          order_index INTEGER NOT NULL,
          PRIMARY KEY (project_id, order_index),
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
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
        );

        CREATE UNIQUE INDEX IF NOT EXISTS workspaces_project_branch_unique
        ON workspaces(project_id, branch)
        WHERE length(branch) > 0;

        CREATE TABLE IF NOT EXISTS workspace_ports (
          workspace_id TEXT NOT NULL,
          port_index INTEGER NOT NULL,
          port_number INTEGER NOT NULL,
          port_name TEXT NOT NULL CHECK (length(trim(port_name, ' \n\r\t')) > 0),
          definition_id TEXT NOT NULL DEFAULT '',
          PRIMARY KEY (workspace_id, port_index),
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspace_port_definitions (
          id TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          name TEXT NOT NULL CHECK (length(trim(name, ' \n\r\t')) > 0),
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

        CREATE TABLE IF NOT EXISTS workspace_browser_sessions (
          workspace_id TEXT NOT NULL,
          name TEXT,
          url TEXT,
          extracted_target_url TEXT,
          extracted_window_id INTEGER,
          extracted_window_valid INTEGER NOT NULL DEFAULT 0,
          order_index INTEGER NOT NULL,
          PRIMARY KEY (workspace_id, order_index),
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS workspace_agent_launchers (
          workspace_id TEXT NOT NULL,
          name TEXT NOT NULL,
          command TEXT NOT NULL,
          order_index INTEGER NOT NULL,
          PRIMARY KEY (workspace_id, order_index),
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
          terminal_container_id TEXT,
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
          terminal_container_id TEXT,
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

        CREATE TABLE IF NOT EXISTS runtime_targets (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          type TEXT NOT NULL,
          name TEXT,
          detail TEXT,
          app TEXT NOT NULL,
          window_id INTEGER,
          order_index INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS terminal_targets (
          runtime_target_id TEXT PRIMARY KEY,
          provider TEXT NOT NULL,
          tracking_id TEXT,
          native_id TEXT,
          container_id TEXT,
          iterm_tab_index INTEGER,
          tmux_window_id TEXT,
          FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS browser_targets (
          runtime_target_id TEXT PRIMARY KEY,
          target_url TEXT,
          resolved_url TEXT,
          FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS agent_sessions (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          provider TEXT NOT NULL,
          label TEXT,
          status TEXT NOT NULL DEFAULT 'idle',
          terminal_target_id TEXT,
          terminal_tracking_id TEXT,
          terminal_native_id TEXT,
          tmux_window_id TEXT,
          window_id INTEGER,
          yabai_window_id INTEGER,
          session_key TEXT,
          claimed_launcher_name TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
          FOREIGN KEY (terminal_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
        );

        CREATE TABLE IF NOT EXISTS runtime_target_events (
          id TEXT PRIMARY KEY,
          runtime_target_id TEXT NOT NULL,
          event_type TEXT NOT NULL,
          source TEXT NOT NULL,
          message TEXT,
          window_id INTEGER,
          created_at TEXT NOT NULL,
          FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS agent_session_events (
          id TEXT PRIMARY KEY,
          agent_session_id TEXT NOT NULL,
          event_type TEXT NOT NULL,
          source TEXT NOT NULL,
          message TEXT,
          terminal_target_id TEXT,
          created_at TEXT NOT NULL,
          FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE,
          FOREIGN KEY (terminal_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
        );

        CREATE TABLE IF NOT EXISTS migration_state (
          current_version INTEGER NOT NULL
        );
        """

    private static func migrateV1toV2(db: OpaquePointer) throws {
        try executeMigrationSQL(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS runtime_targets (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  name TEXT,
                  detail TEXT,
                  app TEXT NOT NULL,
                  window_id INTEGER,
                  order_index INTEGER NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS terminal_targets (
                  runtime_target_id TEXT PRIMARY KEY,
                  provider TEXT NOT NULL,
                  tracking_id TEXT,
                  native_id TEXT,
                  container_id TEXT,
                  iterm_tab_index INTEGER,
                  tmux_window_id TEXT,
                  FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS browser_targets (
                  runtime_target_id TEXT PRIMARY KEY,
                  target_url TEXT,
                  resolved_url TEXT,
                  FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS agent_sessions (
                  id TEXT PRIMARY KEY,
                  workspace_id TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  label TEXT,
                  status TEXT NOT NULL DEFAULT 'idle',
                  terminal_target_id TEXT,
                  terminal_tracking_id TEXT,
                  terminal_native_id TEXT,
                  tmux_window_id TEXT,
                  window_id INTEGER,
                  yabai_window_id INTEGER,
                  session_key TEXT,
                  claimed_launcher_name TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
                  FOREIGN KEY (terminal_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
                );

                CREATE TABLE IF NOT EXISTS runtime_target_events (
                  id TEXT PRIMARY KEY,
                  runtime_target_id TEXT NOT NULL,
                  event_type TEXT NOT NULL,
                  source TEXT NOT NULL,
                  message TEXT,
                  window_id INTEGER,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS agent_session_events (
                  id TEXT PRIMARY KEY,
                  agent_session_id TEXT NOT NULL,
                  event_type TEXT NOT NULL,
                  source TEXT NOT NULL,
                  message TEXT,
                  terminal_target_id TEXT,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE,
                  FOREIGN KEY (terminal_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
                );

                INSERT INTO runtime_targets(id, workspace_id, type, name, detail, app, window_id, order_index, created_at, updated_at)
                SELECT
                  id,
                  workspace_id,
                  CASE WHEN role = 'browser' THEN 'browser' ELSE 'terminal' END,
                  name,
                  detail,
                  app,
                  window_id,
                  COALESCE(order_index, 0),
                  COALESCE(last_seen_at, ''),
                  COALESCE(last_seen_at, '')
                FROM windows
                WHERE NOT EXISTS (SELECT 1 FROM runtime_targets WHERE runtime_targets.id = windows.id);

                INSERT INTO terminal_targets(runtime_target_id, provider, tracking_id, native_id, container_id, iterm_tab_index, tmux_window_id)
                SELECT
                  id,
                  CASE
                    WHEN app = 'Ghostty' THEN 'ghostty'
                    WHEN app = 'iTerm2' THEN 'iterm2'
                    ELSE lower(app)
                  END,
                  terminal_tracking_id,
                  terminal_native_id,
                  terminal_container_id,
                  iterm_tab_index,
                  tmux_window_id
                FROM windows
                WHERE role = 'terminal'
                  AND NOT EXISTS (SELECT 1 FROM terminal_targets WHERE terminal_targets.runtime_target_id = windows.id);

                INSERT INTO browser_targets(runtime_target_id, target_url, resolved_url)
                SELECT
                  id,
                  target_url,
                  detail
                FROM windows
                WHERE role = 'browser'
                  AND NOT EXISTS (SELECT 1 FROM browser_targets WHERE browser_targets.runtime_target_id = windows.id);

                INSERT INTO agent_sessions(
                  id, workspace_id, provider, label, status, terminal_target_id, terminal_tracking_id, terminal_native_id,
                  tmux_window_id, window_id, yabai_window_id, session_key, claimed_launcher_name, created_at, updated_at
                )
                SELECT
                  aw.id,
                  aw.workspace_id,
                  aw.provider,
                  aw.label,
                  aw.status,
                  rt.id,
                  aw.terminal_tracking_id,
                  aw.terminal_native_id,
                  aw.tmux_window_id,
                  aw.window_id,
                  aw.yabai_window_id,
                  aw.codex_thread_id,
                  NULL,
                  aw.created_at,
                  aw.updated_at
                FROM agent_windows aw
                LEFT JOIN runtime_targets rt
                  ON rt.workspace_id = aw.workspace_id
                 AND rt.type = 'terminal'
                 AND (
                      (aw.tmux_window_id IS NOT NULL AND aw.tmux_window_id != '' AND EXISTS (
                        SELECT 1 FROM terminal_targets tt
                        WHERE tt.runtime_target_id = rt.id AND tt.tmux_window_id = aw.tmux_window_id
                      ))
                   OR (aw.terminal_native_id IS NOT NULL AND aw.terminal_native_id != '' AND EXISTS (
                        SELECT 1 FROM terminal_targets tt
                        WHERE tt.runtime_target_id = rt.id AND tt.native_id = aw.terminal_native_id
                      ))
                   OR (aw.terminal_tracking_id IS NOT NULL AND aw.terminal_tracking_id != '' AND EXISTS (
                        SELECT 1 FROM terminal_targets tt
                        WHERE tt.runtime_target_id = rt.id AND tt.tracking_id = aw.terminal_tracking_id
                      ))
                   OR (aw.yabai_window_id IS NOT NULL AND rt.window_id = aw.yabai_window_id)
                   OR (aw.window_id IS NOT NULL AND rt.window_id = aw.window_id)
                 )
                WHERE NOT EXISTS (SELECT 1 FROM agent_sessions WHERE agent_sessions.id = aw.id);
                """)
    }

    private static func executeMigrationSQL(db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite migration error"
            sqlite3_free(errorMessage)
            throw WorkspaceError.databaseMigrationFailed(message: message)
        }
    }
}
