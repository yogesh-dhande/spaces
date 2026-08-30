import AppKit
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// A terminal runtime signal carries device-overview content, not config or pairing changes. It must
    /// therefore fetch and apply only This Mac's overview; routing it through the full snapshot loader is
    /// the regression that made an agent's animated title rebuild every device section several times a
    /// second.
    @MainActor @Suite final class SidebarLocalOverviewRefreshTests {
        private static let projectID = "project-1"
        private static let workspaceID = "workspace-1"
        private static let sessionID = "session-1"

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

        private func localDevice() -> SpacesPairedDeviceRecord {
            SpacesPairedDeviceRecord(
                id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", hosts: ["127.0.0.1"], port: 47847,
                certificateFingerprint: "fingerprint", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        }

        private func overview(liveTitle: String?) -> SpacesDeviceOverviewPayload {
            let workspace = SpacesDeviceWorkspaceSummary(
                id: Self.workspaceID, projectID: Self.projectID, projectName: "Project", branch: "feature", baseBranch: "main",
                dir: "/tmp/project-feature", isRunning: true, isHidden: false, isDefault: false, sessionCount: 1,
                terminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-1", workspaceID: Self.workspaceID, title: "shell", workingDirectory: "/tmp/project-feature",
                        sessionID: Self.sessionID, runState: .running, canOpenTerminal: true, canStop: true, liveTitle: liveTitle)
                ])
            return SpacesDeviceOverviewPayload(
                projects: [
                    SpacesDeviceProjectSummary(id: Self.projectID, name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")
                ], workspaces: [workspace], sessions: [])
        }

        private func overview(_ base: SpacesDeviceOverviewPayload, addingWorkspaceID workspaceID: String) -> SpacesDeviceOverviewPayload {
            let workspace = SpacesDeviceWorkspaceSummary(
                id: workspaceID, projectID: Self.projectID, projectName: "Project", branch: "created", baseBranch: "main",
                dir: "/tmp/project-created", isRunning: true, isHidden: false, isDefault: false, sessionCount: 0)
            return SpacesDeviceOverviewPayload(
                projects: base.projects, workspaces: base.workspaces + [workspace], sessions: base.sessions,
                retainedTerminalSessionIDs: base.retainedTerminalSessionIDs,
                workspaceIDsWithTeardownInFlight: base.workspaceIDsWithTeardownInFlight, daemonStatus: base.daemonStatus,
                automations: base.automations, automationRuns: base.automationRuns)
        }

        private func section(overview: SpacesDeviceOverviewPayload) -> AppKitController.DeviceSection {
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: SpacesPairedDeviceRecord.localDeviceID)
            return AppKitController.DeviceSection(
                deviceID: SpacesPairedDeviceRecord.localDeviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: localDevice(),
                projects: mapped.projects, workspacesByProject: mapped.workspacesByProject,
                workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview, daemonStatus: .testStatus,
                compatibility: .compatible)
        }

        private func fullSnapshot(overview: SpacesDeviceOverviewPayload) -> AppKitController.SidebarDataSnapshot {
            AppKitController.SidebarDataSnapshot(config: AppConfig(portRange: .default), local: localSnapshot(overview: overview))
        }

        private func localSnapshot(overview: SpacesDeviceOverviewPayload) -> AppKitController.LocalDeviceSidebarSnapshot {
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: SpacesPairedDeviceRecord.localDeviceID)
            return AppKitController.LocalDeviceSidebarSnapshot(
                projects: mapped.projects, workspacesByProject: mapped.workspacesByProject,
                workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, alertsGroups: [],
                localDeviceID: SpacesPairedDeviceRecord.localDeviceID, localDeviceName: "This Mac", localPairedDevice: localDevice(),
                localDeviceOverview: overview, localDaemonStatus: .testStatus, localCompatibility: .compatible, localOfflineMessage: nil)
        }

        @Test func terminalOverviewSignalUsesTheLocalOverviewLaneInsteadOfTheFullSnapshotLoader() async throws {
            let controller = makeController()
            let before = overview(liveTitle: nil)
            let after = overview(liveTitle: "vim main.swift")
            controller.deviceSections = [section(overview: before)]
            controller.localPairedDevice = localDevice()
            controller.sidebar.applySidebarDataSnapshot(fullSnapshot(overview: before))

            var fullSnapshotLoads = 0
            controller.sidebar.loadSnapshotOverrideForTesting = {
                fullSnapshotLoads += 1
                return .success(self.fullSnapshot(overview: before))
            }
            controller.sidebar.localOverviewLoadOverrideForTesting = { .success(self.localSnapshot(overview: after)) }

            controller.sidebar.handleTerminalOverviewDidChange()
            await controller.sidebar.drainSidebarRefreshForTesting()

            #expect(fullSnapshotLoads == 0, "A terminal-only change must not read config or rebuild the full snapshot.")
            #expect(controller.deviceSections.first?.overview == after)
            let row = try #require(controller.deviceSections.first?.overview?.workspaces.first?.terminalRows.first)
            #expect(row.liveTitle == "vim main.swift")
        }

        @Test func terminalSignalRetainsFullScopeUntilColdStartHasAppliedAFullSnapshot() async {
            let controller = makeController()
            let after = overview(liveTitle: "recovered")
            var fullSnapshotLoads = 0
            var localOverviewLoads = 0
            controller.sidebar.loadSnapshotOverrideForTesting = {
                fullSnapshotLoads += 1
                return .success(self.fullSnapshot(overview: after))
            }
            controller.sidebar.localOverviewLoadOverrideForTesting = {
                localOverviewLoads += 1
                return .success(self.localSnapshot(overview: after))
            }

            controller.sidebar.handleTerminalOverviewDidChange()
            await controller.sidebar.drainSidebarRefreshForTesting()

            #expect(fullSnapshotLoads == 1)
            #expect(localOverviewLoads == 0)
            #expect(controller.deviceSections.first?.overview == after)
        }

        @Test func staleLocalReloadCannotDeleteRecoveryStateForWorkspaceInstalledByMutation() async throws {
            let controller = makeController()
            let staleOverview = overview(liveTitle: nil)
            controller.deviceSections = [section(overview: staleOverview)]
            controller.localPairedDevice = localDevice()

            let createdWorkspaceID = "workspace-created"
            let storageKey = ClientCodePaneWorkspaceStateStorage.storageKey(deviceID: SpacesPairedDeviceRecord.localDeviceID)
            CodePaneWorkspaceStateCache.store(
                CodePaneWorkspaceState(mode: .editor, editorState: nil, pendingReviewComments: nil),
                storageKey: storageKey, workspaceID: createdWorkspaceID)
            defer { CodePaneWorkspaceStateCache.remove(storageKey: storageKey, workspaceID: createdWorkspaceID) }

            var releaseSnapshot: CheckedContinuation<Result<AppKitController.SidebarDataSnapshot, any Error>, Never>?
            controller.sidebar.loadSnapshotOverrideForTesting = {
                await withCheckedContinuation { continuation in
                    releaseSnapshot = continuation
                }
            }
            controller.sidebar.requestSidebarReload()
            while releaseSnapshot == nil { await Task.yield() }

            // The mutation response is authoritative and installs the workspace while the older
            // sidebar read is still in flight. Releasing that read afterward reproduces the stale
            // `liveWorkspaceIDs`/`previousLocalSection` ordering that used to delete valid state.
            let currentOverview = overview(staleOverview, addingWorkspaceID: createdWorkspaceID)
            let response = SpacesDeviceAPIResponse(
                ok: true, message: "ok", result: .mutation(SpacesDeviceMutationResult(overview: currentOverview)))
            controller.applyDeviceMutationResponse(
                response, deviceID: SpacesPairedDeviceRecord.localDeviceID, epoch: controller.panelCoordinator.paneReplacementEpoch)
            #expect(controller.deviceWorkspaceSummary(workspaceID: createdWorkspaceID) != nil)

            releaseSnapshot!.resume(returning: .success(fullSnapshot(overview: staleOverview)))
            await controller.sidebar.drainSidebarRefreshForTesting()

            #expect(controller.deviceWorkspaceSummary(workspaceID: createdWorkspaceID) != nil)
            #expect(CodePaneWorkspaceStateCache.state(storageKey: storageKey, workspaceID: createdWorkspaceID) != nil)
        }
    }
}
