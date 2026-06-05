import Foundation
import SQLite3

public enum DatabaseSchema {
    public static let currentVersion = 4

    public static let migrationSteps: [DatabaseMigrationStep] = [
        DatabaseMigrationStep(fromVersion: 1, toVersion: 2, description: "terminal metadata tables", requiresBackup: false) { database in
            try executeBatch(sql: terminalSchemaSQL, database: database)
        },
        DatabaseMigrationStep(fromVersion: 2, toVersion: 3, description: "terminal final render state", requiresBackup: false) { database in
            try executeBatch(sql: terminalRemoteSessionStateSQL, database: database)
        },
        DatabaseMigrationStep(fromVersion: 3, toVersion: 4, description: "configured terminal session identities", requiresBackup: false) {
            database in
            try addColumnIfNeeded(table: "running_processes", column: "terminal_session_id", definition: "TEXT", database: database)
            try addColumnIfNeeded(table: "agent_sessions", column: "terminal_session_id", definition: "TEXT", database: database)
            if try tableExists("running_processes", database: database) {
                try executeBatch(sql: configuredProcessTerminalSessionIdentityBackfillSQL, database: database)
            }
            if try tableExists("agent_sessions", database: database) {
                try executeBatch(sql: configuredAgentTerminalSessionIdentityBackfillSQL, database: database)
            }
        },
    ]

    static let configuredProcessTerminalSessionIdentityBackfillSQL = """
            UPDATE running_processes
            SET terminal_session_id = (
              SELECT tracking_id
              FROM runtime_targets
              WHERE runtime_targets.id = running_processes.runtime_target_id
                AND runtime_targets.app = 'Spaces'
                AND length(runtime_targets.tracking_id) > 0
            )
            WHERE terminal_session_id IS NULL;
        """

    static let configuredAgentTerminalSessionIdentityBackfillSQL = """
            UPDATE agent_sessions
            SET terminal_session_id = (
              SELECT tracking_id
              FROM runtime_targets
              WHERE runtime_targets.id = agent_sessions.runtime_target_id
                AND runtime_targets.app = 'Spaces'
                AND length(runtime_targets.tracking_id) > 0
            )
            WHERE terminal_session_id IS NULL
              AND provider = 'spaces';
        """

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

    static let terminalSchemaSQL = """
            CREATE TABLE IF NOT EXISTS terminal_sessions (
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
              exited_at TEXT
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
        """

    public static let latestSchemaSQL = """
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
              window_id INTEGER,
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

    private static func executeBatch(sql: String, database: OpaquePointer) throws {
        if sqlite3_exec(database, sql, nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(database))
            throw NSError(domain: "spaces.database", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func addColumnIfNeeded(table: String, column: String, definition: String, database: OpaquePointer) throws {
        guard try tableExists(table, database: database), try !columnExists(table: table, column: column, database: database) else { return }
        try executeBatch(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);", database: database)
    }

    private static func tableExists(_ table: String, database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK
        else {
            let message = String(cString: sqlite3_errmsg(database))
            throw NSError(domain: "spaces.database", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func columnExists(table: String, column: String, database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(database))
            throw NSError(domain: "spaces.database", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawName = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: rawName) == column { return true }
        }
        return false
    }
}
