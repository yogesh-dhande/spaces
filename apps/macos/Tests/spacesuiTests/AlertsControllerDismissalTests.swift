import AppKit
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Dismissals are requests to the device that raised the alert, so the controls that send them follow
    /// that device's reachability. Builds an `AppKitController` the way `AlertsDetailRebuildTests` does
    /// (a fabricated lease/profile over a throwaway temp directory) and nests under
    /// `ProcessProfileEnvironmentSuites` for the same reason: it mutates the process-global
    /// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class AlertsControllerDismissalTests {
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

        private func section(_ deviceID: String, isLocal: Bool, _ loadState: AppKitController.SidebarDeviceLoadState) -> AppKitController.DeviceSection {
            AppKitController.DeviceSection(deviceID: deviceID, deviceName: deviceID, isLocal: isLocal, loadState: loadState)
        }

        @Test func dismissingFollowsTheReachabilityOfTheDeviceThatRaisedTheAlert() {
            let host = makeHost()
            host.deviceModel.deviceSections = [
                section(SpacesPairedDeviceRecord.localDeviceID, isLocal: true, .loaded),
                section("linux-box", isLocal: false, .loaded),
                section("offline-box", isLocal: false, .offline("unreachable")),
                section("loading-box", isLocal: false, .loading),
            ]
            let alerts = host.alerts

            #expect(alerts.canDismissAlert(attentionID: "alert:\(SpacesPairedDeviceRecord.localDeviceID):process:p1:t1"))
            #expect(alerts.canDismissAlert(attentionID: "alert:linux-box:bell:s1:t1"))
            #expect(!alerts.canDismissAlert(attentionID: "alert:offline-box:bell:s1:t1"))
            #expect(!alerts.canDismissAlert(attentionID: "alert:loading-box:bell:s1:t1"))
            #expect(!alerts.canDismissAlert(attentionID: "alert:unknown-box:bell:s1:t1"))
            #expect(!alerts.canDismissAlert(attentionID: "not-an-alert-id"))
        }

        /// Nothing hides ahead of the device's answer: asking an unreachable device to dismiss reports the
        /// failure and leaves the list as it was.
        @Test func dismissingOnAnOfflineDeviceReportsAnErrorAndLeavesTheListAlone() async throws {
            let host = makeHost()
            host.deviceModel.deviceSections = [section("offline-box", isLocal: false, .offline("unreachable"))]
            let entry = AlertsController.AlertsAttentionEntry(
                attentionID: "alert:offline-box:bell:s1:t1", kind: .bell, deviceID: "offline-box", alertKey: "bell:s1:t1", icon: "terminal",
                iconTint: .terminal, label: "shell", detail: nil, shortcut: "", countsTowardBadge: true, eventDate: nil)
            host.deviceModel.alertsGroups = [
                AlertsController.AlertsGroup(
                    projectName: "p", workspaceID: "ws", workspaceName: "w", workspaceBranch: nil, isFromHiddenWorkspace: false, items: [entry],
                    deviceID: "offline-box")
            ]
            var errors: [any Error] = []
            host.showErrorOverrideForTesting = { errors.append($0) }

            host.alerts.dismissAlertsAttentionItem(entry.attentionID)
            for _ in 0..<50 where errors.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

            #expect(errors.count == 1)
            #expect(host.deviceModel.alertsGroups.flatMap(\.items).map(\.attentionID) == [entry.attentionID])
        }
    }
}
