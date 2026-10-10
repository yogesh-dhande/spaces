import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Renaming a paired remote device from Settings > Devices reaches the sidebar through its next load:
    /// the section header and the device-titled automation alerts group must show the new name without a
    /// relaunch. Nests under `ProcessProfileEnvironmentSuites` because it mutates the process-global
    /// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class SidebarRemoteDeviceRenameTests {
        private static let deviceID = "remote-box"

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

        private func makeController() -> AppKitController {
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

        /// A paired record with no certificate fingerprint, so the sidebar load never dials it.
        private func pairedRecord(name: String) -> SpacesPairedDeviceRecord {
            SpacesPairedDeviceRecord(
                id: Self.deviceID, name: name, platform: "linux", hosts: ["10.0.0.5"], port: 8443, certificateFingerprint: "",
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        }

        private func overviewWithFailedAutomationRun() -> SpacesDeviceOverviewPayload {
            SpacesDeviceOverviewPayload(
                workspaces: [], sessions: [], daemonStatus: .testStatus,
                automationRuns: [
                    TerminalServiceAutomationRunSummary(
                        id: "run-1", automationID: "auto-1", automationName: "nightly", kind: "script", status: "failed", trigger: "schedule",
                        skipReason: nil, exitCode: 1, terminalSessionID: nil, startedAt: "2026-06-28T09:00:00Z", endedAt: "2026-06-28T09:01:00Z",
                        createdAt: "2026-06-28T09:00:00Z")
                ])
        }

        @Test func aRenamedRemoteDeviceShowsItsNewNameInTheSectionAndItsAlertsOnTheNextLoad() throws {
            let controller = makeController()
            let database = try controller.clientDatabase()
            try database.upsert(device: pairedRecord(name: "Old Box"))

            controller.sidebar.loadRemoteDeviceSections()
            let index = try #require(controller.deviceModel.deviceSections.firstIndex { $0.deviceID == Self.deviceID })
            let overview = overviewWithFailedAutomationRun()
            controller.deviceModel.deviceSections[index].overview = overview
            controller.deviceModel.deviceSections[index].alertsGroups = AlertsController.buildOverviewAlertsGroups(
                from: overview, deviceID: Self.deviceID, deviceName: "Old Box")
            controller.sidebar.applySidebarDataChange()
            #expect(controller.deviceModel.alertsGroups.map(\.workspaceName) == ["Old Box"])

            try database.upsert(device: pairedRecord(name: "New Box"))
            controller.sidebar.loadRemoteDeviceSections()

            let renamed = try #require(controller.deviceModel.deviceSections.first { $0.deviceID == Self.deviceID })
            #expect(renamed.displayName == "New Box")
            #expect(controller.deviceModel.alertsGroups.map(\.workspaceName) == ["New Box"])
        }
    }
}
