import AppKit
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// A focus request that arrives before the app has caught up with a just-started process must wait
    /// for the app's next sidebar snapshot instead of being refused (issue #357).
    ///
    /// Drives the resolution step, which is the part that was refusing: the controller looks for the
    /// process in the snapshot it holds, finds it configured but not running, waits for the reload it
    /// asked for to apply, and resolves against what that reload brought. The window summon that follows
    /// a resolved target needs a real terminal pane and a real daemon behind it, so it is not exercised
    /// here.
    ///
    /// Builds a real `AppKitController` the way `PanelReplacementHoldTests` does (a fabricated
    /// lease/profile pointing at a throwaway directory) and nests under `ProcessProfileEnvironmentSuites`
    /// because it mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class AppKitControllerFocusAfterReloadTests {
        private static let projectID = "project-1"
        private static let workspaceID = "workspace-1"
        private static let processName = "backend"
        private static let processID = "process-backend"

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

        private func localDevice() -> SpacesPairedDeviceRecord {
            SpacesPairedDeviceRecord(
                id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", hosts: ["127.0.0.1"], port: 47847,
                certificateFingerprint: "fingerprint", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        }

        /// The workspace as the daemon reports it before and after `workspace start`: the process is
        /// configured either way, and only the running row (its process and session ids) arrives with the
        /// start.
        private func overview(processIsRunning: Bool) -> SpacesDeviceOverviewPayload {
            let workspace = SpacesDeviceWorkspaceSummary(
                id: Self.workspaceID, projectID: Self.projectID, projectName: "Project", branch: "feature", baseBranch: "main",
                dir: "/tmp/project-feature", isRunning: processIsRunning, isHidden: false, isDefault: false, sessionCount: processIsRunning ? 1 : 0,
                config: SpacesDeviceWorkspaceConfig(processes: [
                    SpacesDeviceProcessTemplate(id: "template-backend", name: Self.processName, command: "npm run dev")
                ]),
                processRows: [
                    SpacesDeviceWorkspaceProcessRow(
                        id: "row-backend", workspaceID: Self.workspaceID, name: Self.processName, command: "npm run dev",
                        templateID: "template-backend", processID: processIsRunning ? Self.processID : nil,
                        sessionID: processIsRunning ? "session-backend" : nil, runState: processIsRunning ? .running : .notStarted, canRun: true,
                        canStop: processIsRunning, canRestart: processIsRunning)
                ])
            return SpacesDeviceOverviewPayload(
                projects: [
                    SpacesDeviceProjectSummary(id: Self.projectID, name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")
                ], workspaces: [workspace], sessions: [])
        }

        private func section(overview: SpacesDeviceOverviewPayload, deviceID: String) -> AppKitController.DeviceSection {
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: localDevice(), projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        private func snapshot(overview: SpacesDeviceOverviewPayload, deviceID: String) -> AppKitController.SidebarDataSnapshot {
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.SidebarDataSnapshot(
                config: AppConfig(portRange: .default),
                local: AppKitController.LocalDeviceSidebarSnapshot(
                    projects: mapped.projects, workspacesByProject: mapped.workspacesByProject,
                    workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, alertsGroups: [], localDeviceID: deviceID,
                    localDeviceName: "This Mac", localPairedDevice: localDevice(), localDeviceOverview: overview, localDaemonStatus: .testStatus,
                    localCompatibility: .compatible, localOfflineMessage: nil))
        }

        /// The measured failure: the app is holding the pre-start snapshot when the focus arrives, so the
        /// process is only a configured target and the old resolution answered `no_match`. The focus now
        /// waits for the reload it triggers and resolves against the running row that reload brings.
        @Test func aProcessFocusThatMissesTheCurrentSnapshotResolvesAgainstTheNextOne() async throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(overview: overview(processIsRunning: false), deviceID: deviceID)]
            controller.sidebar.applySidebarDataChange()

            let staleTargets = try #require(controller.focusableWindowContext(workspaceID: Self.workspaceID)?.targets)
            #expect(
                staleTargets.map(\.kind) == [.missingConfiguredProcess],
                "precondition: the snapshot on screen has the process configured but not running")

            let runningSnapshot = snapshot(overview: overview(processIsRunning: true), deviceID: deviceID)
            controller.sidebar.loadSnapshotOverrideForTesting = { .success(runningSnapshot) }

            let resolved = await controller.processFocusMatch(workspaceID: Self.workspaceID, processName: Self.processName)

            #expect(resolved.retried, "the miss must be retried against a fresh snapshot rather than refused")
            let target = try #require(resolved.value?.target)
            #expect(target.kind == .process)
            #expect(target.processID == Self.processID)
        }

        /// The retry is one snapshot, not a loop: a process the daemon never started stays unresolved, so
        /// the focus still refuses instead of hanging on reload after reload.
        @Test func aProcessThatIsStillNotRunningAfterTheFreshSnapshotStaysUnresolved() async throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(overview: overview(processIsRunning: false), deviceID: deviceID)]
            controller.sidebar.applySidebarDataChange()

            let stoppedSnapshot = snapshot(overview: overview(processIsRunning: false), deviceID: deviceID)
            var loads = 0
            controller.sidebar.loadSnapshotOverrideForTesting = {
                loads += 1
                return .success(stoppedSnapshot)
            }

            let resolved = await controller.processFocusMatch(workspaceID: Self.workspaceID, processName: Self.processName)

            #expect(resolved.value == nil)
            #expect(resolved.retried)
            #expect(loads == 1, "one fresh snapshot, one retry")
        }

        /// A minimal terminal-open request for a session no snapshot has ever seen, pinned to `deviceID`
        /// so device reachability never depends on the sidebar's index (which is exactly the thing these
        /// two tests vary). `openTerminalSessionPane` is called with `openIntent: .withoutFocus`, not the
        /// `.focused` every production caller uses, because a focusing refusal shows a real
        /// `NSAlert.runModal()` for the device-unavailable case below; a unit test process must never
        /// trigger that.
        private func openRequest(deviceID: String, sessionID: String) -> AppKitController.DeviceTerminalOpenRequest {
            AppKitController.DeviceTerminalOpenRequest(
                workspaceID: Self.workspaceID, deviceID: deviceID, sessionID: sessionID, title: sessionID, workingDirectory: "/tmp", kind: .shell)
        }

        /// The review finding this covers: `openOrFocusTerminalPane` also returns nil when the device
        /// cannot service the open (already reported here, since `mayActOnTerminalPane` calls
        /// `showTerminalOpenRequestDeviceUnavailableError`) or when content construction fails, neither of
        /// which is a stale-snapshot problem. Retrying either would only repeat the same refusal, so the
        /// gate must not fire when `workspaceScope(forWorkspaceID:)` is already present.
        @Test func anOpenRefusedWithTheWorkspaceScopeAlreadyKnownDoesNotReload() async throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            // The workspace is in the sidebar's own index (scope present), but its device section is
            // offline, so `mayActOnTerminalPane` refuses the open: a real refusal, not a stale snapshot.
            var offlineSection = section(overview: overview(processIsRunning: false), deviceID: deviceID)
            offlineSection.loadState = .offline("test")
            controller.deviceModel.deviceSections = [offlineSection]
            controller.sidebar.applySidebarDataChange()
            #expect(controller.panelCoordinator.workspaceScope(forWorkspaceID: Self.workspaceID) != nil, "precondition: scope is already known")

            var loads = 0
            controller.sidebar.loadSnapshotOverrideForTesting = {
                loads += 1
                return .success(self.snapshot(overview: self.overview(processIsRunning: false), deviceID: deviceID))
            }

            let opened = await controller.openTerminalSessionPane(
                sessionID: "session-new", mode: .owner, openIntent: TerminalPaneOpenIntent(focus: .withoutFocus),
                resolvedRequest: openRequest(deviceID: deviceID, sessionID: "session-new"))

            #expect(!opened)
            #expect(loads == 0, "a refusal the scope already explains must not trigger a reload")
        }

        /// The companion case the gate must still allow: a workspace the sidebar's index does not know
        /// about yet (the just-created-workspace case issue #357 is about) is retried after a reload, the
        /// same as before this gate existed.
        @Test func anOpenRefusedWithTheWorkspaceScopeNotYetKnownRetriesOnce() async throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            // No `deviceSections`/sidebar index at all: `workspaceScope(forWorkspaceID:)` is nil, the
            // just-created-workspace case. The pinned `deviceID` alone is enough for `mayActOnTerminalPane`
            // to allow the local device before any section exists.
            var loads = 0
            let emptyOverview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])
            controller.sidebar.loadSnapshotOverrideForTesting = {
                loads += 1
                return .success(self.snapshot(overview: emptyOverview, deviceID: deviceID))
            }

            let opened = await controller.openTerminalSessionPane(
                sessionID: "session-new", mode: .owner, openIntent: TerminalPaneOpenIntent(focus: .withoutFocus),
                resolvedRequest: openRequest(deviceID: deviceID, sessionID: "session-new"))

            #expect(!opened, "the reload snapshot still does not carry the workspace, so the retry stays unresolved")
            #expect(loads == 1, "the scope being unknown is retried exactly once")
        }
    }
}
