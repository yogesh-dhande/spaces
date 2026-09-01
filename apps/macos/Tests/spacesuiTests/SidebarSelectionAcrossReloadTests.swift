import AppKit
import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// A background sidebar reload must never take the user's selection with it. `applySidebarDataChange`
    /// reloads the whole outline for any structural change (a session starting anywhere, a device section
    /// changing load state), and a wholesale reload is a programmatic repaint, not the user clicking empty
    /// space — so the workspace stays selected and its detail pane stays on screen.
    ///
    /// Drives the real `NSOutlineView` the way `SidebarRowRepaintTests` does, because the whole question is
    /// what AppKit does with the outline's selection across a reload: nothing short of the real view can
    /// answer it.
    @MainActor @Suite final class SidebarSelectionAcrossReloadTests {
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

        private func workspace(terminalRows: [SpacesDeviceWorkspaceTerminalRow] = []) -> SpacesDeviceWorkspaceSummary {
            SpacesDeviceWorkspaceSummary(
                id: Self.workspaceID, projectID: Self.projectID, projectName: "Project", branch: "feature", baseBranch: "main",
                dir: "/tmp/project-feature", isRunning: true, isHidden: false, isDefault: false, sessionCount: terminalRows.count,
                codingAgentRows: [], terminalRows: terminalRows)
        }

        private func terminalRow(id: String) -> SpacesDeviceWorkspaceTerminalRow {
            SpacesDeviceWorkspaceTerminalRow(
                id: id, workspaceID: Self.workspaceID, title: id, workingDirectory: "/tmp/project-feature", sessionID: "session-\(id)",
                runState: .running, canOpenTerminal: true, canStop: true, liveTitle: nil)
        }

        private func section(
            deviceID: String, isLocal: Bool, loadState: AppKitController.SidebarDeviceLoadState, terminalRows: [SpacesDeviceWorkspaceTerminalRow]
        ) -> AppKitController.DeviceSection {
            let overview = SpacesDeviceOverviewPayload(
                projects: [
                    SpacesDeviceProjectSummary(id: Self.projectID, name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")
                ], workspaces: [workspace(terminalRows: terminalRows)], sessions: [])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: isLocal ? "This Mac" : "Other", isLocal: isLocal, loadState: loadState, device: nil,
                projects: mapped.projects, workspacesByProject: mapped.workspacesByProject,
                workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        /// AppKit posts the selection change a `reloadData` caused through the run loop rather than from
        /// inside the reload, so a test that asserts straight after the apply reads the model before the
        /// outline delegate has run. Spinning briefly is what lets the delegate's no-selection branch fire —
        /// the same delivery the app gets for free, and the reason the bug looks intermittent.
        private func drainPendingSelectionNotifications() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        /// A controller showing one loaded local device with the workspace selected, its detail pane up.
        private func selectedController() throws -> AppKitController {
            let controller = makeController()
            attachOutline(controller)
            controller.deviceModel.deviceSections = [
                section(deviceID: controller.deviceModel.localDeviceID, isLocal: true, loadState: .loaded, terminalRows: [terminalRow(id: "terminal-1")])
            ]
            controller.sidebar.applySidebarDataChange()
            let summary = try #require(controller.sidebar.findWorkspace(id: Self.workspaceID)?.1)
            controller.sidebar.selectWorkspace(summary)
            #expect(controller.selectedWorkspaceID == Self.workspaceID)
            #expect(controller.detailPane.workspaceID == Self.workspaceID)
            return controller
        }

        /// A session starting anywhere adds a runtime-target row, which the row diff calls a structural
        /// change and repaints wholesale. The user is typing in a terminal while it happens.
        @Test func selectionSurvivesAStructuralReloadFromASessionStarting() throws {
            let controller = try selectedController()

            controller.deviceModel.deviceSections = [
                section(
                    deviceID: controller.deviceModel.localDeviceID, isLocal: true, loadState: .loaded,
                    terminalRows: [terminalRow(id: "terminal-1"), terminalRow(id: "terminal-2")])
            ]
            controller.sidebar.applySidebarDataChange()
            drainPendingSelectionNotifications()

            #expect(controller.outlineView.selectedRow >= 0, "the reloaded outline keeps the row it had selected")
            #expect(controller.selectedWorkspaceID == Self.workspaceID)
            #expect(controller.detailPane.workspaceID == Self.workspaceID, "the workspace pane stays up instead of falling back to the placeholder")
        }

        /// A second device section arriving (a paired device answering, or its daemon dropping out) flips
        /// the sidebar into per-device headers, which re-parents every project row under a header row the
        /// outline has never seen. The selected workspace's row is rebuilt at a new depth, and it comes
        /// back — so the selection has to come back with it.
        @Test func selectionSurvivesTheDeviceHeaderStructureFlip() throws {
            let controller = try selectedController()

            controller.deviceModel.deviceSections = [
                section(deviceID: controller.deviceModel.localDeviceID, isLocal: true, loadState: .loaded, terminalRows: [terminalRow(id: "terminal-1")]),
                section(deviceID: "remote-device", isLocal: false, loadState: .loading, terminalRows: []),
            ]
            controller.sidebar.applySidebarDataChange()
            drainPendingSelectionNotifications()

            #expect(controller.sidebar.showsDeviceHeaders, "an unloaded section groups the sidebar under device headers")
            #expect(controller.outlineView.selectedRow >= 0, "the reloaded outline keeps the row it had selected")
            #expect(controller.selectedWorkspaceID == Self.workspaceID)
            #expect(controller.detailPane.workspaceID == Self.workspaceID, "the workspace pane stays up instead of falling back to the placeholder")
        }
    }
}
