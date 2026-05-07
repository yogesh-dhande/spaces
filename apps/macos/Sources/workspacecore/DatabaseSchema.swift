import Foundation
import SQLite3

enum DatabaseSchema {
    static let currentVersion = 1

    static let migrationSteps: [DatabaseMigrationStep] = []

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

        CREATE TABLE IF NOT EXISTS migration_state (
          current_version INTEGER NOT NULL
        );
        """
}
