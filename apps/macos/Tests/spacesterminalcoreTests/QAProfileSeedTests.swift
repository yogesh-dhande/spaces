#if os(macOS)
    import Foundation
    import Testing
    import spacesclientcore
    import spacesdatabase

    @testable import spacesterminalcore

    /// Covers what a QA profile inherits from the user's installed profile and what it must not: the
    /// configuration QA exercises comes across, while every row that names something the installed
    /// profile's daemon owns, and every device credential, stays behind.
    ///
    /// Both fixture databases are built through the product's own types, so the schema under test is the
    /// real one rather than a hand-written copy of it, and everything happens under a temporary directory.
    @Suite struct QAProfileSeedTests {
        @Test func carriesConfigurationForwardAndStripsLiveRuntimeState() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let installedDatabase = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()
            for table in QAProfileSeed.liveRuntimeStateTables {
                #expect(try fixture.count(in: installedDatabase, table: table) == 1, "the fixture seeded no \(table) row to strip")
            }

            // The source stays open across the seed, which is the case the online-backup copy exists for: a
            // QA profile is seeded while the installed daemon is serving that database.
            try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)

            #expect(try fixture.count(in: installedDatabase, table: "terminal_sessions") == 1)

            let qaDatabase = try SpacesSQLiteDatabase(path: QAProfileSeed.databaseURL(profileRoot: fixture.qaRoot).path)
            #expect(try fixture.count(in: qaDatabase, table: "projects") == 1)
            #expect(try fixture.count(in: qaDatabase, table: "workspaces") == 1)
            #expect(try fixture.count(in: qaDatabase, table: "workspace_settings") == 1)
            #expect(try qaDatabase.queryRow(sql: "SELECT is_running FROM workspaces")?.first == "0")
            for table in QAProfileSeed.liveRuntimeStateTables {
                #expect(try fixture.count(in: qaDatabase, table: table) == 0, "\(table) still has rows")
            }
        }

        /// The copied workspaces name the user's real repository directories, so an automation must not be
        /// able to fire from the QA profile on its own. It keeps its definition, so a QA run can enable it
        /// deliberately.
        @Test func carriesAutomationsForwardDisabled() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let installedDatabase = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()

            try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)

            let qaDatabase = try SpacesSQLiteDatabase(path: QAProfileSeed.databaseURL(profileRoot: fixture.qaRoot).path)
            #expect(try qaDatabase.queryRow(sql: "SELECT name, enabled FROM automations WHERE id = 'au1'") == ["Nightly", "0"])
            #expect(try installedDatabase.queryRow(sql: "SELECT enabled FROM automations WHERE id = 'au1'")?.first == "1")
        }

        /// A run the installed daemon had queued or in flight is a command the QA daemon would adopt on
        /// startup without ever consulting whether its automation is enabled, and run in the real workspace
        /// directory the row names. Finished runs are inert history and stay.
        @Test func dropsUnfinishedAutomationRunsAndKeepsFinishedOnes() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()

            try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)

            let qaDatabase = try SpacesSQLiteDatabase(path: QAProfileSeed.databaseURL(profileRoot: fixture.qaRoot).path)
            #expect(try qaDatabase.queryRows(sql: "SELECT id FROM automation_runs ORDER BY id").map { $0[0] } == ["r3", "r4"])
        }

        /// The router port in the copy is the port the installed daemon's router holds, which the QA
        /// daemon's own router cannot bind while that one runs. Without the setting the QA profile derives
        /// its own port on first start.
        @Test func dropsTheInstalledRouterPortSetting() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()

            try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)

            let qaDatabase = try SpacesSQLiteDatabase(path: QAProfileSeed.databaseURL(profileRoot: fixture.qaRoot).path)
            #expect(try qaDatabase.queryRow(sql: "SELECT value FROM settings WHERE key = 'app_router_port'") == nil)
            #expect(try qaDatabase.queryRow(sql: "SELECT value FROM settings WHERE key = 'app_port_range_start'")?.first == "20000")
        }

        @Test func dropsPairedDevicesFromTheClientDatabaseCopy() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            let installedClientDatabase = try fixture.makeInstalledClientDatabase()
            #expect(try installedClientDatabase.pairedDevices().count == 1)

            try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)

            // Opening the copy at all is half the assertion: SpacesClientDatabase fails closed on a database
            // with no migration_state marker, so a copy it can open is a copy that kept the whole schema.
            let qaClientDatabase = try SpacesClientDatabase(path: QAProfileSeed.clientDatabaseURL(profileRoot: fixture.qaRoot).path)
            #expect(try qaClientDatabase.pairedDevices().isEmpty)
            #expect(try installedClientDatabase.pairedDevices().count == 1)
        }

        /// A browser-session window id is a live handle to a window on the user's desktop, and the client
        /// id these rows are keyed by comes from the Mac rather than the profile, so the QA app would read
        /// the user's own rows as its own and close the windows they name. The terminal owner client ids
        /// name attachments only the installed profile's database holds, and an editor state row can carry
        /// an unsaved buffer whose autosave would land in the user's own repository.
        @Test func dropsClientRowsThatNameLiveDesktopState() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            let installedClientDatabase = try fixture.makeInstalledClientDatabase()
            #expect(
                try installedClientDatabase.browserSessionWindowID(deviceID: "local", workspaceID: "w1", targetURL: "http://localhost:3000") == 8_421)

            try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)

            let qaClientDatabase = try SpacesClientDatabase(path: QAProfileSeed.clientDatabaseURL(profileRoot: fixture.qaRoot).path)
            #expect(try qaClientDatabase.browserSessionWindowIDs(deviceID: "local", workspaceID: "w1").isEmpty)
            #expect(try qaClientDatabase.terminalOwnerClientID(deviceID: "local", sessionID: "s1") == nil)
            #expect(try qaClientDatabase.codePaneWorkspaceIDs(deviceID: "local").isEmpty)
            #expect(try installedClientDatabase.browserSessionWindowIDs(deviceID: "local", workspaceID: "w1").count == 1)
        }

        /// Setup that the installed daemon had in flight when the snapshot was taken has nothing to finish
        /// it in the QA profile, and the value that means "not run yet" is the one the daemon acts on by
        /// running the script itself, in the real worktree the copied workspace names.
        @Test func resolvesUnfinishedWorkspaceSetup() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()

            try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)

            let qaDatabase = try SpacesSQLiteDatabase(path: QAProfileSeed.databaseURL(profileRoot: fixture.qaRoot).path)
            #expect(try qaDatabase.queryRow(sql: "SELECT setup_status FROM workspace_settings WHERE workspace_id = 'w1'")?.first == "succeeded")
        }

        /// The identity and credential material a QA profile must never share with the real one is absent
        /// because it is never copied: the seed writes two databases and nothing else.
        @Test func copiesNoIdentityOrRuntimeMaterial() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()
            for directory in ["runtime", "client-secrets", "leases", "bin", "backups", "ghostty"] {
                try FileManager.default.createDirectory(
                    at: fixture.installedRoot.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
            }

            try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)

            let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.qaRoot.path)
            #expect(Set(contents) == ["spaces.db", "Client"])
        }

        @Test func refusesWhenAQAProfileAlreadyExists() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()
            try FileManager.default.createDirectory(at: fixture.qaRoot, withIntermediateDirectories: true)

            #expect(throws: QAProfileSeedError.qaRootExists(path: fixture.qaRoot.path)) {
                try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)
            }
        }

        @Test func refusesWhenThereIsNoInstalledDatabase() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }

            #expect(throws: QAProfileSeedError.installedDatabaseMissing(path: QAProfileSeed.databaseURL(profileRoot: fixture.installedRoot).path)) {
                try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.qaRoot.path))
        }

        /// A newer installed build can hold a live-state table this checkout has never heard of, which the
        /// strip would pass over in silence, leaving the QA profile carrying rows that name the installed
        /// daemon's own processes and windows. The recorded schema version is what detects that.
        @Test func refusesASnapshotNewerThanThisCheckout() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()
            let installedDatabasePath = QAProfileSeed.databaseURL(profileRoot: fixture.installedRoot).path
            try fixture.stampSchemaVersion(DatabaseSchema.currentVersion + 1, atDatabasePath: installedDatabasePath)

            #expect(
                throws: QAProfileSeedError.snapshotSchemaTooNew(
                    path: QAProfileSeed.databaseURL(profileRoot: fixture.qaRoot).path, snapshotVersion: DatabaseSchema.currentVersion + 1,
                    supportedVersion: DatabaseSchema.currentVersion)
            ) { try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot) }
            #expect(!FileManager.default.fileExists(atPath: fixture.qaRoot.path))
        }

        /// The client database is versioned on its own train, so it is checked on its own.
        @Test func refusesAClientSnapshotNewerThanThisCheckout() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()
            let installedClientDatabasePath = QAProfileSeed.clientDatabaseURL(profileRoot: fixture.installedRoot).path
            try fixture.stampSchemaVersion(QAProfileSeed.supportedClientSchemaVersion + 1, atDatabasePath: installedClientDatabasePath)

            #expect(
                throws: QAProfileSeedError.snapshotSchemaTooNew(
                    path: QAProfileSeed.clientDatabaseURL(profileRoot: fixture.qaRoot).path,
                    snapshotVersion: QAProfileSeed.supportedClientSchemaVersion + 1, supportedVersion: QAProfileSeed.supportedClientSchemaVersion)
            ) { try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot) }
            #expect(!FileManager.default.fileExists(atPath: fixture.qaRoot.path))
        }

        /// An installed build BEHIND this checkout is the ordinary case, and the strip handles it by naming
        /// only the tables the snapshot holds.
        @Test func seedsASnapshotOlderThanThisCheckout() throws {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            _ = try fixture.makeInstalledDatabase()
            _ = try fixture.makeInstalledClientDatabase()
            try fixture.stampSchemaVersion(
                DatabaseSchema.currentVersion - 1, atDatabasePath: QAProfileSeed.databaseURL(profileRoot: fixture.installedRoot).path)
            try fixture.stampSchemaVersion(
                QAProfileSeed.supportedClientSchemaVersion - 1,
                atDatabasePath: QAProfileSeed.clientDatabaseURL(profileRoot: fixture.installedRoot).path)

            try QAProfileSeed.seed(installedRootDirectory: fixture.installedRoot, qaRootDirectory: fixture.qaRoot)

            #expect(FileManager.default.fileExists(atPath: QAProfileSeed.databaseURL(profileRoot: fixture.qaRoot).path))
            #expect(FileManager.default.fileExists(atPath: QAProfileSeed.clientDatabaseURL(profileRoot: fixture.qaRoot).path))
        }

        /// The client schema version this seed checks against is a copy of the one `spacesclientcore`
        /// declares, which this module cannot import. A bump there has to be a bump here.
        @Test func tracksTheClientSchemaVersion() { #expect(QAProfileSeed.supportedClientSchemaVersion == SpacesClientDatabase.currentVersion) }

        /// A released build's database can predate this checkout, so the strip names only the tables the
        /// snapshot actually has: a table this build knows about but that build never created must not fail
        /// the whole strip.
        @Test func stripsOnlyTheTablesTheSnapshotHolds() {
            let sql = QAProfileSeed.liveRuntimeStateStripSQL(presentTables: ["terminal_sessions", "workspaces"])

            #expect(sql.contains("DELETE FROM terminal_sessions;"))
            #expect(sql.contains("UPDATE workspaces SET is_running = 0;"))
            #expect(!sql.contains("agent_sessions"))
            #expect(!sql.contains("automations"))
            #expect(!sql.contains("automation_runs"))
            #expect(!sql.contains("settings"))
        }

        /// A temporary stand-in for an account home: an installed profile root to seed from and the QA root
        /// to seed into.
        private struct Fixture {
            let root: URL
            let installedRoot: URL
            let qaRoot: URL

            init() throws {
                root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                installedRoot = root.appendingPathComponent(".spaces", isDirectory: true)
                qaRoot = QAProfileSeed.rootDirectory(homeDirectoryURL: root)
                try FileManager.default.createDirectory(at: installedRoot, withIntermediateDirectories: true)
            }

            func cleanUp() { try? FileManager.default.removeItem(at: root) }

            /// The installed daemon database, holding one project and workspace plus one row in every table
            /// the strip clears. The insert order is the product's own: a row can only reference rows that
            /// already exist.
            func makeInstalledDatabase() throws -> SpacesSQLiteDatabase {
                let database = try SpacesSQLiteDatabase(path: QAProfileSeed.databaseURL(profileRoot: installedRoot).path)
                let timestamp = "2026-01-01T00:00:00.000Z"
                let sessionRoot = "\(installedRoot.path)/runtime/terminal/sessions/s1"
                try database.execute(sql: "INSERT INTO projects(id, name, dir, is_git) VALUES ('p1', 'Demo', '/tmp/demo', 1)")
                try database.execute(
                    sql: "INSERT INTO workspaces(id, project_id, dir, is_default, is_running) VALUES ('w1', 'p1', '/tmp/demo/w1', 1, 1)")
                try database.execute(sql: "INSERT INTO workspace_settings(workspace_id, setup_status) VALUES ('w1', 'running')")
                try database.execute(
                    sql: """
                        INSERT INTO terminal_sessions(
                          session_id, root_directory, backend, lifetime_policy, workspace_id, title, working_directory, shell, created_at)
                        VALUES ('s1', ?, 'ghostty', 'workspace', 'w1', 'Shell', '/tmp/demo/w1', '/bin/zsh', ?)
                        """, bindings: [sessionRoot, timestamp])
                try database.execute(
                    sql: """
                        INSERT INTO terminal_runtime_states(session_id, root_directory, backend, service_pid, state, updated_at)
                        VALUES ('s1', ?, 'ghostty', 4242, 'running', ?)
                        """, bindings: [sessionRoot, timestamp])
                try database.execute(
                    sql: """
                        INSERT INTO terminal_clients(
                          root_directory, session_id, client_id, kind, identity_label, connected_at, lease_refreshed_at)
                        VALUES (?, 's1', 'c1', 'local', 'Mac', ?, ?)
                        """, bindings: [sessionRoot, timestamp, timestamp])
                try database.execute(
                    sql:
                        "INSERT INTO terminal_attachments(id, root_directory, session_id, client_id, mode, attached_at) VALUES ('t1', ?, 's1', 'c1', 'owner', ?)",
                    bindings: [sessionRoot, timestamp])
                try database.execute(
                    sql: "INSERT INTO terminal_remote_session_states(session_id, root_directory, payload_json) VALUES ('s1', ?, '{}')",
                    bindings: [sessionRoot])
                try database.execute(
                    sql: """
                        INSERT INTO terminal_agent_signal_events(
                          id, root_directory, session_id, event_type, provider, environment_keys_json, created_at)
                        VALUES ('e1', ?, 's1', 'working', 'claude', '[]', ?)
                        """, bindings: [sessionRoot, timestamp])
                try database.execute(
                    sql: """
                        INSERT INTO agent_sessions(id, workspace_id, provider, terminal_session_id, created_at, updated_at)
                        VALUES ('a1', 'w1', 'claude', 's1', ?, ?)
                        """, bindings: [timestamp, timestamp])
                try database.execute(
                    sql: "INSERT INTO agent_subscriptions(subscriber_terminal_session_id, agent_session_id, created_at) VALUES ('s1', 'a1', ?)",
                    bindings: [timestamp])
                try database.execute(
                    sql: """
                        INSERT INTO agent_pending_notifications(id, subscriber_terminal_session_id, agent_session_id, message, created_at)
                        VALUES ('n1', 's1', 'a1', 'done', ?)
                        """, bindings: [timestamp])
                try database.execute(
                    sql: """
                        INSERT INTO agent_remote_subscriptions(subscriber_terminal_session_id, device_id, agent_session_id, created_at)
                        VALUES ('s1', 'device-1', 'remote-session', ?)
                        """, bindings: [timestamp])
                try database.execute(
                    sql: "INSERT INTO agent_remote_watch_baselines(device_id, agent_session_id, row_json) VALUES ('device-1', 'remote-session', '{}')"
                )
                try database.execute(
                    sql: """
                        INSERT INTO runtime_targets(id, workspace_id, type, app, order_index, updated_at)
                        VALUES ('rt1', 'w1', 'browser', 'Chrome', 0, ?)
                        """, bindings: [timestamp])
                try database.execute(
                    sql: """
                        INSERT INTO running_processes(id, workspace_id, template_name, command, terminal_session_id, pid, status)
                        VALUES ('rp1', 'w1', 'dev', 'npm run dev', 's1', 4243, 'running')
                        """)
                try database.execute(
                    sql: """
                        INSERT INTO automations(
                          id, name, enabled, trigger_kind, cron_expression, kind, script, workspace_id, concurrency_policy, missed_run_policy,
                          created_at, updated_at)
                        VALUES ('au1', 'Nightly', 1, 'cron', '0 2 * * *', 'script', 'git gc', 'w1', 'skip', 'run_once', 0, 0)
                        """)
                for (id, status) in [("r1", "queued"), ("r2", "running"), ("r3", "succeeded"), ("r4", "failed")] {
                    try database.execute(
                        sql:
                            "INSERT INTO automation_runs(id, automation_id, kind, status, trigger_kind, created_at) VALUES (?, 'au1', 'script', ?, 'cron', 0)",
                        bindings: [id, status])
                }
                try database.execute(sql: "INSERT INTO settings(key, value) VALUES ('app_router_port', '7391')")
                try database.execute(sql: "INSERT INTO settings(key, value) VALUES ('app_port_range_start', '20000')")
                return database
            }

            /// The installed client database with one paired device, the row the copy must lose.
            func makeInstalledClientDatabase() throws -> SpacesClientDatabase {
                let path = QAProfileSeed.clientDatabaseURL(profileRoot: installedRoot).path
                let database = try SpacesClientDatabase(path: path)
                try database.upsert(
                    device: SpacesPairedDeviceRecord(
                        id: "device-1", name: "Linux box", platform: "linux", hosts: ["10.0.0.2"], port: 47_850, certificateFingerprint: "sha256-abc",
                        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"))
                try database.setBrowserSessionWindowID(deviceID: "local", workspaceID: "w1", targetURL: "http://localhost:3000", windowID: 8_421)
                try database.setTerminalOwnerClientID(deviceID: "local", sessionID: "s1", clientID: "c1")
                try database.writeCodePaneWorkspaceState(deviceID: "local", workspaceID: "w1", stateJSON: "{\"unsaved\":\"draft\"}")
                return database
            }

            /// Rewrites a fixture database's recorded schema version. Both databases keep it in the same
            /// `migration_state` row, and it is written through `DatabaseSnapshot` rather than through
            /// either product type, since opening a database through those is what migrates it.
            func stampSchemaVersion(_ version: Int, atDatabasePath path: String) throws {
                try DatabaseSnapshot.applyStatements("UPDATE migration_state SET current_version = \(version);", toDatabaseAt: path)
            }

            func count(in database: SpacesSQLiteDatabase, table: String) throws -> Int {
                Int(try database.queryRow(sql: "SELECT COUNT(*) FROM \(table)")?.first ?? "") ?? -1
            }
        }
    }
#endif
