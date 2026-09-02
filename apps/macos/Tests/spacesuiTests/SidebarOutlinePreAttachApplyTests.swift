import AppKit
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// A sidebar data change applied before the window build attaches the outline's data source (an
    /// IPC-triggered reload racing the deferred launch build, issue #581) must not advance the paint
    /// baseline, or the outline is left permanently missing rows it never got the chance to paint.
    ///
    /// Builds a real `AppKitController` the way `AppKitControllerFocusAfterReloadTests` does (a
    /// fabricated lease/profile pointing at a throwaway directory) and nests under
    /// `ProcessProfileEnvironmentSuites` because it mutates the process-global
    /// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class SidebarOutlinePreAttachApplyTests {
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

        /// The workspace as the daemon reports it, with one configured (not running) process. The pane
        /// content itself is irrelevant here; only the resulting project/workspace row count matters.
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

        /// A sidebar data change applied before the window build attaches the outline's data source
        /// (an IPC-triggered reload racing the deferred launch build, issue #581) must not advance the
        /// paint baseline, and the attach itself must repaint what the skipped apply enumerated: a
        /// later refresh with an identical payload takes the unchanged path and would never paint it,
        /// leaving the outline permanently missing rows.
        @Test func aDataChangeAppliedBeforeTheOutlineAttachesRepaintsWholesaleOnAttach() throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(overview: overview(processIsRunning: false), deviceID: deviceID)]

            controller.sidebar.applySidebarDataChange()
            #expect(controller.outlineView.numberOfRows == 0, "precondition: nothing can paint before the data source is attached")

            // The column setup `makeLeftPane` performs, so the attached outline materializes rows.
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            controller.outlineView.addTableColumn(column)
            controller.outlineView.outlineTableColumn = column
            controller.sidebar.attachOutlineView(controller.outlineView)

            #expect(
                controller.outlineView.numberOfRows == 2,
                "the attach must paint the project row and its workspace row itself; no further data change is owed")
        }
    }
}
