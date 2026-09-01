import AppKit
import Testing
import spacesclientcore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Covers `AlertsController`'s dismissed-attention-item persistence: the client database it is
    /// constructed with (via `init(host:database:)`) is where a dismissal survives across rebuilds, and
    /// where a pruned-to-empty set is expected to clear the setting rather than persist an empty array.
    ///
    /// Builds an `AppKitController` the way `AlertsDetailRebuildTests` does (a fabricated lease/profile
    /// over a throwaway temp directory) and nests under `ProcessProfileEnvironmentSuites` for the same
    /// reason: it mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`. The host's own
    /// `clientDatabase()` is unused here — the point of `init(host:database:)` is that `AlertsController`
    /// persists through whichever database its caller injects, so this suite injects its own throwaway
    /// `SpacesClientDatabase` rather than reaching through the host.
    @MainActor @Suite final class AlertsControllerDismissalPersistenceTests {
        private let root: URL
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
            setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        }

        deinit {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        private func makeHost() -> AppKitController {
            let profile = SpacesProfile(
                source: .explicitDatabasePath, databasePath: root.appendingPathComponent("spaces.db").path, rootDirectory: root.path,
                isInstalledProfile: false, runtimeDirectory: root.appendingPathComponent("runtime").path,
                ipcNotificationObject: "com.spaces.test.\(UUID().uuidString)", developmentContext: nil, branchSlug: nil, worktreeHash: nil)
            let owner = SpacesProcessLeaseOwner(
                pid: ProcessInfo.processInfo.processIdentifier, executablePath: "/tmp/spaces-test", profileRoot: root.path, token: UUID().uuidString,
                acquiredAt: "2026-01-01T00:00:00Z")
            let lease = SpacesProcessLease(
                owner: owner, leaseDirectoryPath: root.appendingPathComponent("app-owner-lease").path, metadataPath: "unused", fileManager: .default)
            let context = SpacesAppLaunchContext(profile: profile, appOwnerLease: lease, desktopControlState: .passive(owner))
            return AppKitController(launchContext: context)
        }

        /// A throwaway client database distinct from the host's own, at its own temp path — proving
        /// `AlertsController` persists through the injected closure rather than `host.clientDatabase()`.
        private func makeInjectedDatabase() throws -> SpacesClientDatabase {
            try SpacesClientDatabase(path: root.appendingPathComponent("injected-client.db").path)
        }

        @Test func dismissalsSurviveIntoANewControllerReadingTheSameDatabase() throws {
            let host = makeHost()
            let database = try makeInjectedDatabase()
            let alerts = AlertsController(host: host, database: { database })

            alerts.dismissAlertsAttentionItem("id-1")
            alerts.dismissAlertsAttentionItem("id-2")
            #expect(alerts.dismissedAlertsAttentionItemIDs == ["id-1", "id-2"])

            // A fresh controller over the same database starts empty until it loads.
            let reloaded = AlertsController(host: host, database: { database })
            #expect(reloaded.dismissedAlertsAttentionItemIDs.isEmpty)
            reloaded.loadAlertsDismissedAttentionItemIDs()
            #expect(reloaded.dismissedAlertsAttentionItemIDs == ["id-1", "id-2"])
        }

        @Test func pruningEveryDismissalAwayClearsTheStoredSettingRatherThanPersistingAnEmptySet() throws {
            let host = makeHost()
            let database = try makeInjectedDatabase()
            let alerts = AlertsController(host: host, database: { database })

            alerts.dismissAlertsAttentionItem("id-1")
            alerts.dismissAlertsAttentionItem("id-2")
            #expect(try database.setting(key: ClientSettingsKey.alertsDismissedAttentionItems) != nil)

            // `host.alertsGroups` is empty (no overview was ever loaded), so neither dismissed id is still
            // derived and pruning drops both, exercising `storeDismissedAlertsAttentionItemIDs`'s
            // empty-set path.
            #expect(host.alertsGroups.isEmpty)
            alerts.pruneDismissedAlertsAttentionItemIDsIfNeeded()
            #expect(alerts.dismissedAlertsAttentionItemIDs.isEmpty)
            #expect(try database.setting(key: ClientSettingsKey.alertsDismissedAttentionItems) == nil)
        }
    }
}
