import AppKit
import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// A content-only sidebar change has to reach the screen. `applySidebarDataChange` classifies a
    /// terminal's live title arriving after its row was first painted as `.rowsChanged` and repaints only
    /// that row, so this suite drives the real `NSOutlineView` and reads the cell it ends up showing: the
    /// row-diff verdict on its own says nothing about whether AppKit rebuilt the view behind the row.
    ///
    /// Builds an `AppKitController` the way `MainWindowCloseBehaviorTests` does (a fabricated
    /// lease/profile over a throwaway temp directory) and nests under `ProcessProfileEnvironmentSuites`
    /// for the same reason: it mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class SidebarRowRepaintTests {
        private static let projectID = "project-1"
        private static let workspaceID = "workspace-1"
        private static let targetKey = "terminal:session-1"
        private static let rowName = "shell-1"
        private static let agentTargetKey = "agent:agent-1"
        private static let agentRowName = "Codex"
        private static let liveTitle = "vim main.swift"

        private let root: URL
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        /// Row views are materialized only for an outline view that lives in a window, so the suite owns
        /// one for the outline's lifetime. It is never ordered front.
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
        /// chrome: a column, this controller as delegate and data source, and a scroll view in a window.
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

        /// The workspace's one ad hoc shell, whose session reports `liveTitle`.
        private func shellWorkspace(liveTitle: String?) -> SpacesDeviceWorkspaceSummary {
            workspace(terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "terminal-1", workspaceID: Self.workspaceID, title: Self.rowName, workingDirectory: "/tmp/project-feature",
                    sessionID: "session-1", runState: .running, canOpenTerminal: true, canStop: true, liveTitle: liveTitle)
            ])
        }

        /// The workspace's one coding agent, whose claimed session reports `liveTitle`. The agent claims
        /// the session, so it produces no terminal row of its own.
        private func agentWorkspace(liveTitle: String?) -> SpacesDeviceWorkspaceSummary {
            workspace(codingAgentRows: [
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: Self.agentTargetKey, workspaceID: Self.workspaceID, name: Self.agentRowName, command: "codex", agentID: "agent-1",
                    sessionID: "session-1", isConfigured: false, runState: .running, activityState: .idle, canRun: false, canStop: true,
                    canRestart: true, liveTitle: liveTitle)
            ])
        }

        private func workspace(terminalRows: [SpacesDeviceWorkspaceTerminalRow] = [], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [])
            -> SpacesDeviceWorkspaceSummary
        {
            SpacesDeviceWorkspaceSummary(
                id: Self.workspaceID, projectID: Self.projectID, projectName: "Project", branch: "feature", baseBranch: "main",
                dir: "/tmp/project-feature", isRunning: true, isHidden: false, isDefault: false, sessionCount: 1, codingAgentRows: codingAgentRows,
                terminalRows: terminalRows)
        }

        /// One local device with a single git project and `workspace`. Only the row's live title differs
        /// between the two applies a test drives, so the row keys stay identical and the change is
        /// content-only.
        private func section(deviceID: String, workspace: SpacesDeviceWorkspaceSummary) -> AppKitController.DeviceSection {
            let overview = SpacesDeviceOverviewPayload(
                projects: [
                    SpacesDeviceProjectSummary(id: Self.projectID, name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")
                ], workspaces: [workspace], sessions: [])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        private func runtimeTargetRow(_ controller: AppKitController, key: String) -> Int? {
            (0..<controller.outlineView.numberOfRows).first { row in
                guard let ref = controller.outlineView.item(atRow: row) as? AppKitController.OutlineItemRef,
                    case .runtimeTarget(_, _, let item) = ref.item
                else { return false }
                return item.key == key
            }
        }

        /// Paints the workspace's target row with no live title, then applies the same workspace with one
        /// and returns the row cell's text before and after. Both reads are of the cell AppKit is showing,
        /// so a repaint that never reached the view fails the caller's assertion.
        private func labelsAroundLiveTitleArrival(
            _ workspaceWithLiveTitle: (String?) -> SpacesDeviceWorkspaceSummary, targetKey: String, liveTitle: String
        ) throws -> (before: [String], after: [String]) {
            let controller = makeController()
            attachOutline(controller)

            controller.deviceSections = [section(deviceID: controller.localDeviceID, workspace: workspaceWithLiveTitle(nil))]
            controller.sidebar.applySidebarDataChange()
            // Target rows hang off a collapsed workspace until the user opens it, so without this there
            // would be no painted row for the live title to reach.
            controller.sidebar.toggleWorkspaceExpanded(workspaceID: Self.workspaceID)
            controller.sidebar.applySidebarDataChange()

            let row = try #require(runtimeTargetRow(controller, key: targetKey), "the expanded workspace must list the target row")
            let before = labels(in: try #require(paintedCell(controller, row: row), "the outline must have materialized the target row's cell"))

            controller.deviceSections = [section(deviceID: controller.localDeviceID, workspace: workspaceWithLiveTitle(liveTitle))]
            controller.sidebar.applySidebarDataChange()

            let after = labels(in: try #require(paintedCell(controller, row: row), "the repaint must leave a cell on screen for the row"))
            return (before, after)
        }

        /// The cell AppKit is showing for `row`. `makeIfNecessary: false` deliberately: letting AppKit
        /// build one on demand would answer from a fresh cell rather than from what the repaint left on
        /// screen, so a dropped repaint would still read as a pass.
        private func paintedCell(_ controller: AppKitController, row: Int) -> NSView? {
            window?.contentView?.layoutSubtreeIfNeeded()
            return controller.outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
        }

        private func labels(in view: NSView) -> [String] {
            var found: [String] = []
            func walk(_ view: NSView) {
                if let field = view as? NSTextField { found.append(field.stringValue) }
                for subview in view.subviews { walk(subview) }
            }
            walk(view)
            return found
        }

        @Test func shellRowShowsALiveTitleThatArrivesAfterTheRowWasPainted() throws {
            let painted = try labelsAroundLiveTitleArrival(shellWorkspace, targetKey: Self.targetKey, liveTitle: Self.liveTitle)

            #expect(painted.before == [Self.rowName], "the terminal has reported no title yet, so the row is its name alone")
            #expect(painted.after == [Self.rowName, Self.liveTitle])
        }

        /// A coding-agent row reads like a shell row: the agent keeps its stable name and the title its
        /// terminal reports trails it. Virtually every session a user runs is claimed by an agent row, so
        /// this is the row the live title is read on most often.
        @Test func codingAgentRowShowsALiveTitleThatArrivesAfterTheRowWasPainted() throws {
            let painted = try labelsAroundLiveTitleArrival(agentWorkspace, targetKey: Self.agentTargetKey, liveTitle: Self.liveTitle)

            #expect(painted.before == [Self.agentRowName], "the agent's terminal has reported no title yet")
            #expect(painted.after == [Self.agentRowName, Self.liveTitle])
        }
    }
}
