import AppKit
import Testing
import spacesterminalcore
import spacesterminalghostty
import workspacecore

@testable import spacesterminalui
@testable import spacesui

extension ProcessProfileEnvironmentSuites {
    /// Some tests resolve the active profile through process-global profile paths, so this suite pins an
    /// isolated database and runtime root for its lifetime. Nests under `ProcessProfileEnvironmentSuites`
    /// (rather than declaring its own `.serialized`) because it mutates the process-global
    /// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` in `init`/`deinit`; see that parent's doc comment for why a
    /// per-suite trait alone is not enough to keep those overrides race-free.
    @Suite final class AppKitControllerWindowSummonTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseRoot = root
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
            setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        }

        deinit {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: databaseRoot)
        }

        @MainActor @Test func terminalSessionHostUsesRemoteSessionHostForServiceOwnedSession() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "service-session", title: "service", workingDirectory: root.path, shell: "/bin/zsh", command: nil,
                createdAt: "2026-05-18T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let paths = TerminalSessionPaths(rootDirectory: root.path)

            let resolvedHost = AppKitController.terminalSessionHost(launchConfiguration: launchConfiguration, paths: paths)

            #expect(resolvedHost is RemoteGhosttySessionHost)
        }

        /// Re-showing the pane the user is already in must cost nothing beyond foregrounding it: no state
        /// fetch, no re-attach, no ownership reclaim. Every other shape of the request keeps the full path,
        /// most importantly the one where another client owns the session — reclaiming that is the request.
        @Test func reShowingTheFocusedOwnerAttachedPaneSkipsTheAttachPath() {
            #expect(
                AppKitController.canRefocusTerminalPaneWithoutReattaching(
                    paneIsFocused: true, paneIsInSelectedTab: true, paneHoldsOwnerAttachedSurface: true))
            #expect(
                !AppKitController.canRefocusTerminalPaneWithoutReattaching(
                    paneIsFocused: false, paneIsInSelectedTab: true, paneHoldsOwnerAttachedSurface: true))
            #expect(
                !AppKitController.canRefocusTerminalPaneWithoutReattaching(
                    paneIsFocused: true, paneIsInSelectedTab: false, paneHoldsOwnerAttachedSurface: true))
            #expect(
                !AppKitController.canRefocusTerminalPaneWithoutReattaching(
                    paneIsFocused: true, paneIsInSelectedTab: true, paneHoldsOwnerAttachedSurface: false))
        }

        /// A programmatic launch (`spaces workspace start`, its MCP tool, or a restart they trigger) must
        /// never move the window the user is working in, whether or not that session had a pane already:
        /// a session with no pane gets one on an unselected tab, and a session that already has one is
        /// left exactly where it sits.
        @Test func programmaticOpenInstallsOrKeepsThePaneWithoutMovingFocus() {
            #expect(
                AppKitController.terminalPaneOpenAction(hasExistingPane: false, hasReplaceablePane: false, focusIntent: .withoutFocus)
                    == .installUnselectedTab)
            #expect(
                AppKitController.terminalPaneOpenAction(hasExistingPane: true, hasReplaceablePane: false, focusIntent: .withoutFocus)
                    == .leaveExistingPaneInPlace)
        }

        /// A user asking for a terminal (`spaces terminal show`, a `spaces://` link, a sidebar click) gets
        /// the pane brought forward and focused, which is the behavior every caller inherits by default.
        @Test func userRequestedOpenFocusesThePane() {
            #expect(
                AppKitController.terminalPaneOpenAction(hasExistingPane: false, hasReplaceablePane: false, focusIntent: .focus) == .openFocusedTab)
            #expect(
                AppKitController.terminalPaneOpenAction(hasExistingPane: true, hasReplaceablePane: false, focusIntent: .focus) == .focusExistingPane)
        }

        /// A restart's replacement takes over the pane its predecessor held rather than arriving at the end
        /// of the tab strip, whichever order the close and the open arrive in: the close landing first
        /// leaves the pane held and still placed, and the open landing first finds it still placed. Both
        /// reduce to the same input here, which is what makes the outcome order-independent.
        @Test func replacementClaimsThePaneOfTheSessionItReplaces() {
            #expect(
                AppKitController.terminalPaneOpenAction(hasExistingPane: false, hasReplaceablePane: true, focusIntent: .withoutFocus)
                    == .claimReplacedPane)
        }

        /// A replacement whose predecessor's pane is gone (the user closed it mid-restart) has nothing to
        /// claim, so it installs like any other programmatic launch. And a session that somehow already has
        /// its own pane keeps it: re-opening a placed session must never go move a different pane.
        @Test func replacementFallsBackToInstallingAndNeverStealsAnotherPane() {
            #expect(
                AppKitController.terminalPaneOpenAction(hasExistingPane: false, hasReplaceablePane: false, focusIntent: .withoutFocus)
                    == .installUnselectedTab)
            #expect(
                AppKitController.terminalPaneOpenAction(hasExistingPane: true, hasReplaceablePane: true, focusIntent: .withoutFocus)
                    == .leaveExistingPaneInPlace)
        }

        /// The disposition is required. A missing, blank, or unrecognized value is a malformed IPC and
        /// decodes to nil, the same as a missing session ID, so the handler drops the notification instead
        /// of guessing what the poster meant.
        @Test func closeIPCWithoutAStatedDispositionDecodesToNil() {
            #expect(AppKitController.terminalPaneCloseDisposition(ipcRawValue: nil) == nil)
            #expect(AppKitController.terminalPaneCloseDisposition(ipcRawValue: "  ") == nil)
            #expect(AppKitController.terminalPaneCloseDisposition(ipcRawValue: "sideways") == nil)
            #expect(AppKitController.terminalPaneCloseDisposition(ipcRawValue: "teardown") == .teardown)
            #expect(AppKitController.terminalPaneCloseDisposition(ipcRawValue: "awaitReplacement") == .awaitReplacement)
        }

        /// The intent has to survive the async credential preparation, which finishes long after the pane
        /// is installed and re-activates the panel's focused pane. By then the user has had that whole
        /// window to click into the sidebar or another pane, so a programmatic launch's late completion
        /// must not take the caret.
        @Test func programmaticOpenStillDoesNotMoveFocusWhenItsPreparationFinishes() {
            #expect(AppKitController.terminalPanePreparationFocusAction(focusIntent: .withoutFocus, preparedPaneHoldsKeyboardFocus: false) == .none)
            #expect(
                AppKitController.terminalPanePreparationFocusAction(focusIntent: .focus, preparedPaneHoldsKeyboardFocus: false)
                    == .activatePanelFocusedPane)
        }

        /// The one case a non-focusing open must still put the caret somewhere: the user clicked into the
        /// pane while it was still preparing, so the placeholder holds the caret and swapping it out would
        /// drop it. Restoring focus the user gave this pane is not stealing it.
        @Test func aPaneTheUserClickedIntoWhilePreparingKeepsTheCaret() {
            #expect(
                AppKitController.terminalPanePreparationFocusAction(focusIntent: .withoutFocus, preparedPaneHoldsKeyboardFocus: true)
                    == .restoreToPreparedPane)
        }

        /// A restart's replacement takes over the pane its predecessor occupied, and that pane can be the
        /// one the user is typing in. Swapping the content tears the predecessor's view out and the first
        /// responder goes with it, so the caret moves across rather than being dropped. Every other
        /// retarget touches focus not at all.
        @Test func aRetargetCarriesTheCaretOnlyWhenThePaneAlreadyHadIt() {
            #expect(AppKitController.terminalPaneRetargetMovesKeyboardFocusToReplacement(replacedPaneHoldsKeyboardFocus: true))
            #expect(!AppKitController.terminalPaneRetargetMovesKeyboardFocusToReplacement(replacedPaneHoldsKeyboardFocus: false))
        }

        /// A user waiting on a terminal they asked for is owed the error in front of them. A background
        /// launch failing is not a reason to interrupt them: its pane reports the failure in place.
        ///
        /// The rule governs every way an open can fail, not only the credential-preparation error it was
        /// first written for: content construction throwing after preparation succeeded, and the owning
        /// device refusing the install, both route through `reportTerminalPaneOpenFailure` and ask this.
        @Test func onlyAUserRequestedOpenReportsItsFailureWithAModal() {
            #expect(AppKitController.terminalPaneOpenFailureUsesModalAlert(focusIntent: .focus))
            #expect(!AppKitController.terminalPaneOpenFailureUsesModalAlert(focusIntent: .withoutFocus))
        }

        /// A close the daemon drove (a stop, a restart, an exited process, a pruned session) is not a user
        /// action, so it leaves the caret alone. A programmatic `workspace restart` closes every pane of a
        /// workspace in a row, and moving focus on each would walk the caret through the survivors.
        /// Closing a pane the user closed still hands focus on, because they are working in that panel.
        @Test func daemonDrivenPaneCloseLeavesTheCaretWhereItIs() {
            #expect(!AppKitController.terminalPaneCloseMovesKeyboardFocus(sessionIsTerminating: true))
            #expect(AppKitController.terminalPaneCloseMovesKeyboardFocus(sessionIsTerminating: false))
        }

        /// The intent is required. A missing, blank, or unrecognized value is a malformed IPC and decodes
        /// to nil, the same as a missing session ID, so the handler drops the notification instead of
        /// guessing what the poster meant.
        @Test func openIPCWithoutAStatedIntentDecodesToNil() {
            #expect(AppKitController.terminalOpenFocusIntent(ipcRawValue: nil) == nil)
            #expect(AppKitController.terminalOpenFocusIntent(ipcRawValue: "   ") == nil)
            #expect(AppKitController.terminalOpenFocusIntent(ipcRawValue: "sideways") == nil)
            #expect(AppKitController.terminalOpenFocusIntent(ipcRawValue: "focus") == .focus)
            #expect(AppKitController.terminalOpenFocusIntent(ipcRawValue: "without_focus") == .withoutFocus)
        }

        @Test func activeSpaceSummonAddsMoveToActiveSpaceBehavior() {
            let behavior = NSWindow.CollectionBehavior.fullScreenAuxiliary

            let updated = AppKitController.collectionBehaviorForActiveSpaceSummon(behavior)

            #expect(updated.contains(.moveToActiveSpace))
            #expect(updated.contains(.fullScreenAuxiliary))
        }

        @Test func activeSpaceSummonCleanupRemovesOnlyTransientBehavior() {
            let original: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .managed]
            let summoned = AppKitController.collectionBehaviorForActiveSpaceSummon(original)

            let cleaned = AppKitController.collectionBehaviorAfterActiveSpaceSummon(summoned)

            #expect(!cleaned.contains(.moveToActiveSpace))
            #expect(cleaned.contains(.fullScreenAuxiliary))
            #expect(cleaned.contains(.managed))
        }

        @Test func targetedHotkeyRevealUsesDirectRouteWhenAppIsAlreadyActive() {
            #expect(AppKitController.shouldUseDirectTargetedHotkeyReveal(appIsActive: true))
            #expect(!AppKitController.shouldUseDirectTargetedHotkeyReveal(appIsActive: false))
        }

        @Test func targetedHotkeyRevealActivatesAppWhenInactive() {
            #expect(AppKitController.shouldActivateAppForTargetedHotkeyReveal(appIsActive: false))
            #expect(!AppKitController.shouldActivateAppForTargetedHotkeyReveal(appIsActive: true))
        }

        @Test func targetedHotkeyRevealPrefersLightweightFocusForVisibleWindow() {
            #expect(AppKitController.shouldFocusVisibleTargetedHotkeyWindow(appIsActive: true, windowIsVisible: true, windowIsMiniaturized: false))
            #expect(!AppKitController.shouldFocusVisibleTargetedHotkeyWindow(appIsActive: false, windowIsVisible: true, windowIsMiniaturized: false))
            #expect(!AppKitController.shouldFocusVisibleTargetedHotkeyWindow(appIsActive: true, windowIsVisible: false, windowIsMiniaturized: false))
            #expect(!AppKitController.shouldFocusVisibleTargetedHotkeyWindow(appIsActive: true, windowIsVisible: true, windowIsMiniaturized: true))
        }

        @Test func commandPalettePresentationActivatesAppWhenInactive() {
            #expect(AppKitController.shouldActivateAppForCommandPalettePresentation(appIsActive: false))
        }

        @Test func commandPalettePresentationSkipsActivationWhenAlreadyActive() {
            #expect(!AppKitController.shouldActivateAppForCommandPalettePresentation(appIsActive: true))
        }

        @Test func commandPaletteDismissRestoresOnlyItsCapturedReturnTarget() {
            #expect(AppKitController.shouldRestoreTerminalFocusAfterPaletteHide(returnTerminalSessionID: "session-1"))
            #expect(!AppKitController.shouldRestoreTerminalFocusAfterPaletteHide(returnTerminalSessionID: nil))
            #expect(AppKitController.shouldRestoreReturnApplicationAfterPaletteHide(returnTerminalSessionID: nil, returnApplicationProcessID: 123))
            #expect(
                !AppKitController.shouldRestoreReturnApplicationAfterPaletteHide(
                    returnTerminalSessionID: "session-1", returnApplicationProcessID: 123))
            #expect(!AppKitController.shouldRestoreReturnApplicationAfterPaletteHide(returnTerminalSessionID: nil, returnApplicationProcessID: nil))
        }

        @Test func toggleHotkeyHidesOnlyWhenMainWindowIsFocused() {
            #expect(AppKitController.shouldHideMainWindowForToggle(appIsHidden: false, mainWindowIsFocused: true))
            #expect(!AppKitController.shouldHideMainWindowForToggle(appIsHidden: true, mainWindowIsFocused: true))
            #expect(!AppKitController.shouldHideMainWindowForToggle(appIsHidden: false, mainWindowIsFocused: false))
        }

        @Test func toggleHotkeyVisibilityMatrix() {
            let cases: [(Bool, Bool, Bool)] = [(true, true, false), (true, false, false), (false, true, true), (false, false, false)]
            for (appIsHidden, mainWindowIsFocused, expectedHide) in cases {
                #expect(
                    AppKitController.shouldHideMainWindowForToggle(appIsHidden: appIsHidden, mainWindowIsFocused: mainWindowIsFocused) == expectedHide
                )
            }
        }

        // Terminal panes live inside the main window, so hiding it needs no terminal
        // return-focus handling; the only restoration is the previously frontmost app.
        @Test func toggleHotkeyRestoresReturnApplicationOnlyWhenOneWasCaptured() {
            #expect(AppKitController.shouldRestoreReturnApplicationAfterMainHide(returnApplicationProcessID: 123))
            #expect(!AppKitController.shouldRestoreReturnApplicationAfterMainHide(returnApplicationProcessID: nil))
        }

        @Test func toggleHotkeyCapturesOnlyNonSpacesReturnApplicationProcessID() {
            #expect(AppKitController.returnApplicationProcessIDForAppToggle(frontmostApplicationProcessID: 123, currentProcessID: 456) == 123)
            #expect(AppKitController.returnApplicationProcessIDForAppToggle(frontmostApplicationProcessID: 456, currentProcessID: 456) == nil)
            #expect(AppKitController.returnApplicationProcessIDForAppToggle(frontmostApplicationProcessID: nil, currentProcessID: 456) == nil)
        }

        @Test func commandPalettePresentationCompletesOnlyAfterPaletteBecomesKey() {
            #expect(!AppKitController.commandPalettePresentationIsComplete(panelIsVisible: false, panelIsKey: false))
            #expect(!AppKitController.commandPalettePresentationIsComplete(panelIsVisible: true, panelIsKey: false))
            #expect(AppKitController.commandPalettePresentationIsComplete(panelIsVisible: true, panelIsKey: true))
        }

        @Test func commandPaletteToggleDismissesOnlyWhenPaletteIsFocused() {
            #expect(AppKitController.shouldDismissCommandPaletteForToggle(panelIsVisible: true, panelIsFocused: true))
            #expect(!AppKitController.shouldDismissCommandPaletteForToggle(panelIsVisible: true, panelIsFocused: false))
            #expect(!AppKitController.shouldDismissCommandPaletteForToggle(panelIsVisible: false, panelIsFocused: true))
        }

        @Test func commandPaletteToggleVisibilityMatrix() {
            let cases: [(Bool, Bool, Bool)] = [(true, true, true), (true, false, false), (false, true, false), (false, false, false)]
            for (panelIsVisible, panelIsFocused, expectedDismiss) in cases {
                #expect(
                    AppKitController.shouldDismissCommandPaletteForToggle(panelIsVisible: panelIsVisible, panelIsFocused: panelIsFocused)
                        == expectedDismiss)
            }
        }

        @Test func globalWindowNavigationResolvesWorkspaceFromFocusedPaneThenWindowThenActive() {
            #expect(AppKitController.shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: true))
            #expect(!AppKitController.shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: false))
            #expect(AppKitController.shouldUseFocusedChromeWindowForWorkspaceLookup(frontmostApplicationBundleIdentifier: "com.google.Chrome"))
            #expect(!AppKitController.shouldUseFocusedChromeWindowForWorkspaceLookup(frontmostApplicationBundleIdentifier: "com.apple.TextEdit"))
            #expect(!AppKitController.shouldUseFocusedChromeWindowForWorkspaceLookup(frontmostApplicationBundleIdentifier: nil))
            #expect(
                AppKitController.preferredWorkspaceIDForGlobalNavigation(
                    focusedTerminalSessionWorkspaceID: "terminal", focusedWindowWorkspaceID: "focused", activeWorkspaceID: "active")
                    == AppKitController.GlobalNavigationWorkspaceResolution(workspaceID: "terminal", source: "focused_terminal_session"))
            #expect(
                AppKitController.preferredWorkspaceIDForGlobalNavigation(
                    focusedTerminalSessionWorkspaceID: nil, focusedWindowWorkspaceID: "focused", activeWorkspaceID: "active")
                    == AppKitController.GlobalNavigationWorkspaceResolution(workspaceID: "focused", source: "focused_window"))
            #expect(
                AppKitController.preferredWorkspaceIDForGlobalNavigation(
                    focusedTerminalSessionWorkspaceID: nil, focusedWindowWorkspaceID: nil, activeWorkspaceID: "active")
                    == AppKitController.GlobalNavigationWorkspaceResolution(workspaceID: "active", source: "active_workspace"))
            #expect(
                AppKitController.preferredWorkspaceIDForGlobalNavigation(
                    focusedTerminalSessionWorkspaceID: nil, focusedWindowWorkspaceID: nil, activeWorkspaceID: nil)
                    == AppKitController.GlobalNavigationWorkspaceResolution(workspaceID: nil, source: "none"))
            #expect(AppKitController.activeWorkspaceIDForGlobalNavigation(appIsActive: true, activeWorkspaceID: "active") == "active")
            #expect(AppKitController.activeWorkspaceIDForGlobalNavigation(appIsActive: false, activeWorkspaceID: "active") == nil)
        }

        @Test func commandPaletteSessionUsesCapturedMainWindowVisibilityForHotkeyState() {
            #expect(
                !AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: true, commandPaletteMainWindowVisibility: false)
            )
            #expect(
                AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: false, commandPaletteMainWindowVisibility: true))
            #expect(
                AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: true, commandPaletteMainWindowVisibility: nil))
            #expect(
                !AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: false, commandPaletteMainWindowVisibility: nil))
        }

        // The client only decides WHETHER to ask; whether the session is ad hoc and whether it is idle
        // at a bare prompt are the daemon's to answer, so these cases cover the ask itself.
        @MainActor @Test func ownerPaneCloseAsksTheDaemonToStopTheSession() {
            #expect(
                AppKitController.shouldRequestAdHocBareShellStopOnPaneClose(closedPaneOwnedOrEnded: true, isAppTerminatingAndKeepingSessions: false))
        }

        @MainActor @Test func viewerPaneCloseNeverAsksTheDaemonToStopTheSession() {
            #expect(
                !AppKitController.shouldRequestAdHocBareShellStopOnPaneClose(closedPaneOwnedOrEnded: false, isAppTerminatingAndKeepingSessions: false)
            )
        }

        @MainActor @Test func paneCloseDuringQuitThatKeepsSessionsAsksNothing() {
            #expect(
                !AppKitController.shouldRequestAdHocBareShellStopOnPaneClose(closedPaneOwnedOrEnded: true, isAppTerminatingAndKeepingSessions: true))
        }
    }
}
