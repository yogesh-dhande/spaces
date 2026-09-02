import AppKit
import Testing
import spacesclientcore
import spacesdevicecore
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

        /// A throwaway client database distinct from the host's own, at its own temp path (proving
        /// `AlertsController` persists through the injected closure rather than `host.clientDatabase()`).
        private func makeInjectedDatabase() throws -> SpacesClientDatabase {
            try SpacesClientDatabase(path: root.appendingPathComponent("injected-client.db").path)
        }

        /// A minimal paired-device row for `database.upsert(device:)`, the same write path pairing uses.
        /// `pruneDismissedAlertsAttentionItemIDsIfNeeded` reads `pairedDevices()` off this table through
        /// the controller's injected database, so a case that depends on a device still being paired has
        /// to seed a row here, not just add a `DeviceSection`.
        private func pairedDeviceRecord(id: String, name: String) -> SpacesPairedDeviceRecord {
            SpacesPairedDeviceRecord(
                id: id, name: name, platform: "linux", hosts: ["10.0.0.4"], port: 19000, certificateFingerprint: "fingerprint",
                createdAt: "2026-06-01T00:00:00Z", updatedAt: "2026-06-01T00:00:00Z")
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
            #expect(host.deviceModel.alertsGroups.isEmpty)
            alerts.pruneDismissedAlertsAttentionItemIDsIfNeeded()
            #expect(alerts.dismissedAlertsAttentionItemIDs.isEmpty)
            #expect(try database.setting(key: ClientSettingsKey.alertsDismissedAttentionItems) == nil)
        }

        /// Pins the cold-launch bug (#621) in its exact form: `SidebarController.applyLocalDeviceSidebarSnapshot`
        /// triggers this prune (line ~626) *before* `loadRemoteDeviceSections` has run even once (line
        /// ~710), so a paired remote device has no `DeviceSection` at all yet, not merely a `.loading`
        /// one. Against the pre-fix `retainedDismissedAttentionItemIDs(_:sections:)` (grouping dismissals
        /// by device and keeping only buckets whose device has a matching section), a bucket with no
        /// matching section takes the "no matching section, drop" path unconditionally, so this exact
        /// setup deletes the remote dismissal outright, permanently, on the very first snapshot apply -
        /// which is what made the alert resurrect on relaunch. The fix reads paired device ids off the
        /// injected database and keeps a section-less bucket only while its device is still paired, so
        /// this seeds the remote device as a paired row (via `database.upsert(device:)`, the write pairing
        /// itself uses) without ever installing a `DeviceSection` for it.
        @Test func remoteDeviceDismissalsSurviveAColdLaunchPruneWithNoRemoteSectionAtAll() throws {
            let host = makeHost()
            let database = try makeInjectedDatabase()
            let alerts = AlertsController(host: host, database: { database })

            try database.upsert(device: pairedDeviceRecord(id: "remote-device", name: "Remote"))

            let remoteAttentionID = "alert:remote-device:process:run-1:2026-06-28T10:00:00Z"
            alerts.dismissAlertsAttentionItem(remoteAttentionID)
            #expect(alerts.dismissedAlertsAttentionItemIDs == [remoteAttentionID])

            // Cold launch, before `loadRemoteDeviceSections` has ever appended the remote's `.loading`
            // placeholder: only the local section exists.
            host.deviceModel.deviceSections = [
                AppKitController.DeviceSection(
                    deviceID: SpacesPairedDeviceRecord.localDeviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded,
                    overview: SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])),
            ]
            host.deviceModel.alertsGroups = AppKitController.mergedSidebarData(sections: host.deviceModel.deviceSections).alertsGroups

            alerts.pruneDismissedAlertsAttentionItemIDsIfNeeded()

            #expect(alerts.dismissedAlertsAttentionItemIDs == [remoteAttentionID])
            #expect(try database.setting(key: ClientSettingsKey.alertsDismissedAttentionItems) != nil)
        }

        /// The companion case once `loadRemoteDeviceSections` has run: the remote device's section exists
        /// but sits `.loading`, carrying no overview yet. A prune triggered at that point must not treat
        /// the remote device's silence as evidence its alerts are gone.
        @Test func remoteDeviceDismissalsSurviveAPruneTriggeredWhileTheRemoteSectionIsStillLoading() throws {
            let host = makeHost()
            let database = try makeInjectedDatabase()
            let alerts = AlertsController(host: host, database: { database })

            let remoteAttentionID = "alert:remote-device:process:run-1:2026-06-28T10:00:00Z"
            alerts.dismissAlertsAttentionItem(remoteAttentionID)
            #expect(alerts.dismissedAlertsAttentionItemIDs == [remoteAttentionID])

            host.deviceModel.deviceSections = [
                AppKitController.DeviceSection(
                    deviceID: SpacesPairedDeviceRecord.localDeviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded,
                    overview: SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])),
                AppKitController.DeviceSection(deviceID: "remote-device", deviceName: "Remote", isLocal: false, loadState: .loading),
            ]
            host.deviceModel.alertsGroups = AppKitController.mergedSidebarData(sections: host.deviceModel.deviceSections).alertsGroups

            alerts.pruneDismissedAlertsAttentionItemIDsIfNeeded()

            #expect(alerts.dismissedAlertsAttentionItemIDs == [remoteAttentionID])
            #expect(try database.setting(key: ClientSettingsKey.alertsDismissedAttentionItems) != nil)
        }

        /// A failed paired-device read is unknown pairing state, not evidence that nothing is paired:
        /// the prune pass must abort with the set untouched (the next sidebar refresh retries) rather
        /// than prune against an empty paired set, which would erase every not-yet-loaded device's
        /// dismissals on a transient database error.
        @Test func aFailedPairedDeviceReadAbortsThePruneWithDismissalsUntouched() throws {
            final class DatabaseGate { var shouldThrow = false }
            struct ReadFailure: Error {}
            let host = makeHost()
            let database = try makeInjectedDatabase()
            let gate = DatabaseGate()
            let alerts = AlertsController(
                host: host,
                database: {
                    if gate.shouldThrow { throw ReadFailure() }
                    return database
                })

            let remoteAttentionID = "alert:remote-device:process:run-1:2026-06-28T10:00:00Z"
            alerts.dismissAlertsAttentionItem(remoteAttentionID)
            #expect(alerts.dismissedAlertsAttentionItemIDs == [remoteAttentionID])

            // Same cold-launch shape as above: only the local section exists, so pruning against an
            // empty paired set would drop the remote bucket. The read failure must prevent exactly that.
            host.deviceModel.deviceSections = [
                AppKitController.DeviceSection(
                    deviceID: SpacesPairedDeviceRecord.localDeviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded,
                    overview: SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])),
            ]
            host.deviceModel.alertsGroups = AppKitController.mergedSidebarData(sections: host.deviceModel.deviceSections).alertsGroups

            gate.shouldThrow = true
            alerts.pruneDismissedAlertsAttentionItemIDsIfNeeded()

            #expect(alerts.dismissedAlertsAttentionItemIDs == [remoteAttentionID])
            #expect(try database.setting(key: ClientSettingsKey.alertsDismissedAttentionItems) != nil)
        }

        /// Boundedness: a dismissal whose device has no section and is not (or no longer) a paired
        /// device is dropped rather than kept forever, so an unpair does not leave the set growing for
        /// the life of the install.
        @Test func dismissalForAnUnpairedDeviceWithNoSectionIsDropped() throws {
            let host = makeHost()
            let database = try makeInjectedDatabase()
            let alerts = AlertsController(host: host, database: { database })

            let orphanAttentionID = "alert:unpaired-device:process:run-1:2026-06-28T10:00:00Z"
            alerts.dismissAlertsAttentionItem(orphanAttentionID)
            #expect(alerts.dismissedAlertsAttentionItemIDs == [orphanAttentionID])

            // No paired-device row for "unpaired-device", and no section for it either.
            host.deviceModel.deviceSections = [
                AppKitController.DeviceSection(
                    deviceID: SpacesPairedDeviceRecord.localDeviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded,
                    overview: SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])),
            ]
            host.deviceModel.alertsGroups = AppKitController.mergedSidebarData(sections: host.deviceModel.deviceSections).alertsGroups

            alerts.pruneDismissedAlertsAttentionItemIDsIfNeeded()

            #expect(alerts.dismissedAlertsAttentionItemIDs.isEmpty)
            #expect(try database.setting(key: ClientSettingsKey.alertsDismissedAttentionItems) == nil)
        }
    }
}
