import AppKit
import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Selecting a workspace has to work from anywhere, including from a cycling mode, an alert, or the
    /// command palette, all of which can land in a workspace the user is not looking at. A collapsed git
    /// project materializes no rows for its workspaces, so the selection has no row to land on until the
    /// project is expanded.
    ///
    /// Drives the real `NSOutlineView` the way `SidebarSelectionAcrossReloadTests` does, because the
    /// question is which row AppKit ends up with selected, and nothing short of the real view answers it.
    /// Nests under `ProcessProfileEnvironmentSuites` for the same reason those suites do: it mutates the
    /// process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class SidebarCollapsedProjectSelectionTests {
        private static let projectID = "project-1"
        private static let workspaceID = "workspace-1"

        private let root: URL
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private var window: NSWindow?

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

        /// A cross-workspace landing (a cycling mode, an alert, the command palette) selects a workspace
        /// whose project the user left collapsed. The project opens and the workspace's own row ends up
        /// selected, instead of the sidebar silently keeping whatever was selected before.
        @Test func selectingAWorkspaceUnderACollapsedProjectExpandsItAndSelectsItsRow() throws {
            let controller = makeController()
            attachOutline(controller)
            controller.deviceModel.deviceSections = [section(controller: controller, isGitRepo: true, isCollapsed: true)]
            controller.sidebar.applySidebarDataChange()
            #expect(materializedWorkspaceRow(controller) == nil, "a collapsed project materializes no row for its workspaces")

            let summary = try #require(controller.sidebar.findWorkspace(id: Self.workspaceID)?.1)
            controller.sidebar.selectWorkspace(summary)

            #expect(controller.deviceModel.projects.first { $0.id == Self.projectID }?.isCollapsed == false, "the owning project is expanded")
            let selectedRow = try #require(materializedWorkspaceRow(controller))
            #expect(controller.outlineView.selectedRow == selectedRow)
            #expect(controller.selectedWorkspaceID == Self.workspaceID)
        }

        /// A non-git project's row stands in for its single workspace, so that row is already on screen
        /// whatever the collapse state: the selection lands on it and nothing is expanded.
        @Test func selectingANonGitProjectsWorkspaceSelectsItsStandInRowWithoutExpanding() throws {
            let controller = makeController()
            attachOutline(controller)
            controller.deviceModel.deviceSections = [section(controller: controller, isGitRepo: false, isCollapsed: true)]
            controller.sidebar.applySidebarDataChange()

            let summary = try #require(controller.sidebar.findWorkspace(id: Self.workspaceID)?.1)
            controller.sidebar.selectWorkspace(summary)

            #expect(controller.deviceModel.projects.first { $0.id == Self.projectID }?.isCollapsed == true)
            let selectedRow = controller.outlineView.selectedRow
            #expect(selectedRow >= 0)
            let ref = try #require(controller.outlineView.item(atRow: selectedRow) as? AppKitController.OutlineItemRef)
            #expect(ref.item == .project(projectSummary(deviceID: controller.deviceModel.localDeviceID, isGitRepo: false)))
            #expect(controller.selectedWorkspaceID == Self.workspaceID)
        }

        // MARK: - Fixtures

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

        private func attachOutline(_ controller: AppKitController) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            controller.outlineView.addTableColumn(column)
            controller.outlineView.outlineTableColumn = column
            controller.outlineView.headerView = nil
            controller.outlineView.rowSizeStyle = .medium
            controller.outlineView.style = .plain
            controller.outlineView.indentationPerLevel = 0
            controller.sidebar.attachOutlineView(controller.outlineView)

            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.documentView = controller.outlineView
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            self.window = window
        }

        /// The outline row carrying the workspace's own `.workspace` item, or nil while none is
        /// materialized.
        private func materializedWorkspaceRow(_ controller: AppKitController) -> Int? {
            for row in 0..<controller.outlineView.numberOfRows {
                guard let ref = controller.outlineView.item(atRow: row) as? AppKitController.OutlineItemRef else { continue }
                if case .workspace(_, let workspace) = ref.item, workspace.id == Self.workspaceID { return row }
            }
            return nil
        }

        private func projectSummary(deviceID: String, isGitRepo: Bool) -> ProjectSummary {
            ProjectSummary(
                id: Self.projectID, name: "Project", dir: "/tmp/project", isGitRepo: isGitRepo, defaultBranch: "main", isHidden: false,
                isCollapsed: false, deviceID: deviceID)
        }

        private func section(controller: AppKitController, isGitRepo: Bool, isCollapsed: Bool) -> AppKitController.DeviceSection {
            let deviceID = controller.deviceModel.localDeviceID
            let overview = SpacesDeviceOverviewPayload(
                projects: [
                    SpacesDeviceProjectSummary(id: Self.projectID, name: "Project", dir: "/tmp/project", isGitRepo: isGitRepo, defaultBranch: "main")
                ],
                workspaces: [
                    SpacesDeviceWorkspaceSummary(
                        id: Self.workspaceID, projectID: Self.projectID, projectName: "Project", branch: "feature", baseBranch: "main",
                        dir: "/tmp/project-feature", isRunning: true, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false,
                        codingAgentRows: [], terminalRows: [])
                ], sessions: [])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID, projectCollapseStates: [Self.projectID: isCollapsed])
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }
    }
}
