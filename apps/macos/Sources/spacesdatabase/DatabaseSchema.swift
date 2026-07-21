import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

public enum DatabaseSchema {
    public static let currentVersion = 8

    /// Adds the coding-agent orchestration surface: an explicit `note` on each agent session and the
    /// `agent_subscriptions` graph. The subscriber key is a terminal session id (a subscriber may be a
    /// plain terminal with no agent row), and the target is the agent session id. The foreign key is
    /// `ON DELETE RESTRICT`: an agent row's inbound subscriptions are NOT cascaded away on delete but
    /// dropped explicitly by the single termination chokepoint (`WorkspaceOrchestrator.finalizeAgentRow`)
    /// after it has notified those subscribers the child exited. RESTRICT then makes any delete that
    /// bypasses the chokepoint fail loudly instead of silently stranding a watcher's notice. Named
    /// separately so both the fresh-schema SQL and the v6→v7 rebuild step share one definition and can
    /// never drift apart.
    static let agentSubscriptionsSQL = """
            CREATE TABLE IF NOT EXISTS agent_subscriptions (
              subscriber_terminal_session_id TEXT NOT NULL,
              agent_session_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (subscriber_terminal_session_id, agent_session_id),
              FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE RESTRICT
            );
        """

    /// Queue of coalesced notification lines held for a busy subscriber until it goes idle: one row per
    /// (subscriber terminal, watched agent). Deliberately has NO foreign key to `agent_sessions` — an
    /// exit notification must outlive the agent row (`handleAgentExit` deletes ad-hoc rows before the
    /// subscriber ever reads it), and the `message` is fully rendered at enqueue time, so the row needs
    /// nothing from the agent table after insert. The unique index makes `INSERT OR REPLACE` coalesce
    /// repeated transitions of the same child down to a single latest-state line. `transition` records
    /// the transition word the rendered message carries (`blocked`/`done`/`exited`) so a child that
    /// resumes working can have exactly its held `blocked` line withdrawn structurally, never by
    /// matching message text. This is the latest shape, shared by the fresh schema and the v4→v5 step's
    /// ALTER target; the v2→v3 step keeps its own frozen historical snapshot.
    static let agentPendingNotificationsSQL = """
            CREATE TABLE IF NOT EXISTS agent_pending_notifications (
              id TEXT PRIMARY KEY,
              subscriber_terminal_session_id TEXT NOT NULL,
              agent_session_id TEXT NOT NULL,
              message TEXT NOT NULL,
              created_at TEXT NOT NULL,
              transition TEXT NOT NULL DEFAULT ''
            );

            CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_pending_per_target
              ON agent_pending_notifications(subscriber_terminal_session_id, agent_session_id);
        """

    /// Cross-device watch edges: a local subscriber terminal watches a coding-agent session that lives on
    /// a paired device (`device_id`). `agent_session_id` holds the watched child's terminal session id on
    /// that device (the stable cross-device handle, not a local row id). Deliberately has NO foreign key —
    /// the watched agent lives on another device's database, so there is nothing local to reference. The
    /// watch service on this device drives the lifecycle: when the watched agent exits (its row leaves the
    /// remote listing) the notification line is delivered and the edge is dropped. Keyed on (subscriber,
    /// device, agent) so a terminal watches the same remote agent through exactly one edge. Named
    /// separately so this step and the fresh-schema SQL share one definition and can never drift apart.
    static let agentRemoteSubscriptionsSQL = """
            CREATE TABLE IF NOT EXISTS agent_remote_subscriptions (
              subscriber_terminal_session_id TEXT NOT NULL,
              device_id TEXT NOT NULL,
              agent_session_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (subscriber_terminal_session_id, device_id, agent_session_id)
            );
        """

    /// The remote agent watch's per-device baseline: the last-seen `listAgentSessions` row of each
    /// watched child, keyed by device and by the child's terminal session id on that device. The watch
    /// service diffs fresh listings against this baseline to recover blocked/done/exited transitions;
    /// persisting it lets a restarted daemon deliver transitions that happened while it was down
    /// (including an exit, whose row is simply absent from the first post-restart listing). `row_json`
    /// is the encoded wire row — the baseline needs the full row to render an exited line after the
    /// agent is gone, and a row that fails to decode simply re-seeds silently. Deliberately has NO
    /// foreign key: rows mirror `agent_remote_subscriptions` edges, whose lifecycle the watch service
    /// drives. Named separately so this step and the fresh-schema SQL share one definition and can
    /// never drift apart.
    static let agentRemoteWatchBaselinesSQL = """
            CREATE TABLE IF NOT EXISTS agent_remote_watch_baselines (
              device_id TEXT NOT NULL,
              agent_session_id TEXT NOT NULL,
              row_json TEXT NOT NULL,
              PRIMARY KEY (device_id, agent_session_id)
            );
        """

    /// Daemon-owned scheduled automations that run a shell script or spawn a coding agent in a
    /// workspace-less terminal session. `trigger_kind` is `manual` or `cron`; `cron_expression` holds the
    /// 5-field cron string and is NULL for manual automations. `kind` is `script` or `agent`: a `script`
    /// automation runs `script` verbatim in `working_directory`; an `agent` automation instead runs
    /// `agent_command` (the shell command that launches the coding agent) seeded with `agent_prompt` in
    /// `workspace_id`'s workspace — its location comes from the workspace, so it carries no
    /// `working_directory` of its own. `script`, `working_directory`, `agent_command`, `agent_prompt`, and
    /// `workspace_id` are mutually exclusive by convention (only the fields matching `kind` are populated —
    /// `working_directory` is `''` for an `agent`-kind row, kept NOT NULL rather than nullable so every
    /// reader can treat it as a plain string; see `AutomationDraft.validated()`), not by a CHECK constraint,
    /// so a kind switch is a plain column update rather than a row rebuild. `next_fire_time` is the
    /// persisted next-due epoch for a cron automation and doubles as the missed-run anchor a restarted
    /// daemon reads to decide whether a fire was missed while it was down. Timestamps are stored as REAL
    /// epoch seconds. Named separately so the fresh-schema SQL and the v7→v8 migration step share one
    /// definition and can never drift apart.
    static let automationsSQL = """
            CREATE TABLE IF NOT EXISTS automations (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              enabled INTEGER NOT NULL DEFAULT 1,
              trigger_kind TEXT NOT NULL,
              cron_expression TEXT,
              kind TEXT NOT NULL DEFAULT 'script',
              script TEXT NOT NULL,
              agent_command TEXT,
              agent_prompt TEXT,
              workspace_id TEXT,
              working_directory TEXT NOT NULL,
              timeout_seconds INTEGER,
              concurrency_policy TEXT NOT NULL,
              missed_run_policy TEXT NOT NULL,
              next_fire_time REAL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
        """

    /// One row per automation execution attempt. The foreign key mirrors the `agent_session_events →
    /// agent_sessions` precedent (`ON DELETE CASCADE`): a run history row is a child of its automation and
    /// is removed with it, an app-managed cascade. `skip_reason` records why a `skipped` run never ran
    /// (`concurrency` when a policy blocked an overlapping run, `missed` when a catch-up decision skipped
    /// it); `trigger_kind` records how the run was initiated (`manual`, `cron`, or `missed_catch_up`).
    /// `terminal_session_id` links to the workspace-less session that carried the command. `kind` is the
    /// automation's `script`/`agent` kind stamped onto the run at creation time: an automation's kind can be
    /// edited once its runs are terminal, but a retained historical run keeps the session shape it actually
    /// ran with, so opening its history dispatches on the run's own kind rather than the automation's current
    /// one. `prompt_delivered_at` is set (epoch seconds) once an `agent`-kind run's seed prompt has been written
    /// to its session; it makes prompt delivery survive a daemon restart deterministically — the two
    /// agent-run phases (detecting/sending while NULL, awaiting done/end once set) derive from it so no
    /// in-memory state is lost on restart. Named separately so the fresh-schema SQL and the v7→v8 migration
    /// step share one definition.
    static let automationRunsSQL = """
            CREATE TABLE IF NOT EXISTS automation_runs (
              id TEXT PRIMARY KEY,
              automation_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              status TEXT NOT NULL,
              skip_reason TEXT,
              trigger_kind TEXT NOT NULL,
              exit_code INTEGER,
              terminal_session_id TEXT,
              started_at REAL,
              ended_at REAL,
              created_at REAL NOT NULL,
              prompt_delivered_at REAL,
              FOREIGN KEY (automation_id) REFERENCES automations(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS automation_runs_automation_created_idx
              ON automation_runs(automation_id, created_at);
        """

    public static let migrationSteps: [DatabaseMigrationStep] = [
        DatabaseMigrationStep(fromVersion: 1, toVersion: 2, description: "Add agent_sessions.note and agent_subscriptions", requiresBackup: true) {
            handle in
            // Frozen v2 snapshot of agent_subscriptions with its original `ON DELETE CASCADE`. The latest
            // shape (shared `agentSubscriptionsSQL`) switched this foreign key to `ON DELETE RESTRICT` at
            // v7; creating the latest shape here would let a v1-origin database skip the v6→v7 rebuild that
            // every v2-through-v6-origin database applies, so this step recreates the shape v2 defined.
            try migrationExecuteBatch(
                handle,
                sql: """
                    ALTER TABLE agent_sessions ADD COLUMN note TEXT;
                    CREATE TABLE IF NOT EXISTS agent_subscriptions (
                      subscriber_terminal_session_id TEXT NOT NULL,
                      agent_session_id TEXT NOT NULL,
                      created_at TEXT NOT NULL,
                      PRIMARY KEY (subscriber_terminal_session_id, agent_session_id),
                      FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE
                    );
                    """)
        },
        // Frozen snapshot of the table as v3 defined it (no `transition` column). A migration step
        // creates the shape of its target version, never the latest one — sharing the latest SQL here
        // would make the later v4→v5 ALTER fail with a duplicate column on databases upgrading from v2.
        DatabaseMigrationStep(fromVersion: 2, toVersion: 3, description: "Add agent_pending_notifications", requiresBackup: true) { handle in
            try migrationExecuteBatch(
                handle,
                sql: """
                    CREATE TABLE IF NOT EXISTS agent_pending_notifications (
                      id TEXT PRIMARY KEY,
                      subscriber_terminal_session_id TEXT NOT NULL,
                      agent_session_id TEXT NOT NULL,
                      message TEXT NOT NULL,
                      created_at TEXT NOT NULL
                    );

                    CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_pending_per_target
                      ON agent_pending_notifications(subscriber_terminal_session_id, agent_session_id);
                    """)
        },
        DatabaseMigrationStep(fromVersion: 3, toVersion: 4, description: "Add agent_remote_subscriptions", requiresBackup: true) { handle in
            try migrationExecuteBatch(handle, sql: agentRemoteSubscriptionsSQL)
        },
        // Pre-v5 held rows carry the empty-string default: they are never matched by the
        // blocked-targeted withdrawal and simply flush as before, so no data is lost or reinterpreted.
        DatabaseMigrationStep(fromVersion: 4, toVersion: 5, description: "Add agent_pending_notifications.transition", requiresBackup: true) {
            handle in
            try migrationExecuteBatch(handle, sql: "ALTER TABLE agent_pending_notifications ADD COLUMN transition TEXT NOT NULL DEFAULT '';")
        },
        DatabaseMigrationStep(fromVersion: 5, toVersion: 6, description: "Add agent_remote_watch_baselines", requiresBackup: true) { handle in
            try migrationExecuteBatch(handle, sql: agentRemoteWatchBaselinesSQL)
        },
        // Rebuild agent_subscriptions with `ON DELETE RESTRICT` (was CASCADE) so a delete that bypasses the
        // termination chokepoint fails loudly instead of silently stranding a watcher's exit notice.
        // SQLite cannot alter a foreign key in place, so the table is recreated and every row copied. The
        // copy runs with foreign_keys ON inside the migration transaction, which is safe here: each copied
        // row already referenced a live agent_sessions row, and no table references agent_subscriptions, so
        // the drop/rename touches nothing else.
        DatabaseMigrationStep(fromVersion: 6, toVersion: 7, description: "Rebuild agent_subscriptions FK as ON DELETE RESTRICT", requiresBackup: true)
        { handle in
            try migrationExecuteBatch(
                handle,
                sql: """
                    CREATE TABLE agent_subscriptions_new (
                      subscriber_terminal_session_id TEXT NOT NULL,
                      agent_session_id TEXT NOT NULL,
                      created_at TEXT NOT NULL,
                      PRIMARY KEY (subscriber_terminal_session_id, agent_session_id),
                      FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE RESTRICT
                    );
                    INSERT INTO agent_subscriptions_new (subscriber_terminal_session_id, agent_session_id, created_at)
                      SELECT subscriber_terminal_session_id, agent_session_id, created_at FROM agent_subscriptions;
                    DROP TABLE agent_subscriptions;
                    ALTER TABLE agent_subscriptions_new RENAME TO agent_subscriptions;
                    """)
        },
        // Adds the scheduled-automation surface (`automations`, `automation_runs`) and makes terminal
        // sessions workspace-optional so an automation's command can run in a workspace-less session,
        // attributed back to its run via `automation_run_id`. SQLite cannot drop a column's NOT NULL or
        // add a column mid-table in place, so `terminal_sessions` is rebuilt: create the new shape, copy
        // every row (workspace_id carried forward unchanged; automation_run_id defaults NULL), drop the
        // old table, and rename. No table declares a foreign key onto `terminal_sessions`, so the
        // drop/rename touches nothing else even with foreign_keys ON inside the migration transaction. The
        // new-table column shape here must match `terminalSessionsTableSQL`, which the fresh schema uses.
        DatabaseMigrationStep(fromVersion: 7, toVersion: 8, description: "Add automations tables and make terminal_sessions workspace-optional", requiresBackup: true)
        { handle in
            try migrationExecuteBatch(
                handle,
                sql: """
                    \(automationsSQL)
                    \(automationRunsSQL)
                    CREATE TABLE terminal_sessions_new (
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
                      created_at TEXT NOT NULL,
                      automation_run_id TEXT
                    );
                    INSERT INTO terminal_sessions_new (
                      session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, user_title,
                      working_directory, shell, command, created_at
                    )
                      SELECT session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, user_title,
                             working_directory, shell, command, created_at
                      FROM terminal_sessions;
                    DROP TABLE terminal_sessions;
                    ALTER TABLE terminal_sessions_new RENAME TO terminal_sessions;
                    """)
        },
    ]

    static let terminalRemoteSessionStateSQL = """
            CREATE TABLE IF NOT EXISTS terminal_remote_session_states (
              session_id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL UNIQUE,
              payload_json TEXT NOT NULL
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
              environment_keys_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              acknowledged_at TEXT
            );

            CREATE INDEX IF NOT EXISTS terminal_agent_signal_events_pending_idx
            ON terminal_agent_signal_events(session_id, acknowledged_at, created_at);
        """

    /// The `terminal_sessions` table. `workspace_id` is nullable: a workspace-scoped session carries its
    /// owning workspace, while an automation's command runs in a workspace-less session (NULL). That
    /// session is attributed back to the automation execution that spawned it via `automation_run_id`.
    /// The unique `root_directory` constraint keeps one live session per session directory. Named
    /// separately so the fresh-schema SQL and the v7→v8 rebuild step share one column shape.
    static let terminalSessionsTableSQL = """
            CREATE TABLE IF NOT EXISTS terminal_sessions (
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
              created_at TEXT NOT NULL,
              automation_run_id TEXT
            );
        """

    static let terminalSchemaSQL = """
            \(terminalSessionsTableSQL)

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

            CREATE TABLE IF NOT EXISTS project_services (
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

            CREATE TABLE IF NOT EXISTS workspace_service_ports (
              workspace_id TEXT NOT NULL,
              service_index INTEGER NOT NULL,
              port INTEGER NOT NULL,
              service_name TEXT NOT NULL CHECK (length(trim(service_name, ' \n\r\t')) > 0),
              service_id TEXT NOT NULL DEFAULT '',
              PRIMARY KEY (workspace_id, service_index),
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS workspace_services (
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
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS browser_targets (
              runtime_target_id TEXT PRIMARY KEY,
              target_url TEXT,
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
              note TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
            );

            \(agentSubscriptionsSQL)

            \(agentPendingNotificationsSQL)

            \(agentRemoteSubscriptionsSQL)

            \(agentRemoteWatchBaselinesSQL)

            CREATE TABLE IF NOT EXISTS agent_session_events (
              id TEXT PRIMARY KEY,
              agent_session_id TEXT NOT NULL,
              event_type TEXT NOT NULL,
              source TEXT NOT NULL,
              message TEXT,
              created_at TEXT NOT NULL,
              FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE
            );

            \(terminalSchemaSQL)

            \(automationsSQL)

            \(automationRunsSQL)

            CREATE TABLE IF NOT EXISTS migration_state (
              current_version INTEGER NOT NULL
            );
        """
}
