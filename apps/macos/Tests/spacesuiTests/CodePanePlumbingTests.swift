import AppKit
import Testing
import WebKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Covers the code-pane feature at the `PanelCoordinator` level: the dual-store keying (terminal
    /// panes by session id in `contentControllers`, code panes by pane id in `codePaneControllers`), the
    /// Editor's confinement to the global singleton window, and pruning of a legacy persisted code pane
    /// out of a `.workspace`-scope layout on restore.
    ///
    /// Builds a real `AppKitController` the way `PanelReplacementHoldTests` does (a fabricated
    /// lease/profile over a throwaway temp directory, so the suite never touches real lease state), then
    /// drives its `PanelCoordinator` directly. Nests under `ProcessProfileEnvironmentSuites` because it
    /// mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class CodePanePlumbingTests {
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

        /// One local device with a workspace whose overview retains `sessionID`'s terminal session —
        /// enough to let a persisted terminal pane restore without being pruned. `loadState` defaults to
        /// `.loaded`; passing `.offline` builds a section for the "device went unreachable" tests without
        /// disturbing the merged-sidebar row (an offline device keeps its rows, so `deviceID(forWorkspaceID:)`
        /// still resolves).
        private func section(
            deviceID: String, sessionID: String, workspaceID: String = "workspace-1", loadState: AppKitController.SidebarDeviceLoadState = .loaded
        ) -> AppKitController.DeviceSection {
            let workspace = SpacesDeviceWorkspaceSummary(
                id: workspaceID, projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/\(workspaceID)",
                isRunning: true, isHidden: false, isDefault: false, sessionCount: 1, processRows: [])
            let overview = SpacesDeviceOverviewPayload(
                projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
                workspaces: [workspace],
                sessions: [
                    SpacesDeviceTerminalSessionSummary(
                        id: sessionID, title: "shell", workingDirectory: "/tmp/\(workspaceID)", shell: "/bin/zsh", command: "/bin/zsh",
                        state: .running, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678,
                        workspaceID: workspaceID, workspaceTitle: "feature", projectID: "project-1", projectName: "Project",
                        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", isControlAvailable: true, isSubscriptionAvailable: true,
                        attachmentSnapshot: .init(), rowKind: .process)
                ], retainedTerminalSessionIDs: [sessionID])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: loadState, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        /// Two live workspaces on one device, neither carrying a terminal session — the retarget tests
        /// only need `showWorkspaceDetail` to resolve a workspace and reach its full-panel branch
        /// (`deviceWorkspaceSummary` + `findWorkspace` both need an entry), not any terminal-pane
        /// machinery. Distinct branches (`feature-1`/`feature-2`) so a retargeted pane's title can be told
        /// apart from its predecessor's.
        private func twoWorkspaceSection(deviceID: String) -> AppKitController.DeviceSection {
            let workspace1 = SpacesDeviceWorkspaceSummary(
                id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature-1", baseBranch: "main", dir: "/tmp/workspace-1",
                isRunning: true, isHidden: false, isDefault: false, sessionCount: 0, processRows: [])
            let workspace2 = SpacesDeviceWorkspaceSummary(
                id: "workspace-2", projectID: "project-1", projectName: "Project", branch: "feature-2", baseBranch: "main", dir: "/tmp/workspace-2",
                isRunning: true, isHidden: false, isDefault: false, sessionCount: 0, processRows: [])
            let overview = SpacesDeviceOverviewPayload(
                projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
                workspaces: [workspace1, workspace2], sessions: [], retainedTerminalSessionIDs: [])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        /// A terminal pane restored in a workspace's own panel and a code pane restored in the global
        /// singleton window resolve to their own controller instance: the terminal by session id in
        /// `contentControllers`, the code pane by pane id in `codePaneControllers`. Proves the dual-store
        /// design keeps the two content kinds from colliding rather than one overwriting the other — the
        /// scopes differ because a code pane's only legitimate placement is the global singleton window.
        @Test func aTerminalPaneAndACodePaneKeyToDistinctControllers() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            let terminalLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "term", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(terminalLayout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()
            controller.panelCoordinator.restoreLayoutIfNeeded(
                scope: .workspace(deviceID: deviceID, workspaceID: "workspace-1"), focusIntent: .withoutFocus)
            let codeLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: codeLayout, frame: nil)

            let terminalContent = controller.panelCoordinator.content(forSessionID: "sess-1")
            let codeContent = controller.panelCoordinator.codePaneContent(forPaneID: "code")
            #expect(terminalContent != nil, "the terminal pane's session-keyed controller was built")
            #expect(codeContent != nil, "the code pane's paneID-keyed controller was built")
            #expect((terminalContent as AnyObject?) !== (codeContent as AnyObject?), "each content kind resolves to its own controller instance")
        }

        /// The code pane's lookup is keyed by pane id, which never changes; a terminal session ending and
        /// its controller being torn down must not disturb it. Covers "lookup survives session churn".
        @Test func codePaneLookupSurvivesTerminalSessionChurn() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            let terminalLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "term", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(terminalLayout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()
            controller.panelCoordinator.restoreLayoutIfNeeded(
                scope: .workspace(deviceID: deviceID, workspaceID: "workspace-1"), focusIntent: .withoutFocus)
            let codeLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: codeLayout, frame: nil)
            let codeContentBefore = controller.panelCoordinator.codePaneContent(forPaneID: "code")
            #expect(codeContentBefore != nil, "precondition: the code pane's controller exists")

            controller.panelCoordinator.closePane(forSessionID: "sess-1", sessionIsTerminating: true)

            #expect(controller.panelCoordinator.content(forSessionID: "sess-1") == nil, "the terminal session's controller is gone")
            let codeContentAfter = controller.panelCoordinator.codePaneContent(forPaneID: "code")
            #expect(
                (codeContentBefore as AnyObject?) === (codeContentAfter as AnyObject?),
                "the code pane's controller is untouched by the unrelated terminal session closing")
        }

        /// A persisted `.workspace`-scope code pane is a leftover from before the Editor's placement was
        /// confined to the global singleton window (in-panel code panes were removed entirely): restoring
        /// the workspace's panel prunes it unconditionally (`AppKitController.restoredWorkspacePanelLayout`
        /// passes `keepingWorkspaceKeys: []`), so restore finds nothing left to install rather than
        /// rebuilding a placement that can no longer exist in this scope.
        @Test func restoringAWorkspacePanelPrunesALegacyPersistedCodePane() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)

            controller.panelCoordinator.restoreLayoutIfNeeded(
                scope: .workspace(deviceID: deviceID, workspaceID: "workspace-1"), focusIntent: .withoutFocus)

            let restored = controller.panelCoordinator.layout(for: .workspace(deviceID: deviceID, workspaceID: "workspace-1"))
            #expect(PanelLayoutEngine.allPanes(in: restored).isEmpty, "the legacy code pane is pruned rather than restored")
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code") == nil, "no controller is built for the pruned pane")
        }

        /// Deleting, stopping, or restarting a workspace closes its code panes but leaves another
        /// workspace's code pane (open in the same global panel window) untouched. Covers
        /// `PanelCoordinator.closeCodePanes(workspaceID:)`, the code-pane counterpart of
        /// `closeTerminalPanes` called from the workspace-teardown chokepoint.
        @Test func closeCodePanesClosesOnlyTheGivenWorkspacesPanes() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code-1", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-2", pane: Pane(id: "code-2", content: .codePane(deviceID: deviceID, workspaceID: "workspace-2")), to: layout)
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code-1") != nil, "precondition: workspace-1's pane controller exists")
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code-2") != nil, "precondition: workspace-2's pane controller exists")

            controller.panelCoordinator.closeCodePanes(workspaceID: "workspace-1")

            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).map(\.id) == ["code-2"],
                "only workspace-1's pane leaves the layout")
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code-1") == nil, "workspace-1's controller is torn down")
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code-2") != nil, "workspace-2's controller survives")
        }

        /// `closeCodePanes(deviceID:workspaceIDs:)` — the cross-client lifecycle close run when a
        /// workspace is observed transitioning to not-running in a device's overview (an externally
        /// initiated stop/restart/delete reaching this client only through a sidebar reload) — closes a
        /// matching device+workspace code pane but leaves a same-workspace pane on a different device, a
        /// different workspace's pane on the same device, and a terminal pane untouched.
        @Test func closeCodePanesByDeviceAndWorkspaceClosesOnlyTheMatchingPane() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code-target", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-2", pane: Pane(id: "code-other-workspace", content: .codePane(deviceID: deviceID, workspaceID: "workspace-2")), to: layout
            )
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-3", pane: Pane(id: "code-other-device", content: .codePane(deviceID: "other-device", workspaceID: "workspace-1")),
                to: layout)
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-4", pane: Pane(id: "term", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1")), to: layout)
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code-target") != nil, "precondition: the target pane's controller exists")

            controller.panelCoordinator.closeCodePanes(deviceID: deviceID, workspaceIDs: ["workspace-1"])

            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).map(\.id).sorted() == [
                    "code-other-device", "code-other-workspace", "term",
                ], "only the matching device+workspace pane leaves the layout")
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code-target") == nil, "the target pane's controller is torn down")
            #expect(
                controller.panelCoordinator.codePaneContent(forPaneID: "code-other-workspace") != nil,
                "a different workspace's pane on the same device survives")
            #expect(
                controller.panelCoordinator.codePaneContent(forPaneID: "code-other-device") != nil,
                "the same workspace's pane on a different device survives")
        }

        /// `pruneOpenCodePanes` — the overview-driven counterpart of `closeCodePanes`, run when a device's
        /// overview arrives — closes a code pane whose workspace dropped out of `liveWorkspaceIDs` (the
        /// workspace was deleted) but leaves one whose workspace is still listed, and never touches a
        /// pane owned by a different device even if that device's id is absent from the same set.
        @Test func pruneOpenCodePanesClosesOnlyPanesForGoneWorkspacesOnTheGivenDevice() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code-live", content: .codePane(deviceID: deviceID, workspaceID: "workspace-live")), to: PanelLayout())
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-2", pane: Pane(id: "code-gone", content: .codePane(deviceID: deviceID, workspaceID: "workspace-gone")), to: layout)
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-3", pane: Pane(id: "code-other-device", content: .codePane(deviceID: "other-device", workspaceID: "workspace-gone")),
                to: layout)
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)

            controller.panelCoordinator.pruneOpenCodePanes(deviceID: deviceID, liveWorkspaceIDs: ["workspace-live"])

            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).map(\.id).sorted() == [
                    "code-live", "code-other-device",
                ], "workspace-gone's pane on the pruned device closes; the other device's pane does not")
        }

        /// `openOrFocusGlobalEditorWindow` — the ⌘⌥E shortcut, the sidebar's "Open in Editor" item, and
        /// every other open-editor entry point — creates one code pane in the global singleton window
        /// when none is open anywhere yet, and re-focuses that same pane on a second call instead of
        /// creating a second one. The freshly minted window id is not knowable ahead of time, so the test
        /// recovers it from `onLayoutChanged`.
        @Test func openOrFocusGlobalEditorWindowOpensAFreshSingletonWindowWhenNoneExistsAndFocusesOnASecondCall() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()
            var openedGlobalScopes: [PanelScope] = []
            controller.panelCoordinator.onLayoutChanged = { scope, _ in if case .globalWindow = scope { openedGlobalScopes.append(scope) } }

            let opened = controller.panelCoordinator.openOrFocusGlobalEditorWindow(deviceID: deviceID, workspaceID: "workspace-1")

            #expect(opened)
            let globalScope = try #require(openedGlobalScopes.first, "a fresh global window scope was minted")
            let panes = PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: globalScope))
            #expect(panes.map(\.content) == [.codePane(deviceID: deviceID, workspaceID: "workspace-1")])
            let paneID = try #require(panes.first?.id)

            let focusedAgain = controller.panelCoordinator.openOrFocusGlobalEditorWindow(deviceID: deviceID, workspaceID: "workspace-1")

            #expect(focusedAgain)
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: globalScope)).map(\.id) == [paneID],
                "the second call focuses the existing pane instead of opening a second one")
        }

        /// Fix 6 (P2 review): an already-open Editor window stays focusable while its device is offline —
        /// focusing a pane that already exists is client-side, so an unreachable device never withholds
        /// it; only *creating* a fresh one is refused (`PanelCoordinator.mayCreateCodePane`, gated on
        /// `.offline`). This is deliberately not exercised through the *refused* creation branch, since
        /// that branch's `host.showWorkspaceDeviceUnavailableError` presents a real `NSAlert.runModal()`
        /// that would hang the suite (see `PanelReplacementHoldTests.swift`'s identical caution);
        /// `AppKitControllerDeviceParityTests.aFreshCodePaneIsRefusedForADeviceThatCannotAct` covers that
        /// refusal's pure decision logic instead.
        @Test func openOrFocusGlobalEditorWindowFocusesAnExistingWindowEvenWhileItsDeviceIsOffline() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1", loadState: .offline("Connection refused"))]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)

            let focused = controller.panelCoordinator.openOrFocusGlobalEditorWindow(deviceID: deviceID, workspaceID: "workspace-1")

            #expect(focused, "the existing window focuses even though its device cannot service a fresh creation")
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).map(\.id) == ["code"],
                "no second pane is installed alongside the existing one")
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code") != nil, "the existing pane's controller is live")
        }

        /// `focusPane(forCodePaneID:)` — the code-pane counterpart of `focusPane(forSessionID:)`, used to
        /// restore the command palette's captured return focus onto a code pane — focuses an existing
        /// pane's placement (selecting its tab along the way) and reports false for a pane id that is not
        /// open anywhere.
        @Test func focusPaneForCodePaneIDFocusesAnExistingPaneAndMissesAnUnknownOne() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code-1", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            layout = PanelLayoutEngine.appendUnselectedTab(
                tabID: "tab-2", pane: Pane(id: "code-2", content: .codePane(deviceID: deviceID, workspaceID: "workspace-2")), to: layout)
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            #expect(controller.panelCoordinator.layout(for: scope).focusedPaneID == "code-1", "precondition: tab-1's pane is focused")

            let focused = controller.panelCoordinator.focusPane(forCodePaneID: "code-2")

            #expect(focused)
            #expect(controller.panelCoordinator.layout(for: scope).focusedPaneID == "code-2", "the named pane becomes focused")
            #expect(controller.panelCoordinator.layout(for: scope).selectedTabID == "tab-2", "focusing a pane in another tab selects that tab")

            let missed = controller.panelCoordinator.focusPane(forCodePaneID: "does-not-exist")

            #expect(!missed, "a pane id that is not open anywhere is reported as not found")
        }

        /// The workspace panel view's window-membership seam (`WorkspacePanelView.onWindowMembershipChanged`,
        /// wired in `panelCoordinator.panelView(for:)`) hibernates a code pane's `WKWebView` when the panel
        /// view leaves the window while keeping the panel alive detached, and rebuilds it when the panel
        /// rejoins a window. A terminal pane split alongside it in the same global singleton window is
        /// untouched by the same transition: Ghostty surfaces are meant to survive detachment, so only
        /// code-pane content hibernates. Splits (but not tabs) are allowed in the global window, so a
        /// terminal pane and a code pane can legitimately sit side by side there.
        @Test func panelLeavingTheWindowHibernatesItsCodePaneButLeavesItsTerminalPaneAlone() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()
            // Pre-populates "sess-1"'s controller through the same `.withoutFocus` restore path
            // `aTerminalPaneAndACodePaneKeyToDistinctControllers` uses, before the `.globalWindow` restore
            // below ever runs. `restorePanelWindow`'s own terminal branch always prepares with `.focus` (a
            // restored window's focused pane re-activates on completion), and a fake session with no real
            // daemon behind it always fails preparation — with `.focus` that reports itself with a real,
            // blocking `NSAlert.runModal()` (`terminalPaneOpenFailureUsesModalAlert`), which nothing in this
            // test process can dismiss. Priming the controller here first means `restorePanelWindow`'s guard
            // (`contentControllers[sessionID] == nil`) finds it already installed and never schedules that
            // `.focus` preparation at all; the `.withoutFocus` task this priming step itself schedules can
            // still fail later, silently, exactly as intended for a non-interactive open.
            let terminalLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "term-ws", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1")), to: PanelLayout())
            let terminalJSON = String(decoding: try JSONEncoder().encode(terminalLayout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: terminalJSON)
            controller.panelCoordinator.restoreLayoutIfNeeded(
                scope: .workspace(deviceID: deviceID, workspaceID: "workspace-1"), focusIntent: .withoutFocus)

            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            let layout = PanelLayout(
                version: PanelLayout.currentVersion,
                tabs: [
                    PanelTab(
                        id: "tab-1", title: nil, lastFocusedPaneID: nil,
                        root: .split(
                            PaneSplit(
                                id: "split-1", orientation: .horizontal, weights: [0.5, 0.5],
                                children: [
                                    .leaf(Pane(id: "term", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1"))),
                                    .leaf(Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1"))),
                                ])))
                ], selectedTabID: "tab-1", focusedPaneID: "code")
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            let panelView = controller.panelCoordinator.panelView(for: scope)

            let terminalContentBefore = controller.panelCoordinator.content(forSessionID: "sess-1")
            #expect(terminalContentBefore != nil, "precondition: the terminal pane's controller exists")
            let codeContent = try #require(
                controller.panelCoordinator.codePaneContent(forPaneID: "code") as? CodePaneContentController,
                "precondition: the code pane's controller exists")
            #expect(codeContent.contentView.subviews.contains { $0 is WKWebView }, "precondition: the selected tab's code pane is activated")

            panelView.removeFromSuperview()

            #expect(!codeContent.contentView.subviews.contains { $0 is WKWebView }, "leaving the window tears down the code pane's web view")
            #expect(
                (controller.panelCoordinator.content(forSessionID: "sess-1") as AnyObject?) === (terminalContentBefore as AnyObject?),
                "the terminal pane's controller is untouched by the detach path")

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView?.addSubview(panelView)

            #expect(codeContent.contentView.subviews.contains { $0 is WKWebView }, "rejoining a window rebuilds the code pane's web view")
        }

        // MARK: - Workspace-following Editor window (`.globalWindow` code pane retargets on selection)

        /// The single funnel (`showWorkspaceDetail`) presenting a different workspace than it last
        /// presented retargets the `.globalWindow` code pane to the new workspace: the pane's descriptor,
        /// its persisted layout, its controller instance (a fresh one — retarget is close-and-reinstall,
        /// not a live edit), and its title all move to the newly selected workspace. The very first
        /// `showWorkspaceDetail` call of a session must not retarget — a restored monitor stays on its
        /// saved workspace until a real subsequent change — so this exercises that call first and confirms
        /// it is a no-op before exercising the real change.
        @Test func showWorkspaceDetailRetargetsAGlobalPanelWindowsCodePaneToTheNewlySelectedWorkspace() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "monitor", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            let originalContent = try #require(
                controller.panelCoordinator.codePaneContent(forPaneID: "monitor") as? CodePaneContentController,
                "precondition: the monitor's controller exists")
            let (project1, workspace1) = try #require(controller.findWorkspace(id: "workspace-1"))
            let (project2, workspace2) = try #require(controller.findWorkspace(id: "workspace-2"))

            // First-ever presentation this session: `visibleDetailWorkspaceID` starts nil, so this must
            // not retarget even though the monitor is already showing this same workspace.
            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)

            #expect(
                (controller.panelCoordinator.codePaneContent(forPaneID: "monitor") as AnyObject?) === (originalContent as AnyObject?),
                "presenting the workspace the monitor already shows, for the first time this session, does not retarget it")

            controller.showWorkspaceDetail(project: project2, workspace: workspace2, presentation: .userNavigation)

            let retargetedContent = try #require(
                controller.panelCoordinator.codePaneContent(forPaneID: "monitor") as? CodePaneContentController,
                "the monitor's pane id keeps a live controller after retargeting")
            #expect(
                (retargetedContent as AnyObject?) !== (originalContent as AnyObject?),
                "retarget installs a fresh controller instance rather than mutating the old one in place")
            #expect(retargetedContent.workspaceID == "workspace-2", "the new controller is scoped to the newly selected workspace")
            #expect(retargetedContent.initialMode == .diff, "a retargeted monitor lands in diff mode")
            #expect(retargetedContent.displayTitle == "Code — feature-2", "the title reflects the newly selected workspace's name")
            let pane = try #require(PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).first { $0.id == "monitor" })
            #expect(
                pane.content == .codePane(deviceID: deviceID, workspaceID: "workspace-2"), "the layout's pane descriptor moves to the new workspace")

            let record = try #require(controller.clientDatabase().panelWindows().first { $0.id == "panel-1" }, "the retarget persists")
            let persistedLayout = try JSONDecoder().decode(PanelLayout.self, from: Data(record.layoutJSON.utf8))
            let persistedPane = try #require(PanelLayoutEngine.allPanes(in: persistedLayout).first { $0.id == "monitor" })
            #expect(
                persistedPane.content == .codePane(deviceID: deviceID, workspaceID: "workspace-2"),
                "the persisted layout on disk reflects the retarget, not just the in-memory copy")
        }

        /// A detour through the Alerts detail between two workspace presentations does not reset which
        /// workspace `showWorkspaceDetail` last presented: retargeting must key off the workspace the user
        /// actually last selected (`lastPresentedWorkspaceDetailID`), not off whatever `detailPane` happens
        /// to be showing right now (`visibleDetailWorkspaceID`, which Alerts nils out). Without the fix,
        /// presenting workspace-1 again after the Alerts detour would see `previousWorkspaceID == nil` (since
        /// visiting Alerts nil'd out `visibleDetailWorkspaceID`) and skip the retarget, leaving the monitor
        /// incorrectly stranded on workspace-2. Reaches Alerts via `showAlertsDetail`, the same production
        /// entry point the sidebar's Alerts row and its keyboard shortcut both call (round-16 Fix 2).
        @Test func alertsDetourBetweenTwoWorkspacePresentationsStillRetargetsOnReturn() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "monitor", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            let (project1, workspace1) = try #require(controller.findWorkspace(id: "workspace-1"))
            let (project2, workspace2) = try #require(controller.findWorkspace(id: "workspace-2"))

            // First-ever presentation this session (a no-op retarget, same as the sibling test above), then
            // a real change to workspace-2.
            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)
            controller.showWorkspaceDetail(project: project2, workspace: workspace2, presentation: .userNavigation)
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).first { $0.id == "monitor" }?.content
                    == .codePane(deviceID: deviceID, workspaceID: "workspace-2"), "precondition: the monitor retargeted to workspace-2")

            // A detour through Alerts: nils out `visibleDetailWorkspaceID`, but must not disturb which
            // workspace was last presented.
            controller.showAlertsDetail(presentation: .userNavigation)

            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)

            let retargetedContent = try #require(
                controller.panelCoordinator.codePaneContent(forPaneID: "monitor") as? CodePaneContentController,
                "the monitor's pane id keeps a live controller after retargeting back")
            #expect(retargetedContent.workspaceID == "workspace-1", "the monitor retargets back to workspace-1 despite the Alerts detour")
            #expect(retargetedContent.initialMode == .diff, "the retargeted monitor lands in diff mode")
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).first { $0.id == "monitor" }?.content
                    == .codePane(deviceID: deviceID, workspaceID: "workspace-1"), "the layout's pane descriptor moves back to workspace-1")
        }

        /// A same-workspace reselection must never retarget the monitor, whether or not an Alerts detour
        /// sits in between — control for the test above, proving the fix only restores the A → Alerts → B
        /// retarget without making an unrelated case (A → Alerts → A) start retargeting instead.
        @Test func sameWorkspaceReselectionAcrossAnAlertsDetourDoesNotRetarget() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "monitor", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            let (project1, workspace1) = try #require(controller.findWorkspace(id: "workspace-1"))

            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)
            let contentAfterFirstPresentation = try #require(controller.panelCoordinator.codePaneContent(forPaneID: "monitor"))

            controller.showAlertsDetail(presentation: .userNavigation)
            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)

            #expect(
                (controller.panelCoordinator.codePaneContent(forPaneID: "monitor") as AnyObject?) === (contentAfterFirstPresentation as AnyObject?),
                "a same-workspace reselection never retargets the monitor, even across an Alerts detour")
        }

        /// An overview tick re-presenting the workspace already shown (`showWorkspaceDetail` firing
        /// repeatedly for an unchanged selection, as it does on every background refresh) must not churn
        /// a monitor: no retarget, no new controller instance.
        @Test func overviewTickRepresentingTheSameWorkspaceDoesNotChurnTheMonitor() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "monitor", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            let (project1, workspace1) = try #require(controller.findWorkspace(id: "workspace-1"))
            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)
            let contentAfterFirstPresentation = try #require(controller.panelCoordinator.codePaneContent(forPaneID: "monitor"))

            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .backgroundRefresh)
            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .backgroundRefresh)

            #expect(
                (controller.panelCoordinator.codePaneContent(forPaneID: "monitor") as AnyObject?) === (contentAfterFirstPresentation as AnyObject?),
                "repeated presentation of the same workspace never retargets or replaces the monitor's controller")
        }

        /// Reusing a global singleton for `openOrFocusGlobalEditorWindow` whose workspace it does not
        /// currently show retargets it — closing and reinstalling on the same pane id (`retargetCodePane`,
        /// shared with `retargetGlobalWindowCodePanes`) — and lands in `.diff` mode, the mode every
        /// open-editor entry point requests.
        @Test func openOrFocusGlobalEditorWindowRetargetsAnExistingSingletonToDiffMode() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "monitor", content: .codePane(deviceID: deviceID, workspaceID: "workspace-2")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            let originalContent = try #require(controller.panelCoordinator.codePaneContent(forPaneID: "monitor"))

            let focused = controller.panelCoordinator.openOrFocusGlobalEditorWindow(deviceID: deviceID, workspaceID: "workspace-1")

            #expect(focused)
            let retargetedContent = try #require(
                controller.panelCoordinator.codePaneContent(forPaneID: "monitor") as? CodePaneContentController,
                "the singleton's pane id keeps a live controller after retargeting")
            #expect((retargetedContent as AnyObject?) !== (originalContent as AnyObject?), "retarget installs a fresh controller instance")
            #expect(retargetedContent.workspaceID == "workspace-1", "the new controller is scoped to the requested workspace")
            #expect(retargetedContent.initialMode == .diff, "every open-editor entry point lands in diff mode")
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).first { $0.id == "monitor" }?.content
                    == .codePane(deviceID: deviceID, workspaceID: "workspace-1"), "the layout's pane descriptor moves to the requested workspace")
            #expect(controller.panelCoordinator.layout(for: scope).focusedPaneID == "monitor", "the retargeted singleton is focused")
        }

        /// Deleting (or otherwise retiring) a monitor's target workspace closes its pane through the
        /// existing, unmodified `closeCodePanes` path — retargeting introduces no special-case fallback
        /// that would try to move the monitor to some other workspace instead of closing it.
        @Test func deletingAMonitorsWorkspaceClosesItsPaneViaTheExistingPrunePath() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "monitor", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            let (project1, workspace1) = try #require(controller.findWorkspace(id: "workspace-1"))
            let (project2, workspace2) = try #require(controller.findWorkspace(id: "workspace-2"))
            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)
            controller.showWorkspaceDetail(project: project2, workspace: workspace2, presentation: .userNavigation)
            #expect(
                controller.panelCoordinator.codePaneContent(forPaneID: "monitor") != nil,
                "precondition: the monitor retargeted to workspace-2 and is still open")

            controller.panelCoordinator.closeCodePanes(workspaceID: "workspace-2")

            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).isEmpty,
                "the monitor's pane closes through the existing prune path rather than retargeting elsewhere")
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "monitor") == nil, "its controller is torn down")
        }

        /// A restored monitor stays on its persisted workspace through the first `showWorkspaceDetail`
        /// call of a session (even one presenting a *different* workspace than the monitor holds — restore
        /// must not retarget, full stop) and only moves once a genuine subsequent selection change fires.
        @Test func restoreLeavesAMonitorOnItsSavedWorkspaceUntilARealSelectionChange() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.globalWindow(panelWindowID: "panel-1")
            // Restored monitor is already on workspace-1, matching what its persisted layout says.
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "monitor", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            let restoredContent = try #require(controller.panelCoordinator.codePaneContent(forPaneID: "monitor"))
            let (project2, workspace2) = try #require(controller.findWorkspace(id: "workspace-2"))

            // The session's very first presented workspace is a *different* one (workspace-2) — e.g. the
            // sidebar's default selection at launch. Restore's monitor must not react to this.
            controller.showWorkspaceDetail(project: project2, workspace: workspace2, presentation: .userNavigation)

            #expect(
                (controller.panelCoordinator.codePaneContent(forPaneID: "monitor") as AnyObject?) === (restoredContent as AnyObject?),
                "the first-ever presentation this session does not retarget the restored monitor, even to a workspace other than its own")
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).first { $0.id == "monitor" }?.content
                    == .codePane(deviceID: deviceID, workspaceID: "workspace-1"), "the monitor is still on its persisted workspace")

            let (project1, workspace1) = try #require(controller.findWorkspace(id: "workspace-1"))
            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)
            // A genuine subsequent change (workspace-2 -> workspace-1, both real presentations now)
            // retargets normally.
            controller.showWorkspaceDetail(project: project2, workspace: workspace2, presentation: .userNavigation)

            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).first { $0.id == "monitor" }?.content
                    == .codePane(deviceID: deviceID, workspaceID: "workspace-2"), "a real subsequent selection change still retargets the monitor")
        }

        // MARK: - Legacy multi-tab global window restore (decision: global windows carry no tabs)

        /// A global panel window persisted before global windows dropped tabs can still have more than
        /// one tab in its saved layout. Restoring it must not collapse or drop any of them: each tab
        /// becomes its own single-tab window, the original record's id and frame staying with its first
        /// tab. The split result is persisted immediately so this is a one-time migration.
        @Test func reopenPersistedPanelWindowsSplitsALegacyMultiTabWindowIntoOneWindowPerTab() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            var legacyLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code-1", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            legacyLayout = PanelLayoutEngine.appendUnselectedTab(
                tabID: "tab-2", pane: Pane(id: "code-2", content: .codePane(deviceID: deviceID, workspaceID: "workspace-2")), to: legacyLayout)
            let json = String(decoding: try JSONEncoder().encode(legacyLayout), as: UTF8.self)
            try controller.clientDatabase().upsertPanelWindow(
                SpacesClientDatabase.PanelWindowRecord(id: "legacy-1", layoutJSON: json, frame: (x: 10, y: 20, width: 300, height: 200)))

            controller.reopenPersistedPanelWindowsIfPossible()

            let originalScope = PanelScope.globalWindow(panelWindowID: "legacy-1")
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: originalScope)).map(\.id) == ["code-1"],
                "the original record keeps its id and its first tab only")
            let persistedRows = try controller.clientDatabase().panelWindows()
            #expect(persistedRows.count == 2, "the split result is persisted as two rows, not left as one multi-tab row")
            let splitOffRow = try #require(persistedRows.first { $0.id != "legacy-1" })
            let splitOffLayout = try JSONDecoder().decode(PanelLayout.self, from: Data(splitOffRow.layoutJSON.utf8))
            #expect(splitOffLayout.tabs.map(\.id) == ["tab-2"], "the second tab becomes its own window, with no tab lost or collapsed")
            #expect(PanelLayoutEngine.allPanes(in: splitOffLayout).map(\.id) == ["code-2"])
            #expect(splitOffRow.frame?.x == 34, "the split-off window's frame is cascaded off the original rather than stacking exactly on it")
        }
    }
}
