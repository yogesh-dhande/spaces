import AppKit
import Testing
import spacesterminalcore
import spacesterminalghostty
import workspacecore

@testable import spacesterminalui
@testable import spacesui

/// Test state provider backed by the on-disk terminal session store the daemon
/// writes; production injects a Device-API-backed model. Lets these summon/focus
/// tests keep seeding state through `TerminalSessionPersistence`.
@MainActor final class PersistenceBackedTerminalSessionStateProvider: TerminalSessionStateProviding {
    private let paths: TerminalSessionPaths
    init(paths: TerminalSessionPaths) { self.paths = paths }
    var currentLaunchConfiguration: TerminalSessionLaunchConfiguration? { try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths) }
    var currentRuntimeState: TerminalSessionRuntimeState? { try? TerminalSessionPersistence.readRuntimeState(paths: paths) }
    var currentAttachmentSnapshot: TerminalSessionAttachmentSnapshot? { try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths) }
    var latestRemoteStatePayload: GhosttyRemoteSessionStatePayload? { try? TerminalSessionPersistence.readRemoteSessionState(paths: paths) }
    func refreshState() {}
    func startStateStream(
        onUpdate _: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect _: @escaping @MainActor ((any Error)?) -> Void
    ) {}
}

// Persistence-backed control/window-frame closures for tests (production injects
// Device API + SpacesClientDatabase closures into the now-DB-free controller).
func persistenceBackedAttachAction(_ paths: TerminalSessionPaths) -> @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void {
    { client, mode in
        let sessionID =
            (try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths))?.sessionID ?? (paths.rootDirectory as NSString).lastPathComponent
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: ISO8601DateFormatter().string(from: Date()))
    }
}

func persistenceBackedDetachAction(_ paths: TerminalSessionPaths) -> @Sendable (String) throws -> Void {
    { clientID in try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date())) }
}

func persistenceBackedLoadWindowFrame(_ paths: TerminalSessionPaths) -> (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame? {
    { mode in try TerminalSessionPersistence.readWindowFrame(mode: mode, paths: paths) }
}

func persistenceBackedSaveWindowFrame(_ paths: TerminalSessionPaths) -> (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void {
    { frame, mode in try TerminalSessionPersistence.writeWindowFrame(frame, mode: mode, paths: paths) }
}

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
            terminalApp: "Spaces", terminalTrackingID: "session-frontend", terminalNativeID: "session-frontend", pid: nil, status: .exited,
            logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: "2026-06-05T00:00:00Z")

        let descriptor = AppKitController.terminalRuntimeControlDescriptor(
            sessionID: "session-frontend", workspaceID: "workspace-1", deviceID: "device-a", settings: WorkspaceSettings(processes: [template]),
            runningProcesses: [process], agentWindows: [], trackedWindows: [], isSessionRunning: false)

        #expect(descriptor?.kind == .process)
        #expect(descriptor?.deviceID == "device-a")
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
            sessionID: "session-codex", workspaceID: "workspace-1", deviceID: "device-a", settings: WorkspaceSettings(agentLaunchers: [launcher]),
            runningProcesses: [], agentWindows: [agent], trackedWindows: [], isSessionRunning: false)

        #expect(descriptor?.kind == .codingAgent)
        #expect(descriptor?.deviceID == "device-a")
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
            sessionID: "session-codex", workspaceID: "workspace-1", deviceID: "device-a", settings: WorkspaceSettings(agentLaunchers: [launcher]),
            runningProcesses: [], agentWindows: [agent], trackedWindows: [], isSessionRunning: false)

        #expect(descriptor?.kind == .codingAgent)
        #expect(descriptor?.deviceID == "device-a")
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

        let controller = TerminalSessionWindowController(
            sessionID: "session-shortcuts", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)),
            attachClientAction: persistenceBackedAttachAction(.init(rootDirectory: root.path)),
            detachClientAction: persistenceBackedDetachAction(.init(rootDirectory: root.path)),
            loadWindowFrameAction: persistenceBackedLoadWindowFrame(.init(rootDirectory: root.path)),
            saveWindowFrameAction: persistenceBackedSaveWindowFrame(.init(rootDirectory: root.path)))

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
            sessionID: "session-1", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in },
            loadWindowFrameAction: persistenceBackedLoadWindowFrame(paths), saveWindowFrameAction: persistenceBackedSaveWindowFrame(paths))

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
            sessionID: "session-2", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in },
            loadWindowFrameAction: persistenceBackedLoadWindowFrame(paths), saveWindowFrameAction: persistenceBackedSaveWindowFrame(paths))
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
            sessionID: "session-3", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in },
            loadWindowFrameAction: persistenceBackedLoadWindowFrame(paths), saveWindowFrameAction: persistenceBackedSaveWindowFrame(paths))

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
            sessionID: "session-4", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in },
            loadWindowFrameAction: persistenceBackedLoadWindowFrame(paths), saveWindowFrameAction: persistenceBackedSaveWindowFrame(paths))
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
            sessionID: "session-5", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in },
            loadWindowFrameAction: persistenceBackedLoadWindowFrame(paths), saveWindowFrameAction: persistenceBackedSaveWindowFrame(paths))

        let selected = AppKitController.focusableTerminalSessionWindowController(controller, sessionID: "session-5")

        #expect(selected?.controller === controller)
        #expect(selected?.route == "existing_window")
    }

    // Ad hoc terminate-on-window-close is now a pure decision over device-owned
    // liveness: the caller derives `hasLiveAttachments` from the device overview's
    // attachment snapshot (the daemon prunes stale/lease-expired remote clients),
    // so these cases validate the decision logic rather than re-test daemon pruning.
    @MainActor @Test func adHocSessionWithLiveAttachmentIsNotTerminated() {
        #expect(!AppKitController.shouldTerminateAdHocBuiltInTerminalSession(hasLiveAttachments: true, isConfiguredProcessSession: false))
    }

    @MainActor @Test func adHocSessionWithoutLiveAttachmentsTerminates() {
        #expect(AppKitController.shouldTerminateAdHocBuiltInTerminalSession(hasLiveAttachments: false, isConfiguredProcessSession: false))
    }

    @MainActor @Test func configuredProcessSessionIsNeverTerminatedOnWindowClose() {
        #expect(!AppKitController.shouldTerminateAdHocBuiltInTerminalSession(hasLiveAttachments: false, isConfiguredProcessSession: true))
    }

    @MainActor @Test func adHocSessionIsKeptWhileAppTerminatesAndKeepsSessions() {
        #expect(
            !AppKitController.shouldTerminateAdHocBuiltInTerminalSession(
                hasLiveAttachments: false, isConfiguredProcessSession: false, isAppTerminatingAndKeepingSessions: true))
    }

    private func writeLaunchConfiguration(sessionID: String, paths: TerminalSessionPaths) throws {
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: sessionID, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
                createdAt: "2026-05-17T18:00:00Z"), paths: paths)
    }
}
