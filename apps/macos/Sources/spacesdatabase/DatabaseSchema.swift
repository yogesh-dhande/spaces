import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

public enum DatabaseSchema {
    public static let currentVersion = 7

    public static let migrationSteps: [DatabaseMigrationStep] = [
        DatabaseMigrationStep(fromVersion: 1, toVersion: 2, description: "Reset daemon-owned device schema", requiresBackup: true) { database in
            try executeBatch(database: database, sql: destructiveResetSQL)
        },
        DatabaseMigrationStep(fromVersion: 2, toVersion: 3, description: "Rename target_branch to base_branch", requiresBackup: false) { database in
            try executeBatch(database: database, sql: "ALTER TABLE workspaces RENAME COLUMN target_branch TO base_branch")
        },
        DatabaseMigrationStep(fromVersion: 3, toVersion: 4, description: "Remove daemon project collapse state", requiresBackup: true) { database in
            try executeBatch(
                database: database,
                sql: """
                    CREATE TABLE projects_v4 (
                      id TEXT PRIMARY KEY,
                      name TEXT NOT NULL,
                      dir TEXT NOT NULL UNIQUE,
                      is_git INTEGER NOT NULL,
                      default_branch TEXT,
                      setup_script TEXT,
                      stop_script TEXT
                    );
                    INSERT INTO projects_v4(id, name, dir, is_git, default_branch, setup_script, stop_script)
                    SELECT id, name, dir, is_git, default_branch, setup_script, stop_script FROM projects;
                    DROP TABLE projects;
                    ALTER TABLE projects_v4 RENAME TO projects;
                    DELETE FROM settings
                    WHERE key IN (
                      'app_editor',
                      'gui_hotkey',
                      'gui_command_palette_hotkey',
                      'gui_leader_hotkey',
                      'gui_alerts_shortcut',
                      'gui_add_project_shortcut',
                      'gui_add_workspace_shortcut',
                      'gui_reload_shortcut',
                      'gui_open_editor_shortcut',
                      'gui_open_terminal_shortcut',
                      'gui_open_finder_shortcut',
                      'gui_open_settings_shortcut',
                      'gui_next_shortcut',
                      'gui_previous_shortcut',
                      'gui_window_shortcut',
                      'active_workspace_id',
                      'window_focus_pulse_color',
                      'window_focus_pulse_enabled'
                    );
                    """)
        },
        DatabaseMigrationStep(fromVersion: 4, toVersion: 5, description: "Drop workspace title column", requiresBackup: true) { database in
            try executeBatch(database: database, sql: "ALTER TABLE workspaces DROP COLUMN title")
        },
        // Desktop window IDs moved to the client database (client-owned, desktop-local). The
        // daemon never has a desktop session, so this column was only ever written by the GUI.
        DatabaseMigrationStep(fromVersion: 5, toVersion: 6, description: "Drop daemon-owned desktop window IDs", requiresBackup: true) { database in
            try executeBatch(database: database, sql: "ALTER TABLE runtime_targets DROP COLUMN window_id;")
        },
        // Browser session windows moved to the client database (client-owned, desktop-local).
        // The daemon never has a desktop session, so these extracted-window columns were only
        // ever written by the GUI's former in-process orchestrator.
        DatabaseMigrationStep(fromVersion: 6, toVersion: 7, description: "Drop daemon-owned browser extracted window IDs", requiresBackup: true) {
            database in
            try executeBatch(
                database: database,
                sql: """
                    ALTER TABLE workspace_browser_sessions DROP COLUMN extracted_window_valid;
                    ALTER TABLE workspace_browser_sessions DROP COLUMN extracted_window_id;
                    ALTER TABLE workspace_browser_sessions DROP COLUMN extracted_target_url;
                    """)
        },
    ]

    static let terminalRemoteSessionStateSQL = """
            CREATE TABLE IF NOT EXISTS terminal_remote_session_states (
              session_id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL UNIQUE,
              reason TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              emitted_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
        """

    static let terminalAgentSignalEventsSQL = """
            CREATE TABLE IF NOT EXISTS terminal_agent_signal_events (
              id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL,
              session_id TEXT NOT NULL,
              event_type TEXT NOT NULL,
              workspace_id TEXT,
              workspace_path TEXT,
              provider TEXT NOT NULL,
              label TEXT,
              terminal_tracking_id TEXT,
              terminal_native_id TEXT,
              codex_thread_id TEXT,
              environment_keys_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              acknowledged_at TEXT
            );

            CREATE INDEX IF NOT EXISTS terminal_agent_signal_events_pending_idx
            ON terminal_agent_signal_events(session_id, acknowledged_at, created_at);
        """

    static let terminalSchemaSQL = """
            CREATE TABLE IF NOT EXISTS terminal_sessions (
              session_id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL UNIQUE,
              backend TEXT NOT NULL,
              lifetime_policy TEXT NOT NULL,
              workspace_id TEXT,
              kind TEXT NOT NULL DEFAULT 'shell',
              title TEXT NOT NULL,
              working_directory TEXT NOT NULL,
              shell TEXT NOT NULL,
              command TEXT,
              created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS terminal_runtime_states (
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

            CREATE TABLE IF NOT EXISTS terminal_clients (
              root_directory TEXT NOT NULL,
              session_id TEXT NOT NULL,
              client_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              identity_label TEXT NOT NULL,
              identity_host_name TEXT,
              identity_device_name TEXT,
              identity_network_address TEXT,
              connected_at TEXT NOT NULL,
              lease_refreshed_at TEXT NOT NULL,
              disconnected_at TEXT,
              PRIMARY KEY (root_directory, client_id)
            );

            CREATE INDEX IF NOT EXISTS terminal_clients_session_idx
            ON terminal_clients(session_id);

            CREATE TABLE IF NOT EXISTS terminal_attachments (
              id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL,
              session_id TEXT NOT NULL,
              client_id TEXT NOT NULL,
              mode TEXT NOT NULL,
              attached_at TEXT NOT NULL,
              detached_at TEXT
            );

            CREATE INDEX IF NOT EXISTS terminal_attachments_session_idx
            ON terminal_attachments(session_id);

            CREATE INDEX IF NOT EXISTS terminal_attachments_root_idx
            ON terminal_attachments(root_directory);

            CREATE UNIQUE INDEX IF NOT EXISTS terminal_attachments_active_owner_unique
            ON terminal_attachments(root_directory)
            WHERE detached_at IS NULL AND mode = 'owner';

            CREATE UNIQUE INDEX IF NOT EXISTS terminal_attachments_active_client_unique
            ON terminal_attachments(root_directory, client_id)
            WHERE detached_at IS NULL;

            CREATE TABLE IF NOT EXISTS terminal_window_frames (
              root_directory TEXT NOT NULL,
              session_id TEXT NOT NULL,
              mode TEXT NOT NULL,
              x REAL NOT NULL,
              y REAL NOT NULL,
              width REAL NOT NULL,
              height REAL NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (root_directory, mode)
            );

            \(terminalRemoteSessionStateSQL)
            \(terminalAgentSignalEventsSQL)
        """

    public static let latestSchemaSQL = """
            CREATE TABLE IF NOT EXISTS projects (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              dir TEXT NOT NULL UNIQUE,
              is_git INTEGER NOT NULL,
              default_branch TEXT,
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
              id TEXT NOT NULL,
              name TEXT NOT NULL,
              command TEXT NOT NULL,
              order_index INTEGER NOT NULL,
              PRIMARY KEY (project_id, order_index),
              FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS workspaces (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              dir TEXT NOT NULL,
              runtime_path TEXT NOT NULL,
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

            CREATE UNIQUE INDEX IF NOT EXISTS workspaces_project_branch_active_unique
            ON workspaces(project_id, branch)
            WHERE length(branch) > 0 AND is_archived = 0;

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
              setup_exit_code INTEGER,
              setup_log_path TEXT,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS workspace_processes (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              name TEXT,
              command TEXT NOT NULL,
              on_exit TEXT NOT NULL DEFAULT 'none',
              order_index INTEGER NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS workspace_browser_sessions (
              workspace_id TEXT NOT NULL,
              name TEXT,
              url TEXT,
              order_index INTEGER NOT NULL,
              PRIMARY KEY (workspace_id, order_index),
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS workspace_agent_launchers (
              workspace_id TEXT NOT NULL,
              id TEXT NOT NULL,
              name TEXT NOT NULL,
              command TEXT NOT NULL,
              order_index INTEGER NOT NULL,
              PRIMARY KEY (workspace_id, order_index),
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS running_processes (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              template_id TEXT,
              template_name TEXT NOT NULL,
              command TEXT NOT NULL,
              runtime_target_id TEXT,
              terminal_session_id TEXT,
              pid INTEGER,
              status TEXT NOT NULL,
              log_path TEXT,
              last_output_at TEXT,
              started_at TEXT,
              exited_at TEXT,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
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

            CREATE TABLE IF NOT EXISTS runtime_targets (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              type TEXT NOT NULL,
              name TEXT,
              detail TEXT,
              app TEXT NOT NULL,
              tracking_id TEXT,
              order_index INTEGER NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
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
              runtime_target_id TEXT,
              terminal_session_id TEXT,
              session_key TEXT,
              claimed_launcher_id TEXT,
              claimed_launcher_name TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
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
              runtime_target_id TEXT,
              created_at TEXT NOT NULL,
              FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE,
              FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
            );

            \(terminalSchemaSQL)

            CREATE TABLE IF NOT EXISTS migration_state (
              current_version INTEGER NOT NULL
            );
        """

    static let destructiveResetSQL = """
            PRAGMA foreign_keys = OFF;

            DROP TABLE IF EXISTS terminal_agent_signal_events;
            DROP TABLE IF EXISTS terminal_remote_session_states;
            DROP TABLE IF EXISTS terminal_window_frames;
            DROP TABLE IF EXISTS terminal_attachments;
            DROP TABLE IF EXISTS terminal_clients;
            DROP TABLE IF EXISTS terminal_runtime_states;
            DROP TABLE IF EXISTS terminal_sessions;
            DROP TABLE IF EXISTS agent_session_events;
            DROP TABLE IF EXISTS runtime_target_events;
            DROP TABLE IF EXISTS agent_sessions;
            DROP TABLE IF EXISTS browser_targets;
            DROP TABLE IF EXISTS runtime_targets;
            DROP TABLE IF EXISTS ignored_worktrees;
            DROP TABLE IF EXISTS settings;
            DROP TABLE IF EXISTS running_processes;
            DROP TABLE IF EXISTS workspace_agent_launchers;
            DROP TABLE IF EXISTS workspace_browser_sessions;
            DROP TABLE IF EXISTS workspace_processes;
            DROP TABLE IF EXISTS workspace_settings;
            DROP TABLE IF EXISTS workspace_port_definitions;
            DROP TABLE IF EXISTS workspace_ports;
            DROP TABLE IF EXISTS workspaces;
            DROP TABLE IF EXISTS project_agent_launchers;
            DROP TABLE IF EXISTS project_browser_sessions;
            DROP TABLE IF EXISTS project_processes;
            DROP TABLE IF EXISTS project_port_definitions;
            DROP TABLE IF EXISTS projects;
            DROP TABLE IF EXISTS compute_hosts;
            DROP TABLE IF EXISTS migration_state;

            PRAGMA foreign_keys = ON;

            \(latestSchemaSQL)
        """

    private static func executeBatch(database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw SpacesDatabaseError.migrationFailed(message: message)
        }
    }
}
