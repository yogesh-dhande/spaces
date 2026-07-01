import AppKit
import Testing
import spacesterminalcore
import spacesterminalghostty
import workspacecore

@testable import spacesterminalui
@testable import spacesui

// Some tests resolve the active profile through the process-global SPACES_DB_PATH, so this suite pins an
// isolated database root for its lifetime and runs serialized to keep that override race-free.
@Suite(.serialized) final class AppKitControllerWindowSummonTests {
    private let originalDatabasePath: String?
    private let databaseRoot: URL

    init() throws {
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
    }

    deinit {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        try? FileManager.default.removeItem(at: databaseRoot)
    }

    @MainActor @Test func terminalSessionHostUsesRemoteSessionHostForServiceOwnedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "service-session", title: "service", workingDirectory: root.path, shell: "/bin/zsh", command: nil,
            createdAt: "2026-05-18T00:00:00Z")
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

    @MainActor @Test func terminalRuntimeControlsResolveProcessByStableTemplateID() {
        let template = ProcessTemplate(id: "template-frontend", name: "frontend", command: "npm run dev")
        let process = RunningProcessRecord(
            id: "runtime-frontend", workspaceID: "workspace-1", templateID: template.id, templateName: "old-name", command: "old command",
            terminalApp: "Spaces", windowID: nil, terminalTrackingID: "session-frontend", terminalNativeID: "session-frontend", pid: nil,
            status: .exited, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: "2026-06-05T00:00:00Z")

        let descriptor = AppKitController.terminalRuntimeControlDescriptor(
            sessionID: "session-frontend", workspaceID: "workspace-1", settings: WorkspaceSettings(processes: [template]),
            runningProcesses: [process], agentWindows: [], trackedWindows: [], isSessionRunning: false)

        #expect(descriptor?.kind == .process)
        #expect(descriptor?.title == "frontend")
        #expect(descriptor?.processTemplateID == "template-frontend")
        #expect(descriptor?.processKey == "frontend")
        #expect(descriptor?.canRun == true)
        #expect(descriptor?.canStop == true)
        #expect(descriptor?.canRestart == true)
    }

    @MainActor @Test func terminalRuntimeControlsResolveAgentByStableLauncherID() {
        let launcher = AgentLauncher(id: "launcher-codex", name: "Codex Renamed", command: "codex")
        let agent = AgentWindowRecord(
            id: "agent-codex", workspaceID: "workspace-1", provider: .spaces, label: "Codex",
            terminalTarget: TerminalTargetRecord(trackingID: "session-codex"), claimedLauncherID: launcher.id, claimedLauncherName: "Codex",
            status: .done, createdAt: "2026-06-05T00:00:00Z", updatedAt: "2026-06-05T00:00:00Z")

        let descriptor = AppKitController.terminalRuntimeControlDescriptor(
            sessionID: "session-codex", workspaceID: "workspace-1", settings: WorkspaceSettings(agentLaunchers: [launcher]), runningProcesses: [],
            agentWindows: [agent], trackedWindows: [], isSessionRunning: false)

        #expect(descriptor?.kind == .codingAgent)
        #expect(descriptor?.title == "Codex Renamed")
        #expect(descriptor?.agentLauncherID == "launcher-codex")
        #expect(descriptor?.canRun == true)
        #expect(descriptor?.canStop == true)
        #expect(descriptor?.canRestart == true)
    }

    @MainActor @Test func terminalRuntimeControlsDoNotRestartAgentWithStaleClaimedLauncherID() {
        let launcher = AgentLauncher(id: "launcher-current", name: "Codex", command: "codex")
        let agent = AgentWindowRecord(
            id: "agent-codex", workspaceID: "workspace-1", provider: .spaces, label: "Codex",
            terminalTarget: TerminalTargetRecord(trackingID: "session-codex"), claimedLauncherID: "launcher-deleted",
            claimedLauncherName: launcher.name, status: .done, createdAt: "2026-06-05T00:00:00Z", updatedAt: "2026-06-05T00:00:00Z")

        let descriptor = AppKitController.terminalRuntimeControlDescriptor(
            sessionID: "session-codex", workspaceID: "workspace-1", settings: WorkspaceSettings(agentLaunchers: [launcher]), runningProcesses: [],
            agentWindows: [agent], trackedWindows: [], isSessionRunning: false)

        #expect(descriptor?.kind == .codingAgent)
        #expect(descriptor?.canRun == false)
        #expect(descriptor?.canStop == true)
        #expect(descriptor?.canRestart == false)
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

    @Test func toggleHotkeyRestoresTerminalFocusOnlyWhenReturnTargetAndAuxiliaryWindowExist() {
        #expect(AppKitController.shouldRestoreTerminalFocusAfterMainHide(returnTerminalSessionID: "session-1", auxiliaryTerminalWindowsVisible: true))
        #expect(!AppKitController.shouldRestoreTerminalFocusAfterMainHide(returnTerminalSessionID: nil, auxiliaryTerminalWindowsVisible: true))
        #expect(
            !AppKitController.shouldRestoreTerminalFocusAfterMainHide(returnTerminalSessionID: "session-1", auxiliaryTerminalWindowsVisible: false))
    }

    @Test func toggleHotkeyRestoresReturnApplicationOnlyWhenNoTerminalReturnTargetExists() {
        #expect(
            AppKitController.shouldRestoreReturnApplicationAfterMainHide(
                returnTerminalSessionID: nil, returnApplicationProcessID: 123, auxiliaryTerminalWindowsVisible: false))
        #expect(
            !AppKitController.shouldRestoreReturnApplicationAfterMainHide(
                returnTerminalSessionID: "session-1", returnApplicationProcessID: 123, auxiliaryTerminalWindowsVisible: false))
        #expect(
            !AppKitController.shouldRestoreReturnApplicationAfterMainHide(
                returnTerminalSessionID: nil, returnApplicationProcessID: nil, auxiliaryTerminalWindowsVisible: false))
        #expect(
            !AppKitController.shouldRestoreReturnApplicationAfterMainHide(
                returnTerminalSessionID: nil, returnApplicationProcessID: 123, auxiliaryTerminalWindowsVisible: true))
    }

    @Test func toggleHotkeyCapturesOnlyNonSpacesReturnApplicationProcessID() {
        #expect(AppKitController.returnApplicationProcessIDForAppToggle(frontmostApplicationProcessID: 123, currentProcessID: 456) == 123)
        #expect(AppKitController.returnApplicationProcessIDForAppToggle(frontmostApplicationProcessID: 456, currentProcessID: 456) == nil)
        #expect(AppKitController.returnApplicationProcessIDForAppToggle(frontmostApplicationProcessID: nil, currentProcessID: 456) == nil)
    }

    @MainActor @Test func localShortcutMonitorBypassesFocusedTerminalWindow() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = TerminalSessionWindowController(sessionID: "session-shortcuts", paths: .init(rootDirectory: root.path))

        #expect(AppKitController.shouldBypassLocalShortcutMonitor(for: controller.window))
        #expect(!AppKitController.shouldBypassLocalShortcutMonitor(for: NSWindow()))
        #expect(!AppKitController.shouldBypassLocalShortcutMonitor(for: nil))
    }

    @Test func toggleHotkeyMiniaturizesMainWindowOnlyWhenNoTerminalReturnTargetExists() {
        #expect(AppKitController.shouldMiniaturizeMainWindowAfterHide(returnTerminalSessionID: nil))
        #expect(!AppKitController.shouldMiniaturizeMainWindowAfterHide(returnTerminalSessionID: "session-1"))
    }

    @Test func toggleHotkeyHidesAppWhenReturningToExternalApplicationWithoutAuxiliaryWindows() {
        #expect(
            AppKitController.shouldHideAppAfterMainHide(
                returnTerminalSessionID: nil, returnApplicationProcessID: 123, auxiliaryTerminalWindowsVisible: false))
        #expect(
            AppKitController.shouldHideAppAfterMainHide(
                returnTerminalSessionID: nil, returnApplicationProcessID: nil, auxiliaryTerminalWindowsVisible: false))
        #expect(
            !AppKitController.shouldHideAppAfterMainHide(
                returnTerminalSessionID: "session-1", returnApplicationProcessID: 123, auxiliaryTerminalWindowsVisible: false))
        #expect(
            !AppKitController.shouldHideAppAfterMainHide(
                returnTerminalSessionID: nil, returnApplicationProcessID: 123, auxiliaryTerminalWindowsVisible: true))
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

    @Test func globalWindowNavigationUsesRememberedBuiltInTerminalSessionOnlyDuringActiveTerminalFocus() {
        #expect(AppKitController.shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: true))
        #expect(!AppKitController.shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: false))
        #expect(AppKitController.shouldUseFocusedChromeWindowForWorkspaceLookup(frontmostApplicationBundleIdentifier: "com.google.Chrome"))
        #expect(!AppKitController.shouldUseFocusedChromeWindowForWorkspaceLookup(frontmostApplicationBundleIdentifier: "com.apple.TextEdit"))
        #expect(!AppKitController.shouldUseFocusedChromeWindowForWorkspaceLookup(frontmostApplicationBundleIdentifier: nil))
        #expect(
            AppKitController.shouldUseRememberedBuiltInTerminalSessionForGlobalNavigation(
                appIsActive: true, mainWindowIsFocused: false, commandPaletteIsFocused: false))
        #expect(
            !AppKitController.shouldUseRememberedBuiltInTerminalSessionForGlobalNavigation(
                appIsActive: false, mainWindowIsFocused: false, commandPaletteIsFocused: false))
        #expect(
            !AppKitController.shouldUseRememberedBuiltInTerminalSessionForGlobalNavigation(
                appIsActive: true, mainWindowIsFocused: true, commandPaletteIsFocused: false))
        #expect(
            !AppKitController.shouldUseRememberedBuiltInTerminalSessionForGlobalNavigation(
                appIsActive: true, mainWindowIsFocused: false, commandPaletteIsFocused: true))
        #expect(
            AppKitController.preferredWorkspaceIDForGlobalNavigation(
                focusedTerminalSessionWorkspaceID: "terminal", focusedWindowWorkspaceID: "focused", rememberedTerminalSessionWorkspaceID: nil,
                activeWorkspaceID: "active")
                == AppKitController.GlobalNavigationWorkspaceResolution(workspaceID: "terminal", source: "focused_terminal_session"))
        #expect(
            AppKitController.preferredWorkspaceIDForGlobalNavigation(
                focusedTerminalSessionWorkspaceID: nil, focusedWindowWorkspaceID: "focused", rememberedTerminalSessionWorkspaceID: "remembered",
                activeWorkspaceID: "active") == AppKitController.GlobalNavigationWorkspaceResolution(workspaceID: "focused", source: "focused_window")
        )
        #expect(
            AppKitController.preferredWorkspaceIDForGlobalNavigation(
                focusedTerminalSessionWorkspaceID: nil, focusedWindowWorkspaceID: nil, rememberedTerminalSessionWorkspaceID: "remembered",
                activeWorkspaceID: "active")
                == AppKitController.GlobalNavigationWorkspaceResolution(workspaceID: "remembered", source: "remembered_terminal_session"))
        #expect(
            AppKitController.preferredWorkspaceIDForGlobalNavigation(
                focusedTerminalSessionWorkspaceID: nil, focusedWindowWorkspaceID: nil, rememberedTerminalSessionWorkspaceID: nil,
                activeWorkspaceID: "active")
                == AppKitController.GlobalNavigationWorkspaceResolution(workspaceID: "active", source: "active_workspace"))
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

    @MainActor @Test func liveWindowReuseReturnsExistingController() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-1", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-1", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let controller = TerminalSessionWindowController(
            sessionID: "session-1", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        let selected = AppKitController.liveTerminalSessionWindowController(controller)

        #expect(selected === controller)
    }

    @MainActor @Test func liveWindowReuseReturnsNilWhenControllerClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-2", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-2", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let controller = TerminalSessionWindowController(
            sessionID: "session-2", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })
        controller.closeForSessionTermination()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        let selected = AppKitController.liveTerminalSessionWindowController(controller)

        #expect(selected == nil)
    }

    @MainActor @Test func focusableWindowReuseReturnsExistingController() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-3", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-3", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let controller = TerminalSessionWindowController(
            sessionID: "session-3", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        let selected = AppKitController.focusableTerminalSessionWindowController(controller, sessionID: "session-3")

        #expect(selected?.controller === controller)
        #expect(selected?.route == "existing_window")
    }

    @MainActor @Test func focusableWindowReuseReturnsNilWhenControllerClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-4", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-4", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let controller = TerminalSessionWindowController(
            sessionID: "session-4", paths: paths, preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in })
        controller.closeForSessionTermination()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        let selected = AppKitController.focusableTerminalSessionWindowController(controller, sessionID: "session-4")

        #expect(selected == nil)
    }

    @MainActor @Test func focusableOwnerWindowReuseReturnsNilWhenNoLiveWindowExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selected = AppKitController.focusableTerminalSessionWindowController(nil, sessionID: "missing-session")

        #expect(selected == nil)
    }

    @MainActor @Test func focusableWindowReuseLabelsExistingWindowRoute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-5", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-5", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let controller = TerminalSessionWindowController(
            sessionID: "session-5", paths: paths, preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        let selected = AppKitController.focusableTerminalSessionWindowController(controller, sessionID: "session-5")

        #expect(selected?.controller === controller)
        #expect(selected?.route == "existing_window")
    }

    @MainActor @Test func adHocTerminationWaitsForAllPersistedAttachmentsToDetach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try writeLaunchConfiguration(sessionID: "session-remote", paths: paths)
        let localClient = TerminalClient(
            id: "local-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-17T18:00:00Z")
        let remoteClient = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", hostName: "phone", deviceName: "Remote Client"),
            connectedAt: "2026-05-17T18:00:01Z")

        try TerminalSessionPersistence.attachClient(
            sessionID: "session-remote", client: localClient, mode: .owner, paths: paths, attachedAt: "2026-05-17T18:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-remote", client: remoteClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T18:00:01Z")
        try TerminalSessionPersistence.detachClient(id: localClient.id, paths: paths, detachedAt: "2026-05-17T18:00:02Z")
        let now = ISO8601DateFormatter().date(from: "2026-05-17T18:00:03Z")!

        #expect(!AppKitController.shouldTerminateAdHocBuiltInTerminalSession(paths: paths, isConfiguredProcessSession: false, now: now))
    }

    @MainActor @Test func adHocTerminationResumesAfterRemoteViewerDetaches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try writeLaunchConfiguration(sessionID: "session-remote", paths: paths)
        let remoteClient = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", hostName: "phone", deviceName: "Remote Client"),
            connectedAt: "2026-05-17T18:00:01Z")
        let now = ISO8601DateFormatter().date(from: "2026-05-17T18:00:03Z")!

        try TerminalSessionPersistence.attachClient(
            sessionID: "session-remote", client: remoteClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T18:00:01Z")
        #expect(!AppKitController.shouldTerminateAdHocBuiltInTerminalSession(paths: paths, isConfiguredProcessSession: false, now: now))

        try TerminalSessionPersistence.detachClient(id: remoteClient.id, paths: paths, detachedAt: "2026-05-17T18:00:02Z")
        #expect(AppKitController.shouldTerminateAdHocBuiltInTerminalSession(paths: paths, isConfiguredProcessSession: false, now: now))
    }

    @MainActor @Test func adHocTerminationIgnoresLeaseExpiredRemoteViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try writeLaunchConfiguration(sessionID: "session-remote", paths: paths)
        let remoteClient = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", hostName: "phone", deviceName: "Remote Client"),
            connectedAt: "2026-05-17T18:00:01Z")

        try TerminalSessionPersistence.attachClient(
            sessionID: "session-remote", client: remoteClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T18:00:01Z")
        let now = ISO8601DateFormatter().date(from: "2026-05-17T18:01:05Z")!

        #expect(AppKitController.shouldTerminateAdHocBuiltInTerminalSession(paths: paths, isConfiguredProcessSession: false, now: now))
    }

    @MainActor @Test func adHocTerminationRequiresNoAttachmentsAndNoConfiguredProcessOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)

        #expect(AppKitController.shouldTerminateAdHocBuiltInTerminalSession(paths: paths, isConfiguredProcessSession: false))
        #expect(!AppKitController.shouldTerminateAdHocBuiltInTerminalSession(paths: paths, isConfiguredProcessSession: true))
        #expect(!AppKitController.shouldTerminateAdHocBuiltInTerminalSession(paths: nil, isConfiguredProcessSession: false))
    }

    private func writeLaunchConfiguration(sessionID: String, paths: TerminalSessionPaths) throws {
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: sessionID, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
                createdAt: "2026-05-17T18:00:00Z"), paths: paths)
    }
}
