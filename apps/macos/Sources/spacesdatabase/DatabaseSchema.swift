import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

public enum DatabaseSchema {
    public static let currentVersion = 13

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
        // Stores the "does this row carry a replayable final frame" answer the device overview asks for
        // every ended session, several times a second, instead of JSON-decoding the whole ~36 KB payload
        // per row per build.
        //
        // The frozen pre-v8 shape is created first because a database that predates the terminal tables
        // carries none of them (they were only ever created by the fresh-schema SQL), and the ALTER needs
        // a table to alter; on a database that already has the table the CREATE is a no-op.
        //
        // Existing rows are backfilled so an ended pane that could replay before the upgrade still
        // replays after it. A stored payload's render update is always a materialized full frame — the
        // state reducer either materializes one or clears the field — so the presence of `renderUpdate`
        // is exactly the fact a decode computed. The match is on the raw JSON text rather than a JSON
        // function because it needs no JSON1 build option, and it cannot false-positive: a quote inside
        // a JSON string value is backslash-escaped, so the unescaped byte sequence `"renderUpdate":"`
        // can only ever be the key itself.
        DatabaseMigrationStep(fromVersion: 7, toVersion: 8, description: "Add terminal_remote_session_states.has_final_render", requiresBackup: true)
        { handle in
            try migrationExecuteBatch(
                handle,
                sql: """
                    CREATE TABLE IF NOT EXISTS terminal_remote_session_states (
                      session_id TEXT PRIMARY KEY,
                      root_directory TEXT NOT NULL UNIQUE,
                      payload_json TEXT NOT NULL
                    );
                    ALTER TABLE terminal_remote_session_states ADD COLUMN has_final_render INTEGER NOT NULL DEFAULT 0;
                    UPDATE terminal_remote_session_states SET has_final_render = 1 WHERE payload_json LIKE '%"renderUpdate":"%';
                    """)
        },
        // Records when a session's program last rang the terminal bell, which is what the clients derive
        // a bell alert from. Existing rows carry NULL: nothing observed a bell before this version, and a
        // synthesized timestamp would raise an alert for a session that never rang.
        //
        // The frozen pre-v9 shape is created first for the same reason the v7→v8 step creates its table:
        // a database that predates the terminal tables carries none of them (they were only ever created
        // by the fresh-schema SQL), and the ALTER needs a table to alter; on a database that already has
        // the table the CREATE is a no-op.
        DatabaseMigrationStep(fromVersion: 8, toVersion: 9, description: "Add terminal_runtime_states.bell_at", requiresBackup: true) { handle in
            try migrationExecuteBatch(
                handle,
                sql: """
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
                    ALTER TABLE terminal_runtime_states ADD COLUMN bell_at TEXT;
                    """)
        },
        // Records the coding agent kind (claude/codex/opencode) detected for an agent session, so the
        // identity survives the agent process ending: the live foreground state it is detected from is
        // cleared by the exit, and the exit notification the child's subscribers receive names the kind.
        // Existing rows carry NULL, which renders honestly as "coding agent" until a detection lands —
        // the same reading a row whose foreground was never classified has always had.
        //
        // The frozen pre-v10 shape is created first for the same reason the v7→v8 and v8→v9 steps create
        // theirs, and it is load-bearing rather than defensive: NO migration step has ever created
        // `agent_sessions`. The table is defined only in the fresh-schema SQL, and the v1→v2 step already
        // assumes it, so an upgrade chain that reaches here without it has no table to alter and the whole
        // migration fails. Creating it — rather than making the ALTER conditional — is what guarantees a
        // v10 database always HAS `agent_sessions`; skipping the ALTER on a missing table would leave the
        // profile at v10 with no agent table at all, which is worse than failing. The shape frozen here is
        // the one v2 through v9 held (`note` present, `detected_agent_kind` absent), so the ALTER below
        // lands the same v10 shape whichever way the table arrived; on a database that already has it —
        // every profile created from the fresh schema, and every v1-origin profile carried up the chain —
        // the CREATE is a no-op and every existing row is preserved.
        DatabaseMigrationStep(fromVersion: 9, toVersion: 10, description: "Add agent_sessions.detected_agent_kind", requiresBackup: true) { handle in
            try migrationExecuteBatch(
                handle,
                sql: """
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
                    ALTER TABLE agent_sessions ADD COLUMN detected_agent_kind TEXT;
                    """)
        },
        // Archiving a workspace deletes its record, so the archived flag and the rows it marked have no
        // reader left. The archived rows go first: `workspaces` children cascade (the connection runs with
        // `foreign_keys=ON`), but two agent tables are not reached by that cascade and are cleared first.
        // `agent_subscriptions.agent_session_id` is `ON DELETE RESTRICT`, so an archived workspace still
        // holding a watched agent row would otherwise abort the whole upgrade, and `agent_pending_
        // notifications` deliberately has no foreign key and would be orphaned. A watcher of an archived
        // workspace's agent loses that edge without an exit notice, which is the one thing this bulk purge
        // cannot deliver — the rows being removed are invisible to the product and their agents stopped when
        // the workspace was archived. The branch-uniqueness index is rebuilt without the archived predicate
        // and renamed to match, which also has to happen before the column can be dropped: SQLite refuses to
        // drop a column an index reads. `ignored_worktrees` goes with them: deleting a workspace removes its
        // worktree, so a worktree still standing at a former workspace's path is live work for discovery to
        // import, and nothing writes that table any more. Each table this step did not create itself is
        // touched only when it is present, so a database that never had one is upgraded rather than failed on
        // work it does not need.
        DatabaseMigrationStep(fromVersion: 10, toVersion: 11, description: "Delete archived workspaces and drop is_archived", requiresBackup: true) {
            handle in
            guard try migrationTableExists(handle, table: "workspaces") else { return }
            if try migrationTableExists(handle, table: "agent_sessions") {
                for table in ["agent_subscriptions", "agent_pending_notifications"] where try migrationTableExists(handle, table: table) {
                    try migrationExecuteBatch(
                        handle,
                        sql: """
                            DELETE FROM \(table) WHERE agent_session_id IN (
                              SELECT id FROM agent_sessions WHERE workspace_id IN (SELECT id FROM workspaces WHERE is_archived = 1));
                            """)
                }
            }
            try migrationExecuteBatch(
                handle,
                sql: """
                    DELETE FROM workspaces WHERE is_archived = 1;
                    DROP TABLE IF EXISTS ignored_worktrees;
                    DROP INDEX IF EXISTS workspaces_project_branch_active_unique;
                    ALTER TABLE workspaces DROP COLUMN is_archived;
                    CREATE UNIQUE INDEX IF NOT EXISTS workspaces_project_branch_unique
                      ON workspaces(project_id, branch)
                      WHERE length(branch) > 0;
                    """)
        },
        // Holds the name a user typed for a coding-agent row. It is its own column, separate from `label`,
        // for the same reason `terminal_sessions.user_title` is separate from a terminal's live title: the
        // hook and foreground-detection writers rewrite `label` from what the agent reports, so a rename
        // stored there would be overwritten by the next signal. Existing rows carry NULL — nothing was
        // renamed before this version — and read their name from `label` as they always have.
        //
        // The frozen pre-step shape is created first, exactly like the v9→v10 step and for the same
        // load-bearing reason: no migration step before v10 ever created `agent_sessions`, so a chain can
        // reach this ALTER with no table to alter (the v10→v11 step tolerates the absence rather than
        // filling it). The shape frozen here is the v11 one (the v10 CREATE plus `detected_agent_kind`),
        // so both arrival routes land the same v12 schema; on a database that already carries the table
        // the CREATE is a no-op and every row is preserved.
        DatabaseMigrationStep(fromVersion: 11, toVersion: 12, description: "Add agent_sessions.user_label", requiresBackup: true) { handle in
            try migrationExecuteBatch(
                handle,
                sql: """
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
                      detected_agent_kind TEXT,
                      FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
                      FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
                    );
                    ALTER TABLE agent_sessions ADD COLUMN user_label TEXT;
                    """)
        },
        // Configured coding agents (per-project and per-workspace `{id, name, command}` launcher entries)
        // are gone: an agent exists only as a live session started by running its command in a terminal,
        // and every agent row is renamed through `agent_sessions.user_label`. The two launcher tables and
        // the two claim columns that bound a live row to a launcher entry therefore have no reader left.
        //
        // The DROPs are `IF EXISTS` because only the baseline fresh schema ever created these tables — no
        // migration step did — so a profile whose chain started before they existed can reach this step
        // without them.
        //
        // The frozen v12-shape `agent_sessions` CREATE comes first for the same load-bearing reason as the
        // v11→v12 step: no step before v10 created the table, so a chain can reach these ALTERs with no
        // table to alter. The shape frozen here is exactly v12 (the v11 CREATE plus `user_label`), so both
        // arrival routes land the same v13 schema; on a database that already carries the table the CREATE
        // is a no-op and every row is preserved.
        DatabaseMigrationStep(fromVersion: 12, toVersion: 13, description: "Drop agent launchers", requiresBackup: true) { handle in
            try migrationExecuteBatch(
                handle,
                sql: """
                    DROP TABLE IF EXISTS project_agent_launchers;
                    DROP TABLE IF EXISTS workspace_agent_launchers;
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
                      detected_agent_kind TEXT,
                      user_label TEXT,
                      FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
                      FOREIGN KEY (runtime_target_id) REFERENCES runtime_targets(id) ON DELETE SET NULL
                    );
                    ALTER TABLE agent_sessions DROP COLUMN claimed_launcher_id;
                    ALTER TABLE agent_sessions DROP COLUMN claimed_launcher_name;
                    """)
        },
    ]

    /// The persisted final-render state of a session, one row per session. `has_final_render` stores
    /// whether `payload_json` carries a replayable final frame, because that single fact is read for
    /// every ended session on every device-overview build while the payload itself is a ~36 KB
    /// base64 grid snapshot; deriving it meant decoding the whole payload per row per build.
    static let terminalRemoteSessionStateSQL = """
            CREATE TABLE IF NOT EXISTS terminal_remote_session_states (
              session_id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL UNIQUE,
              payload_json TEXT NOT NULL,
              has_final_render INTEGER NOT NULL DEFAULT 0
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

    static let terminalSchemaSQL = """
            CREATE TABLE IF NOT EXISTS terminal_sessions (
              session_id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL UNIQUE,
              backend TEXT NOT NULL,
              lifetime_policy TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              kind TEXT NOT NULL DEFAULT 'shell',
              title TEXT NOT NULL,
              user_title TEXT,
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
              foreground_display_command TEXT,
              bell_at TEXT
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

            CREATE TABLE IF NOT EXISTS workspaces (
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

            CREATE UNIQUE INDEX IF NOT EXISTS workspaces_project_branch_unique
            ON workspaces(project_id, branch)
            WHERE length(branch) > 0;

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
              user_label TEXT,
              status TEXT NOT NULL DEFAULT 'idle',
              runtime_target_id TEXT,
              terminal_session_id TEXT,
              session_key TEXT,
              note TEXT,
              detected_agent_kind TEXT,
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

            CREATE TABLE IF NOT EXISTS migration_state (
              current_version INTEGER NOT NULL
            );
        """
}
