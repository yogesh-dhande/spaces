import AppKit
import Testing
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
