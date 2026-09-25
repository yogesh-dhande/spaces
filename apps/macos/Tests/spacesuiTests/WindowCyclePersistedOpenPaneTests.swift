import AppKit
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Covers the Open sessions cycling mode's pane set for a workspace whose panel this launch has
    /// not restored, which after a relaunch is every workspace the user has not visited yet.
    ///
    /// Builds a real `AppKitController` the way `CodePanePlumbingTests` does (a fabricated
    /// lease/profile over a throwaway temp directory, so the suite never touches real lease state),
    /// then drives its `PanelCoordinator` directly. Nests under `ProcessProfileEnvironmentSuites`
    /// because it mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class WindowCyclePersistedOpenPaneTests {
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

        /// One local device with a workspace whose overview retains every session in `sessionIDs`, so a
        /// persisted pane for one of them survives the keep-set pruning a restore applies.
        private func section(deviceID: String, sessionIDs: [String], workspaceID: String = "workspace-1") -> AppKitController.DeviceSection {
            let workspace = SpacesDeviceWorkspaceSummary(
                id: workspaceID, projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/\(workspaceID)",
                isRunning: true, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: !sessionIDs.isEmpty, processRows: [],
                codingAgentRows: [])
            let overview = SpacesDeviceOverviewPayload(
                projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
                workspaces: [workspace],
                sessions: sessionIDs.map { sessionID in
                    SpacesDeviceTerminalSessionSummary(
                        id: sessionID, title: "shell", workingDirectory: "/tmp/\(workspaceID)", shell: "/bin/zsh", command: "/bin/zsh",
                        state: .running, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678,
                        workspaceID: workspaceID, workspaceTitle: "feature", projectID: "project-1", projectName: "Project",
                        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", isControlAvailable: true, isSubscriptionAvailable: true,
                        attachmentSnapshot: .init(), rowKind: .process)
                }, retainedTerminalSessionIDs: sessionIDs)
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        /// A tab holding `first`, split alongside `second`: the shape a user leaves behind when they quit
        /// with a split open, and the shape the mode has to enumerate before that workspace is visited.
        private func splitLayout(first: String, second: String, deviceID: String) -> PanelLayout {
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "pane-1", content: .terminalSession(deviceID: deviceID, sessionID: first)), to: PanelLayout())
            return PanelLayoutEngine.splitPane(
                paneID: "pane-1", direction: .right, newPane: Pane(id: "pane-2", content: .terminalSession(deviceID: deviceID, sessionID: second)),
                newSplitID: "split-1", in: layout) ?? layout
        }

        private func persist(_ layout: PanelLayout, deviceID: String, workspaceID: String, in controller: AppKitController) throws {
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: workspaceID, layoutJSON: json)
        }

        /// The relaunch case the Open sessions mode is defined over: the panes are open, nothing has
        /// selected their workspace yet, so the only record of them is the persisted layout.
        @Test func anUnrestoredWorkspaceReportsThePanesItsPersistedLayoutHolds() throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(deviceID: deviceID, sessionIDs: ["session-a", "session-b"])]
            controller.rebuildFlatSidebarData()
            try persist(
                splitLayout(first: "session-a", second: "session-b", deviceID: deviceID), deviceID: deviceID, workspaceID: "workspace-1",
                in: controller)

            let byWorkspace = controller.panelCoordinator.openTerminalSessionIDsByWorkspace(includingPersistedLayoutsFor: [
                PanelLayoutEngine.WorkspaceKey(deviceID: deviceID, workspaceID: "workspace-1")
            ])

            #expect(byWorkspace["workspace-1"] == ["session-a", "session-b"])
            #expect(
                controller.panelCoordinator.openTerminalSessionIDsByWorkspace().isEmpty,
                "reading the layout must not restore the panel, which would attach sessions the user never asked for")
        }

        /// A workspace the user left with nothing open has no layout row at all, and contributes no
        /// target rather than an empty entry.
        @Test func aWorkspaceWithNoPersistedLayoutReportsNothing() {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(deviceID: deviceID, sessionIDs: ["session-a"])]
            controller.rebuildFlatSidebarData()

            let byWorkspace = controller.panelCoordinator.openTerminalSessionIDsByWorkspace(includingPersistedLayoutsFor: [
                PanelLayoutEngine.WorkspaceKey(deviceID: deviceID, workspaceID: "workspace-1")
            ])

            #expect(byWorkspace.isEmpty)
        }

        /// A session the persisted layout still names but the daemon no longer retains is not a pane the
        /// relaunch would reopen, so it is not a cycle target either: the same keep-set pruning a restore
        /// applies runs here.
        @Test func aPersistedPaneWhoseSessionIsGoneIsNotReported() throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(deviceID: deviceID, sessionIDs: ["session-a"])]
            controller.rebuildFlatSidebarData()
            try persist(
                splitLayout(first: "session-a", second: "session-gone", deviceID: deviceID), deviceID: deviceID, workspaceID: "workspace-1",
                in: controller)

            let byWorkspace = controller.panelCoordinator.openTerminalSessionIDsByWorkspace(includingPersistedLayoutsFor: [
                PanelLayoutEngine.WorkspaceKey(deviceID: deviceID, workspaceID: "workspace-1")
            ])

            #expect(byWorkspace["workspace-1"] == ["session-a"])
        }

        /// The count is read on every sidebar apply, so an unrestored workspace's persisted layout is
        /// read once and cached. A rewrite of that layout, which is what putting a restored session back
        /// in its predecessor's slot does, has to reach the next count.
        @Test func aRewrittenPersistedLayoutIsReportedByTheNextRead() throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(deviceID: deviceID, sessionIDs: ["session-a", "session-b"])]
            controller.rebuildFlatSidebarData()
            try persist(
                splitLayout(first: "session-a", second: "session-b", deviceID: deviceID), deviceID: deviceID, workspaceID: "workspace-1",
                in: controller)
            let keys = [PanelLayoutEngine.WorkspaceKey(deviceID: deviceID, workspaceID: "workspace-1")]
            #expect(
                controller.panelCoordinator.openTerminalSessionIDsByWorkspace(includingPersistedLayoutsFor: keys)["workspace-1"] == [
                    "session-a", "session-b",
                ])

            controller.deviceModel.deviceSections = [section(deviceID: deviceID, sessionIDs: ["session-a", "session-restored"])]
            controller.rebuildFlatSidebarData()
            #expect(
                controller.retargetPersistedWorkspacePanelLayoutPane(
                    deviceID: deviceID, workspaceID: "workspace-1", replacing: "session-b",
                    with: .terminalSession(deviceID: deviceID, sessionID: "session-restored")))

            #expect(
                controller.panelCoordinator.openTerminalSessionIDsByWorkspace(includingPersistedLayoutsFor: keys)["workspace-1"] == [
                    "session-a", "session-restored",
                ])
        }

        /// A session stops being retained without anything writing the layout it is named in, so the
        /// pruning has to run on every read rather than once with the layout: a cycle press must never
        /// be offered a pane a relaunch would not reopen.
        @Test func aPaneWhoseSessionStopsBeingRetainedDropsWithoutALayoutWrite() throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(deviceID: deviceID, sessionIDs: ["session-a", "session-b"])]
            controller.rebuildFlatSidebarData()
            try persist(
                splitLayout(first: "session-a", second: "session-b", deviceID: deviceID), deviceID: deviceID, workspaceID: "workspace-1",
                in: controller)
            let keys = [PanelLayoutEngine.WorkspaceKey(deviceID: deviceID, workspaceID: "workspace-1")]
            #expect(
                controller.panelCoordinator.openTerminalSessionIDsByWorkspace(includingPersistedLayoutsFor: keys)["workspace-1"] == [
                    "session-a", "session-b",
                ])

            controller.deviceModel.deviceSections = [section(deviceID: deviceID, sessionIDs: ["session-a"])]
            controller.rebuildFlatSidebarData()

            #expect(controller.panelCoordinator.openTerminalSessionIDsByWorkspace(includingPersistedLayoutsFor: keys)["workspace-1"] == ["session-a"])
        }
    }
}
