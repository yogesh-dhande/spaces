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

    @Test func commandPalettePresentationKeepsWindowVisibilityDecisionsLocal() {
        #expect(AppKitController.shouldOrderOutMainWindowForCommandPalettePresentation(mainWindowIsVisible: false))
        #expect(!AppKitController.shouldOrderOutMainWindowForCommandPalettePresentation(mainWindowIsVisible: true))
        #expect(AppKitController.shouldHideAppAfterCommandPaletteDismissal(mainWindowIsVisible: false, auxiliarySessionWindowsVisible: false))
        #expect(!AppKitController.shouldHideAppAfterCommandPaletteDismissal(mainWindowIsVisible: false, auxiliarySessionWindowsVisible: true))
        #expect(!AppKitController.shouldHideAppAfterCommandPaletteDismissal(mainWindowIsVisible: true, auxiliarySessionWindowsVisible: false))
    }

    @Test func toggleHotkeyOnlyHidesWhenMainWindowIsActuallyKey() {
        #expect(
            AppKitController.shouldHideMainWindowForToggle(appIsActive: true, appIsHidden: false, mainWindowIsVisible: true, mainWindowIsKey: true))
        #expect(
            !AppKitController.shouldHideMainWindowForToggle(appIsActive: true, appIsHidden: false, mainWindowIsVisible: true, mainWindowIsKey: false))
        #expect(
            !AppKitController.shouldHideMainWindowForToggle(appIsActive: false, appIsHidden: false, mainWindowIsVisible: true, mainWindowIsKey: true))
        #expect(
            !AppKitController.shouldHideMainWindowForToggle(appIsActive: true, appIsHidden: true, mainWindowIsVisible: true, mainWindowIsKey: true))
    }

    @Test func commandPalettePresentationCompletesOnlyAfterPaletteBecomesKey() {
        #expect(!AppKitController.commandPalettePresentationIsComplete(panelIsVisible: false, panelIsKey: false))
        #expect(!AppKitController.commandPalettePresentationIsComplete(panelIsVisible: true, panelIsKey: false))
        #expect(AppKitController.commandPalettePresentationIsComplete(panelIsVisible: true, panelIsKey: true))
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
}
