import AppKit
import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Leader-arrow navigation walks Alerts, Automations, then the workspace rows, and it reads the
    /// detail pane to know which of those the user is currently on. Presenting Automations clears the
    /// outline selection, and that `deselectAll` re-enters the selection delegate synchronously, so the
    /// pane state has to survive its own presentation: a placeholder raised from that re-entry leaves
    /// Automations rendered but no longer identified as showing, and navigation then has neither a pane
    /// nor a selected row to move from. This suite drives the real controller through that sequence.
    ///
    /// Builds an `AppKitController` the way `SidebarRowRepaintTests` does (a fabricated lease/profile
    /// over a throwaway temp directory) and nests under `ProcessProfileEnvironmentSuites` for the same
    /// reason: it mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class SidebarAutomationsNavigationTests {
        private static let projectID = "project-1"
        private static let firstWorkspaceID = "workspace-1"
        private static let secondWorkspaceID = "workspace-2"

        private let root: URL
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        /// The outline resolves rows only inside a window, so the suite owns one for its lifetime. It is
        /// never ordered front.
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

        /// Mirrors the outline wiring in `AppKitController.makeLeftPane` without the surrounding sidebar
        /// chrome: a column, the controller as delegate and data source, and a scroll view in a window.
        private func attachOutline(_ controller: AppKitController) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            controller.outlineView.addTableColumn(column)
            controller.outlineView.outlineTableColumn = column
            controller.outlineView.headerView = nil
            controller.outlineView.style = .plain
            controller.sidebar.attachOutlineView(controller.outlineView)

            let scroll = NSScrollView()
            scroll.documentView = controller.outlineView
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            self.window = window
        }

        private func workspace(id: String, branch: String) -> SpacesDeviceWorkspaceSummary {
            SpacesDeviceWorkspaceSummary(
                id: id, projectID: Self.projectID, projectName: "Project", branch: branch, baseBranch: "main", dir: "/tmp/project-\(branch)",
                isRunning: false, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false, codingAgentRows: [], terminalRows: [])
        }

        /// One local device with a single git project holding two workspaces, so navigation has a row to
        /// arrive back on after Automations.
        private func section(deviceID: String) -> AppKitController.DeviceSection {
            let overview = SpacesDeviceOverviewPayload(
                projects: [
                    SpacesDeviceProjectSummary(id: Self.projectID, name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")
                ], workspaces: [workspace(id: Self.firstWorkspaceID, branch: "feature"), workspace(id: Self.secondWorkspaceID, branch: "fix")],
                sessions: [])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        private func loadedController() -> AppKitController {
            let controller = makeController()
            attachOutline(controller)
            controller.deviceModel.deviceSections = [section(deviceID: controller.deviceModel.localDeviceID)]
            controller.sidebar.applySidebarDataChange()
            return controller
        }

        @Test func upArrowFromTheFirstWorkspaceLeavesAutomationsShowing() throws {
            let controller = loadedController()
            let first = try #require(controller.deviceModel.workspacesByProject[Self.projectID]?.first, "the project must list its workspaces")
            controller.sidebar.selectWorkspace(first)
            #expect(controller.selectedWorkspaceID == Self.firstWorkspaceID)

            #expect(controller.sidebar.navigateSidebarSelection(direction: -1), "the first workspace's up target is the Automations row")

            #expect(controller.showingAutomations, "presenting Automations clears the outline selection and must survive that re-entry")
            #expect(controller.selectedWorkspaceID == nil)
        }

        @Test func arrowNavigationKeepsMovingAfterLandingOnAutomations() throws {
            let controller = loadedController()
            let first = try #require(controller.deviceModel.workspacesByProject[Self.projectID]?.first, "the project must list its workspaces")
            controller.sidebar.selectWorkspace(first)
            #expect(controller.sidebar.navigateSidebarSelection(direction: -1))

            #expect(controller.sidebar.navigateSidebarSelection(direction: 1), "down from Automations returns to the first workspace")
            #expect(controller.selectedWorkspaceID == Self.firstWorkspaceID)

            #expect(controller.sidebar.navigateSidebarSelection(direction: -1))
            #expect(controller.sidebar.navigateSidebarSelection(direction: -1), "up from Automations reaches Alerts")
            #expect(controller.showingAlerts)
        }

        /// A device with a home project and two standard git projects, named so the daemon's own
        /// `ORDER BY name` (alphabetic, `~` last) disagrees with the outline's order (home first): this is
        /// what distinguishes the navigation sequence from a device where hoisting made no difference.
        private func homeAndStandardSection(deviceID: String) -> AppKitController.DeviceSection {
            let homeProjectID = "home"
            let alphaProjectID = "project-alpha"
            let betaProjectID = "project-beta"
            let overview = SpacesDeviceOverviewPayload(
                projects: [
                    SpacesDeviceProjectSummary(id: alphaProjectID, name: "alpha", dir: "/tmp/alpha", isGitRepo: true, defaultBranch: "main"),
                    SpacesDeviceProjectSummary(id: betaProjectID, name: "beta", dir: "/tmp/beta", isGitRepo: true, defaultBranch: "main"),
                    SpacesDeviceProjectSummary(
                        id: homeProjectID, name: "~", dir: "/Users/someone", isGitRepo: false, defaultBranch: nil, kind: .home),
                ],
                workspaces: [
                    SpacesDeviceWorkspaceSummary(
                        id: "alpha-workspace", projectID: alphaProjectID, projectName: "alpha", branch: "feature", baseBranch: "main",
                        dir: "/tmp/alpha", isRunning: false, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false),
                    SpacesDeviceWorkspaceSummary(
                        id: "beta-workspace", projectID: betaProjectID, projectName: "beta", branch: "feature", baseBranch: "main", dir: "/tmp/beta",
                        isRunning: false, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false),
                    SpacesDeviceWorkspaceSummary(
                        id: "home-workspace", projectID: homeProjectID, projectName: "~", projectKind: .home, branch: nil, baseBranch: nil,
                        dir: "/Users/someone", isRunning: false, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false),
                ], sessions: [])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        private func loadedHomeRowController() -> AppKitController {
            let controller = makeController()
            attachOutline(controller)
            controller.deviceModel.deviceSections = [homeAndStandardSection(deviceID: controller.deviceModel.localDeviceID)]
            controller.sidebar.applySidebarDataChange()
            // Landing on the home row also starts a terminal in it when none is running
            // (`autoOpenHomeTerminalIfNeeded`), which asks a daemon this process does not have. These
            // tests are about where the arrow keys land, so that creation is stubbed out here.
            controller.createWorkspaceTerminalSessionOverrideForTesting = { _, _ in }
            return controller
        }

        @Test func downArrowFromAutomationsWalksTheHomeRowFirstThenTheStandardProjectsInOutlineOrder() throws {
            let controller = loadedHomeRowController()
            let home = try #require(controller.deviceModel.workspacesByProject["home"]?.first, "the home project must list its workspace")
            controller.sidebar.selectWorkspace(home)
            #expect(controller.sidebar.navigateSidebarSelection(direction: -1), "up from the first row, the home row, reaches Automations")

            #expect(controller.sidebar.navigateSidebarSelection(direction: 1), "the home row opens the device section, same as the outline")
            #expect(controller.selectedWorkspaceID == "home-workspace")

            #expect(controller.sidebar.navigateSidebarSelection(direction: 1))
            #expect(controller.selectedWorkspaceID == "alpha-workspace", "alpha follows the home row, the daemon's own order for the rest")

            #expect(controller.sidebar.navigateSidebarSelection(direction: 1))
            #expect(controller.selectedWorkspaceID == "beta-workspace")

            #expect(controller.sidebar.navigateSidebarSelection(direction: 1) == false, "beta is the last row")
        }

        @Test func upArrowWalksBackThroughTheHomeRowToAutomations() throws {
            let controller = loadedHomeRowController()
            let beta = try #require(controller.deviceModel.workspacesByProject["project-beta"]?.first, "the beta project must list its workspace")
            controller.sidebar.selectWorkspace(beta)
            #expect(controller.selectedWorkspaceID == "beta-workspace")

            #expect(controller.sidebar.navigateSidebarSelection(direction: -1))
            #expect(controller.selectedWorkspaceID == "alpha-workspace")

            #expect(controller.sidebar.navigateSidebarSelection(direction: -1))
            #expect(controller.selectedWorkspaceID == "home-workspace", "up from alpha lands back on the home row, not project order")

            #expect(controller.sidebar.navigateSidebarSelection(direction: -1))
            #expect(controller.showingAutomations, "up from the home row reaches Automations")
        }
    }
}
