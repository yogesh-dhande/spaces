import AppKit
import Testing
import spacesterminalcore
import spacesterminalghostty
import workspacecore

@testable import spacesterminalui
@testable import spacesui

// Some tests resolve the active profile through process-global profile paths, so this suite pins an
// isolated database and runtime root for its lifetime and runs serialized to keep those overrides race-free.
@Suite(.serialized) final class AppKitControllerWindowSummonTests {
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
            !AppKitController.shouldRestoreReturnApplicationAfterPaletteHide(returnTerminalSessionID: "session-1", returnApplicationProcessID: 123))
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
                AppKitController.shouldHideMainWindowForToggle(appIsHidden: appIsHidden, mainWindowIsFocused: mainWindowIsFocused) == expectedHide)
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
            !AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: true, commandPaletteMainWindowVisibility: false))
        #expect(AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: false, commandPaletteMainWindowVisibility: true))
        #expect(AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: true, commandPaletteMainWindowVisibility: nil))
        #expect(!AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: false, commandPaletteMainWindowVisibility: nil))
    }

    // Ad hoc terminate-on-pane-close is a pure decision over device-owned liveness:
    // the caller derives `hasLiveAttachments` from the device overview's attachment
    // snapshot (the daemon prunes stale/lease-expired remote clients), so these cases
    // validate the decision logic rather than re-test daemon pruning.
    @MainActor @Test func adHocSessionWithLiveAttachmentIsNotTerminated() {
        #expect(!AppKitController.shouldTerminateAdHocBuiltInTerminalSession(hasLiveAttachments: true, isConfiguredProcessSession: false))
    }

    @MainActor @Test func adHocSessionWithoutLiveAttachmentsTerminates() {
        #expect(AppKitController.shouldTerminateAdHocBuiltInTerminalSession(hasLiveAttachments: false, isConfiguredProcessSession: false))
    }

    @MainActor @Test func configuredProcessSessionIsNeverTerminatedOnPaneClose() {
        #expect(!AppKitController.shouldTerminateAdHocBuiltInTerminalSession(hasLiveAttachments: false, isConfiguredProcessSession: true))
    }

    @MainActor @Test func adHocSessionIsKeptWhileAppTerminatesAndKeepsSessions() {
        #expect(
            !AppKitController.shouldTerminateAdHocBuiltInTerminalSession(
                hasLiveAttachments: false, isConfiguredProcessSession: false, isAppTerminatingAndKeepingSessions: true))
    }
}
