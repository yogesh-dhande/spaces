import Foundation
import spacesdatabase

/// Seeds the QA profile: a throwaway profile root, copied from this account's installed profile, that the
/// installed Spaces build can be pointed at so QA may create, mutate, and delete state without any of it
/// landing in the profile the user actually works in.
///
/// The QA root is `~/.spaces-dev/qa`, deliberately beside `~/.spaces-dev/profiles` rather than inside it:
/// `SPACES_DB_PATH` is how the installed binaries are pointed at it, and profile resolution refuses that
/// variable anywhere inside `~/.spaces` or `~/.spaces-dev/profiles` (see `SpacesProfile.makeProfile`),
/// which is exactly the protection that keeps a stray binding from reaching a live profile.
///
/// What is carried forward is the user's configuration: their projects, workspaces, workspace settings and
/// ports, automations, and app settings, so QA exercises the shipped build against realistic state rather
/// than an empty profile. Automations arrive disabled, since their workspaces name the user's real
/// repository directories. What is deliberately left behind is device identity, credentials, and live
/// runtime state; see `liveRuntimeStateStripSQL` and `pairedDeviceStripSQL` for why each row goes.
public enum QAProfileSeed {
    /// The QA profile root for `homeDirectoryURL`. One fixed root per account: the lane creates it, runs
    /// against it, and removes it, so there is nothing for a caller to name.
    public static func rootDirectory(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".spaces-dev", isDirectory: true).appendingPathComponent("qa", isDirectory: true)
    }

    /// The daemon database inside a profile root. Same layout for the installed profile and the QA copy,
    /// which is what lets the copy be a plain profile as far as every binary is concerned.
    public static func databaseURL(profileRoot: URL) -> URL { profileRoot.appendingPathComponent("spaces.db", isDirectory: false) }

    /// The client database inside a profile root, which holds this Mac's paired devices and its per-client
    /// UI state.
    public static func clientDatabaseURL(profileRoot: URL) -> URL {
        profileRoot.appendingPathComponent("Client", isDirectory: true).appendingPathComponent("spaces-client.db", isDirectory: false)
    }

    /// Copies the installed profile's two databases into a fresh QA root and strips what must not be
    /// carried across.
    ///
    /// Nothing else is copied. `client-secrets/` (paired-device auth tokens), `runtime/` (the daemon's TLS
    /// identity, its inbound device pairings, its Device API port assignment, session directories, logs,
    /// and the router state), `leases/`, `bin/`, `backups/`, and `ghostty/` all stay behind: each is either
    /// an identity the QA profile must not share with the real one, or state that is regenerated on first
    /// start. The QA profile's own identity follows from its root, since the Mac client's installation id
    /// is derived from the profile root path and the daemon's TLS identity is generated into its own
    /// runtime directory.
    ///
    /// A failure part way through removes the root it was building, so the next run starts from the same
    /// clean refusal rather than inheriting a half-seeded profile.
    public static func seed(installedRootDirectory: URL, qaRootDirectory: URL, fileManager: FileManager = .default) throws {
        guard !fileManager.fileExists(atPath: qaRootDirectory.path) else { throw QAProfileSeedError.qaRootExists(path: qaRootDirectory.path) }
        let installedDatabaseURL = databaseURL(profileRoot: installedRootDirectory)
        guard fileManager.fileExists(atPath: installedDatabaseURL.path) else {
            throw QAProfileSeedError.installedDatabaseMissing(path: installedDatabaseURL.path)
        }
        let installedClientDatabaseURL = clientDatabaseURL(profileRoot: installedRootDirectory)
        guard fileManager.fileExists(atPath: installedClientDatabaseURL.path) else {
            throw QAProfileSeedError.installedClientDatabaseMissing(path: installedClientDatabaseURL.path)
        }

        let qaDatabaseURL = databaseURL(profileRoot: qaRootDirectory)
        let qaClientDatabaseURL = clientDatabaseURL(profileRoot: qaRootDirectory)
        do {
            try fileManager.createDirectory(at: qaRootDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: qaClientDatabaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DatabaseSnapshot.copy(from: installedDatabaseURL.path, to: qaDatabaseURL.path)
            try requireSchemaThisBuildKnows(copyPath: qaDatabaseURL.path, supportedVersion: DatabaseSchema.currentVersion)
            try DatabaseSnapshot.applyStatements(
                liveRuntimeStateStripSQL(presentTables: try DatabaseSnapshot.tableNames(inDatabaseAt: qaDatabaseURL.path)),
                toDatabaseAt: qaDatabaseURL.path)
            try DatabaseSnapshot.copy(from: installedClientDatabaseURL.path, to: qaClientDatabaseURL.path)
            try requireSchemaThisBuildKnows(copyPath: qaClientDatabaseURL.path, supportedVersion: supportedClientSchemaVersion)
            try DatabaseSnapshot.applyStatements(
                clientStripSQL(presentTables: try DatabaseSnapshot.tableNames(inDatabaseAt: qaClientDatabaseURL.path)),
                toDatabaseAt: qaClientDatabaseURL.path)
        } catch {
            try? fileManager.removeItem(at: qaRootDirectory)
            throw error
        }
    }

    /// `SpacesClientDatabase.currentVersion`, mirrored because `spacesclientcore` depends on this module
    /// rather than the other way around. `QAProfileSeedTests` asserts the two are equal, so a bump there
    /// fails a test here instead of drifting.
    static let supportedClientSchemaVersion = 4

    /// Refuses a snapshot whose schema is newer than this checkout knows.
    ///
    /// The strip names tables, and it is narrowed to the tables the snapshot holds so that an OLDER
    /// installed build is seeded correctly. The opposite case cannot be handled that way: a NEWER installed
    /// build can hold a live-state table this checkout has never heard of, which the strip would pass over
    /// in silence, and the QA profile would come up carrying rows that name the installed daemon's own
    /// processes and windows. The version is the one thing that detects it, so it is a refusal.
    ///
    /// Read from the copy rather than from the installed database, so the check costs the installed profile
    /// nothing. A copy recording no version at all is not ahead of anything: what that means is decided by
    /// the migrator when a daemon opens it, which fails closed on a missing marker.
    static func requireSchemaThisBuildKnows(copyPath: String, supportedVersion: Int) throws {
        guard let version = DatabaseSchemaVersionReader.recordedVersion(atPath: copyPath), version > supportedVersion else { return }
        throw QAProfileSeedError.snapshotSchemaTooNew(path: copyPath, snapshotVersion: version, supportedVersion: supportedVersion)
    }

    /// What the daemon database copy loses.
    ///
    /// Every row here describes something the INSTALLED profile's daemon owns right now, which the QA
    /// profile owns nothing of. Carried across, they are worse than stale: a runtime row names a pid and a
    /// window the other daemon is driving, so a QA stop or restart would act on the user's real processes,
    /// browser tabs, and editor windows.
    ///
    /// - Terminal sessions and everything keyed by them: their session directories live under the
    ///   installed profile's `runtime/` and are not copied, so every one of these rows points at a
    ///   directory the QA daemon does not have. These tables carry no foreign keys between them, so each
    ///   is cleared explicitly rather than left to a cascade.
    /// - Coding-agent rows: an agent row exists for a terminal session, so it is dangling the moment those
    ///   sessions go. `agent_subscriptions` is `ON DELETE RESTRICT` (the termination chokepoint drops
    ///   subscriptions itself), so it is cleared before the agent rows it guards; `agent_session_events`
    ///   cascades with them.
    /// - Remote agent subscriptions and their watch baselines: they name devices this profile is not
    ///   paired with, since pairings do not come across.
    /// - Running processes and runtime targets: pids, terminal sessions, browser tabs, and editor windows
    ///   belonging to the installed profile's daemon and the user's own apps.
    /// - `workspaces.is_running`: with no runtime rows left, a workspace claiming to be running is a claim
    ///   the QA profile cannot honour.
    /// - `automations.enabled`: the copied workspaces point at the user's real repository directories, so a
    ///   cron automation carried across live would fire unattended against real work, from a second daemon
    ///   the user is not watching. The rows themselves stay, so a QA run can enable one deliberately.
    /// - Unfinished automation runs: a copied `queued` or `running` row is a fire the installed daemon had
    ///   in hand. The QA daemon adopts both on startup without consulting `automations.enabled`: it
    ///   finalizes a `running` row it never launched, and it promotes a `queued` one into a real command in
    ///   the workspace directory that row names, which is the user's own. Finished runs stay: they are
    ///   inert history, and the run list is part of what QA looks at.
    /// - `settings.app_router_port`: the port the installed daemon's router bound. Carried across, the QA
    ///   daemon's Caddy tries to bind the same port and cannot while the installed one holds it. Deleting
    ///   the key returns the QA profile to deriving its own port on first start
    ///   (`seedProfileRouterPortIfNeeded`). The other two settings keys, the workspace port range bounds,
    ///   are user configuration rather than anything this machine's installed instance holds.
    ///
    /// Projects, workspaces, their settings and ports, automation definitions, and app settings are
    /// deliberately carried across. They are the configuration QA is here to exercise.
    ///
    /// Order matters: `agent_subscriptions` before the agent rows it restricts, and every table that names
    /// a terminal session before the sessions themselves, so no delete ever runs against a row a later one
    /// would have removed anyway.
    static let liveRuntimeStateTables = [
        "agent_remote_subscriptions", "agent_remote_watch_baselines", "agent_subscriptions", "agent_pending_notifications", "agent_sessions",
        "terminal_attachments", "terminal_clients", "terminal_runtime_states", "terminal_remote_session_states", "terminal_agent_signal_events",
        "terminal_sessions", "running_processes", "runtime_targets",
    ]

    /// The strip, narrowed to the tables `presentTables` actually holds.
    ///
    /// The snapshot is of the INSTALLED build's database, which is a release and so can predate this
    /// checkout: a table this checkout knows about may simply not exist there yet, and naming it in a
    /// `DELETE` would fail the whole strip. The reverse case, a snapshot holding a runtime table this
    /// checkout has never heard of, is not covered and cannot be: seed the QA profile from a checkout that
    /// is not behind the build under test.
    static func liveRuntimeStateStripSQL(presentTables: Set<String>) -> String {
        let deletes = liveRuntimeStateTables.filter(presentTables.contains).map { "DELETE FROM \($0);" }
        let runningFlagReset = presentTables.contains("workspaces") ? ["UPDATE workspaces SET is_running = 0;"] : []
        let automationDisable = presentTables.contains("automations") ? ["UPDATE automations SET enabled = 0;"] : []
        let setupStateReset = presentTables.contains("workspace_settings") ? [unfinishedSetupResetSQL] : []
        let unfinishedRunDelete = presentTables.contains("automation_runs") ? [unfinishedAutomationRunDeleteSQL] : []
        let installedPortDelete = presentTables.contains("settings") ? ["DELETE FROM settings WHERE key = '\(installedRouterPortSettingKey)';"] : []
        let statements = deletes + runningFlagReset + automationDisable + setupStateReset + unfinishedRunDelete + installedPortDelete
        return (["BEGIN IMMEDIATE;"] + statements + ["COMMIT;"]).joined(separator: "\n")
    }

    /// Workspace setup that has not finished, resolved to `succeeded`.
    ///
    /// A snapshot taken while a setup script was running copies `running`, and no process in the QA profile
    /// will ever finish it: a start then waits out the 900-second setup timeout and the UI holds setup
    /// closed. `pending` is copied the same way and is worse than a stall, because
    /// `triggerDeferredWorkspaceSetupIfNeeded` acts on exactly that value, so the QA daemon would run the
    /// user's setup script unattended in the real worktree the copied workspace names.
    ///
    /// `succeeded` is what the schema itself defaults a workspace to when no setup was ever recorded, and
    /// it is the only value that neither stalls a start nor starts a script: setup is something QA
    /// exercises on a workspace it creates itself, where the state is its own from the beginning.
    ///
    /// The values are `WorkspaceSetupStatus` literals because `workspacecore` owns that enum and depends on
    /// this module rather than the other way around.
    static let unfinishedSetupResetSQL = "UPDATE workspace_settings SET setup_status = 'succeeded' WHERE setup_status IN ('running', 'pending');"

    /// The unfinished runs, named by the two `AutomationRunStatus` cases that report `isTerminal == false`.
    /// The statuses are literals because `spacesdevicecore` owns that enum and depends on this module
    /// rather than the other way around; adding a non-terminal status there means adding it here.
    static let unfinishedAutomationRunDeleteSQL = "DELETE FROM automation_runs WHERE status IN ('queued', 'running');"

    /// `SettingsKey.appRouterPort`, mirrored as a literal for the same module-direction reason as the run
    /// statuses above: `workspacecore` owns it and depends on this module.
    static let installedRouterPortSettingKey = "app_router_port"

    /// What the client database copy loses.
    ///
    /// - `paired_devices`: a paired-device row is half of a credential. Its other half is the auth token in
    ///   the profile's `client-secrets/`, which is not copied, and the daemon it names pinned a certificate
    ///   against the installed profile's client installation id rather than the QA profile's. The QA
    ///   profile pairs afresh, so the rows would name devices it cannot talk to.
    /// - `browser_session_window_ids`: each row holds a Chrome window id, a live handle to a window on this
    ///   desktop, and the client id these rows are keyed by is derived from the Mac rather than from the
    ///   profile, so the QA app reads the user's own rows as its own. Closing or reopening a browser
    ///   session in the QA profile would then act on the windows the user is working in.
    /// - `terminal_owner_client_ids`: each row names a client id this Mac last owned a terminal session
    ///   with. Those attachments live in the daemon database, where the QA copy keeps none, so the rows can
    ///   only ever name the installed profile's own attachments.
    /// - `code_pane_workspace_states`: each row can hold an unsaved editor buffer for a workspace. Restored
    ///   in the QA app, that buffer re-arms autosave, and the file it saves to is inside the copied
    ///   workspace's directory, which is the user's own repository. Opening an inherited pane would write
    ///   a buffer the user has moved on from back over their working tree. QA exercises the editor on the
    ///   workspaces it creates, where the buffers are its own.
    ///
    /// The rest of the client database stays. It is this Mac's own UI state (panel layouts, sidebar state,
    /// and the panel window frames, which are coordinates rather than handles), which is exactly the
    /// realistic state QA wants, and the file is copied whole because `SpacesClientDatabase` fails closed
    /// on a database with no `migration_state` marker.
    static let clientStripTables = ["paired_devices", "browser_session_window_ids", "terminal_owner_client_ids", "code_pane_workspace_states"]

    /// The client strip, narrowed to the tables the snapshot holds, for the same reason the daemon strip is
    /// narrowed: the build under test is a release and can predate this checkout.
    static func clientStripSQL(presentTables: Set<String>) -> String {
        let deletes = clientStripTables.filter(presentTables.contains).map { "DELETE FROM \($0);" }
        return (["BEGIN IMMEDIATE;"] + deletes + ["COMMIT;"]).joined(separator: "\n")
    }
}

public enum QAProfileSeedError: LocalizedError, Equatable {
    case qaRootExists(path: String)
    case installedDatabaseMissing(path: String)
    case installedClientDatabaseMissing(path: String)
    case snapshotSchemaTooNew(path: String, snapshotVersion: Int, supportedVersion: Int)

    public var errorDescription: String? {
        switch self {
        case .qaRootExists(let path): return "A QA profile already exists at \(path). Remove it before seeding another one."
        case .installedDatabaseMissing(let path): return "There is no installed Spaces database at \(path) to seed a QA profile from."
        case .installedClientDatabaseMissing(let path): return "There is no installed Spaces client database at \(path) to seed a QA profile from."
        case .snapshotSchemaTooNew(let path, let snapshotVersion, let supportedVersion):
            return "The installed build's database is at schema version \(snapshotVersion) and this checkout knows version \(supportedVersion) "
                + "(\(path)). Run the QA lane from a checkout at or ahead of the installed build, so the seed knows every table it has to strip."
        }
    }
}
