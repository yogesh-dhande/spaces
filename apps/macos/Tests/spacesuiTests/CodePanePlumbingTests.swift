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
        /// enough to let a persisted terminal pane restore without being pruned.
        private func section(deviceID: String, sessionID: String, workspaceID: String = "workspace-1") -> AppKitController.DeviceSection {
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
            controller.panelCoordinator.restoreSelection(scope: scope)

            let terminalContentBefore = controller.panelCoordinator.content(forSessionID: "sess-1")
            #expect(terminalContentBefore != nil, "precondition: the terminal pane's controller exists")
            let codeContent = try #require(
                controller.panelCoordinator.codePaneContent(forPaneID: "code") as? CodePaneContentController,
                "precondition: the code pane's controller exists")
            #expect(codeContent.contentView.subviews.contains { $0 is WKWebView }, "precondition: the selected tab's code pane is activated")

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView?.addSubview(panelView)
            #expect(panelView.window === window, "precondition: the panel view joined a window")

            panelView.removeFromSuperview()

            #expect(!codeContent.contentView.subviews.contains { $0 is WKWebView }, "leaving the window tears down the code pane's web view")
            #expect(
                (controller.panelCoordinator.content(forSessionID: "sess-1") as AnyObject?) === (terminalContentBefore as AnyObject?),
                "the terminal pane's controller is untouched by the detach path")

            window.contentView?.addSubview(panelView)

            #expect(
                codeContent.contentView.subviews.contains { $0 is WKWebView }, "rejoining the window rebuilds the code pane's web view")
        }
    }
}
