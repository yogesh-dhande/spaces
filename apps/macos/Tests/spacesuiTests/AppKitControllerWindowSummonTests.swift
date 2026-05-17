import AppKit
import Testing
import spacesterminalcore

@testable import spacesterminalui
@testable import spacesui

@Suite struct AppKitControllerWindowSummonTests {
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
    }

    @Test func commandPaletteSessionUsesCapturedMainWindowVisibilityForHotkeyState() {
        #expect(
            !AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: true, commandPaletteMainWindowVisibility: false))
        #expect(AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: false, commandPaletteMainWindowVisibility: true))
        #expect(AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: true, commandPaletteMainWindowVisibility: nil))
        #expect(!AppKitController.effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: false, commandPaletteMainWindowVisibility: nil))
    }

    @MainActor @Test func ownerWindowReusePrefersActiveOwnerControllerOverViewer() throws {
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

        let viewerController = TerminalSessionWindowController(
            sessionID: "session-1", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })
        let ownerController = TerminalSessionWindowController(
            sessionID: "session-1", paths: paths, preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        let ownerClient = TerminalClient(
            id: ownerController.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        let viewerClient = TerminalClient(
            id: viewerController.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-1", client: viewerClient, mode: .viewer, paths: paths, attachedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-1", client: ownerClient, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:02Z")

        let selected = AppKitController.reusableTerminalSessionWindowController(
            [viewerController, ownerController], mode: .owner, activeOwnerClientID: AppKitController.activeOwnerClientID(paths: paths))

        #expect(selected === ownerController)
    }

    @MainActor @Test func ownerWindowReuseFollowsTransferredOwnerBeforeWindowRefresh() throws {
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

        let ownerController = TerminalSessionWindowController(
            sessionID: "session-2", paths: paths, preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in })
        let promotedViewerController = TerminalSessionWindowController(
            sessionID: "session-2", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        let ownerClient = TerminalClient(
            id: ownerController.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        let viewerClient = TerminalClient(
            id: promotedViewerController.clientID, kind: .localWindow,
            identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"), connectedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-2", client: ownerClient, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-2", client: viewerClient, mode: .viewer, paths: paths, attachedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-2", newOwnerClientID: promotedViewerController.clientID, paths: paths, transferredAt: "2026-05-09T00:00:02Z")

        #expect(promotedViewerController.attachmentMode == .viewer)

        let selected = AppKitController.reusableTerminalSessionWindowController(
            [ownerController, promotedViewerController], mode: .owner, activeOwnerClientID: AppKitController.activeOwnerClientID(paths: paths))

        #expect(selected === promotedViewerController)
    }

    @MainActor @Test func inMemoryOwnerWindowReuseAvoidsAttachmentSnapshotWhenOneLiveOwnerExists() throws {
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

        let ownerController = TerminalSessionWindowController(
            sessionID: "session-3", paths: paths, preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in })
        let viewerController = TerminalSessionWindowController(
            sessionID: "session-3", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        let selected = AppKitController.inMemoryOwnerTerminalSessionWindowController([viewerController, ownerController])

        #expect(selected === ownerController)
    }

    @MainActor @Test func inMemoryOwnerWindowReuseReturnsNilWhenOwnerIsAmbiguous() throws {
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

        let firstOwner = TerminalSessionWindowController(
            sessionID: "session-4", paths: paths, preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in })
        let secondOwner = TerminalSessionWindowController(
            sessionID: "session-4", paths: paths, preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        let selected = AppKitController.inMemoryOwnerTerminalSessionWindowController([firstOwner, secondOwner])

        #expect(selected == nil)
    }

    @MainActor @Test func focusableOwnerWindowReuseReturnsNilWhenNoLiveWindowExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selected = AppKitController.focusableTerminalSessionWindowController([], sessionID: "missing-session")

        #expect(selected == nil)
    }

    @MainActor @Test func focusableOwnerWindowReuseLabelsInMemoryOwnerRoute() throws {
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

        let ownerController = TerminalSessionWindowController(
            sessionID: "session-5", paths: paths, preferredAttachmentMode: .owner, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        let selected = AppKitController.focusableTerminalSessionWindowController([ownerController], sessionID: "session-5")

        #expect(selected?.controller === ownerController)
        #expect(selected?.route == "in_memory_owner")
    }

    @MainActor @Test func adHocTerminationWaitsForAllPersistedAttachmentsToDetach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
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
}
