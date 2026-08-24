import AppKit
import Testing
import WebKit
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Covers Phase 1 of the code-pane feature at the `PanelCoordinator` level: the dual-store keying
    /// (terminal panes by session id in `contentControllers`, code panes by pane id in
    /// `codePaneControllers`) and restore of a persisted `.codePane` pane.
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
            deviceID: String, sessionID: String, workspaceID: String = "workspace-1",
            loadState: AppKitController.SidebarDeviceLoadState = .loaded
        ) -> AppKitController.DeviceSection {
            let workspace = SpacesDeviceWorkspaceSummary(
                id: workspaceID, projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                dir: "/tmp/\(workspaceID)", isRunning: true, isHidden: false, isDefault: false, sessionCount: 1, processRows: [])
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
                id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature-1", baseBranch: "main",
                dir: "/tmp/workspace-1", isRunning: true, isHidden: false, isDefault: false, sessionCount: 0, processRows: [])
            let workspace2 = SpacesDeviceWorkspaceSummary(
                id: "workspace-2", projectID: "project-1", projectName: "Project", branch: "feature-2", baseBranch: "main",
                dir: "/tmp/workspace-2", isRunning: true, isHidden: false, isDefault: false, sessionCount: 0, processRows: [])
            let overview = SpacesDeviceOverviewPayload(
                projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
                workspaces: [workspace1, workspace2], sessions: [], retainedTerminalSessionIDs: [])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        /// A workspace panel restoring a terminal pane and a code pane side by side resolves each to its
        /// own controller instance: the terminal by session id in `contentControllers`, the code pane by
        /// pane id in `codePaneControllers`. Proves the dual-store design keeps the two content kinds from
        /// colliding rather than one overwriting the other.
        @Test func aTerminalPaneAndACodePaneKeyToDistinctControllers() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "term", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1")), to: PanelLayout())
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-2", pane: Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: layout)
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()

            controller.panelCoordinator.restoreLayoutIfNeeded(
                scope: .workspace(deviceID: deviceID, workspaceID: "workspace-1"), focusIntent: .withoutFocus)

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
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "term", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1")), to: PanelLayout())
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-2", pane: Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: layout)
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()
            controller.panelCoordinator.restoreLayoutIfNeeded(
                scope: .workspace(deviceID: deviceID, workspaceID: "workspace-1"), focusIntent: .withoutFocus)
            let codeContentBefore = controller.panelCoordinator.codePaneContent(forPaneID: "code")
            #expect(codeContentBefore != nil, "precondition: the code pane's controller exists")

            controller.panelCoordinator.closePane(forSessionID: "sess-1", sessionIsTerminating: true)

            #expect(controller.panelCoordinator.content(forSessionID: "sess-1") == nil, "the terminal session's controller is gone")
            let codeContentAfter = controller.panelCoordinator.codePaneContent(forPaneID: "code")
            #expect(
                (codeContentBefore as AnyObject?) === (codeContentAfter as AnyObject?),
                "the code pane's controller is untouched by the unrelated terminal session closing")
        }

        /// A persisted `.codePane` pane is rebuilt on restore rather than dropped: the layout keeps the
        /// pane, and the pane is backed by a live controller, not merely an inert layout entry. Exercised
        /// with no device overview at all, since a code pane carries no daemon-side session to reconcile
        /// and so does not depend on one to restore.
        @Test func restoringAWorkspacePanelRebuildsAPersistedCodePane() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)

            controller.panelCoordinator.restoreLayoutIfNeeded(
                scope: .workspace(deviceID: deviceID, workspaceID: "workspace-1"), focusIntent: .withoutFocus)

            let restored = controller.panelCoordinator.layout(for: .workspace(deviceID: deviceID, workspaceID: "workspace-1"))
            #expect(PanelLayoutEngine.allPanes(in: restored).map(\.id) == ["code"], "the code pane is not dropped by restore")
            #expect(
                controller.panelCoordinator.codePaneContent(forPaneID: "code") != nil,
                "restore rebuilds a live controller for the pane, not just the layout entry")
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
                tabID: "tab-2", pane: Pane(id: "code-other-workspace", content: .codePane(deviceID: deviceID, workspaceID: "workspace-2")), to: layout)
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-3", pane: Pane(id: "code-other-device", content: .codePane(deviceID: "other-device", workspaceID: "workspace-1")),
                to: layout)
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-4", pane: Pane(id: "term", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1")), to: layout)
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code-target") != nil, "precondition: the target pane's controller exists")

            controller.panelCoordinator.closeCodePanes(deviceID: deviceID, workspaceIDs: ["workspace-1"])

            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).map(\.id).sorted()
                    == ["code-other-device", "code-other-workspace", "term"],
                "only the matching device+workspace pane leaves the layout")
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
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).map(\.id).sorted()
                    == ["code-live", "code-other-device"], "workspace-gone's pane on the pruned device closes; the other device's pane does not")
        }

        /// `openOrFocusCodePane` — the "Review changes" shortcut's handler — creates one code pane per
        /// workspace panel and re-focuses it on a second call instead of creating a second one.
        @Test func openOrFocusCodePaneCreatesOnceAndFocusesAfter() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")

            let opened = controller.panelCoordinator.openOrFocusCodePane(deviceID: deviceID, workspaceID: "workspace-1", mode: .diff)
            #expect(opened)
            let paneID = try #require(PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).first?.id)

            let focusedAgain = controller.panelCoordinator.openOrFocusCodePane(deviceID: deviceID, workspaceID: "workspace-1", mode: .diff)

            #expect(focusedAgain)
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).map(\.id) == [paneID],
                "the second call focuses the existing code pane instead of opening a second one")
        }

        /// Fix 6 (P2 review): an already-open code pane stays focusable while its device is offline,
        /// mirroring the terminal-pane parity rule (`canOpenOrFocusTerminalPane`) — focusing a pane that
        /// already exists is client-side, so an unreachable device never withholds it; only *creating* a
        /// fresh one is refused (`PanelCoordinator.mayCreateCodePane`, gated on `.offline`, not merely "no
        /// section yet"). `restoreLayoutIfNeeded` installs the persisted pane's controller unconditionally
        /// (a code pane has no daemon-side session to reconcile), so restoring it is unaffected by the
        /// device's load state, and `openOrFocusCodePane`'s existing-placement branch focuses it without
        /// ever reaching the creation gate — this is deliberately not exercised through the *refused*
        /// creation branch, since that branch's `host.showWorkspaceDeviceUnavailableError` presents a real
        /// `NSAlert.runModal()` that would hang the suite (see `PanelReplacementHoldTests.swift`'s
        /// identical caution); `AppKitControllerDeviceParityTests.aFreshCodePaneIsRefusedForADeviceThatCannotAct`
        /// covers that refusal's pure decision logic instead.
        @Test func openOrFocusCodePaneFocusesAnExistingPaneEvenWhileItsDeviceIsOffline() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1", loadState: .offline("Connection refused"))]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)

            let focused = controller.panelCoordinator.openOrFocusCodePane(deviceID: deviceID, workspaceID: "workspace-1", mode: .diff)

            #expect(focused, "the existing pane focuses even though its device cannot service a fresh creation")
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).map(\.id) == ["code"],
                "no second pane is installed alongside the restored one")
            #expect(controller.panelCoordinator.codePaneContent(forPaneID: "code") != nil, "the restored pane's controller is live")
        }

        /// A code pane already open in a global panel window is the same pane `openOrFocusCodePane` must
        /// find: it focuses that pane instead of installing a duplicate in the workspace's own panel.
        /// Mirrors the terminal convention of focusing a session's pane wherever it lives
        /// (`placement(forSessionID:)`), which the code-pane lookup did not follow before this fix — it
        /// searched only the workspace's own panel scope.
        @Test func openOrFocusCodePaneFocusesAnExistingPaneInAGlobalPanelWindowInsteadOfDuplicating() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()
            let globalScope = PanelScope.globalWindow(panelWindowID: "panel-1")
            let workspaceScope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "code-global", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: layout, frame: nil)

            let focused = controller.panelCoordinator.openOrFocusCodePane(deviceID: deviceID, workspaceID: "workspace-1", mode: .diff)

            #expect(focused)
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: globalScope)).map(\.id) == ["code-global"],
                "no duplicate pane is installed in the global panel window")
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: workspaceScope)).isEmpty,
                "the workspace's own panel gains no code pane")
            #expect(
                controller.panelCoordinator.layout(for: globalScope).focusedPaneID == "code-global",
                "the existing pane in the global panel window is focused")
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
        /// view leaves the window — a workspace switch removing it from the main window's detail container
        /// while keeping the panel alive detached — and rebuilds it when the panel rejoins a window. A
        /// terminal pane in the same selected tab is untouched by the same transition: Ghostty surfaces are
        /// meant to survive detachment, so only code-pane content hibernates.
        @Test func panelLeavingTheWindowHibernatesItsCodePaneButLeavesItsTerminalPaneAlone() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")
            // Both panes sit in the same (only, selected) tab as split children, so restoring selection
            // activates both — proving the terminal pane is left alone rather than merely never having
            // been activated in the first place.
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
                                ]))),
                ], selectedTabID: "tab-1", focusedPaneID: "code")
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)

            controller.panelCoordinator.restoreLayoutIfNeeded(scope: scope, focusIntent: .withoutFocus)
            let panelView = controller.panelCoordinator.panelView(for: scope)
            // Joins a window before `restoreSelection`, matching production order (AppKitController
            // attaches the panel view to the detail container before calling `restoreSelection`): a
            // code pane only activates while its panel view is windowed (Fix 4's window-membership
            // gate in `activateContentIfVisible`), so restoring selection first would leave it
            // inactive and falsify this test's own precondition below.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView?.addSubview(panelView)
            #expect(panelView.window === window, "precondition: the panel view joined a window")
            controller.panelCoordinator.restoreSelection(scope: scope)

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

            window.contentView?.addSubview(panelView)

            #expect(
                codeContent.contentView.subviews.contains { $0 is WKWebView }, "rejoining the window rebuilds the code pane's web view")
        }

        /// Fix 4 regression: a *background* layout mutation reached while the panel is detached must not
        /// undo the hibernation the detach just performed. `closePane(sessionIsTerminating: true)` (an
        /// externally-driven close, e.g. overview pruning — see
        /// `AppKitController.terminalPaneCloseMovesKeyboardFocus`) removes tab-1's only pane, which
        /// removes the whole tab and falls back to selecting tab-2 — the code pane's tab — entirely
        /// through `mutateLayout`'s internal `activateContentIfVisible` scan, never through
        /// `activateFocusedPane` (which would bypass the window-membership gate this test exercises).
        /// Rejoining the window afterward must still activate the code pane the detached scan correctly
        /// skipped.
        @Test func detachedPanelDoesNotReactivateACodePaneSelectedByABackgroundMutation() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [section(deviceID: deviceID, sessionID: "sess-1")]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")
            // tab-1 (selected, terminal-only) and tab-2 (unselected, code pane) — closing tab-1's only
            // pane removes the tab and falls back to tab-2.
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "term", content: .terminalSession(deviceID: deviceID, sessionID: "sess-1")), to: PanelLayout())
            layout = PanelLayoutEngine.appendUnselectedTab(
                tabID: "tab-2", pane: Pane(id: "code", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: layout)
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)

            controller.panelCoordinator.restoreLayoutIfNeeded(scope: scope, focusIntent: .withoutFocus)
            let panelView = controller.panelCoordinator.panelView(for: scope)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView?.addSubview(panelView)
            controller.panelCoordinator.restoreSelection(scope: scope)

            let codeContent = try #require(
                controller.panelCoordinator.codePaneContent(forPaneID: "code") as? CodePaneContentController,
                "precondition: the code pane's controller exists")
            #expect(
                !codeContent.contentView.subviews.contains { $0 is WKWebView },
                "precondition: the code pane's unselected tab is not activated")

            panelView.removeFromSuperview()
            #expect(panelView.window == nil, "precondition: the panel view left the window")

            controller.panelCoordinator.closePane(forSessionID: "sess-1", sessionIsTerminating: true)

            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).map(\.id) == ["code"],
                "precondition: closing tab-1's only pane removed the tab, leaving tab-2 as the sole (and now selected) tab")
            #expect(
                !codeContent.contentView.subviews.contains { $0 is WKWebView },
                "a background mutation selecting the code pane's tab while detached must not activate it")

            window.contentView?.addSubview(panelView)

            #expect(
                codeContent.contentView.subviews.contains { $0 is WKWebView },
                "rejoining the window activates the code pane the detached scan correctly skipped")
        }

        // MARK: - Phase 6: workspace-following review monitors (`.globalWindow` code panes retarget)

        /// The single funnel (`showWorkspaceDetail`) presenting a different workspace than it last
        /// presented retargets every `.globalWindow` code pane to the new workspace: the pane's
        /// descriptor, its persisted layout, its controller instance (a fresh one — retarget is
        /// close-and-reinstall, not a live edit), and its title all move to the newly selected
        /// workspace. The very first `showWorkspaceDetail` call of a session must not retarget — a
        /// restored monitor stays on its saved workspace until a real subsequent change — so this
        /// exercises that call first and confirms it is a no-op before exercising the real change.
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
            #expect(
                retargetedContent.displayTitle == "Code — feature-2",
                "the title reflects the newly selected workspace's name")
            let pane = try #require(PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).first { $0.id == "monitor" })
            #expect(
                pane.content == .codePane(deviceID: deviceID, workspaceID: "workspace-2"),
                "the layout's pane descriptor moves to the new workspace")

            let record = try #require(controller.clientDatabase().panelWindows().first { $0.id == "panel-1" }, "the retarget persists")
            let persistedLayout = try JSONDecoder().decode(PanelLayout.self, from: Data(record.layoutJSON.utf8))
            let persistedPane = try #require(PanelLayoutEngine.allPanes(in: persistedLayout).first { $0.id == "monitor" })
            #expect(
                persistedPane.content == .codePane(deviceID: deviceID, workspaceID: "workspace-2"),
                "the persisted layout on disk reflects the retarget, not just the in-memory copy")
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
                (controller.panelCoordinator.codePaneContent(forPaneID: "monitor") as AnyObject?)
                    === (contentAfterFirstPresentation as AnyObject?),
                "repeated presentation of the same workspace never retargets or replaces the monitor's controller")
        }

        /// A code pane in a workspace's own panel (`.workspace` scope) belongs to that one workspace and
        /// never retargets, even while a `.globalWindow` monitor open at the same time does. Locks in the
        /// Part 3 requirement that placement — not a flag — is what decides retargeting behavior.
        @Test func retargetGlobalWindowCodePanesLeavesAWorkspaceScopedCodePaneUntouched() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            let workspaceScope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")
            let workspaceLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "owned", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(workspaceLayout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            controller.panelCoordinator.restoreLayoutIfNeeded(scope: workspaceScope, focusIntent: .withoutFocus)
            let globalLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "monitor", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: globalLayout, frame: nil)
            let ownedContentBefore = try #require(controller.panelCoordinator.codePaneContent(forPaneID: "owned"))
            let (project1, workspace1) = try #require(controller.findWorkspace(id: "workspace-1"))
            let (project2, workspace2) = try #require(controller.findWorkspace(id: "workspace-2"))
            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)

            controller.showWorkspaceDetail(project: project2, workspace: workspace2, presentation: .userNavigation)

            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: workspaceScope)).map(\.id) == ["owned"],
                "the workspace-scoped pane is neither closed nor moved")
            #expect(
                (controller.panelCoordinator.codePaneContent(forPaneID: "owned") as AnyObject?) === (ownedContentBefore as AnyObject?),
                "the workspace-scoped pane's controller instance is untouched by a retarget targeting the same workspace id")
            let monitorPane = try #require(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: .globalWindow(panelWindowID: "panel-1"))).first {
                    $0.id == "monitor"
                })
            #expect(
                monitorPane.content == .codePane(deviceID: deviceID, workspaceID: "workspace-2"),
                "meanwhile the global-window monitor did retarget")
        }

        /// When a workspace's own panel already holds a code pane for it and a `.globalWindow` monitor is
        /// also retargeted onto the same workspace, `openOrFocusCodePane` still prefers the workspace
        /// panel's pane (`scopeSortKey` sorts `.workspace` before `.globalWindow`) — a monitor existing
        /// alongside the workspace's own pane must not change which one "Review changes" focuses.
        @Test func openOrFocusCodePanePrefersTheWorkspacesOwnPanelPaneOverAGlobalWindowMonitor() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            controller.deviceSections = [twoWorkspaceSection(deviceID: deviceID)]
            controller.rebuildFlatSidebarData()
            let workspaceScope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")
            let workspaceLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "owned", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(workspaceLayout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            controller.panelCoordinator.restoreLayoutIfNeeded(scope: workspaceScope, focusIntent: .withoutFocus)
            let globalLayout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "monitor", content: .codePane(deviceID: deviceID, workspaceID: "workspace-1")), to: PanelLayout())
            controller.panelCoordinator.restorePanelWindow(panelWindowID: "panel-1", layout: globalLayout, frame: nil)

            let focused = controller.panelCoordinator.openOrFocusCodePane(deviceID: deviceID, workspaceID: "workspace-1", mode: .diff)

            #expect(focused)
            #expect(
                controller.panelCoordinator.layout(for: workspaceScope).focusedPaneID == "owned",
                "the workspace's own panel pane is focused, not the global-window monitor")
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: workspaceScope)).map(\.id) == ["owned"],
                "no duplicate pane is installed in the workspace's own panel")
            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: .globalWindow(panelWindowID: "panel-1"))).map(\.id) == [
                    "monitor"
                ], "the global-window monitor is left exactly as it was")
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
                    == .codePane(deviceID: deviceID, workspaceID: "workspace-1"),
                "the monitor is still on its persisted workspace")

            let (project1, workspace1) = try #require(controller.findWorkspace(id: "workspace-1"))
            controller.showWorkspaceDetail(project: project1, workspace: workspace1, presentation: .userNavigation)
            // A genuine subsequent change (workspace-2 -> workspace-1, both real presentations now)
            // retargets normally.
            controller.showWorkspaceDetail(project: project2, workspace: workspace2, presentation: .userNavigation)

            #expect(
                PanelLayoutEngine.allPanes(in: controller.panelCoordinator.layout(for: scope)).first { $0.id == "monitor" }?.content
                    == .codePane(deviceID: deviceID, workspaceID: "workspace-2"),
                "a real subsequent selection change still retargets the monitor")
        }
    }
}
