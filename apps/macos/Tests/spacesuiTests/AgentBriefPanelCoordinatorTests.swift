import AppKit
import Testing
import spacesdevicecore
import spacesterminalcore
import spacesterminalui
import spacestestsupport

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// An open terminal pane whose session belongs to a coding agent with a brief shows that brief, the
    /// toggle surfaces flip it per agent, and every overview install carries the agent's latest brief to
    /// the pane. Drives a real `AppKitController` and `PanelCoordinator` over a fabricated local
    /// overview, with a recording stub standing in for the pane's terminal content.
    ///
    /// Nests under `ProcessProfileEnvironmentSuites` because it mutates the process-global
    /// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`, matching `AppKitControllerOwnerReclaimShortcutTests`.
    @MainActor @Suite final class AgentBriefPanelCoordinatorTests {
        private static let workspaceID = "workspace-1"
        private static let sessionID = "session-1"
        private static let briefUpdatedAt = "2026-09-25T10:00:00Z"

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

        /// Installs the local device's overview with one workspace whose coding agent runs in `session-1`
        /// and keeps `brief`.
        private func installOverview(_ controller: AppKitController, brief: String?) {
            let deviceID = controller.deviceModel.localDeviceID
            let workspace = SpacesDeviceWorkspaceSummary(
                id: Self.workspaceID, projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/workspace-1",
                isRunning: true, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: true,
                codingAgentRows: [
                    SpacesDeviceWorkspaceCodingAgentRow(
                        id: "agent:agent-1", workspaceID: Self.workspaceID, name: "claude", command: "claude", agentID: "agent-1",
                        sessionID: Self.sessionID, runState: .running, activityState: .waiting, brief: brief,
                        briefUpdatedAt: brief == nil ? nil : Self.briefUpdatedAt, canStop: true)
                ])
            let overview = SpacesDeviceOverviewPayload(
                projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
                workspaces: [workspace],
                sessions: [
                    SpacesDeviceTerminalSessionSummary(
                        id: Self.sessionID, title: "claude", workingDirectory: "/tmp/workspace-1", shell: "/bin/zsh", command: "claude",
                        state: .running, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678,
                        workspaceID: Self.workspaceID, workspaceTitle: "feature", projectID: "project-1", projectName: "Project",
                        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", isControlAvailable: true, isSubscriptionAvailable: true,
                        attachmentSnapshot: .init(), rowKind: .liveSession)
                ], retainedTerminalSessionIDs: [Self.sessionID])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            controller.deviceModel.deviceSections = [
                AppKitController.DeviceSection(
                    deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                    workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview
                )
            ]
            controller.rebuildFlatSidebarData()
        }

        /// A controller whose workspace panel holds the agent's session as its focused pane, backed by a
        /// recording stub.
        private func controllerWithAgentPane(brief: String?) throws -> (AppKitController, BriefRecordingTerminalPaneContentStub) {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "pane-1", content: .terminalSession(deviceID: deviceID, sessionID: Self.sessionID)), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: Self.workspaceID, layoutJSON: json)
            installOverview(controller, brief: brief)
            controller.panelCoordinator.restoreLayoutIfNeeded(scope: scope(controller), focusIntent: .focus)
            let stub = BriefRecordingTerminalPaneContentStub(
                descriptor: .terminalSession(deviceID: deviceID, sessionID: Self.sessionID), workspaceID: Self.workspaceID, sessionID: Self.sessionID)
            controller.panelCoordinator.installContentControllerForTesting(stub, sessionID: Self.sessionID)
            return (controller, stub)
        }

        private func scope(_ controller: AppKitController) -> PanelScope {
            .workspace(deviceID: controller.deviceModel.localDeviceID, workspaceID: Self.workspaceID)
        }

        @Test func anOpenAgentPaneShowsItsAgentsBrief() throws {
            let (controller, stub) = try controllerWithAgentPane(brief: "# Waiting on review")

            #expect(
                stub.appliedBriefs.last
                    == AgentBriefPresentation(agentKey: "agent-1", markdown: "# Waiting on review", updatedAt: Self.briefUpdatedAt),
                "the brief is keyed by the agent, not by the session it runs in")
            #expect(controller.focusedPaneBriefToggleState(workspaceID: Self.workspaceID) == .shown)
        }

        @Test func togglingHidesAndShowsTheFocusedPanesBrief() throws {
            let (controller, stub) = try controllerWithAgentPane(brief: "# Waiting on review")

            #expect(controller.panelCoordinator.toggleAgentBrief(scope: scope(controller)))
            #expect(stub.appliedBriefs.last == .some(nil), "a hidden brief removes the pane's column")
            #expect(controller.focusedPaneBriefToggleState(workspaceID: Self.workspaceID) == .hidden)

            #expect(controller.panelCoordinator.toggleAgentBrief(scope: scope(controller)))
            #expect(stub.appliedBriefs.last??.markdown == "# Waiting on review")
            #expect(controller.focusedPaneBriefToggleState(workspaceID: Self.workspaceID) == .shown)
        }

        @Test func anOverviewInstallCarriesTheRewrittenBriefToThePane() throws {
            let (controller, stub) = try controllerWithAgentPane(brief: "# Waiting on review")

            installOverview(controller, brief: "# Merged")
            #expect(stub.appliedBriefs.last??.markdown == "# Merged")
        }

        @Test func aHiddenBriefStaysHiddenWhenTheAgentRewritesIt() throws {
            let (controller, stub) = try controllerWithAgentPane(brief: "# Waiting on review")
            controller.panelCoordinator.toggleAgentBrief(scope: scope(controller))

            installOverview(controller, brief: "# Merged")
            #expect(stub.appliedBriefs.last == .some(nil))
            #expect(controller.focusedPaneBriefToggleState(workspaceID: Self.workspaceID) == .hidden)
        }

        @Test func aClearedBriefRemovesTheColumnAndLeavesNothingToToggle() throws {
            let (controller, stub) = try controllerWithAgentPane(brief: "# Waiting on review")

            installOverview(controller, brief: nil)
            #expect(stub.appliedBriefs.last == .some(nil))
            #expect(controller.focusedPaneBriefToggleState(workspaceID: Self.workspaceID) == .unavailable)
            #expect(!controller.panelCoordinator.toggleAgentBrief(scope: scope(controller)), "a pane without a brief has nothing to toggle")
        }

        @Test func aSessionNoAgentClaimsHasNoBrief() throws {
            let (controller, _) = try controllerWithAgentPane(brief: "# Waiting on review")
            #expect(!controller.panelCoordinator.toggleAgentBrief(forSessionID: "session-unclaimed"))
        }

        @Test func theToggleShortcutIsOptionCommandBAlone() {
            #expect(AppKitController.isToggleBriefShortcut(charactersIgnoringModifiers: "b", eventModifiers: [.command, .option]))
            #expect(!AppKitController.isToggleBriefShortcut(charactersIgnoringModifiers: "b", eventModifiers: [.command]))
            #expect(!AppKitController.isToggleBriefShortcut(charactersIgnoringModifiers: "B", eventModifiers: [.command, .option, .shift]))
            #expect(!AppKitController.isToggleBriefShortcut(charactersIgnoringModifiers: "b", eventModifiers: [.command, .option, .control]))
            #expect(!AppKitController.isToggleBriefShortcut(charactersIgnoringModifiers: "n", eventModifiers: [.command, .option]))
        }
    }
}

/// Records every brief the coordinator hands the pane; every other member is a trivial stub, since the
/// suite asserts which brief the pane is told to show, never what its terminal renders.
@MainActor private final class BriefRecordingTerminalPaneContentStub: TerminalPaneContentHosting {
    let descriptor: PaneContentDescriptor
    let workspaceID: String
    let sessionID: String
    var holdsOwnerAttachedSurface = false
    private(set) var appliedBriefs: [AgentBriefPresentation?] = []

    var onTitleChanged: ((String) -> Void)?
    var displayTitle: String { "stub" }
    lazy var contentView: NSView = NSView()

    init(descriptor: PaneContentDescriptor, workspaceID: String, sessionID: String) {
        self.descriptor = descriptor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }

    func applyAgentBrief(_ brief: AgentBriefPresentation?) { appliedBriefs.append(brief) }

    func activate(focus: Bool) {}
    func deactivate() {}
    func close() {}
    func closeForSessionTermination() {}
    @discardableResult func makeContentFirstResponder() -> Bool { true }
    func owns(responder: NSResponder) -> Bool { false }
    func handleKeyEvent(_ event: NSEvent) -> Bool { false }
    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool { false }
    func applyAppearance(_ appearance: ThemeAppearance) {}
    func applyTerminalTextSize(_ size: TerminalTextSize) {}
    func setAccessibilityRuntimeTargetName(_ name: String) {}
    func requestOwnershipIfNeeded() {}
    var canPerformFindActions: Bool { false }
    func find(_ sender: Any?) {}
    func findNext(_ sender: Any?) {}
    func findPrevious(_ sender: Any?) {}
    func useSelectionForFind(_ sender: Any?) {}
    func performShortcutForTesting(action: String, text: String?) {}
    func debugRefreshStateForTesting(skipOwnerAttach: Bool) {}
    func debugStateDump() -> TerminalSessionWindowDebugState { fatalError("not exercised by this suite") }
}
