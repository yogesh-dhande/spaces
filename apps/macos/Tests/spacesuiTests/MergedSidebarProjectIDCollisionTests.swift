import AppKit
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// #532: project ids are per-daemon UUIDs, so two device sections sharing one is not reachable
    /// through normal pairing. A profile database copied or restored across devices can produce the
    /// collision, and the merge in `AppKitController.mergedSidebarData` must resolve it the same way
    /// for every collection it builds, or `findWorkspace(id:)` can pair a workspace that survived the
    /// collision with the other device's `ProjectSummary`.
    ///
    /// Drives the real `AppKitController`/`SidebarController` merge path (`rebuildFlatSidebarData()` +
    /// `findWorkspace(id:)`) rather than reimplementing the resolution logic, since `project(id:)` is
    /// private to `SidebarController` and this is the only way to observe it end to end.
    @MainActor @Suite final class MergedSidebarProjectIDCollisionTests {
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

        /// A device section carrying one project (`sharedProjectID` on every call, so two sections can be
        /// made to collide) and that project's single workspace.
        private func section(deviceID: String, isLocal: Bool, projectIsHidden: Bool, workspaceID: String) -> AppKitController.DeviceSection {
            let projectID = "shared-project"
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: deviceID, isLocal: isLocal, loadState: .loaded, device: nil,
                projects: [
                    ProjectSummary(
                        id: projectID, name: "Shared", dir: "/\(deviceID)/shared", isGitRepo: true, defaultBranch: "main", isHidden: projectIsHidden,
                        deviceID: deviceID)
                ],
                workspacesByProject: [
                    projectID: [
                        WorkspaceSummary(
                            id: workspaceID, branch: "feature", dir: "/\(deviceID)/shared/feature", isRunning: true, isDefault: false, deviceID: deviceID)
                    ]
                ], workspaceRuntimeStatusByID: [:])
        }

        /// Same shared-project section as above, but with no workspaces at all -- `workspacesByProject`
        /// omits the project id entirely, which is what a project with zero workspaces on that device
        /// actually looks like.
        private func sectionWithNoWorkspaces(deviceID: String, isLocal: Bool, projectIsHidden: Bool) -> AppKitController.DeviceSection {
            let projectID = "shared-project"
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: deviceID, isLocal: isLocal, loadState: .loaded, device: nil,
                projects: [
                    ProjectSummary(
                        id: projectID, name: "Shared", dir: "/\(deviceID)/shared", isGitRepo: true, defaultBranch: "main", isHidden: projectIsHidden,
                        deviceID: deviceID)
                ], workspacesByProject: [:], workspaceRuntimeStatusByID: [:])
        }

        @Test func findWorkspacePairsASurvivingWorkspaceWithItsOwnSectionsProjectNotTheOtherDevices() throws {
            let controller = makeController()
            // Device A's project is visible; device B's copy of the same id is hidden. Device A is
            // installed first, so its workspace is the one first-wins keeps in `workspacesByProject`.
            let deviceA = section(deviceID: "device-a", isLocal: true, projectIsHidden: false, workspaceID: "ws-a")
            let deviceB = section(deviceID: "device-b", isLocal: false, projectIsHidden: true, workspaceID: "ws-b")
            controller.deviceModel.deviceSections = [deviceA, deviceB]
            controller.rebuildFlatSidebarData()

            // Device A's workspace survives the collision (first-wins) and must resolve against device
            // A's own project record -- not device B's hidden copy of the same id. Before the fix,
            // `projects` kept both copies and the id-keyed lookup that backs `findWorkspace` resolved the
            // last one installed (device B's, hidden), so a visible workspace silently paired with a
            // hidden project.
            let (project, workspace) = try #require(controller.findWorkspace(id: "ws-a"))
            #expect(workspace.deviceID == "device-a")
            #expect(project.deviceID == "device-a")
            #expect(project.isHidden == false)

            // Device B's workspace lost the collision entirely: it has no project row left to attach to,
            // so it must not resolve to a mismatched pairing either.
            #expect(controller.findWorkspace(id: "ws-b") == nil)
        }

        @Test func findWorkspaceDoesNotLeakAShadowedDevicesWorkspaceWhenTheWinningSectionHasNone() throws {
            // Device A wins the shared project id (it is first) but reports zero workspaces for it.
            // Device B, a shadowed copy of the same profile, reports one workspace under the same id.
            // Before the fix, `workspacesByProject.merge` only resolves first-wins for keys present in
            // both dicts -- a key device A's dict never wrote fell through to device B's value, so
            // device B's workspace ended up displayed under device A's (visible, winning) project row.
            let controller = makeController()
            let deviceA = sectionWithNoWorkspaces(deviceID: "device-a", isLocal: true, projectIsHidden: false)
            let deviceB = section(deviceID: "device-b", isLocal: false, projectIsHidden: true, workspaceID: "ws-b")
            controller.deviceModel.deviceSections = [deviceA, deviceB]
            controller.rebuildFlatSidebarData()

            // Device A's project record wins and shows no workspaces.
            #expect(controller.deviceModel.projects.map(\.id) == ["shared-project"])
            #expect(controller.deviceModel.projects.first?.deviceID == "device-a")
            #expect(controller.deviceModel.workspacesByProject["shared-project"] == [])

            // Device B's workspace must not resolve at all: it lost the collision, and its project id no
            // longer maps to device B's project row (device A's won), so it has nothing to pair with.
            #expect(controller.findWorkspace(id: "ws-b") == nil)
        }
    }
}
