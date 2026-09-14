import AppKit
import Testing
import spacesclientcore
import spacesdevicecore

@testable import spacesterminalcore
@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// The launch draws a loading placeholder into the detail container, and nothing dismisses it: it
    /// goes away only when a later pane render empties that container. So every way the initial load can
    /// end without resolving a pane owes the user a landing, or the spinner outlives the load it reports.
    ///
    /// The case this suite covers is the Sparkle relaunch: the new app meets the old daemon, which is
    /// still up with the update staged, so the launch snapshot fails wire-incompatible. No block is
    /// rendered for that (Spaces asks the daemon to apply the staged build itself, and the block is
    /// withheld while that is in flight), so the reload after the handoff is what has to land the pane.
    ///
    /// Builds an `AppKitController` the way `SidebarLocalOverviewRefreshTests` does (a fabricated
    /// lease/profile over a throwaway temp directory) and nests under `ProcessProfileEnvironmentSuites`
    /// for the same reason: it mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class SidebarLaunchLandingTests {
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
            return AppKitController(
                launchContext: SpacesAppLaunchContext(profile: profile, appOwnerLease: lease, desktopControlState: .passive(owner)))
        }

        /// The state `presentMainWorkspaceUI` leaves behind before the initial load runs.
        private func drawLaunchPlaceholder(_ controller: AppKitController) {
            controller.showLoadingPlaceholder(message: "Loading projects and workspaces...", detail: "Spaces is preparing your workspace data.")
        }

        /// The launch placeholder's spinner, or nil once some pane render has emptied the container.
        private func launchSpinner(_ controller: AppKitController) -> NSProgressIndicator? {
            func walk(_ view: NSView) -> NSProgressIndicator? {
                if let spinner = view as? NSProgressIndicator { return spinner }
                for subview in view.subviews { if let found = walk(subview) { return found } }
                return nil
            }
            return walk(controller.detailContainer)
        }

        private func status(version: String, installedVersion: String?, protocolVersion: Int) -> TerminalServiceDaemonStatus {
            TerminalServiceDaemonStatus(
                version: version, installedVersion: installedVersion, certificateFingerprint: nil, activeSessionCount: 0,
                protocolVersion: protocolVersion)
        }

        /// The old daemon a Sparkle relaunch meets: too old to talk to, with the build the update just
        /// installed staged and waiting for a restart. Its remedy is `.applyStagedUpdate`, so the block
        /// is withheld while Spaces applies it silently.
        private func stagedUpdateIncompatibility() -> TerminalServiceDaemonWireIncompatibility {
            TerminalServiceDaemonWireIncompatibility(
                verdict: .daemonTooOld,
                status: status(version: "0.13.0", installedVersion: "0.14.0", protocolVersion: SpacesWireProtocol.version - 1),
                message: "The running spacesd daemon is older than this Spaces build.")
        }

        /// A daemon that is too old with nothing staged: only the user can resolve it, so the block is
        /// rendered rather than withheld.
        private func installUpdateIncompatibility() -> TerminalServiceDaemonWireIncompatibility {
            TerminalServiceDaemonWireIncompatibility(
                verdict: .daemonTooOld, status: status(version: "0.13.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version - 1),
                message: "The running spacesd daemon is older than this Spaces build.")
        }

        private func localDevice() -> SpacesPairedDeviceRecord {
            SpacesPairedDeviceRecord(
                id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", hosts: ["127.0.0.1"], port: 47847,
                certificateFingerprint: "fingerprint", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        }

        private func snapshot(daemonStatus: TerminalServiceDaemonStatus, compatibility: SpacesWireCompatibility)
            -> AppKitController.SidebarDataSnapshot
        {
            AppKitController.SidebarDataSnapshot(
                config: AppConfig(portRange: .default),
                local: AppKitController.LocalDeviceSidebarSnapshot(
                    projects: [], workspacesByProject: [:], workspaceRuntimeStatusByID: [:], alertsGroups: [],
                    localDeviceID: SpacesPairedDeviceRecord.localDeviceID, localDeviceName: "This Mac", localPairedDevice: localDevice(),
                    localDeviceOverview: SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: []), localDaemonStatus: daemonStatus,
                    localCompatibility: compatibility, localOfflineMessage: nil))
        }

        /// The daemon that comes back after the handoff, on the build the update staged.
        private func handedOffSnapshot() -> AppKitController.SidebarDataSnapshot {
            snapshot(
                daemonStatus: status(version: "0.14.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version),
                compatibility: .compatible)
        }

        @Test func aLaunchBlockedByAStagedDaemonUpdateLandsAlertsOnTheReloadAfterTheHandoff() async {
            let controller = makeController()
            drawLaunchPlaceholder(controller)
            controller.sidebar.loadSnapshotOverrideForTesting = {
                .failure(TerminalServiceError.daemonWireIncompatible(self.stagedUpdateIncompatibility()))
            }

            await controller.sidebar.loadInitialSidebarData()

            // Nothing is rendered for a staged update the app is already applying, so the launch
            // placeholder is still the whole detail pane.
            #expect(controller.detailPane == .none)
            #expect(launchSpinner(controller) != nil, "a withheld block leaves the launch placeholder on screen")

            // The daemon restarts onto the staged build and the handoff's reload succeeds. That reload is
            // the app's first chance to land a pane, and the placeholder stays up unless it takes it.
            controller.sidebar.loadSnapshotOverrideForTesting = { .success(self.handedOffSnapshot()) }
            controller.sidebar.requestSidebarReload()
            await controller.sidebar.drainSidebarRefreshForTesting()

            #expect(controller.detailPane == .alerts)
            #expect(launchSpinner(controller) == nil, "the landing must replace the launch placeholder")
        }

        @Test func aRenderedCompatibilityBlockSurvivesTheReloadThatWouldHaveLandedTheLaunch() async {
            let controller = makeController()
            drawLaunchPlaceholder(controller)
            controller.sidebar.loadSnapshotOverrideForTesting = {
                .failure(TerminalServiceError.daemonWireIncompatible(self.installUpdateIncompatibility()))
            }

            await controller.sidebar.loadInitialSidebarData()

            #expect(controller.detailPane == .compatibilityBlock(deviceID: SpacesPairedDeviceRecord.localDeviceID))

            // The device is still on the old build with nothing staged, so the block is still the right
            // surface. The owed landing must lapse rather than navigate away from what the user must act on.
            controller.sidebar.loadSnapshotOverrideForTesting = {
                .success(
                    self.snapshot(
                        daemonStatus: self.status(version: "0.13.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version - 1),
                        compatibility: .daemonTooOld))
            }
            controller.sidebar.requestSidebarReload()
            await controller.sidebar.drainSidebarRefreshForTesting()

            #expect(controller.detailPane == .compatibilityBlock(deviceID: SpacesPairedDeviceRecord.localDeviceID))
        }
    }
}
