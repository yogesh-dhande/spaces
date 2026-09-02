import AppKit
import Testing
import spacesdevicecore
import spacesterminalcore
import spacesterminalui
import spacestestsupport

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Covers the refocus shortcut in `AppKitController.openTerminalSessionPane`: when the pane is
    /// already placed, focused, and selected, `panelCoordinator.refocusFocusedTerminalPane` succeeds and
    /// the function returns early before reaching the owner-reclaim call at the bottom of the normal
    /// open path. An owner-mode open that hits this shortcut must still reclaim ownership, or a `spaces
    /// terminal show` / owner IPC that lands while the pane is already the focused pane silently stays a
    /// viewer instead of preempting a different active owner.
    ///
    /// Nests under `ProcessProfileEnvironmentSuites` because it mutates the process-global
    /// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`, matching `PanelReplacementHoldTests`.
    @MainActor @Suite final class AppKitControllerOwnerReclaimShortcutTests {
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

        /// Reproduces race hole 1: a pane that is already the focused pane in its selected tab, opened in
        /// owner mode, must still call `requestOwnershipIfNeeded()` even though `refocusFocusedTerminalPane`
        /// takes the early-return shortcut.
        @Test func anOwnerModeOpenReclaimsOwnershipEvenWhenTheRefocusShortcutShortCircuits() async throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "a", content: .terminalSession(deviceID: deviceID, sessionID: "session-1")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            let workspace = SpacesDeviceWorkspaceSummary(
                id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/workspace-1",
                isRunning: true, isHidden: false, isDefault: false, sessionCount: 1, processRows: [])
            let overview = SpacesDeviceOverviewPayload(
                projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
                workspaces: [workspace],
                sessions: [
                    SpacesDeviceTerminalSessionSummary(
                        id: "session-1", title: "session-1", workingDirectory: "/tmp/workspace-1", shell: "/bin/zsh", command: nil,
                        state: .running, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678,
                        workspaceID: "workspace-1", workspaceTitle: "feature", projectID: "project-1", projectName: "Project",
                        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", isControlAvailable: true, isSubscriptionAvailable: true,
                        attachmentSnapshot: .init(), rowKind: .liveSession)
                ], retainedTerminalSessionIDs: ["session-1"])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            controller.deviceModel.deviceSections = [
                AppKitController.DeviceSection(
                    deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                    workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
            ]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")
            controller.panelCoordinator.restoreLayoutIfNeeded(scope: scope, focusIntent: .focus)
            let placement = try #require(controller.panelCoordinator.placement(forSessionID: "session-1"), "precondition: the pane is placed")
            let restoredLayout = controller.panelCoordinator.layout(for: scope)
            #expect(restoredLayout.focusedPaneID == placement.paneID, "precondition: the pane is already focused")
            #expect(restoredLayout.selectedTabID == placement.tabID, "precondition: the pane's tab is already selected")

            let stub = RecordingTerminalPaneContentStub(
                descriptor: .terminalSession(deviceID: deviceID, sessionID: "session-1"), workspaceID: "workspace-1", sessionID: "session-1")
            stub.holdsOwnerAttachedSurface = true
            controller.panelCoordinator.installContentControllerForTesting(stub, sessionID: "session-1")
            // The real `showPanelScope` calls `NSApp.activate(ignoringOtherApps:)`, which a unit test
            // process must never trigger; the override lets this test drive the real refocus shortcut
            // (and the bug it can skip) without that side effect.
            controller.showPanelScopeOverrideForTesting = { _ in }

            let opened = await controller.openTerminalSessionPane(
                sessionID: "session-1", mode: .owner, openIntent: TerminalPaneOpenIntent(focus: .focus))

            #expect(opened, "precondition: the refocus shortcut reports success")
            #expect(
                stub.requestOwnershipCallCount == 1,
                "an owner-mode open must reclaim ownership even when the refocus shortcut short-circuits the normal open path")
        }
    }
}

/// Records `requestOwnershipIfNeeded()`/`makeContentFirstResponder()` calls; every other member is a
/// trivial stub, since `AppKitControllerOwnerReclaimShortcutTests` only drives the pane-reuse decision
/// path in `openTerminalSessionPane`/`refocusFocusedTerminalPane`, never a pane's real terminal content.
@MainActor private final class RecordingTerminalPaneContentStub: TerminalPaneContentHosting {
    let descriptor: PaneContentDescriptor
    let workspaceID: String
    let sessionID: String
    var holdsOwnerAttachedSurface = false
    private(set) var requestOwnershipCallCount = 0
    private(set) var makeContentFirstResponderCallCount = 0

    var onTitleChanged: ((String) -> Void)?
    var displayTitle: String { "stub" }
    lazy var contentView: NSView = NSView()

    init(descriptor: PaneContentDescriptor, workspaceID: String, sessionID: String) {
        self.descriptor = descriptor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }

    func activate(focus: Bool) {}
    func deactivate() {}
    func close() {}
    func closeForSessionTermination() {}

    @discardableResult func makeContentFirstResponder() -> Bool {
        makeContentFirstResponderCallCount += 1
        return true
    }

    func owns(responder: NSResponder) -> Bool { false }
    func handleKeyEvent(_ event: NSEvent) -> Bool { false }
    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool { false }

    func applyAppearance(_ appearance: ThemeAppearance) {}
    func applyTerminalTextSize(_ size: TerminalTextSize) {}
    func setAccessibilityRuntimeTargetName(_ name: String) {}

    func requestOwnershipIfNeeded() { requestOwnershipCallCount += 1 }

    var canPerformFindActions: Bool { false }
    func find(_ sender: Any?) {}
    func findNext(_ sender: Any?) {}
    func findPrevious(_ sender: Any?) {}
    func useSelectionForFind(_ sender: Any?) {}

    func performShortcutForTesting(action: String, text: String?) {}
    func debugRefreshStateForTesting(skipOwnerAttach: Bool) {}
    func debugStateDump() -> TerminalSessionWindowDebugState { fatalError("not exercised by this test") }
}
