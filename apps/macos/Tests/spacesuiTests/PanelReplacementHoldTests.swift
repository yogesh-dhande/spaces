import AppKit
import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Covers the hold a programmatic restart places on a pane while its replacement launches.
    ///
    /// Builds a real `AppKitController` the way `MainWindowCloseBehaviorTests` does (a fabricated
    /// lease/profile pointing at a throwaway directory, so the suite never touches real lease state), then
    /// drives its `PanelCoordinator` directly. Nests under `ProcessProfileEnvironmentSuites` because it
    /// mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class PanelReplacementHoldTests {
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

        /// The restart the hold exists for usually targets a workspace the user is not viewing, whose
        /// panel has never been materialized, so there is no in-memory pane to point at. Recording the
        /// hold has to happen anyway: it is what stops restore-time pruning from dropping that workspace's
        /// persisted pane before the replacement arrives to claim its slot.
        @Test func aHoldIsRecordedForAWorkspaceWhosePanelWasNeverShown() {
            let coordinator = makeController().panelCoordinator
            #expect(coordinator.placement(forSessionID: "predecessor") == nil, "precondition: nothing is materialized for this session")

            coordinator.closePane(forSessionID: "predecessor", sessionIsTerminating: true, disposition: .awaitReplacement)

            #expect(coordinator.sessionIDsHeldForReplacement.contains("predecessor"))
        }

        /// The same case driven through the handler the close IPC actually lands in, which is one layer
        /// above the coordinator and is where a placement gate was swallowing the disposition: the
        /// coordinator never saw the hold, so a workspace the user was not viewing lost its pane position
        /// exactly as it did before the hold existed. Every close is forwarded now, whatever the layout
        /// currently holds in memory.
        @Test func theCloseHandlerForwardsAHoldForAWorkspaceWhosePanelWasNeverShown() {
            let controller = makeController()
            #expect(controller.panelCoordinator.placement(forSessionID: "predecessor") == nil, "precondition: nothing is materialized")

            controller.closeTerminalSessionPane(sessionID: "predecessor", sessionIsTerminating: true, disposition: .awaitReplacement)

            #expect(controller.panelCoordinator.sessionIDsHeldForReplacement.contains("predecessor"))
        }

        /// And the handler's own report tells the three outcomes apart, so a hold recorded without a pane
        /// is a success rather than the nothing-to-do case it used to be filed under.
        @Test func theCloseHandlerReportsAHoldSeparatelyFromHavingNothingToDo() {
            #expect(AppKitController.terminalPaneCloseRoute(hasPlacement: false, disposition: .awaitReplacement) == .hold)
            #expect(AppKitController.terminalPaneCloseRoute(hasPlacement: false, disposition: .teardown) == .missingPane)
            #expect(AppKitController.terminalPaneCloseRoute(hasPlacement: true, disposition: .awaitReplacement) == .pane)
            #expect(AppKitController.terminalPaneCloseRoute(hasPlacement: true, disposition: .teardown) == .pane)
        }

        /// The two IPCs are independent, so a replacement's open can be processed before the close it
        /// replaces. If that open then fails, its release runs against a session nothing is holding yet.
        /// Dropping it silently would strand the hold the close is about to record, because the daemon
        /// consumed the reservation when it launched the replacement and sends nothing further. The
        /// release is remembered instead, and the arriving hold converts straight to a teardown.
        @Test func aReleaseThatBeatsItsHoldSettlesTheHoldOnArrival() {
            let controller = makeController()

            controller.panelCoordinator.releasePaneHeldForReplacement(sessionID: "predecessor")
            controller.closeTerminalSessionPane(sessionID: "predecessor", sessionIsTerminating: true, disposition: .awaitReplacement)

            #expect(controller.panelCoordinator.sessionIDsHeldForReplacement.isEmpty, "the hold is settled on arrival, not left waiting")
        }

        /// Content construction is the failure mode the modal rule was missing: credential preparation
        /// succeeds and `makeTerminalPaneContent` then throws (the device disappeared, the session's
        /// metadata is unavailable), and its catch raised a modal regardless of intent. A background
        /// launch failing that way must stay silent, exactly as a failed preparation does.
        ///
        /// Reaching `showError` presents a real `NSAlert.runModal()`, which would hang this suite, so a
        /// non-focusing construction failure returning without hanging is what the assertion rests on.
        @Test func aFailedContentConstructionRaisesNoModalForANonFocusingOpen() {
            let controller = makeController()

            let content = controller.makeTerminalPaneContent(
                request: AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: "workspace-1", deviceID: "local", sessionID: "no-such-session", title: "t", workingDirectory: "/tmp", kind: .shell),
                focusIntent: .withoutFocus)

            #expect(content == nil, "construction failed and reported itself without interrupting the user")
        }

        /// The last ordering cell: the replacement's open is processed before its predecessor's close, the
        /// workspace panel has never been materialized, and the stop has already dropped the predecessor
        /// from the overview. The open restores the panel itself, and with no hold recorded yet an
        /// unprotected restore would prune the very pane the open is about to claim, so the replacement
        /// would land as a new tab and the late close could no longer put it back. The open protects its
        /// own named predecessor for the duration of that restore.
        @Test func anOpenProtectsItsOwnPredecessorFromTheRestoreItTriggers() throws {
            let controller = makeController()
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "a", content: .terminalSession(deviceID: "local", sessionID: "predecessor")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: "local", workspaceID: "workspace-1", layoutJSON: json)

            // No overview and no hold recorded, which is exactly the state an open-before-close restore runs in.
            let unprotected = controller.restoredWorkspacePanelLayout(deviceID: "local", workspaceID: "workspace-1")
            let protected = controller.restoredWorkspacePanelLayout(
                deviceID: "local", workspaceID: "workspace-1", additionalKeepSessionIDs: ["predecessor"])

            #expect(unprotected?.isEmpty ?? true, "without protection the predecessor's pane is pruned before the open can claim it")
            #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: protected ?? PanelLayout()) == ["predecessor"])
        }

        /// The mirror of the early release: a replacement open processed before its predecessor's close
        /// finds the predecessor still placed and retargets straight away, so the pane belongs to the
        /// replacement by the time the close lands. The late hold must be a no-op. Recording it would
        /// leave a dead id in every keep-set, and treating it as an ordinary hold to tear down would kill
        /// the pane the replacement is now living in.
        @Test func aClaimThatBeatsItsCloseMakesTheLateHoldANoOp() {
            #expect(AppKitController.terminalPaneHoldAction(hasPendingClaim: true, hasPendingRelease: false) == .consumeClaim)
        }

        /// All three orders of the close and its replacement's open, which are independent IPCs. A pending
        /// claim wins over a pending release: a claim that succeeded is authoritative about where the pane
        /// went, while a release only says some open did not claim it.
        @Test func theHoldTransitionCoversEveryOrderOfTheTwoMessages() {
            #expect(AppKitController.terminalPaneHoldAction(hasPendingClaim: false, hasPendingRelease: false) == .hold)
            #expect(AppKitController.terminalPaneHoldAction(hasPendingClaim: false, hasPendingRelease: true) == .teardown)
            #expect(AppKitController.terminalPaneHoldAction(hasPendingClaim: true, hasPendingRelease: true) == .consumeClaim)
        }

        /// The ordinary order still holds a pane: a release only converts the *next* hold when it arrived
        /// first, so remembering the intent cannot make an unrelated later restart fail to hold.
        @Test func aReleaseIsConsumedByOneHoldOnly() {
            let controller = makeController()
            controller.panelCoordinator.releasePaneHeldForReplacement(sessionID: "predecessor")
            controller.closeTerminalSessionPane(sessionID: "predecessor", sessionIsTerminating: true, disposition: .awaitReplacement)

            controller.closeTerminalSessionPane(sessionID: "predecessor", sessionIsTerminating: true, disposition: .awaitReplacement)

            #expect(controller.panelCoordinator.sessionIDsHeldForReplacement.contains("predecessor"), "a later restart holds normally again")
        }

        /// A predecessor whose pane the user closed before the restart leaves an id-only hold with no pane
        /// behind it. The replacement then succeeds by installing a fresh pane rather than claiming, and
        /// that has to release the hold: counting any successful open as a claim left the id in every
        /// restoration keep-set for the life of the app.
        @Test func aFallbackInstallReleasesTheHoldItNeverClaimed() {
            #expect(
                AppKitController.heldPredecessorSessionToRelease(replacesSessionID: "predecessor", openAction: .installUnselectedTab) == "predecessor"
            )
            #expect(AppKitController.heldPredecessorSessionToRelease(replacesSessionID: "predecessor", openAction: .claimReplacedPane) == nil)
            #expect(AppKitController.heldPredecessorSessionToRelease(replacesSessionID: "predecessor", openAction: nil) == "predecessor")
            #expect(AppKitController.heldPredecessorSessionToRelease(replacesSessionID: nil, openAction: .installUnselectedTab) == nil)
        }

        // MARK: - Overview-driven retarget

        private func openRequest(sessionID: String, workspaceID: String = "workspace-1") -> AppKitController.DeviceTerminalOpenRequest {
            AppKitController.DeviceTerminalOpenRequest(
                workspaceID: workspaceID, deviceID: "local", sessionID: sessionID, title: "api", workingDirectory: "/tmp", kind: .process)
        }

        /// A start or restart of a runtime target is served by the Device API, whose orchestrator has no
        /// opener to any client, so the replacement's open never arrives and the overview diff is the only
        /// thing that names the pairing. Whatever that retarget can or cannot do with the pane, it is the
        /// last word on the restart: leaving the hold behind would keep a dead session's pane alive, and
        /// its id in every keep-set, until the app relaunched.
        @Test func anOverviewReplacementAlwaysSettlesTheHoldItsCloseRecorded() {
            let controller = makeController()
            let coordinator = controller.panelCoordinator
            coordinator.closePane(forSessionID: "predecessor", sessionIsTerminating: true, disposition: .awaitReplacement)

            coordinator.retargetPaneForReplacement(replacedSessionID: "predecessor", request: openRequest(sessionID: "replacement"))

            #expect(coordinator.sessionIDsHeldForReplacement.isEmpty)
        }

        /// Restarting a target the user never had a pane open for must not conjure one. The open path
        /// installs a pane when it has no predecessor to claim, which is right for an open the user asked
        /// for and wrong for a refresh: every restart on any client would land a pane on this one.
        @Test func anOverviewReplacementForATargetWithNoPaneOpensNothing() {
            let controller = makeController()
            let coordinator = controller.panelCoordinator

            coordinator.retargetPaneForReplacement(replacedSessionID: "predecessor", request: openRequest(sessionID: "replacement"))

            #expect(coordinator.openPanes().isEmpty)
            #expect(coordinator.sessionIDsHeldForReplacement.isEmpty)
        }

        /// The ordinary shape of a restart the user is not watching: the workspace's panel has never been
        /// materialized this launch, so the held pane exists only in the persisted layout. The retarget
        /// restores that panel — protecting the predecessor from the pruning the restore would otherwise
        /// apply, since the device no longer retains its session — and hands the pane to the replacement in
        /// the slot the predecessor held, ahead of the workspace's other pane. The predecessor's id is gone
        /// from the layout, so nothing keeps a dead session's pane, and the hold is settled.
        @Test func aHeldPersistedPaneIsHandedToTheReplacementInPlace() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "a", content: .terminalSession(deviceID: deviceID, sessionID: "predecessor")), to: PanelLayout())
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-2", pane: Pane(id: "b", content: .terminalSession(deviceID: deviceID, sessionID: "other")), to: layout)
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            controller.deviceSections = [section(deviceID: deviceID, processSessionID: "replacement", retained: ["replacement", "other"])]
            controller.rebuildFlatSidebarData()
            controller.closeTerminalSessionPane(sessionID: "predecessor", sessionIsTerminating: true, disposition: .awaitReplacement)

            controller.panelCoordinator.retargetPaneForReplacement(replacedSessionID: "predecessor", request: openRequest(sessionID: "replacement"))

            #expect(controller.panelCoordinator.sessionIDsHeldForReplacement.isEmpty, "the hold is settled by the retarget")
            let restored = controller.panelCoordinator.layout(for: .workspace(deviceID: deviceID, workspaceID: "workspace-1"))
            #expect(
                PanelLayoutEngine.orderedTerminalSessionIDs(in: restored) == ["replacement", "other"],
                "the replacement took the predecessor's slot rather than being appended after the workspace's other pane")
            let persisted = try #require(try controller.clientDatabase().workspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1"))
            let persistedLayout = try JSONDecoder().decode(PanelLayout.self, from: Data(persisted.utf8))
            #expect(
                PanelLayoutEngine.orderedTerminalSessionIDs(in: persistedLayout) == ["replacement", "other"],
                "the handover is persisted, so a relaunch restores the replacement and not the session it replaced")
        }

        /// The remote-daemon shape, and the reason the retarget cannot key off the hold: a device reached
        /// over the network posts no close IPC at all, so nothing marks the pane and the refreshed overview
        /// is the only word that the process row's session changed. The pane is simply still placed and no
        /// longer retained, one prune away from closing. Driven in the order the refresh runs in: install
        /// the overview, retarget against the previous one, then prune.
        @Test func aPlacedPaneIsHandedOverWithNoCloseEverArriving() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            let layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "a", content: .terminalSession(deviceID: deviceID, sessionID: "predecessor")), to: PanelLayout())
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            let before = section(deviceID: deviceID, processSessionID: "predecessor", retained: ["predecessor"])
            controller.deviceSections = [before]
            controller.rebuildFlatSidebarData()
            let scope = PanelScope.workspace(deviceID: deviceID, workspaceID: "workspace-1")
            controller.panelCoordinator.restoreLayoutIfNeeded(scope: scope, focusIntent: .withoutFocus)
            #expect(controller.panelCoordinator.placement(forSessionID: "predecessor") != nil, "precondition: the pane is placed and unheld")

            let after = section(deviceID: deviceID, processSessionID: "replacement", retained: ["replacement"], createdAt: "2026-01-01T00:01:00Z")
            controller.deviceSections = [after]
            controller.rebuildFlatSidebarData()
            controller.retargetReplacedTerminalPanes(previousOverview: before.overview, overview: try #require(after.overview), deviceID: deviceID)
            controller.panelCoordinator.pruneOpenPanes(deviceID: deviceID, catalogSessionIDs: ["replacement"])

            #expect(
                PanelLayoutEngine.orderedTerminalSessionIDs(in: controller.panelCoordinator.layout(for: scope)) == ["replacement"],
                "the pane survived the refresh pointing at the replacement instead of being pruned away")
        }

        /// Fix for the remote-daemon gap one step further than `aPlacedPaneIsHandedOverWithNoCloseEverArriving`:
        /// there the predecessor's panel had already been restored (its pane was placed, just unheld). Here
        /// the panel has never been materialized this launch either, so the predecessor starts with neither
        /// a hold nor an in-memory placement — only a persisted layout. The restore attempt does not depend
        /// on a hold, so the pane is still found and handed over in place.
        @Test func aPersistedPaneWithNoHoldIsHandedToTheReplacementInPlace() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "a", content: .terminalSession(deviceID: deviceID, sessionID: "predecessor")), to: PanelLayout())
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-2", pane: Pane(id: "b", content: .terminalSession(deviceID: deviceID, sessionID: "other")), to: layout)
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            controller.deviceSections = [section(deviceID: deviceID, processSessionID: "replacement", retained: ["replacement", "other"])]
            controller.rebuildFlatSidebarData()
            #expect(controller.panelCoordinator.sessionIDsHeldForReplacement.isEmpty, "precondition: no close ever recorded a hold")
            #expect(controller.panelCoordinator.placement(forSessionID: "predecessor") == nil, "precondition: nothing is materialized yet")

            let claimed = controller.panelCoordinator.retargetPaneForReplacement(
                replacedSessionID: "predecessor", request: openRequest(sessionID: "replacement"))

            #expect(claimed)
            let restored = controller.panelCoordinator.layout(for: .workspace(deviceID: deviceID, workspaceID: "workspace-1"))
            #expect(
                PanelLayoutEngine.orderedTerminalSessionIDs(in: restored) == ["replacement", "other"],
                "the replacement took the predecessor's slot rather than being appended after the workspace's other pane")
        }

        /// A session id with no home anywhere — never held, never placed, no persisted layout, no pending
        /// panel window record — must still be rejected: the retarget cannot conjure a pane for a
        /// replacement that had nothing to inherit.
        @Test func aWhollyUnknownPredecessorSessionIsRejected() {
            let controller = makeController()

            let claimed = controller.panelCoordinator.retargetPaneForReplacement(
                replacedSessionID: "nonexistent-predecessor", request: openRequest(sessionID: "replacement"))

            #expect(!claimed)
            #expect(controller.panelCoordinator.openPanes().isEmpty)
        }

        // MARK: - Replacement epoch

        /// `paneReplacementEpoch` is what tells a client-side overview apply that its data predates a pane
        /// replacement (see `SidebarController.applySidebarDataSnapshot`/`applyRemoteDeviceSection`), so a
        /// successful retarget must bump it. Reuses the persisted-pane-with-no-hold shape, the simplest
        /// scenario that reaches a claim.
        @Test func aSuccessfulRetargetBumpsTheReplacementEpoch() throws {
            let controller = makeController()
            let deviceID = controller.localDeviceID
            var layout = PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "a", content: .terminalSession(deviceID: deviceID, sessionID: "predecessor")), to: PanelLayout())
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-2", pane: Pane(id: "b", content: .terminalSession(deviceID: deviceID, sessionID: "other")), to: layout)
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            try controller.clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: "workspace-1", layoutJSON: json)
            controller.deviceSections = [section(deviceID: deviceID, processSessionID: "replacement", retained: ["replacement", "other"])]
            controller.rebuildFlatSidebarData()
            let epochBeforeRetarget = controller.panelCoordinator.paneReplacementEpoch

            let claimed = controller.panelCoordinator.retargetPaneForReplacement(
                replacedSessionID: "predecessor", request: openRequest(sessionID: "replacement"))

            #expect(claimed)
            #expect(controller.panelCoordinator.paneReplacementEpoch == epochBeforeRetarget + 1)
        }

        /// A retarget that finds nothing to claim changes nothing about any pane, so it must not bump the
        /// epoch either: a bump with no accompanying replacement would make a client skip a prune it still
        /// owed, over a session change that never happened.
        @Test func aRejectedRetargetLeavesTheReplacementEpochUnchanged() {
            let controller = makeController()
            let epochBeforeRetarget = controller.panelCoordinator.paneReplacementEpoch

            let claimed = controller.panelCoordinator.retargetPaneForReplacement(
                replacedSessionID: "nonexistent-predecessor", request: openRequest(sessionID: "replacement"))

            #expect(!claimed)
            #expect(controller.panelCoordinator.paneReplacementEpoch == epochBeforeRetarget)
        }

        /// One local device holding the workspace the retarget runs against: enough sidebar data to resolve
        /// the workspace's device and panel scope, the session behind its process row, and a retention
        /// keep-set for its restore. `createdAt` defaults to a fixed instant; the overview-diffing retarget
        /// test below passes a later one for the replacement so the pairing clears the diff's ordering gate
        /// (`TerminalSessionReplacementDiff` requires the replacement to be strictly newer).
        private func section(deviceID: String, processSessionID: String, retained: [String], createdAt: String = "2026-01-01T00:00:00Z")
            -> AppKitController.DeviceSection
        {
            let workspace = SpacesDeviceWorkspaceSummary(
                id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/workspace-1",
                isRunning: true, isHidden: false, isDefault: false, sessionCount: 1,
                processRows: [
                    SpacesDeviceWorkspaceProcessRow(
                        id: "api", workspaceID: "workspace-1", name: "api", command: "echo api", processID: "process-1", sessionID: processSessionID,
                        runState: .running, canRun: true, canStop: true, canRestart: true)
                ])
            let overview = SpacesDeviceOverviewPayload(
                projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
                workspaces: [workspace],
                sessions: [
                    SpacesDeviceTerminalSessionSummary(
                        id: processSessionID, title: "api", workingDirectory: "/tmp/workspace-1", shell: "/bin/zsh", command: "echo api",
                        state: .running, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678,
                        workspaceID: "workspace-1", workspaceTitle: "feature", projectID: "project-1", projectName: "Project",
                        createdAt: createdAt, updatedAt: createdAt, isControlAvailable: true, isSubscriptionAvailable: true,
                        attachmentSnapshot: .init(), rowKind: .process)
                ], retainedTerminalSessionIDs: retained)
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        /// An ordinary teardown close of a session with no materialized pane records nothing, so a plain
        /// stop cannot leave a hold behind that would protect a pane forever.
        @Test func anOrdinaryCloseRecordsNoHold() {
            let coordinator = makeController().panelCoordinator

            coordinator.closePane(forSessionID: "predecessor", sessionIsTerminating: true, disposition: .teardown)

            #expect(coordinator.sessionIDsHeldForReplacement.isEmpty)
        }

        /// Releasing a hold that was placed without a materialized pane clears it, so the failed-open
        /// release path and the daemon's teardown both settle a hold whichever state its panel is in.
        @Test func releasingAHoldClearsItEvenWithNoMaterializedPane() {
            let coordinator = makeController().panelCoordinator
            coordinator.closePane(forSessionID: "predecessor", sessionIsTerminating: true, disposition: .awaitReplacement)

            coordinator.closePane(forSessionID: "predecessor", sessionIsTerminating: true, disposition: .teardown)

            #expect(coordinator.sessionIDsHeldForReplacement.isEmpty)
        }
    }
}
