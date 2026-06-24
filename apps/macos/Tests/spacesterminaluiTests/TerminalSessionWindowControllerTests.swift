import Carbon
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty
@testable import spacesterminalui

final class TerminalSessionWindowControllerTests: XCTestCase {
    private var originalDatabasePath: String?
    private var databaseRoot: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let databaseRoot { try? FileManager.default.removeItem(at: databaseRoot) }
        databaseRoot = nil
        originalDatabasePath = nil
        try super.tearDownWithError()
    }

    @MainActor private final class FakeGhosttySessionHost: TerminalGhosttySessionHosting {
        var hasSurface = true
        var snapshotValue: GhosttyTerminalSnapshot?
        var snapshotTextValue: String?
        var sessionSnapshotTextValue: String?
        var debugVisibleSurfaceTextValue: String?
        var effectiveTitle = "ghostty"
        var effectiveWorkingDirectory = "/tmp/work"
        var didReleaseSurface = false
        var copiedSelection = false
        var pastedClipboard = false
        var focusedStates: [(clientID: String, focused: Bool)] = []
        var focusWindowCount = 0
        var synchronizeSurfaceGeometryCount = 0
        var prepareRenderStateExportCount = 0
        var attachCount = 0
        var attachedModes: [TerminalAttachmentMode] = []
        var recordedBindingActions: [String] = []
        var handledKeySpecifiers: [String] = []
        var handleKeyEventCallCount = 0
        var searchDebugState = GhosttyTerminalSearchDebugState(isVisible: false, query: "", total: nil, selected: nil)
        var activeOwnerClientIDValue: String?
        var debugSurfaceRefreshRequestCount = 0
        func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
            attachCount += 1
            attachedModes.append(mode)
            if mode == .owner { activeOwnerClientIDValue = client.id }
        }
        func releaseRendererSurface() { didReleaseSurface = true }
        func setFocused(_ focused: Bool, for clientID: String) { focusedStates.append((clientID, focused)) }
        func focusWindow(_ window: NSWindow?) { focusWindowCount += 1 }
        @discardableResult func handleKeyEvent(_ event: NSEvent, for clientID: String) -> Bool {
            _ = clientID
            handleKeyEventCallCount += 1
            guard let keySpec = GhosttyMirrorTerminalView.remoteKeySpecifier(for: event) else { return false }
            handledKeySpecifiers.append(keySpec)
            return true
        }
        @discardableResult func synchronizeSurfaceGeometry() -> Bool {
            synchronizeSurfaceGeometryCount += 1
            return true
        }
        func activeOwnerClientID() -> String? { activeOwnerClientIDValue }
        func hasRenderableSurface() -> Bool { hasSurface }
        func requestSurfaceRefresh() { debugSurfaceRefreshRequestCount += 1 }
        func prepareRenderStateExport() { prepareRenderStateExportCount += 1 }
        func snapshot() -> GhosttyTerminalSnapshot? { snapshotValue }
        func snapshotText() -> String? { snapshotTextValue }
        func sessionSnapshot() -> GhosttyTerminalSnapshot? { snapshotValue }
        func sessionSnapshotText() -> String? { sessionSnapshotTextValue ?? snapshotTextValue }
        func copySelectionToPasteboard() -> Bool {
            copiedSelection = true
            return true
        }
        func pasteClipboardContents() -> Bool {
            pastedClipboard = true
            return true
        }
        @discardableResult func performBindingAction(_ action: String) -> Bool {
            recordedBindingActions.append(action)
            switch action {
            case "start_search": searchDebugState = .init(isVisible: true, query: searchDebugState.query, total: nil, selected: nil)
            case "end_search": searchDebugState = .init(isVisible: false, query: "", total: nil, selected: nil)
            case let queryAction where queryAction.hasPrefix("search:"):
                searchDebugState = .init(
                    isVisible: true, query: String(queryAction.dropFirst("search:".count)), total: searchDebugState.total,
                    selected: searchDebugState.selected)
            default: break
            }
            return true
        }
        @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32) -> Bool {
            _ = scrollMods
            debugSurfaceRefreshRequestCount += 1
            return true
        }
        @discardableResult func clearScreenAndScrollback() -> Bool {
            debugSurfaceRefreshRequestCount += 1
            return true
        }
        var debugSearchState: GhosttyTerminalSearchDebugState { searchDebugState }
        func debugVisibleSurfaceText() -> String? { debugVisibleSurfaceTextValue ?? snapshotTextValue }
    }

    private final class ClientCapture: @unchecked Sendable {
        var attachedClientID: String?
        var attachedMode: TerminalAttachmentMode?
        var attachedModes: [TerminalAttachmentMode] = []
        var detachedClientID: String?
    }

    private final class TakeoverAttemptRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var attemptClientIDs: [String] = []

        func record(clientID: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            attemptClientIDs.append(clientID)
            return attemptClientIDs.count
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return attemptClientIDs.count
        }
    }

    private final class ValidatedItem: NSObject, NSValidatedUserInterfaceItem {
        let action: Selector?

        init(action: Selector?) { self.action = action }

        var tag: Int { 0 }
    }

    @MainActor private func ghosttySnapshot(text: String = "hi") -> GhosttyTerminalSnapshot {
        let cells = text.unicodeScalars.map {
            GhosttyTerminalSnapshot.Cell(codepoint: $0.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
        }
        return GhosttyTerminalSnapshot(
            columns: max(text.count, 1), rows: 1, cursorColumn: max(text.count - 1, 0), cursorRow: 0, cursorVisible: true,
            defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0x000000, cells: cells)
    }

    private func normalizedRenderedOutput(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false
        ).map { line in String(line).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    @MainActor private func keyEvent(
        keyCode: Int, characters: String, modifiers: NSEvent.ModifierFlags = .command, window: NSWindow? = nil,
        charactersIgnoringModifiers: String? = nil
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters.lowercased(), isARepeat: false,
                keyCode: UInt16(keyCode)))
    }

    @MainActor private func makeGhosttyController(
        sessionID: String, paths: TerminalSessionPaths, preferredAttachmentMode: TerminalAttachmentMode = .owner, host: FakeGhosttySessionHost? = nil,
        performInitialRefresh: Bool = true, attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil, detachClientAction: (@Sendable (String) throws -> Void)? = nil,
        copySelectionAction: (@MainActor () -> Bool)? = nil, detachClientSynchronouslyOnClose: Bool = true,
        pasteClipboardAction: (@MainActor () -> Bool)? = nil, ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil,
        ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil, onWindowClose: (@MainActor (String, String, Bool) -> Void)? = nil,
        sessionHostProvider: (@MainActor @Sendable (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting)? =
            nil
    ) -> TerminalSessionWindowController {
        let resolvedHost =
            host
            ?? {
                let host = FakeGhosttySessionHost()
                if preferredAttachmentMode == .owner { host.snapshotValue = ghosttySnapshot() } else { host.hasSurface = false }
                return host
            }()
        return TerminalSessionWindowController(
            sessionID: sessionID, paths: paths, preferredAttachmentMode: preferredAttachmentMode, performInitialRefresh: performInitialRefresh,
            takeoverAction: takeoverAction, attachClientAction: attachClientAction, detachClientAction: detachClientAction,
            copySelectionAction: copySelectionAction, detachClientSynchronouslyOnClose: detachClientSynchronouslyOnClose,
            pasteClipboardAction: pasteClipboardAction, ownerWindowFocusAction: ownerWindowFocusAction,
            ownerSurfaceFocusAction: ownerSurfaceFocusAction, onWindowClose: onWindowClose,
            sessionHostProvider: sessionHostProvider ?? { @MainActor @Sendable _, _ in resolvedHost })
    }

    @MainActor func testControllerCreatesWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = TerminalSessionWindowController(sessionID: "session-1", paths: .init(rootDirectory: root.path))

        XCTAssertNotNil(controller.window)
        XCTAssertEqual(controller.window?.title, "Terminal session-1")
        XCTAssertEqual(controller.window?.tabbingMode, .disallowed)
    }

    @MainActor func testRuntimeToolbarShowsRightAlignedLifecycleControlsWithoutDuplicatedTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var didRun = false
        var didStop = false
        var didRestart = false
        let controller = TerminalSessionWindowController(sessionID: "session-controls", paths: .init(rootDirectory: root.path))

        controller.setRuntimeControls(
            TerminalSessionRuntimeControls(
                title: "frontend", canRun: true, canStop: true, canRestart: true, onRun: { didRun = true }, onStop: { didStop = true },
                onRestart: { didRestart = true }))

        XCTAssertTrue(controller.debugShowsHeader)
        XCTAssertTrue(controller.debugShowsRuntimeToolbar)
        XCTAssertEqual(controller.debugRuntimeToolbarTitle, "frontend")
        XCTAssertFalse(controller.debugShowsRuntimeToolbarTitle)
        XCTAssertTrue(controller.debugShowsRuntimeRunButton)
        XCTAssertTrue(controller.debugShowsRuntimeStopButton)
        XCTAssertTrue(controller.debugShowsRuntimeRestartButton)
        XCTAssertFalse(controller.debugShowsSummaryLabel)
        XCTAssertFalse(controller.debugShowsStateLabel)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.debugRuntimeToolbarTrailingGap, 0, accuracy: 1)

        controller.debugRunRuntimeToolbarAction()
        controller.debugStopRuntimeToolbarAction()
        controller.debugRestartRuntimeToolbarAction()

        XCTAssertTrue(didRun)
        XCTAssertTrue(didStop)
        XCTAssertTrue(didRestart)
    }

    @MainActor func testRuntimeControlsReuseCachedValueDuringFocusUntilDirty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-controls-cache", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-controls-cache", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        var refreshCount = 0
        let controller = TerminalSessionWindowController(
            sessionID: "session-controls-cache", paths: paths,
            runtimeControlsProvider: { _ in
                refreshCount += 1
                return TerminalSessionRuntimeControls(title: "frontend", canRun: false, canStop: true, canRestart: true)
            })

        XCTAssertEqual(refreshCount, 1)
        controller.focusWindow()
        XCTAssertEqual(refreshCount, 1)

        controller.markRuntimeControlsDirty()
        controller.debugForceRefresh()
        XCTAssertEqual(refreshCount, 2)
    }

    @MainActor func testRuntimeControlsRefreshAfterRuntimeNotification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-controls-notify", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-controls-notify", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        var refreshCount = 0
        let controller = TerminalSessionWindowController(
            sessionID: "session-controls-notify", paths: paths,
            runtimeControlsProvider: { _ in
                refreshCount += 1
                return TerminalSessionRuntimeControls(title: "frontend", canRun: false, canStop: true, canRestart: true)
            })

        XCTAssertEqual(refreshCount, 1)
        controller.debugSimulateRuntimeStateDidChange()
        XCTAssertEqual(refreshCount, 2)
    }

    @MainActor func testShowAttachesClientAndCloseDetachesClient() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = ClientCapture()
        let controller = TerminalSessionWindowController(
            sessionID: "session-1", paths: .init(rootDirectory: root.path),
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                XCTAssertEqual(mode, .owner)
            }, detachClientAction: { clientID in capture.detachedClientID = clientID })

        controller.show()
        XCTAssertNotNil(capture.attachedClientID)
        XCTAssertNil(capture.detachedClientID)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(capture.detachedClientID, capture.attachedClientID)
    }

    @MainActor func testCloseForSessionTerminationSkipsDetachAndSurfaceRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = ClientCapture()
        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        let controller = makeGhosttyController(
            sessionID: "session-termination", paths: .init(rootDirectory: root.path), host: host,
            attachClientAction: { client, _ in capture.attachedClientID = client.id },
            detachClientAction: { clientID in capture.detachedClientID = clientID })

        controller.show()
        XCTAssertNotNil(capture.attachedClientID)

        controller.closeForSessionTermination()

        XCTAssertNil(capture.detachedClientID)
        XCTAssertFalse(host.didReleaseSurface)
        XCTAssertTrue(controller.debugDidCloseWindow)
    }

    @MainActor func testWindowCloseCanDetachClientAsynchronously() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = ClientCapture()
        let detachedExpectation = expectation(description: "detach client asynchronously")
        let controller = TerminalSessionWindowController(
            sessionID: "session-async-detach", paths: .init(rootDirectory: root.path),
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                XCTAssertEqual(mode, .owner)
            },
            detachClientAction: { clientID in
                capture.detachedClientID = clientID
                detachedExpectation.fulfill()
            }, detachClientSynchronouslyOnClose: false)

        controller.show()
        XCTAssertNotNil(capture.attachedClientID)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        await fulfillment(of: [detachedExpectation], timeout: 1)
        XCTAssertEqual(capture.detachedClientID, capture.attachedClientID)
    }

    @MainActor func testCommandWClosesOnlyTerminalWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = makeGhosttyController(sessionID: "session-close-w", paths: .init(rootDirectory: root.path))
        controller.show()

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
                context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: UInt16(kVK_ANSI_W)))

        XCTAssertTrue(controller.window?.performKeyEquivalent(with: event) == true)
        XCTAssertTrue(controller.debugDidCloseWindow)
    }

    @MainActor func testCommandQClosesOnlyTerminalWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = makeGhosttyController(sessionID: "session-close-q", paths: .init(rootDirectory: root.path))
        controller.show()

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
                context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: UInt16(kVK_ANSI_Q)))

        XCTAssertTrue(controller.window?.performKeyEquivalent(with: event) == true)
        XCTAssertTrue(controller.debugDidCloseWindow)
    }

    @MainActor func testViewerShowAttachesClientAsViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "attach viewer client")
        let controller = TerminalSessionWindowController(
            sessionID: "session-1", paths: .init(rootDirectory: root.path), preferredAttachmentMode: .viewer,
            attachClientAction: { _, mode in
                XCTAssertEqual(mode, .viewer)
                expectation.fulfill()
            })

        controller.show()
        wait(for: [expectation], timeout: 1)
    }

    @MainActor func testViewerUsesConfiguredSessionHostProviderWithoutAttachingLiveSurface() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-viewer-provider"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "viewer-provider", workingDirectory: "/tmp/viewer-provider", shell: "/bin/zsh", command: nil,
            createdAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: sessionID, servicePID: 1, childPID: nil, state: .running, updatedAt: "2026-05-20T00:00:00Z",
                title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory, columns: 80, rows: 24), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "viewer")
        var providerCallCount = 0
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, preferredAttachmentMode: .viewer, host: host, performInitialRefresh: false,
            sessionHostProvider: { _, _ in
                providerCallCount += 1
                return host
            })

        controller.show()

        XCTAssertEqual(providerCallCount, 1)
        XCTAssertEqual(host.attachCount, 0)
        XCTAssertTrue(host.attachedModes.isEmpty)
    }

    @MainActor func testRuntimeNotificationDuringHostCreationDoesNotReenterHostResolution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-host-notification-reentry"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "reentry", workingDirectory: "/tmp/reentry", shell: "/bin/zsh", command: nil,
                createdAt: "2026-06-06T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .exited, updatedAt: "2026-06-06T00:00:01Z"),
            paths: paths)
        let host = FakeGhosttySessionHost()
        host.hasSurface = false
        var providerCallCount = 0

        _ = makeGhosttyController(
            sessionID: sessionID, paths: paths, preferredAttachmentMode: .viewer,
            sessionHostProvider: { _, _ in
                providerCallCount += 1
                NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil, userInfo: ["sessionID": sessionID])
                return host
            })
        await Task.yield()

        XCTAssertEqual(providerCallCount, 1)
    }

    @MainActor func testRuntimeNotificationDuringOwnerHostCreationDoesNotReenterAttachResolution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-owner-host-notification-reentry"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "owner-reentry", workingDirectory: "/tmp/reentry", shell: "/bin/zsh",
                command: nil, createdAt: "2026-06-06T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-06-06T00:00:01Z"),
            paths: paths)
        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        var providerCallCount = 0
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, preferredAttachmentMode: .owner, performInitialRefresh: false,
            sessionHostProvider: { _, _ in
                providerCallCount += 1
                NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil, userInfo: ["sessionID": sessionID])
                return host
            })
        let owner = TerminalClient(
            id: controller.clientID, kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-06-06T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-06-06T00:00:00Z")

        controller.debugForceRefresh()

        XCTAssertEqual(providerCallCount, 1)
        XCTAssertEqual(host.attachCount, 1)
        XCTAssertEqual(host.attachedModes, [.owner])
    }

    @MainActor func testShowRestoresPersistedWindowFrameForAttachmentMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = TerminalSessionWindowController(
            sessionID: "session-restore", paths: .init(rootDirectory: root.path),
            loadWindowFrameAction: { mode in
                XCTAssertEqual(mode, .owner)
                return .init(x: 90, y: 110, width: 840, height: 560)
            })

        controller.show()

        XCTAssertEqual(controller.debugWindowFrame.width, 840, accuracy: 0.5)
        XCTAssertEqual(controller.debugWindowFrame.height, 560, accuracy: 0.5)
    }

    @MainActor func testRepeatedShowDoesNotReapplyPersistedFrameForVisibleWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var loadCalls = 0
        let controller = TerminalSessionWindowController(
            sessionID: "session-restore-reuse", paths: .init(rootDirectory: root.path),
            loadWindowFrameAction: { mode in
                XCTAssertEqual(mode, .owner)
                loadCalls += 1
                return .init(x: 90, y: 110, width: 840, height: 560)
            })

        controller.show()
        controller.show()

        XCTAssertEqual(loadCalls, 1)
    }

    @MainActor func testWindowResizeCoalescesFramePersistenceBeforeFlush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var writes: [TerminalSessionWindowFrame] = []
        let controller = TerminalSessionWindowController(
            sessionID: "session-frame-write", paths: .init(rootDirectory: root.path),
            saveWindowFrameAction: { frame, mode in
                XCTAssertEqual(mode, .owner)
                writes.append(frame)
            })

        controller.show()
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))

        XCTAssertTrue(writes.isEmpty)

        await controller.debugFlushPendingWindowFramePersistence()

        XCTAssertEqual(writes.count, 1)
    }

    @MainActor func testDefaultGhosttyOwnerDoesNotRenderOutputLogWhenLiveStreamIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-1", title: "session title", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-1", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        try "echo hello\necho hello\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let controller = TerminalSessionWindowController(sessionID: "session-1", paths: paths)

        XCTAssertEqual(controller.window?.title, "session title")
        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertTrue(controller.debugShowsTextRenderer)
        XCTAssertEqual(normalizedRenderedOutput(controller.debugRenderedOutput), "")
        XCTAssertFalse(controller.debugRenderedOutput.contains("echo hello"))
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: preparing owner surface")
    }

    @MainActor func testGhosttyOwnerDoesNotRenderSnapshotTextWhenSurfaceIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-render-state-text", title: "session title", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-render-state-text", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let host = FakeGhosttySessionHost()
        host.hasSurface = false
        host.snapshotValue = ghosttySnapshot(text: "owner snapshot")
        host.snapshotTextValue = "owner snapshot"
        let controller = makeGhosttyController(sessionID: "session-render-state-text", paths: paths, host: host)

        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertTrue(controller.debugShowsTextRenderer)
        XCTAssertEqual(normalizedRenderedOutput(controller.debugRenderedOutput), "")
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: preparing owner surface")
    }

    @MainActor func testControllerUpgradesFromFallbackBackendOnceGhosttyMetadataAppears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let controller = makeGhosttyController(sessionID: "session-upgrade", paths: paths, performInitialRefresh: false)

        XCTAssertTrue(controller.debugShowsInlineControls)

        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-upgrade", backend: .ghosttyEmbedded, title: "backend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-10T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-upgrade", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running,
                updatedAt: "2026-05-10T00:00:01Z"), paths: paths)
        let owner = TerminalClient(
            id: controller.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-10T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-upgrade", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-10T00:00:00Z")

        controller.debugForceRefresh()
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertFalse(controller.debugShowsInlineControls)
    }

    @MainActor func testControllerCompactsExportHeavyProcessCommandInSummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-2", backend: .ghosttyEmbedded, title: "process", workingDirectory: "/Users/test/project", shell: "/bin/zsh",
                command: "export API_PORT=20001; export APP_PORT=20000; export PATH='/usr/bin:/bin'; uv run python -m spaces_e2e_demo",
                createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-2", backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)
        try "Traceback...\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let controller = TerminalSessionWindowController(sessionID: "session-2", paths: paths)
        controller.show()

        XCTAssertTrue(controller.debugSummary.contains("cwd: "))
        XCTAssertTrue(controller.debugSummary.contains("project"))
        XCTAssertTrue(controller.debugSummary.contains("shell: zsh"))
        XCTAssertTrue(controller.debugSummary.contains("uv run python -m spaces_e2e_demo"))
        XCTAssertFalse(controller.debugSummary.contains("export API_PORT"))
        XCTAssertTrue(controller.debugRendererSummary.contains("Renderer:"))
    }

    @MainActor func testViewerWindowShowsSimplifiedTakeoverShell() throws {
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
        let owner = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Yogesh Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.upsertClient(owner, paths: paths)
        try TerminalSessionPersistence.upsertClient(viewer, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-3", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-3", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-09T00:00:01Z")

        let controller = TerminalSessionWindowController(
            sessionID: "session-3", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        XCTAssertEqual(controller.debugWindowTitle, "frontend")
        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsInlineControls)
        XCTAssertTrue(controller.debugShowsTakeoverButton)
        // The simplified viewer shell shows only a centered status message plus the
        // Take Over button; the detail header and output body are hidden.
        XCTAssertTrue(controller.debugShowsTakeoverMessage)
        XCTAssertTrue(controller.debugTakeoverMessage.contains("Current owner"))
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertFalse(controller.debugShowsHeader)
    }

    @MainActor func testGhosttyViewerShowsTakeoverStatusWhenNotOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-viewer-snapshot", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-15T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-viewer-snapshot", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-15T00:00:01Z"), paths: paths)
        try "tail-only-content\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
        let owner = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-15T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-15T00:00:01Z")
        try TerminalSessionPersistence.upsertClient(owner, paths: paths)
        try TerminalSessionPersistence.upsertClient(viewer, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-snapshot", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-15T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-snapshot", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-15T00:00:01Z")

        let controller = makeGhosttyController(
            sessionID: "session-viewer-snapshot", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(controller.debugRenderedOutput.contains("Live terminal rendering is limited to the active owner."))
        XCTAssertTrue(controller.debugRenderedOutput.contains("Current owner: Owner Mac"))
    }

    @MainActor func testGhosttyViewerDoesNotMountLiveTerminalSurfaceWhenNotOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-viewer-surface", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-19T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-viewer-surface", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-19T00:00:01Z"), paths: paths)

        let owner = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-19T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-19T00:00:01Z")
        try TerminalSessionPersistence.upsertClient(owner, paths: paths)
        try TerminalSessionPersistence.upsertClient(viewer, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-surface", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-19T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-surface", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-19T00:00:01Z")

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "viewer")
        let controller = makeGhosttyController(
            sessionID: "session-viewer-surface", paths: paths, preferredAttachmentMode: .viewer, host: fakeHost, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        controller.show()

        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(controller.debugRenderedOutput.contains("Current owner: Owner Mac"))
    }

    @MainActor func testGhosttyViewerShowsTakeoverStatusUntilOwnershipChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-viewer-loading", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-15T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-viewer-loading", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-15T00:00:01Z"), paths: paths)
        let owner = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-15T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-15T00:00:01Z")
        try TerminalSessionPersistence.upsertClient(owner, paths: paths)
        try TerminalSessionPersistence.upsertClient(viewer, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-loading", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-15T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-loading", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-15T00:00:01Z")

        let controller = makeGhosttyController(
            sessionID: "session-viewer-loading", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(controller.debugRenderedOutput.contains("Current owner: Owner Mac"))
    }

    @MainActor func testOwnerSeekingCustomAttachRegistersViewerWhenAnotherClientOwnsSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-owner-seeking-custom", backend: .ghosttyEmbedded, title: "owner-seeking", workingDirectory: "/tmp/work",
                shell: "/bin/zsh", command: "cat", createdAt: "2026-05-20T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-seeking-custom", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-20T00:00:01Z"), paths: paths)

        let remoteOwner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", hostName: "ipad", deviceName: "iPad Pro 13-inch (M5)"),
            connectedAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-owner-seeking-custom", client: remoteOwner, mode: .owner, paths: paths, attachedAt: "2026-05-20T00:00:00Z")

        let capture = ClientCapture()
        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = false
        let controller = makeGhosttyController(
            sessionID: "session-owner-seeking-custom", paths: paths, host: fakeHost,
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                capture.attachedMode = mode
                try TerminalSessionPersistence.attachClient(
                    sessionID: "session-owner-seeking-custom", client: client, mode: mode, paths: paths, attachedAt: "2026-05-20T00:00:01Z")
            }, detachClientAction: { _ in })

        controller.show()

        let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(capture.attachedClientID, controller.clientID)
        XCTAssertEqual(capture.attachedMode, .viewer)
        XCTAssertEqual(activeAttachments.first { $0.mode == .owner }?.clientID, remoteOwner.id)
        XCTAssertEqual(activeAttachments.first { $0.clientID == controller.clientID }?.mode, .viewer)
        XCTAssertEqual(controller.attachmentMode, .viewer)
    }

    @MainActor func testOwnerSeekingWindowReattachesAsOwnerWhenPreviousOwnerDetachedAfterViewerAttach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-owner-reopen-viewer"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "owner-reopen", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-20T00:00:01Z"),
            paths: paths)

        let remoteOwner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", hostName: "ipad", deviceName: "iPad Pro 13-inch (M5)"),
            connectedAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: remoteOwner, mode: .owner, paths: paths, attachedAt: "2026-05-20T00:00:00Z")

        let capture = ClientCapture()
        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = false
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, host: fakeHost,
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                capture.attachedMode = mode
                capture.attachedModes.append(mode)
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: "2026-05-20T00:00:01Z")
            }, detachClientAction: { _ in })

        controller.show()

        XCTAssertEqual(capture.attachedModes, [.viewer])
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == controller.clientID }?.mode, .viewer)
        XCTAssertEqual(controller.attachmentMode, .viewer)

        try TerminalSessionPersistence.detachClient(id: remoteOwner.id, paths: paths, detachedAt: "2026-05-20T00:00:02Z")
        controller.requestOwnershipIfNeeded()

        fakeHost.hasSurface = true
        fakeHost.snapshotValue = ghosttySnapshot(text: "owned")
        fakeHost.snapshotTextValue = "owned"
        controller.debugForceRefresh()

        let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(capture.attachedClientID, controller.clientID)
        XCTAssertEqual(capture.attachedModes, [.viewer, .owner])
        XCTAssertEqual(activeAttachments.first { $0.clientID == controller.clientID }?.mode, .owner)
        XCTAssertNil(activeAttachments.first { $0.mode == .owner && $0.clientID != controller.clientID })
        XCTAssertEqual(controller.attachmentMode, .owner)
        XCTAssertEqual(fakeHost.attachedModes.last, .owner)
        XCTAssertTrue(controller.debugShowsTerminalSurface)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror")
    }

    @MainActor func testOwnerSeekingWindowPromotesWhenBlockingOwnerDetachesAfterViewerAttach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-owner-detached-after-viewer"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "owner-reopen", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-20T00:00:01Z"),
            paths: paths)

        let remoteOwner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", hostName: "ipad", deviceName: "iPad Pro 13-inch (M5)"),
            connectedAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: remoteOwner, mode: .owner, paths: paths, attachedAt: "2026-05-20T00:00:00Z")

        let capture = ClientCapture()
        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = true
        fakeHost.snapshotValue = ghosttySnapshot(text: "owned")
        fakeHost.snapshotTextValue = "owned"
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, host: fakeHost,
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                capture.attachedMode = mode
                capture.attachedModes.append(mode)
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: "2026-05-20T00:00:\(capture.attachedModes.count)Z")
            }, detachClientAction: { _ in })

        controller.show()

        XCTAssertEqual(capture.attachedModes, [.viewer])
        XCTAssertEqual(controller.attachmentMode, .viewer)

        try TerminalSessionPersistence.detachClient(id: remoteOwner.id, paths: paths, detachedAt: "2026-05-20T00:00:02Z")
        controller.debugForceRefresh()

        let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(capture.attachedClientID, controller.clientID)
        XCTAssertEqual(capture.attachedModes, [.viewer, .owner])
        XCTAssertEqual(activeAttachments.first { $0.clientID == controller.clientID }?.mode, .owner)
        XCTAssertEqual(controller.attachmentMode, .owner)
        XCTAssertEqual(fakeHost.attachedModes.last, .owner)
    }

    @MainActor func testOwnerSeekingWindowKeepsOwnerRequestAfterViewerMirrorDuringFocusRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-owner-viewer-mirror"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "owner-mirror", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-20T00:00:01Z"),
            paths: paths)

        let remoteOwner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", hostName: "ipad", deviceName: "iPad Pro 13-inch (M5)"),
            connectedAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: remoteOwner, mode: .owner, paths: paths, attachedAt: "2026-05-20T00:00:00Z")

        let capture = ClientCapture()
        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = false
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, host: fakeHost,
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                capture.attachedMode = mode
                capture.attachedModes.append(mode)
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: "2026-05-20T00:00:\(capture.attachedModes.count)Z")
            }, detachClientAction: { _ in })

        controller.show()
        try TerminalSessionPersistence.detachClient(id: remoteOwner.id, paths: paths, detachedAt: "2026-05-20T00:00:02Z")
        controller.requestOwnershipIfNeeded()
        XCTAssertEqual(capture.attachedModes, [.viewer, .owner])
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == controller.clientID }?.mode, .owner)

        let mirroredViewer = TerminalClient(
            id: controller.clientID, kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-20T00:00:03Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: mirroredViewer, mode: .viewer, paths: paths, attachedAt: "2026-05-20T00:00:03Z")

        controller.debugForceRefreshSkippingOwnerAttach()

        XCTAssertEqual(controller.attachmentMode, .owner)
        XCTAssertEqual(capture.attachedModes, [.viewer, .owner])
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == controller.clientID }?.mode, .viewer)

        controller.debugForceRefresh()

        XCTAssertEqual(capture.attachedClientID, controller.clientID)
        XCTAssertEqual(capture.attachedModes, [.viewer, .owner, .owner])
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == controller.clientID }?.mode, .owner)
        XCTAssertEqual(controller.attachmentMode, .owner)
    }

    @MainActor func testOwnerWindowDoesNotReclaimOwnershipAfterRemoteTakeoverDuringPassiveRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-remote-retakeover"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "retakeover", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-20T00:00:01Z"),
            paths: paths)

        let capture = ClientCapture()
        let fakeHost = FakeGhosttySessionHost()
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, host: fakeHost,
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                capture.attachedMode = mode
                capture.attachedModes.append(mode)
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: "2026-05-20T00:00:\(capture.attachedModes.count)Z")
            }, detachClientAction: { _ in })

        controller.show()
        XCTAssertEqual(capture.attachedModes, [.owner])

        let remoteOwner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", hostName: "iphone", deviceName: "iPhone"),
            connectedAt: "2026-05-20T00:00:02Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: remoteOwner, mode: .viewer, paths: paths, attachedAt: "2026-05-20T00:00:02Z")
        try TerminalSessionPersistence.transferOwnership(
            sessionID: sessionID, newOwnerClientID: remoteOwner.id, paths: paths, transferredAt: "2026-05-20T00:00:03Z")

        controller.debugAttachLocalClientIfNeeded()
        controller.debugForceRefresh()
        controller.debugForceRefresh()

        XCTAssertEqual(capture.attachedModes, [.owner, .viewer])
        XCTAssertEqual(controller.attachmentMode, .viewer)
        let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(activeAttachments.first { $0.clientID == remoteOwner.id }?.mode, .owner)
        XCTAssertEqual(activeAttachments.first { $0.clientID == controller.clientID }?.mode, .viewer)
    }

    @MainActor func testOwnerSeekingWindowRequestsTakeoverAfterShowWhenAnotherClientOwnsSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-owner-seeking", backend: .ghosttyEmbedded, title: "owner-seeking", workingDirectory: "/tmp/work",
                shell: "/bin/zsh", command: "cat", createdAt: "2026-05-20T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-seeking", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-20T00:00:01Z"), paths: paths)

        let remoteOwner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", hostName: "ipad", deviceName: "iPad Pro 13-inch (M5)"),
            connectedAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-owner-seeking", client: remoteOwner, mode: .owner, paths: paths, attachedAt: "2026-05-20T00:00:00Z")

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = false

        let controller = makeGhosttyController(
            sessionID: "session-owner-seeking", paths: paths, host: fakeHost,
            takeoverAction: { clientID in
                try TerminalSessionPersistence.transferOwnership(
                    sessionID: "session-owner-seeking", newOwnerClientID: clientID, paths: paths, transferredAt: "2026-05-20T00:00:02Z")
                return TerminalControlResponse(ok: true, message: "Took over ownership.")
            }, detachClientAction: { _ in })

        controller.show()

        XCTAssertEqual(controller.attachmentMode, .viewer)
        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(controller.debugRenderedOutput.contains("Current owner: iPad Pro 13-inch (M5)"))
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == controller.clientID }?.mode, .viewer)

        controller.requestOwnershipIfNeeded()

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            controller.debugForceRefresh()
            if controller.attachmentMode == .owner { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        fakeHost.hasSurface = true
        fakeHost.snapshotValue = ghosttySnapshot(text: "owned")
        fakeHost.snapshotTextValue = "owned"
        controller.debugForceRefresh()

        XCTAssertEqual(controller.attachmentMode, .owner)
        XCTAssertTrue(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertEqual(fakeHost.attachedModes.last, .owner)
    }

    @MainActor func testTakeoverRetrySupersedesStalePendingAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-stale-takeover"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "stale-takeover", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-20T00:00:01Z"),
            paths: paths)

        let remoteOwner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", hostName: "iphone", deviceName: "iPhone 17 Pro"),
            connectedAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: remoteOwner, mode: .owner, paths: paths, attachedAt: "2026-05-20T00:00:00Z")

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = false
        let attempts = TakeoverAttemptRecorder()
        let firstAttemptEntered = DispatchSemaphore(value: 0)
        let releaseFirstAttempt = DispatchSemaphore(value: 0)
        defer { releaseFirstAttempt.signal() }

        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, host: fakeHost,
            takeoverAction: { clientID in
                let attempt = attempts.record(clientID: clientID)
                if attempt == 1 {
                    firstAttemptEntered.signal()
                    _ = releaseFirstAttempt.wait(timeout: .now() + 10)
                    try TerminalSessionPersistence.transferOwnership(
                        sessionID: sessionID, newOwnerClientID: clientID, paths: paths, transferredAt: "2026-05-20T00:00:03Z")
                    return TerminalControlResponse(ok: true, message: "Late stale takeover.")
                }
                try TerminalSessionPersistence.transferOwnership(
                    sessionID: sessionID, newOwnerClientID: clientID, paths: paths, transferredAt: "2026-05-20T00:00:02Z")
                return TerminalControlResponse(ok: true, message: "Took over ownership.")
            }, detachClientAction: { _ in })
        controller.show()

        controller.requestOwnershipIfNeeded()
        XCTAssertEqual(firstAttemptEntered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(controller.debugTakeoverPending)
        XCTAssertFalse(controller.debugTakeoverEnabled)

        fakeHost.hasSurface = true
        fakeHost.snapshotValue = ghosttySnapshot(text: "owned")
        fakeHost.snapshotTextValue = "owned"
        controller.debugSetTakeoverTaskStartedAt(Date(timeIntervalSinceNow: -60))
        controller.takeOverOwnership()

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            controller.debugForceRefresh()
            if attempts.count >= 2 && controller.attachmentMode == .owner && !controller.debugTakeoverPending { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(controller.attachmentMode, .owner)
        XCTAssertFalse(controller.debugTakeoverPending)
        XCTAssertTrue(controller.debugShowsTerminalSurface)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror")
    }

    @MainActor func testGhosttyOwnerDemotionToViewerReleasesRendererSurfaceAndShowsTakeoverStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-owner-to-viewer", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-19T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-to-viewer", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-19T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "viewer")
        let controller = makeGhosttyController(sessionID: "session-owner-to-viewer", paths: paths, host: fakeHost)

        let currentOwner = TerminalClient(
            id: controller.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-19T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-owner-to-viewer", client: currentOwner, mode: .owner, paths: paths, attachedAt: "2026-05-19T00:00:00Z")

        controller.show()
        let initialAttachCount = fakeHost.attachCount

        let otherClient = TerminalClient(id: "other-owner", kind: .remoteViewer, identity: .init(label: "iPad"), connectedAt: "2026-05-19T00:00:02Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-owner-to-viewer", client: otherClient, mode: .viewer, paths: paths, attachedAt: "2026-05-19T00:00:02Z")
        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-owner-to-viewer", newOwnerClientID: otherClient.id, paths: paths, transferredAt: "2026-05-19T00:00:03Z")

        controller.debugForceRefresh()

        XCTAssertEqual(controller.attachmentMode, .viewer)
        XCTAssertEqual(fakeHost.attachCount, initialAttachCount)
        XCTAssertTrue(fakeHost.didReleaseSurface)
        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(controller.debugRenderedOutput.contains("Current owner: iPad"))
    }

    @MainActor func testGhosttyViewerShowsFinalRenderAfterSessionExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-viewer-final-output", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work",
                shell: "/bin/zsh", command: "false", createdAt: "2026-05-15T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-viewer-final-output", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .exited,
                updatedAt: "2026-05-15T00:00:01Z"), paths: paths)
        try "output log tail should not render\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
        let owner = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-15T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-15T00:00:01Z")
        try TerminalSessionPersistence.upsertClient(owner, paths: paths)
        try TerminalSessionPersistence.upsertClient(viewer, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-final-output", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-15T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-final-output", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-15T00:00:01Z")

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = false
        fakeHost.snapshotValue = ghosttySnapshot(text: "command failed")
        fakeHost.debugVisibleSurfaceTextValue = "command failed"
        let controller = makeGhosttyController(
            sessionID: "session-viewer-final-output", paths: paths, preferredAttachmentMode: .viewer, host: fakeHost, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        XCTAssertTrue(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertFalse(controller.debugShowsHeader)
        XCTAssertFalse(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugShowsTakeoverMessage)
        XCTAssertTrue(normalizedRenderedOutput(controller.debugStateDump().renderedOutput).contains("command failed"))
        XCTAssertFalse(normalizedRenderedOutput(controller.debugStateDump().renderedOutput).contains("output log tail should not render"))
        XCTAssertEqual(normalizedRenderedOutput(controller.debugRenderedOutput), "command failed")
        NSPasteboard.general.clearContents()
        controller.selectAll(nil)
        controller.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "command failed")
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: final Ghostty render")
    }

    @MainActor func testGhosttyOwnerWindowHidesInlineControls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-4", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-4", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)
        let controller = makeGhosttyController(sessionID: "session-4", paths: paths)

        XCTAssertFalse(controller.debugShowsInlineControls)
        XCTAssertFalse(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugShowsRendererLabel)
        XCTAssertFalse(controller.debugShowsTitleLabel)
        XCTAssertFalse(controller.debugShowsSummaryLabel)
        XCTAssertFalse(controller.debugShowsStateLabel)
        XCTAssertFalse(controller.debugShowsHeader)
        XCTAssertEqual(controller.debugState, "state: running    child: 22")
    }

    @MainActor func testGhosttyOwnerIgnoresInlineSubmitStatusWhenControlsAreHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-4b", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "zsh",
                createdAt: "2026-05-10T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-4b", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-10T00:00:01Z"),
            paths: paths)
        let controller = makeGhosttyController(sessionID: "session-4b", paths: paths)

        controller.debugSubmitInput()

        XCTAssertEqual(controller.debugInputStatus, "")
        XCTAssertFalse(controller.debugShowsInputStatus)
    }

    @MainActor func testGhosttyOwnerShowsHeaderWhenRuntimeStateNeedsStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-owner-status", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-status", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        let controller = makeGhosttyController(sessionID: "session-owner-status", paths: paths)

        XCTAssertFalse(controller.debugShowsHeader)
        XCTAssertTrue(controller.debugShowsSummaryLabel)
        XCTAssertTrue(controller.debugShowsStateLabel)
        XCTAssertTrue(controller.debugState.contains("state: exited"))
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: final Ghostty render")
    }

    @MainActor func testGhosttyOwnerUsesSlowerNotificationFirstRefreshInterval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-owner-refresh", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-refresh", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let controller = makeGhosttyController(sessionID: "session-owner-refresh", paths: paths)

        XCTAssertEqual(controller.debugRefreshIntervalMS, 2000)
    }

    @MainActor func testGhosttyOwnerUsesFastRefreshWhenRuntimeStateNeedsStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-owner-exited-refresh", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work",
                shell: "/bin/zsh", command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-exited-refresh", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let controller = TerminalSessionWindowController(sessionID: "session-owner-exited-refresh", paths: paths)

        XCTAssertEqual(controller.debugRefreshIntervalMS, 500)
    }

    @MainActor func testViewerFallbackKeepsFastRefreshInterval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-viewer-refresh", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-viewer-refresh", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        let owner = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.upsertClient(owner, paths: paths)
        try TerminalSessionPersistence.upsertClient(viewer, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-refresh", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-refresh", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-09T00:00:01Z")

        let controller = TerminalSessionWindowController(
            sessionID: "session-viewer-refresh", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        XCTAssertEqual(controller.debugRefreshIntervalMS, 500)
    }

    @MainActor func testGhosttyViewerHidesTakeoverWhenSessionIsNotRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-viewer-exited", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-viewer-exited", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        let owner = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.upsertClient(owner, paths: paths)
        try TerminalSessionPersistence.upsertClient(viewer, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-exited", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-exited", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-09T00:00:01Z")

        let controller = TerminalSessionWindowController(
            sessionID: "session-viewer-exited", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        XCTAssertFalse(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugTakeoverEnabled)
        XCTAssertTrue(controller.debugShowsTextRenderer)
        XCTAssertFalse(controller.debugShowsHeader)
        XCTAssertFalse(controller.debugShowsTakeoverMessage)
        XCTAssertTrue(controller.debugRenderedOutput.contains("Terminal render unavailable."))
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: unavailable")
    }

    @MainActor func testGhosttyCustomOwnerRouteShowsPreparingForStartingSessionWithoutAttaching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-starting-remote", backend: .ghosttyEmbedded, title: "shell-1", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-06-22T12:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-starting-remote", backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .starting,
                updatedAt: "2026-06-22T12:00:00Z"), paths: paths)
        let capture = ClientCapture()
        let controller = makeGhosttyController(
            sessionID: "session-starting-remote", paths: paths, preferredAttachmentMode: .owner,
            attachClientAction: { _, mode in capture.attachedModes.append(mode) }, detachClientAction: { _ in })

        controller.show()

        XCTAssertTrue(capture.attachedModes.isEmpty)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(controller.debugRenderedOutput.contains("Preparing terminal"))
        XCTAssertFalse(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugTakeoverEnabled)
    }

    @MainActor func testGhosttyLocalReservedStartingSessionDoesNotDeferInitialPresentation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-starting-local", backend: .ghosttyEmbedded, title: "shell-1", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-06-22T12:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-starting-local", backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .starting,
                updatedAt: "2026-06-22T12:00:00Z"), paths: paths)
        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = false
        let controller = makeGhosttyController(sessionID: "session-starting-local", paths: paths, host: fakeHost)

        controller.show()

        XCTAssertFalse(controller.debugShouldDeferInitialOwnerPresentationInProduction())
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(controller.debugRenderedOutput.contains("Preparing terminal"))
        XCTAssertFalse(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugTakeoverEnabled)
    }

    @MainActor func testGhosttyOwnerStatusShellDisablesInlineInputWhenSessionIsNotRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-script-exited", title: "script", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-script-exited", servicePID: 1, childPID: 22, state: .exited, updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let controller = TerminalSessionWindowController(sessionID: "session-script-exited", paths: paths)

        XCTAssertFalse(controller.debugShowsInlineControls)
        XCTAssertFalse(controller.debugInlineInputEnabled)
    }

    @MainActor func testGhosttyOwnerUsesLiveSurfaceBodyWithoutRefreshingFallbackTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-owner-surface", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-surface", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        try "owner output should stay on the live surface\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let controller = makeGhosttyController(sessionID: "session-owner-surface", paths: paths)
        controller.show()
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.debugForceRefresh()

        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertEqual(controller.debugRenderedOutput, "")
        XCTAssertGreaterThan(controller.debugTerminalContainerWidth, 0)
        XCTAssertGreaterThanOrEqual(controller.debugTerminalContainerWidth, controller.debugBodyWidth - 2)
        XCTAssertGreaterThanOrEqual(controller.debugTerminalContainerWidth, controller.debugContentWidth - 2)
    }

    @MainActor func testDebugStateDumpPrefersVisibleSurfaceOverStaleSessionSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-visible-debug-dump", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-29T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-visible-debug-dump", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-29T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.sessionSnapshotTextValue = "stale session snapshot"
        host.debugVisibleSurfaceTextValue = "fresh visible surface"
        let controller = makeGhosttyController(sessionID: "session-visible-debug-dump", paths: paths, host: host)
        controller.show()
        controller.debugForceRefresh()

        XCTAssertTrue(controller.debugShowsTerminalSurface)
        XCTAssertEqual(controller.debugStateDump().renderedOutput, "fresh visible surface")
    }

    @MainActor func testDebugStateDumpPrefersGhosttySnapshotGridOverSurfaceReadText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-snapshot-debug-dump", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-29T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-snapshot-debug-dump", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-29T00:00:01Z"), paths: paths)

        let snapshot = ghosttySnapshot(text: "OpenAI Codex")
        let host = FakeGhosttySessionHost()
        host.snapshotValue = snapshot
        host.debugVisibleSurfaceTextValue = "stale shell prompt"
        let controller = makeGhosttyController(sessionID: "session-snapshot-debug-dump", paths: paths, host: host)
        controller.show()
        controller.debugForceRefresh()

        XCTAssertTrue(controller.debugShowsTerminalSurface)
        XCTAssertEqual(controller.debugStateDump().renderedOutput, GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot))
    }

    @MainActor func testGhosttyOwnerShowPrefersLiveTerminalViewAsFirstResponder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-owner-first-responder", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work",
                shell: "/bin/zsh", command: "cat", createdAt: "2026-05-12T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-first-responder", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-12T00:00:01Z"), paths: paths)

        let controller = makeGhosttyController(sessionID: "session-owner-first-responder", paths: paths)
        controller.show()

        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertFalse(controller.debugFirstResponderTargetsInputField)
        XCTAssertFalse(controller.debugFirstResponderTargetsOutputView)
    }

    @MainActor func testGhosttyOwnerRoutesCopyAndPasteThroughSessionHostActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-copy-paste", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-copy-paste", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        var copyCalls = 0
        var pasteCalls = 0
        let controller = makeGhosttyController(
            sessionID: "session-copy-paste", paths: paths,
            copySelectionAction: {
                copyCalls += 1
                return true
            },
            pasteClipboardAction: {
                pasteCalls += 1
                return true
            })

        controller.copy(nil)
        controller.paste(nil)

        XCTAssertEqual(copyCalls, 1)
        XCTAssertEqual(pasteCalls, 1)
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.copy(_:)))))
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.paste(_:)))))
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.selectAll(_:)))))
    }

    @MainActor func testGhosttyOwnerCommandKeyEquivalentsDispatchEditAndFindActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-command-edit", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-command-edit", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        let controller = makeGhosttyController(sessionID: "session-command-edit", paths: paths, host: host)
        controller.show()

        XCTAssertTrue(
            controller.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_V, characters: "v", window: controller.window)) == true)
        XCTAssertTrue(
            controller.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_C, characters: "c", window: controller.window)) == true)
        XCTAssertTrue(
            controller.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_A, characters: "a", window: controller.window)) == true)
        XCTAssertTrue(
            controller.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_F, characters: "f", window: controller.window)) == true)
        XCTAssertTrue(
            controller.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_E, characters: "e", window: controller.window)) == true)
        XCTAssertTrue(
            controller.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_G, characters: "g", window: controller.window)) == true)
        XCTAssertTrue(
            controller.window?.performKeyEquivalent(
                with: try keyEvent(keyCode: kVK_ANSI_G, characters: "G", modifiers: [.command, .shift], window: controller.window)) == true)

        XCTAssertEqual(
            host.recordedBindingActions,
            ["copy_to_clipboard", "select_all", "start_search", "search_selection", "navigate_search:next", "navigate_search:previous"])
        XCTAssertTrue(host.pastedClipboard)
    }

    @MainActor func testGhosttyOwnerControlCRemainsTerminalInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-control-c", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-control-c", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        let controller = makeGhosttyController(sessionID: "session-control-c", paths: paths, host: host)
        controller.show()
        controller.window?.makeKeyAndOrderFront(nil)
        let event = try keyEvent(
            keyCode: kVK_ANSI_C, characters: "\u{3}", modifiers: .control, window: controller.window, charactersIgnoringModifiers: "c")

        XCTAssertFalse(controller.window?.performKeyEquivalent(with: event) == true)
        controller.window?.sendEvent(event)

        XCTAssertTrue(host.recordedBindingActions.isEmpty)
        XCTAssertEqual(host.handledKeySpecifiers, ["ctrl+c"])
    }

    @MainActor func testGhosttyOwnerEscDismissesSearchWithoutSendingTerminalKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-search-esc", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-search-esc", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        host.searchDebugState = .init(isVisible: true, query: "needle", total: nil, selected: nil)
        let controller = makeGhosttyController(sessionID: "session-search-esc", paths: paths, host: host)
        controller.show()
        controller.window?.makeKeyAndOrderFront(nil)
        let event = try keyEvent(keyCode: kVK_Escape, characters: "\u{1b}", modifiers: [], window: controller.window)

        controller.window?.sendEvent(event)

        XCTAssertEqual(host.recordedBindingActions, ["end_search"])
        XCTAssertEqual(host.debugSearchState.isVisible, false)
    }

    @MainActor func testGhosttyOwnerDoesNotForwardSearchFieldTypingToTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-search-field-typing", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-search-field-typing", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        host.searchDebugState = .init(isVisible: true, query: "", total: nil, selected: nil)
        let controller = makeGhosttyController(sessionID: "session-search-field-typing", paths: paths, host: host)
        controller.show()
        controller.window?.makeKeyAndOrderFront(nil)
        let fieldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        fieldEditor.isFieldEditor = true
        controller.window?.contentView?.addSubview(fieldEditor)
        XCTAssertTrue(controller.window?.makeFirstResponder(fieldEditor) == true)

        let typeEvent = try keyEvent(keyCode: kVK_ANSI_Z, characters: "z", modifiers: [], window: controller.window)
        controller.window?.sendEvent(typeEvent)

        XCTAssertEqual(host.handleKeyEventCallCount, 0)
        XCTAssertTrue(host.recordedBindingActions.isEmpty)
        XCTAssertTrue(host.debugSearchState.isVisible)

        let escapeEvent = try keyEvent(keyCode: kVK_Escape, characters: "\u{1b}", modifiers: [], window: controller.window)
        controller.window?.sendEvent(escapeEvent)

        XCTAssertEqual(host.handleKeyEventCallCount, 0)
        XCTAssertEqual(host.recordedBindingActions, ["end_search"])
        XCTAssertEqual(host.debugSearchState.isVisible, false)
    }

    @MainActor func testGhosttyOwnerEscAndHideFindDismissSearchAfterExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-search-esc-exited", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-search-esc-exited", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        host.searchDebugState = .init(isVisible: true, query: "needle", total: nil, selected: nil)
        let controller = makeGhosttyController(sessionID: "session-search-esc-exited", paths: paths, host: host)
        controller.show()
        controller.window?.makeKeyAndOrderFront(nil)

        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionWindowController.hideFind(_:)))))
        XCTAssertFalse(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionWindowController.find(_:)))))

        let event = try keyEvent(keyCode: kVK_Escape, characters: "\u{1b}", modifiers: [], window: controller.window)
        controller.window?.sendEvent(event)

        XCTAssertEqual(host.recordedBindingActions, ["end_search"])
        XCTAssertEqual(host.debugSearchState.isVisible, false)

        host.searchDebugState = .init(isVisible: true, query: "needle", total: nil, selected: nil)
        host.recordedBindingActions.removeAll()

        controller.hideFind(nil)

        XCTAssertEqual(host.recordedBindingActions, ["end_search"])
        XCTAssertEqual(host.debugSearchState.isVisible, false)
    }

    @MainActor func testGhosttyViewerDisablesActionsAndExitedOwnerKeepsReadOnlyShortcuts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let viewerPaths = TerminalSessionPaths(rootDirectory: root.appendingPathComponent("viewer").path)
        try FileManager.default.createDirectory(atPath: viewerPaths.rootDirectory, withIntermediateDirectories: true)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-viewer-disabled", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: viewerPaths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-viewer-disabled", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: viewerPaths)
        let owner = TerminalClient(id: "owner-client", kind: .localWindow, identity: .init(label: "Owner"), connectedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-viewer-disabled", client: owner, mode: .owner, paths: viewerPaths, attachedAt: "2026-05-09T00:00:00Z")
        let viewerHost = FakeGhosttySessionHost()
        viewerHost.hasSurface = false
        let viewer = makeGhosttyController(
            sessionID: "session-viewer-disabled", paths: viewerPaths, preferredAttachmentMode: .viewer, host: viewerHost,
            attachClientAction: { _, _ in }, detachClientAction: { _ in })

        XCTAssertFalse(viewer.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.paste(_:)))))
        XCTAssertFalse(viewer.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionWindowController.find(_:)))))
        XCTAssertFalse(viewer.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionWindowController.useSelectionForFind(_:)))))

        let exitedPaths = TerminalSessionPaths(rootDirectory: root.appendingPathComponent("exited").path)
        try FileManager.default.createDirectory(atPath: exitedPaths.rootDirectory, withIntermediateDirectories: true)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-exited-disabled", backend: .ghosttyEmbedded, title: "exited", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: exitedPaths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-exited-disabled", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: exitedPaths)
        let exitedHost = FakeGhosttySessionHost()
        exitedHost.snapshotValue = ghosttySnapshot(text: "owner")
        let exited = makeGhosttyController(sessionID: "session-exited-disabled", paths: exitedPaths, host: exitedHost)
        exited.show()

        XCTAssertTrue(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.copy(_:)))))
        XCTAssertTrue(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.selectAll(_:)))))
        XCTAssertFalse(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.paste(_:)))))
        XCTAssertFalse(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionWindowController.find(_:)))))
        XCTAssertFalse(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionWindowController.findNext(_:)))))

        XCTAssertTrue(exited.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_C, characters: "c", window: exited.window)) == true)
        XCTAssertTrue(exited.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_A, characters: "a", window: exited.window)) == true)
        XCTAssertFalse(exited.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_V, characters: "v", window: exited.window)) == true)
        XCTAssertFalse(exited.window?.performKeyEquivalent(with: try keyEvent(keyCode: kVK_ANSI_F, characters: "f", window: exited.window)) == true)
        XCTAssertEqual(exitedHost.recordedBindingActions, ["copy_to_clipboard", "select_all"])
    }

    @MainActor func testGhosttyOwnerPasteIsDisabledWhenSessionIsNotRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-copy-paste-exited", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-copy-paste-exited", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        var pasteCalls = 0
        let controller = makeGhosttyController(
            sessionID: "session-copy-paste-exited", paths: paths,
            pasteClipboardAction: {
                pasteCalls += 1
                return true
            })

        controller.paste(nil)

        XCTAssertEqual(pasteCalls, 0)
        XCTAssertFalse(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.paste(_:)))))
        XCTAssertEqual(controller.debugInputStatus, "Session is not running.")
    }

    @MainActor func testGhosttyOwnerResyncsFocusAcrossWindowAndAppTransitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-focus", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-09T00:00:01Z"
            ), paths: paths)

        var focusWindowCalls = 0
        var focusedStates: [Bool] = []
        let controller = TerminalSessionWindowController(
            sessionID: "session-focus", paths: paths, ownerWindowFocusAction: { _ in focusWindowCalls += 1 },
            ownerSurfaceFocusAction: { focused in focusedStates.append(focused) })

        controller.show()
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        controller.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        let focusWindowCallsBeforeAppActive = focusWindowCalls
        controller.debugSimulateApplicationDidBecomeActive()
        controller.windowDidResignMain(Notification(name: NSWindow.didResignMainNotification))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        controller.debugSimulateApplicationDidResignActive()

        XCTAssertEqual(focusWindowCalls, focusWindowCallsBeforeAppActive)
        XCTAssertGreaterThanOrEqual(focusWindowCalls, 4)
        XCTAssertTrue(focusedStates.contains(false))
    }

    func testDeferredInitialOwnerPresentationActivatesOnlyForActiveAppOrExplicitFocusRequest() {
        XCTAssertTrue(TerminalSessionWindowController.shouldActivateDeferredInitialOwnerPresentation(appIsActive: true, requestID: nil))
        XCTAssertTrue(
            TerminalSessionWindowController.shouldActivateDeferredInitialOwnerPresentation(appIsActive: false, requestID: UUID().uuidString))
        XCTAssertFalse(TerminalSessionWindowController.shouldActivateDeferredInitialOwnerPresentation(appIsActive: false, requestID: nil))
        XCTAssertFalse(TerminalSessionWindowController.shouldActivateDeferredInitialOwnerPresentation(appIsActive: false, requestID: ""))
    }

    func testWindowActivationRetryPredicate() {
        XCTAssertFalse(
            TerminalSessionWindowController.shouldRetryWindowActivation(
                forceFrontmost: true, appWasActive: true, windowIsKeyAfterInitialActivation: true, isDeferredOwnerPresentation: false,
                takeoverPending: false))
        XCTAssertTrue(
            TerminalSessionWindowController.shouldRetryWindowActivation(
                forceFrontmost: true, appWasActive: true, windowIsKeyAfterInitialActivation: true, isDeferredOwnerPresentation: true,
                takeoverPending: false))
        XCTAssertTrue(
            TerminalSessionWindowController.shouldRetryWindowActivation(
                forceFrontmost: true, appWasActive: true, windowIsKeyAfterInitialActivation: true, isDeferredOwnerPresentation: false,
                takeoverPending: true))
        XCTAssertTrue(
            TerminalSessionWindowController.shouldRetryWindowActivation(
                forceFrontmost: true, appWasActive: true, windowIsKeyAfterInitialActivation: false, isDeferredOwnerPresentation: false,
                takeoverPending: false))
        XCTAssertFalse(
            TerminalSessionWindowController.shouldRetryWindowActivation(
                forceFrontmost: false, appWasActive: true, windowIsKeyAfterInitialActivation: false, isDeferredOwnerPresentation: false,
                takeoverPending: false))
    }

    @MainActor func testGhosttyOwnerFocusWindowReassertsOwnerSurfaceFocus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-focus-window", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-focus-window", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        var focusWindowCalls = 0
        var focusedStates: [Bool] = []
        let controller = TerminalSessionWindowController(
            sessionID: "session-focus-window", paths: paths, ownerWindowFocusAction: { _ in focusWindowCalls += 1 },
            ownerSurfaceFocusAction: { focused in focusedStates.append(focused) })

        let initialWindowFocusCalls = focusWindowCalls
        let initialFocusedStateCount = focusedStates.count
        controller.focusWindow()

        XCTAssertGreaterThan(focusWindowCalls, initialWindowFocusCalls)
        XCTAssertGreaterThan(focusedStates.count, initialFocusedStateCount)
    }

    @MainActor func testGhosttyOwnerFocusWindowDoesNotReattachExistingOwnerSurface() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-focus-fast-path", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-focus-fast-path", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "owner")
        let controller = makeGhosttyController(sessionID: "session-focus-fast-path", paths: paths, host: fakeHost)

        controller.show()
        let attachCountAfterShow = fakeHost.attachCount
        let geometrySyncCountAfterShow = fakeHost.synchronizeSurfaceGeometryCount

        controller.focusWindow()

        XCTAssertEqual(fakeHost.attachCount, attachCountAfterShow)
        XCTAssertGreaterThan(fakeHost.focusWindowCount, 0)
        XCTAssertGreaterThan(fakeHost.synchronizeSurfaceGeometryCount, geometrySyncCountAfterShow)
    }

    @MainActor func testGhosttyOwnerFocusWindowRefreshesStaleViewerTitleBeforeFocus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-focus-title-refresh", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work",
                shell: "/bin/zsh", command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-focus-title-refresh", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "owner")
        let ownerController = makeGhosttyController(sessionID: "session-focus-title-refresh", paths: paths, host: fakeHost)
        let viewerController = makeGhosttyController(
            sessionID: "session-focus-title-refresh", paths: paths, preferredAttachmentMode: .viewer, host: fakeHost, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        let owner = TerminalClient(
            id: ownerController.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        let viewer = TerminalClient(
            id: viewerController.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-focus-title-refresh", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-focus-title-refresh", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-09T00:00:01Z")

        ownerController.show()
        viewerController.show()

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-focus-title-refresh", newOwnerClientID: viewer.id, paths: paths, transferredAt: "2026-05-09T00:00:02Z")
        ownerController.debugForceRefresh()
        XCTAssertEqual(ownerController.debugWindowTitle, "ghostty")

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-focus-title-refresh", newOwnerClientID: owner.id, paths: paths, transferredAt: "2026-05-09T00:00:03Z")
        ownerController.focusWindow()

        XCTAssertEqual(ownerController.debugWindowTitle, "ghostty")
    }

    @MainActor func testGhosttyOwnerMetadataRefreshCanSkipLiveAttachUntilShow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-show-focus", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-12T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-show-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-12T00:00:01Z"), paths: paths)

        var focusVisibilityStates: [Bool] = []
        let controller = makeGhosttyController(
            sessionID: "session-show-focus", paths: paths,
            ownerWindowFocusAction: { window in focusVisibilityStates.append(window?.isVisible == true) })

        controller.debugForceRefreshSkippingOwnerAttach()

        XCTAssertEqual(focusVisibilityStates, [false])
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror")
    }

    @MainActor func testGhosttyOwnerScrollRequestsSurfaceRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-scroll-refresh", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "printf 'one\\ntwo\\nthree\\n'", createdAt: "2026-05-12T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-scroll-refresh", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-12T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot()
        let controller = makeGhosttyController(sessionID: "session-scroll-refresh", paths: paths, host: fakeHost)
        controller.show()
        let initialRefreshCount = controller.debugGhosttySurfaceRefreshRequestCount

        XCTAssertTrue(controller.debugSendGhosttyScroll(vertical: 24))
        XCTAssertGreaterThan(controller.debugGhosttySurfaceRefreshRequestCount, initialRefreshCount)
    }

    @MainActor func testGhosttyOwnerStatusShellDisablesPasteUntilRendererIsReady() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-fallback", title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-fallback", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("paste-from-test", forType: .string)

        let controller = TerminalSessionWindowController(sessionID: "session-fallback", paths: paths)

        controller.paste(nil)

        XCTAssertEqual(controller.debugInputFieldValue, "")
        XCTAssertEqual(controller.debugInputStatus, "Take over ownership before sending terminal input.")
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.copy(_:)))))
        XCTAssertFalse(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.paste(_:)))))
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.selectAll(_:)))))
    }

    @MainActor func testFallbackTranscriptCopyStaysEnabledAfterExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-fallback-exited", backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-fallback-exited", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.hasSurface = false
        host.snapshotValue = ghosttySnapshot(text: "final transcript")
        host.snapshotTextValue = "final transcript"
        let controller = makeGhosttyController(sessionID: "session-fallback-exited", paths: paths, host: host)
        controller.show()

        XCTAssertEqual(controller.debugRendererSummary, "Renderer: final Ghostty render")
        XCTAssertEqual(normalizedRenderedOutput(controller.debugRenderedOutput), "final transcript")
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.copy(_:)))))
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.selectAll(_:)))))
        XCTAssertFalse(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.paste(_:)))))
    }

    @MainActor func testFallbackTranscriptDisablesSmartTextEditingFeatures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-transcript-config", title: "transcript", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-transcript-config", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let controller = TerminalSessionWindowController(sessionID: "session-transcript-config", paths: paths)

        XCTAssertTrue(controller.debugOutputDisablesSmartSubstitutions)
    }

    @MainActor func testGhosttyViewerShowPrefersTakeoverShellWhenNotOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-viewer-focus", backend: .ghosttyEmbedded, title: "viewer-focus", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-viewer-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "viewer")
        let controller = makeGhosttyController(
            sessionID: "session-viewer-focus", paths: paths, preferredAttachmentMode: .viewer, host: fakeHost, attachClientAction: { _, _ in },
            detachClientAction: { _ in })
        controller.show()

        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertTrue(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugFirstResponderTargetsOutputView)
        XCTAssertFalse(controller.debugFirstResponderTargetsInputField)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertGreaterThan(controller.debugTakeoverContainerWidth, 120)
    }

    @MainActor func testWindowCloseInvokesCleanupCallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cleanup = expectation(description: "cleanup callback")
        var closedSessionID: String?
        var closedClientID: String?
        var closedForTermination: Bool?
        let controller = TerminalSessionWindowController(
            sessionID: "session-5", paths: .init(rootDirectory: root.path),
            onWindowClose: { sessionID, clientID, isTerminating in
                closedSessionID = sessionID
                closedClientID = clientID
                closedForTermination = isTerminating
                cleanup.fulfill()
            })

        let expectedClientID = controller.clientID
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        wait(for: [cleanup], timeout: 1)
        XCTAssertEqual(closedSessionID, "session-5")
        XCTAssertEqual(closedClientID, expectedClientID)
        XCTAssertEqual(closedForTermination, false)
    }

    @MainActor func testWindowCloseCallbackMarksSessionTerminationClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var closedForTermination: Bool?
        let controller = TerminalSessionWindowController(
            sessionID: "session-termination-close", paths: .init(rootDirectory: root.path),
            onWindowClose: { _, _, isTerminating in closedForTermination = isTerminating })

        controller.closeForSessionTermination()
        if closedForTermination == nil { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }

        XCTAssertEqual(closedForTermination, true)
    }

    @MainActor func testGhosttyControllersRefreshOwnershipAfterTakeover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-6", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-6", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "owner")
        fakeHost.effectiveTitle = "frontend"
        let ownerController = makeGhosttyController(sessionID: "session-6", paths: paths, host: fakeHost)
        let viewerController = makeGhosttyController(
            sessionID: "session-6", paths: paths, preferredAttachmentMode: .viewer, host: fakeHost, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        let owner = TerminalClient(
            id: ownerController.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        let viewer = TerminalClient(
            id: viewerController.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-6", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-6", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-09T00:00:01Z")

        ownerController.debugForceRefresh()
        viewerController.debugForceRefresh()
        XCTAssertEqual(ownerController.debugWindowTitle, "frontend")
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertFalse(ownerController.debugShowsTakeoverButton)
        XCTAssertEqual(viewerController.debugWindowTitle, "frontend")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(viewerController.debugShowsTakeoverButton)
        XCTAssertFalse(viewerController.debugShowsTerminalSurface)

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-6", newOwnerClientID: viewer.id, paths: paths, transferredAt: "2026-05-09T00:00:02Z")

        ownerController.debugForceRefresh()
        viewerController.debugForceRefresh()

        XCTAssertEqual(ownerController.debugWindowTitle, "frontend")
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(ownerController.debugShowsTakeoverButton)
        XCTAssertFalse(ownerController.debugShowsTerminalSurface)
        XCTAssertEqual(viewerController.debugWindowTitle, "frontend")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertFalse(viewerController.debugShowsTakeoverButton)

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-6", newOwnerClientID: owner.id, paths: paths, transferredAt: "2026-05-09T00:00:03Z")

        ownerController.debugForceRefresh()
        viewerController.debugForceRefresh()

        XCTAssertEqual(ownerController.debugWindowTitle, "frontend")
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertFalse(ownerController.debugShowsTakeoverButton)
        XCTAssertEqual(viewerController.debugWindowTitle, "frontend")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(viewerController.debugShowsTakeoverButton)
        XCTAssertFalse(viewerController.debugShowsTerminalSurface)
    }

    @MainActor func testGhosttyControllersRefreshOwnershipAfterAttachmentChangeNotification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-notify", backend: .ghosttyEmbedded, title: "backend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "uv run api", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-notify", backend: .ghosttyEmbedded, servicePID: 1, childPID: 9876, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "notify")
        fakeHost.effectiveTitle = "backend"
        let ownerController = makeGhosttyController(sessionID: "session-notify", paths: paths, host: fakeHost)
        let viewerController = makeGhosttyController(
            sessionID: "session-notify", paths: paths, preferredAttachmentMode: .viewer, host: fakeHost, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        let owner = TerminalClient(
            id: ownerController.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        let viewer = TerminalClient(
            id: viewerController.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-notify", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-notify", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-09T00:00:01Z")

        ownerController.debugForceRefresh()
        viewerController.debugForceRefresh()
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: takeover status")

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-notify", newOwnerClientID: viewer.id, paths: paths, transferredAt: "2026-05-09T00:00:02Z")

        ownerController.debugSimulateAttachmentStateDidChange()
        viewerController.debugSimulateAttachmentStateDidChange()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: takeover status")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertTrue(ownerController.debugShowsTakeoverButton)
        XCTAssertFalse(viewerController.debugShowsTakeoverButton)
    }

    @MainActor func testGhosttyOwnerRefreshesTitleAndWorkingDirectoryImmediatelyFromSessionMetadataNotification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initialWorkingDirectory = root.appendingPathComponent("work", isDirectory: true)
        let updatedWorkingDirectory = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: initialWorkingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: updatedWorkingDirectory, withIntermediateDirectories: true)

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-metadata", backend: .ghosttyEmbedded, title: "backend", workingDirectory: initialWorkingDirectory.path,
                shell: "/bin/zsh", command: "uv run api", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-metadata", backend: .ghosttyEmbedded, servicePID: 1, childPID: 9876, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot()
        fakeHost.effectiveTitle = "backend"
        fakeHost.effectiveWorkingDirectory = initialWorkingDirectory.path
        let controller = makeGhosttyController(sessionID: "session-metadata", paths: paths, host: fakeHost)
        let owner = TerminalClient(
            id: controller.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-metadata", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")

        controller.debugForceRefresh()
        XCTAssertEqual(controller.debugWindowTitle, "backend")
        XCTAssertEqual(controller.debugWindowRepresentedPath, initialWorkingDirectory.path)
        XCTAssertTrue(controller.debugSummary.contains("work"))

        fakeHost.effectiveTitle = "live api"
        fakeHost.effectiveWorkingDirectory = updatedWorkingDirectory.path
        controller.debugSimulateSessionMetadataDidChange()

        XCTAssertEqual(controller.debugWindowTitle, "live api")
        XCTAssertEqual(controller.debugWindowRepresentedPath, updatedWorkingDirectory.path)
        XCTAssertTrue(controller.debugSummary.contains("runtime"))
    }

    @MainActor func testGhosttyOwnerRefreshesRuntimeStateImmediatelyFromRuntimeStateNotification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-runtime", backend: .ghosttyEmbedded, title: "backend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "uv run api", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-runtime", backend: .ghosttyEmbedded, servicePID: 1, childPID: 1111, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let controller = TerminalSessionWindowController(sessionID: "session-runtime", paths: paths)
        let owner = TerminalClient(
            id: controller.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-runtime", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")

        controller.debugForceRefresh()
        XCTAssertTrue(controller.debugState.hasPrefix("state: running"))

        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-runtime", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2222, state: .running,
                updatedAt: "2026-05-09T00:00:02Z"), paths: paths)

        controller.debugSimulateRuntimeStateDidChange()

        XCTAssertEqual(controller.debugState, "state: running    child: 2222")
    }

    @MainActor func testGhosttyViewerTakeoverStatusIgnoresOutputNotificationsWithoutOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-output-notify", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-output-notify", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        try "one\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let owner = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Viewer Mac"),
            connectedAt: "2026-05-09T00:00:01Z")
        try TerminalSessionPersistence.upsertClient(owner, paths: paths)
        try TerminalSessionPersistence.upsertClient(viewer, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-output-notify", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-output-notify", client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-09T00:00:01Z")

        let controller = makeGhosttyController(
            sessionID: "session-output-notify", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        controller.debugForceRefresh()
        let initialRenderedOutput = controller.debugRenderedOutput
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(initialRenderedOutput.contains("Current owner: Owner Mac"))

        try "one\ntwo\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
        controller.debugSimulateOutputDidChange()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(controller.debugRenderedOutput, initialRenderedOutput)
    }

    @MainActor func testGhosttyOwnerClearsStaleNotRunningErrorOnceRuntimeRecovers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-runtime-recover", backend: .ghosttyEmbedded, title: "backend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "uv run api", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-runtime-recover", backend: .ghosttyEmbedded, servicePID: 1, childPID: 1111, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z", exitedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let controller = makeGhosttyController(sessionID: "session-runtime-recover", paths: paths)
        let owner = TerminalClient(
            id: controller.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-runtime-recover", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
        controller.paste(nil)
        XCTAssertEqual(controller.debugInputStatus, "Session is not running.")

        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-runtime-recover", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2222, state: .running,
                updatedAt: "2026-05-09T00:00:02Z"), paths: paths)

        controller.debugForceRefresh()

        XCTAssertFalse(controller.debugShowsInputStatus)
        XCTAssertEqual(controller.debugInputStatus, "")
    }

    @MainActor func testGhosttyOwnerCloseMarksControllerAndReopenUsesFreshClientAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-7", backend: .ghosttyEmbedded, title: "backend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "uv run api", createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-7", backend: .ghosttyEmbedded, servicePID: 1, childPID: 9876, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "backend")
        fakeHost.effectiveTitle = "backend"
        let firstController = makeGhosttyController(
            sessionID: "session-7", paths: paths, host: fakeHost,
            attachClientAction: { client, mode in
                try TerminalSessionPersistence.attachClient(
                    sessionID: "session-7", client: client, mode: mode, paths: paths, attachedAt: "2026-05-09T00:00:00Z")
            },
            detachClientAction: { clientID in
                try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: "2026-05-09T00:00:01Z")
            })
        firstController.show()
        let firstClientID = firstController.clientID

        firstController.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(firstController.debugDidCloseWindow)

        let reopenedController = makeGhosttyController(
            sessionID: "session-7", paths: paths, host: fakeHost,
            attachClientAction: { client, mode in
                try TerminalSessionPersistence.attachClient(
                    sessionID: "session-7", client: client, mode: mode, paths: paths, attachedAt: "2026-05-09T00:00:02Z")
            },
            detachClientAction: { clientID in
                try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: "2026-05-09T00:00:03Z")
            })
        reopenedController.show()
        reopenedController.debugForceRefresh()

        let snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
        let activeOwners = snapshot.attachments.filter { $0.mode == .owner && $0.detachedAt == nil }

        XCTAssertEqual(activeOwners.count, 1)
        XCTAssertEqual(activeOwners.first?.clientID, reopenedController.clientID)
        XCTAssertNotEqual(reopenedController.clientID, firstClientID)
        XCTAssertTrue(snapshot.attachments.contains { $0.clientID == firstClientID && $0.detachedAt != nil })
        XCTAssertEqual(reopenedController.debugWindowTitle, "backend")
        XCTAssertEqual(reopenedController.debugRendererSummary, "Renderer: ghostty-mirror")
    }
}
