import AppKit
import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// The pane session picker (split right/down, ⌘T, the tab strip's "+") returns keyboard focus to the
    /// pane it was opened from when it closes, whether the user picks a row or cancels. The Editor window
    /// is where this shows: in full screen it sits on its own Space, so a picker that fell back to
    /// revealing the main window switched Spaces away from the Editor the user was splitting.
    ///
    /// Builds a real `AppKitController` over a throwaway profile the way `CodePanePlumbingTests` does and
    /// records where focus goes through `showPanelScopeOverrideForTesting`: every pane focus brings its
    /// panel's window forward through `showPanelScope`, so the recorded scopes are exactly the windows the
    /// picker's dismissal fronted. The override also keeps the real `showPanelScope` (which activates the
    /// app) out of the test process. Nests under `ProcessProfileEnvironmentSuites` because it mutates the
    /// process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class PaneSessionPickerReturnFocusTests {
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

        /// One local device with `workspace-1`, retaining `sess-1` and `sess-2`. Only `sess-2` has a sidebar
        /// terminal row, so the picker offers exactly "New terminal session" and `sess-2`.
        private func section(deviceID: String) -> AppKitController.DeviceSection {
            let workspace = SpacesDeviceWorkspaceSummary(
                id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/workspace-1",
                isRunning: true, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: true, processRows: [],
                terminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "row-sess-2", workspaceID: "workspace-1", title: "shell-2", workingDirectory: "/tmp/workspace-1", sessionID: "sess-2",
                        runState: .running, canOpenTerminal: true, canStop: true)
                ])
            let overview = SpacesDeviceOverviewPayload(
                projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
                workspaces: [workspace], sessions: ["sess-1", "sess-2"].map(session(id:)), retainedTerminalSessionIDs: ["sess-1", "sess-2"])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        private func session(id: String) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: id, title: id, workingDirectory: "/tmp/workspace-1", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
                lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678, workspaceID: "workspace-1", workspaceTitle: "feature",
                projectID: "project-1", projectName: "Project", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: .init(), rowKind: .liveSession)
        }

        /// Installs a daemon-less stand-in for a terminal session's pane content, so placing, splitting, and
        /// focusing its pane never dials a session stream (whose failure, for a focused open, would present a
        /// modal alert nothing in the test process can dismiss).
        private func installTerminalStub(_ controller: AppKitController, deviceID: String, sessionID: String) {
            controller.panelCoordinator.installContentControllerForTesting(
                RecordingTerminalPaneContentStub(
                    descriptor: .terminalSession(deviceID: deviceID, sessionID: sessionID), workspaceID: "workspace-1", sessionID: sessionID),
                sessionID: sessionID)
        }

        private func isWorkspaceScope(_ scope: PanelScope) -> Bool {
            if case .workspace = scope { return true }
            return false
        }

        /// The reported bug: splitting the Editor's pane opens the picker, and cancelling it (Esc, or
        /// clicking away) must bring the Editor's own window back rather than fall through to revealing the
        /// main window.
        @Test func cancellingTheSplitPickerOpenedFromTheEditorReturnsFocusToTheEditor() throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            var shownScopes: [PanelScope] = []
            controller.showPanelScopeOverrideForTesting = { shownScopes.append($0) }
            var globalScopes: [PanelScope] = []
            controller.panelCoordinator.onLayoutChanged = { scope, _ in if case .globalWindow = scope { globalScopes.append(scope) } }
            #expect(controller.panelCoordinator.openOrFocusGlobalEditorWindow(deviceID: deviceID, workspaceID: "workspace-1"))
            let editorScope = try #require(globalScopes.first, "precondition: the Editor opened in a global window")
            let editorPaneID = try #require(PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: editorScope)).first?.id)
            shownScopes.removeAll()

            controller.panelCoordinator.panelView(for: editorScope).onSplitPane?(editorPaneID, .right)
            #expect(controller.commandPalette.sessionPickerContext != nil, "precondition: splitting opened the session picker")
            controller.commandPalette.dismissCommandPalette()

            #expect(shownScopes == [editorScope], "cancelling the picker fronts the Editor's window, the one the split was made in")
            #expect(!shownScopes.contains(where: isWorkspaceScope), "cancelling the picker never falls back to the main window")
            #expect(
                controller.panelCoordinator.layout(for: editorScope).focusedPaneID == editorPaneID, "focus goes back to the Editor pane being split")
        }

        /// Picking a session for the Editor's split fills the split in the Editor's window and leaves focus
        /// there: dismissing the picker returns to the Editor first, and the filled pane takes focus in that
        /// same window.
        @Test func pickingASessionForTheEditorSplitKeepsFocusInTheEditorWindow() throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            installTerminalStub(controller, deviceID: deviceID, sessionID: "sess-2")
            var shownScopes: [PanelScope] = []
            controller.showPanelScopeOverrideForTesting = { shownScopes.append($0) }
            var globalScopes: [PanelScope] = []
            controller.panelCoordinator.onLayoutChanged = { scope, _ in if case .globalWindow = scope { globalScopes.append(scope) } }
            #expect(controller.panelCoordinator.openOrFocusGlobalEditorWindow(deviceID: deviceID, workspaceID: "workspace-1"))
            let editorScope = try #require(globalScopes.first, "precondition: the Editor opened in a global window")
            let editorPaneID = try #require(PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: editorScope)).first?.id)
            shownScopes.removeAll()

            controller.panelCoordinator.panelView(for: editorScope).onSplitPane?(editorPaneID, .right)
            let palette = controller.commandPalette
            palette.commandPaletteSelectedIndex = try #require(
                palette.commandPaletteFilteredItems.firstIndex { $0.label == "shell-2" }, "precondition: the picker offers sess-2")
            palette.executeSelectedCommandPaletteItem()

            #expect(shownScopes == [editorScope], "picking fronts the Editor's window, never the main window")
            let layout = controller.panelCoordinator.layout(for: editorScope)
            let panes = PanelLayoutEngine.allPanes(in: layout)
            #expect(
                panes.map(\.content) == [
                    .codePane(deviceID: deviceID, workspaceID: "workspace-1"), .terminalSession(deviceID: deviceID, sessionID: "sess-2"),
                ], "the picked session fills the split beside the Editor")
            #expect(layout.focusedPaneID == panes.last?.id, "the filled pane takes focus in the Editor's window")
        }

        /// A terminal split beside the Editor in its window: cancelling that split's picker returns to the
        /// terminal pane, in the same window.
        @Test func cancellingTheSplitPickerOpenedFromATerminalInTheEditorWindowReturnsFocusToThatTerminal() throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            installTerminalStub(controller, deviceID: deviceID, sessionID: "sess-1")
            var shownScopes: [PanelScope] = []
            controller.showPanelScopeOverrideForTesting = { shownScopes.append($0) }
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            let layout = PanelLayout(
                version: PanelLayout.currentVersion,
                tabs: [
                    PanelTab(
                        id: "tab-1", title: nil, lastFocusedPaneID: "term",
                        root: .split(
                            PaneSplit(
                                id: "split-1", orientation: .horizontal, weights: [0.5, 0.5],
                                children: [
                                    .leaf(Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1"))),
                                    .leaf(Pane(id: "term", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1"))),
                                ])))
                ], selectedTabID: "tab-1", focusedPaneID: "term")
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            shownScopes.removeAll()

            controller.panelCoordinator.panelView(for: scope).onSplitPane?("term", .down)
            #expect(controller.commandPalette.sessionPickerContext != nil, "precondition: splitting opened the session picker")
            controller.commandPalette.dismissCommandPalette()

            #expect(shownScopes == [scope], "cancelling the picker fronts the window the split was made in")
            #expect(!shownScopes.contains(where: isWorkspaceScope), "cancelling the picker never falls back to the main window")
            #expect(controller.panelCoordinator.layout(for: scope).focusedPaneID == "term", "focus goes back to the terminal pane being split")
        }

        /// ⌘T and the tab strip's "+" open the same picker over the workspace panel; cancelling it returns
        /// to the pane the user was in, not just to the main window.
        @Test func cancellingTheNewTabPickerReturnsFocusToThePanelsFocusedPane() throws {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            installTerminalStub(controller, deviceID: deviceID, sessionID: "sess-1")
            installTerminalStub(controller, deviceID: deviceID, sessionID: "sess-2")
            let scope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")
            let persisted = PanelLayout(
                version: PanelLayout.currentVersion,
                tabs: [
                    PanelTab(
                        id: "tab-1", title: nil, lastFocusedPaneID: "b",
                        root: .split(
                            PaneSplit(
                                id: "split-1", orientation: .horizontal, weights: [0.5, 0.5],
                                children: [
                                    .leaf(Pane(id: "a", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1"))),
                                    .leaf(Pane(id: "b", content: .terminalSession(deviceID: deviceID, sessionID: "sess-2"))),
                                ])))
                ], selectedTabID: "tab-1", focusedPaneID: "b")
            try controller.clientDatabase().writeWorkspacePanelLayout(
                deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self))
            controller.panelCoordinator.restoreLayoutIfNeeded(scope: scope, focusIntent: .withoutFocus)
            #expect(controller.panelCoordinator.layout(for: scope).focusedPaneID == "b", "precondition: the restored panel focuses pane b")
            var shownScopes: [PanelScope] = []
            controller.showPanelScopeOverrideForTesting = { shownScopes.append($0) }

            controller.presentNewTabSessionPicker(scope: scope)
            #expect(controller.commandPalette.sessionPickerContext != nil, "precondition: the new-tab picker opened")
            controller.commandPalette.dismissCommandPalette()

            #expect(shownScopes == [scope], "cancelling the picker fronts the workspace panel it was opened over")
            #expect(controller.panelCoordinator.layout(for: scope).focusedPaneID == "b", "focus goes back to the pane the user was in")
        }
    }
}
