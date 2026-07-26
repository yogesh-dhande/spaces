import Carbon
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty
@testable import spacesterminalui

/// Test state provider that reads the same on-disk terminal session store the
/// daemon writes. Production injects a Device-API-backed model instead; this lets
/// existing tests keep seeding state through `TerminalSessionPersistence` while the
/// controller itself only ever reads through the injected provider.
@MainActor final class PersistenceBackedTerminalSessionStateProvider: TerminalSessionStateProviding {
    private let paths: TerminalSessionPaths
    init(paths: TerminalSessionPaths) { self.paths = paths }
    var currentLaunchConfiguration: TerminalSessionLaunchConfiguration? { try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths) }
    var currentRuntimeState: TerminalSessionRuntimeState? { try? TerminalSessionPersistence.readRuntimeState(paths: paths) }
    var currentAttachmentSnapshot: TerminalSessionAttachmentSnapshot? { try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths) }
    var latestRemoteStatePayload: GhosttyRemoteSessionStatePayload? { try? TerminalSessionPersistence.readRemoteSessionState(paths: paths) }
    /// Settable so a test can put the pane's link down without a device: the on-disk store this reads
    /// has no notion of a subscription, and the production model owns the flag.
    var isStateStreamDisconnected = false
    func refreshState() {}
    func startStateStream(
        onUpdate _: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect _: @escaping @MainActor ((any Error)?) -> Void
    ) {}
}

/// Pure in-memory state provider used to verify the pane controller renders,
/// refreshes, focuses, checks ownership, attaches, detaches, and closes without any
/// `TerminalSessionPersistence` access.
@MainActor final class FakeTerminalSessionStateProvider: TerminalSessionStateProviding {
    var currentLaunchConfiguration: TerminalSessionLaunchConfiguration?
    var currentRuntimeState: TerminalSessionRuntimeState?
    var currentAttachmentSnapshot: TerminalSessionAttachmentSnapshot?
    var latestRemoteStatePayload: GhosttyRemoteSessionStatePayload?
    var isStateStreamDisconnected = false
    private(set) var refreshStateCallCount = 0
    private(set) var startStateStreamCallCount = 0

    init(
        launchConfiguration: TerminalSessionLaunchConfiguration? = nil, runtimeState: TerminalSessionRuntimeState? = nil,
        attachmentSnapshot: TerminalSessionAttachmentSnapshot? = nil, latestRemoteStatePayload: GhosttyRemoteSessionStatePayload? = nil
    ) {
        currentLaunchConfiguration = launchConfiguration
        currentRuntimeState = runtimeState
        currentAttachmentSnapshot = attachmentSnapshot
        self.latestRemoteStatePayload = latestRemoteStatePayload
    }

    func refreshState() { refreshStateCallCount += 1 }
    func startStateStream(
        onUpdate _: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect _: @escaping @MainActor ((any Error)?) -> Void
    ) { startStateStreamCallCount += 1 }
}

// Persistence-backed control closures for tests. Production injects Device API
// closures; these keep the persistence-seeded test setup working now that the
// controller requires them (it has no DB defaults).
func persistenceBackedAttachAction(_ paths: TerminalSessionPaths) -> @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void {
    { client, mode in
        // attachClient validates the canonical session id, so read it from the seeded
        // launch configuration rather than guessing from the path.
        let sessionID =
            (try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths))?.sessionID ?? (paths.rootDirectory as NSString).lastPathComponent
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: ISO8601DateFormatter().string(from: Date()))
    }
}

func persistenceBackedDetachAction(_ paths: TerminalSessionPaths) -> @Sendable (String) throws -> Void {
    { clientID in try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date())) }
}

final class TerminalSessionPaneViewControllerTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        if let databaseRoot { try? FileManager.default.removeItem(at: databaseRoot) }
        databaseRoot = nil
        originalDatabasePath = nil
        originalRuntimeDirectory = nil
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
        @discardableResult func sendTextAsPaste(_ text: String) -> Bool {
            pastedClipboard = !text.isEmpty
            return !text.isEmpty
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
        @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)
            -> Bool
        {
            _ = scrollMods
            _ = pointerPosition
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
        /// The detached client id observed at the moment the close hook ran, used to prove the hook
        /// fires only after the async detach has landed.
        var detachedClientIDWhenCloseHookRan: String?
        var closeHookRan = false
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
        keyCode: Int, characters: String, modifiers: NSEvent.ModifierFlags = .command, charactersIgnoringModifiers: String? = nil
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters.lowercased(), isARepeat: false, keyCode: UInt16(keyCode)))
    }

    /// Hosts the pane's view in a real window the way the app's pane container does.
    /// Used by tests that exercise first-responder routing or need a resolved layout
    /// pass; the pane itself never creates or owns a window.
    @MainActor private func makeHostWindow(for controller: TerminalSessionPaneViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 600))
        window.contentView = container
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.layoutIfNeeded()
        return window
    }

    private func imageData(type: NSBitmapImageRep.FileType = .png, width: Int = 2, height: Int = 2) throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        for x in 0..<width {
            for y in 0..<height {
                bitmap.setColor(NSColor(calibratedRed: CGFloat(x + 1) / CGFloat(width + 1), green: 0.25, blue: 0.75, alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }

    @MainActor private func makeGhosttyController(
        sessionID: String, paths: TerminalSessionPaths, preferredAttachmentMode: TerminalAttachmentMode = .owner, host: FakeGhosttySessionHost? = nil,
        performInitialRefresh: Bool = true, reusableOwnerClientID: String? = nil,
        attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil, detachClientAction: (@Sendable (String) throws -> Void)? = nil,
        copySelectionAction: (@MainActor () -> Bool)? = nil, detachClientSynchronouslyOnClose: Bool = true,
        pasteClipboardAction: (@MainActor () -> Bool)? = nil,
        pasteImageAction: (@MainActor (TerminalPasteboardImage) async throws -> TerminalControlResponse)? = nil,
        pasteboardImageReadAction: (@MainActor () -> TerminalPasteboardImageReadResult)? = nil,
        ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil, ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil,
        onWindowClose: (@MainActor (String, String, Bool) -> Void)? = nil,
        sessionHostProvider: (@MainActor @Sendable (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting)? =
            nil
    ) -> TerminalSessionPaneViewController {
        let resolvedHost =
            host
            ?? {
                let host = FakeGhosttySessionHost()
                if preferredAttachmentMode == .owner { host.snapshotValue = ghosttySnapshot() } else { host.hasSurface = false }
                return host
            }()
        return TerminalSessionPaneViewController(
            sessionID: sessionID, paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            preferredAttachmentMode: preferredAttachmentMode, performInitialRefresh: performInitialRefresh,
            reusableOwnerClientID: reusableOwnerClientID, pasteImageAction: pasteImageAction, pasteboardImageReadAction: pasteboardImageReadAction,
            takeoverAction: takeoverAction, attachClientAction: attachClientAction ?? persistenceBackedAttachAction(paths),
            detachClientAction: detachClientAction ?? persistenceBackedDetachAction(paths), copySelectionAction: copySelectionAction,
            detachClientSynchronouslyOnClose: detachClientSynchronouslyOnClose, defersInitialOwnerClientAttach: attachClientAction == nil,
            pasteClipboardAction: pasteClipboardAction, ownerWindowFocusAction: ownerWindowFocusAction,
            ownerSurfaceFocusAction: ownerSurfaceFocusAction, onWindowClose: onWindowClose,
            sessionHostProvider: sessionHostProvider ?? { @MainActor @Sendable _, _ in resolvedHost })
    }

    @MainActor func testControllerInitializesContentAndDefaultDisplayTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = TerminalSessionPaneViewController(
            sessionID: "session-1", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)),
            attachClientAction: persistenceBackedAttachAction(.init(rootDirectory: root.path)),
            detachClientAction: persistenceBackedDetachAction(.init(rootDirectory: root.path)))

        XCTAssertFalse(controller.view.subviews.isEmpty)
        XCTAssertEqual(controller.displayTitle, "Terminal session-1")
    }

    @MainActor func testShowAttachesClientAndCloseDetachesClient() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = ClientCapture()
        let controller = TerminalSessionPaneViewController(
            sessionID: "session-1", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)),
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                XCTAssertEqual(mode, .owner)
            }, detachClientAction: { clientID in capture.detachedClientID = clientID })

        controller.showEmbedded(focus: true)
        XCTAssertNotNil(capture.attachedClientID)
        XCTAssertNil(capture.detachedClientID)

        controller.closeEmbedded()
        XCTAssertEqual(capture.detachedClientID, capture.attachedClientID)
    }

    /// The pane controller renders, refreshes, attaches, and detaches purely from
    /// the injected state provider and control closures — it never reads the daemon's
    /// `spaces.db`. The store is left empty so any persistence read would surface as a
    /// nil runtime state, which the assertions reject.
    @MainActor func testControllerRendersFromInjectedProviderWithoutPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-provider", backend: .ghosttyEmbedded, title: "provider-title", workingDirectory: "/tmp/provider", shell: "/bin/zsh",
            command: nil, createdAt: "2026-06-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: "session-provider", backend: .ghosttyEmbedded, servicePID: 7, childPID: 8, state: .running, updatedAt: "2026-06-29T00:00:01Z",
            title: "provider-title", workingDirectory: "/tmp/provider", columns: 80, rows: 24)
        let provider = FakeTerminalSessionStateProvider(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot())
        let capture = ClientCapture()
        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot()
        let controller = TerminalSessionPaneViewController(
            sessionID: "session-provider", paths: paths, stateProvider: provider, preferredAttachmentMode: .owner, performInitialRefresh: false,
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                capture.attachedMode = mode
            }, detachClientAction: { clientID in capture.detachedClientID = clientID }, sessionHostProvider: { _, _ in host })

        controller.showEmbedded(focus: true)

        XCTAssertGreaterThan(provider.refreshStateCallCount, 0)
        XCTAssertEqual(controller.lastObservedRuntimeState?.state, .running)
        XCTAssertNotNil(capture.attachedClientID)
        XCTAssertEqual(capture.attachedMode, .owner)
        XCTAssertNil(try? TerminalSessionPersistence.readRuntimeState(paths: paths))

        controller.closeEmbedded()
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

        controller.showEmbedded(focus: true)
        XCTAssertNotNil(capture.attachedClientID)

        controller.closeEmbedded(sessionIsTerminating: true)

        XCTAssertNil(capture.detachedClientID)
        XCTAssertFalse(host.didReleaseSurface)
        XCTAssertTrue(controller.debugDidCloseWindow)
    }

    @MainActor func testCloseEmbeddedCanDetachClientAsynchronously() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = ClientCapture()
        let detachedExpectation = expectation(description: "detach client asynchronously")
        let controller = TerminalSessionPaneViewController(
            sessionID: "session-async-detach", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)),
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                XCTAssertEqual(mode, .owner)
            },
            detachClientAction: { clientID in
                capture.detachedClientID = clientID
                detachedExpectation.fulfill()
            }, detachClientSynchronouslyOnClose: false)

        controller.showEmbedded(focus: true)
        XCTAssertNotNil(capture.attachedClientID)

        controller.closeEmbedded()

        await fulfillment(of: [detachedExpectation], timeout: 1)
        XCTAssertEqual(capture.detachedClientID, capture.attachedClientID)
    }

    /// The close hook must run only after the async detach has landed, so the owner's ad hoc cleanup
    /// reads an attachment snapshot that already reflects this client leaving. Asserting the detach was
    /// captured by the time the hook fires guards against the pane leaking a shell on close.
    @MainActor func testCloseEmbeddedRunsCloseHookAfterAsyncDetach() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = ClientCapture()
        let hookRan = expectation(description: "close hook runs")
        let controller = TerminalSessionPaneViewController(
            sessionID: "session-close-hook", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)),
            attachClientAction: { client, _ in capture.attachedClientID = client.id },
            detachClientAction: { clientID in capture.detachedClientID = clientID }, detachClientSynchronouslyOnClose: false,
            onCloseClientDetached: {
                capture.detachedClientIDWhenCloseHookRan = capture.detachedClientID
                hookRan.fulfill()
            })

        controller.showEmbedded(focus: true)
        XCTAssertNotNil(capture.attachedClientID)

        controller.closeEmbedded()

        await fulfillment(of: [hookRan], timeout: 1)
        XCTAssertEqual(capture.detachedClientIDWhenCloseHookRan, capture.attachedClientID)
    }

    /// A session-terminating close is the daemon already stopping the session, so it must not fire the
    /// close hook — running the ad hoc cleanup then would be redundant work against a dying session.
    @MainActor func testCloseForSessionTerminationSkipsCloseHook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = ClientCapture()
        let controller = TerminalSessionPaneViewController(
            sessionID: "session-terminate-no-hook", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)),
            attachClientAction: { client, _ in capture.attachedClientID = client.id },
            detachClientAction: { clientID in capture.detachedClientID = clientID }, detachClientSynchronouslyOnClose: false,
            onCloseClientDetached: { capture.closeHookRan = true })

        controller.showEmbedded(focus: true)
        XCTAssertNotNil(capture.attachedClientID)

        controller.closeEmbedded(sessionIsTerminating: true)

        XCTAssertNil(capture.detachedClientID)
        XCTAssertFalse(capture.closeHookRan)
    }

    @MainActor func testViewerShowAttachesClientAsViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "attach viewer client")
        let controller = TerminalSessionPaneViewController(
            sessionID: "session-1", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)), preferredAttachmentMode: .viewer,
            attachClientAction: { _, mode in
                XCTAssertEqual(mode, .viewer)
                expectation.fulfill()
            }, detachClientAction: persistenceBackedDetachAction(.init(rootDirectory: root.path)))

        controller.showEmbedded(focus: true)
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
            createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
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

        controller.showEmbedded(focus: true)

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
                createdAt: "2026-06-06T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                command: nil, createdAt: "2026-06-06T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

    @MainActor func testDefaultGhosttyOwnerDoesNotRenderOutputLogWhenLiveStreamIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-1", title: "session title", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-1", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        try "echo hello\necho hello\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let controller = TerminalSessionPaneViewController(
            sessionID: "session-1", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            attachClientAction: persistenceBackedAttachAction(paths), detachClientAction: persistenceBackedDetachAction(paths))

        XCTAssertEqual(controller.displayTitle, "session title")
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
                createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                command: "zsh", createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-2", backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)
        try "Traceback...\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let controller = TerminalSessionPaneViewController(
            sessionID: "session-2", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            attachClientAction: persistenceBackedAttachAction(paths), detachClientAction: persistenceBackedDetachAction(paths))
        controller.showEmbedded(focus: true)

        XCTAssertTrue(controller.debugSummary.contains("cwd: "))
        XCTAssertTrue(controller.debugSummary.contains("project"))
        XCTAssertTrue(controller.debugSummary.contains("shell: zsh"))
        XCTAssertTrue(controller.debugSummary.contains("uv run python -m spaces_e2e_demo"))
        XCTAssertFalse(controller.debugSummary.contains("export API_PORT"))
        XCTAssertTrue(controller.debugRendererSummary.contains("Renderer:"))
    }

    @MainActor func testViewerPaneShowsSimplifiedTakeoverShell() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-3", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        let controller = TerminalSessionPaneViewController(
            sessionID: "session-3", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })

        XCTAssertEqual(controller.displayTitle, "frontend")
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
                command: "cat", createdAt: "2026-05-15T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                command: "cat", createdAt: "2026-05-19T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        controller.showEmbedded(focus: true)

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
                command: "cat", createdAt: "2026-05-15T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                shell: "/bin/zsh", command: "cat", createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        controller.showEmbedded(focus: true)

        let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(capture.attachedClientID, controller.clientID)
        XCTAssertEqual(capture.attachedMode, .viewer)
        XCTAssertEqual(activeAttachments.first { $0.mode == .owner }?.clientID, remoteOwner.id)
        XCTAssertEqual(activeAttachments.first { $0.clientID == controller.clientID }?.mode, .viewer)
        XCTAssertEqual(controller.attachmentMode, .viewer)
    }

    @MainActor func testOwnerSeekingPaneReattachesAsOwnerWhenPreviousOwnerDetachedAfterViewerAttach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-owner-reopen-viewer"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "owner-reopen", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        controller.showEmbedded(focus: true)

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

    @MainActor func testRequestOwnershipDoesNotAttachAgainWhenAlreadyActiveOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-already-owner"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "already-owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-20T00:00:01Z"),
            paths: paths)

        let capture = ClientCapture()
        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = true
        fakeHost.snapshotValue = ghosttySnapshot(text: "owned")
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, host: fakeHost, performInitialRefresh: false,
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                capture.attachedMode = mode
                capture.attachedModes.append(mode)
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: "2026-05-20T00:00:0\(capture.attachedModes.count)Z")
            }, detachClientAction: { _ in })

        controller.showEmbedded(focus: true)
        XCTAssertEqual(capture.attachedModes, [.owner])
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == controller.clientID }?.mode, .owner)

        controller.requestOwnershipIfNeeded()

        XCTAssertEqual(capture.attachedModes, [.owner])
        XCTAssertEqual(controller.attachmentMode, .owner)
        XCTAssertEqual(fakeHost.attachedModes.last, .owner)
    }

    /// Relaunch reclaim: a pane built with the owner client id this device stored on its prior launch
    /// matches the daemon's orphaned, never-expiring `localWindow` owner attachment left behind by the
    /// killed instance. `currentOwnerClient?.id == client.id` so the pane silently adopts that owner
    /// attachment — no daemon re-attach, no viewer/takeover UI.
    @MainActor func testReusedOwnerClientIDReclaimsOrphanedOwnerAttachmentSilently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-relaunch-reclaim"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "relaunch", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-20T00:00:01Z"),
            paths: paths)

        // The dead instance's owner attachment: a local window client that still owns the session.
        let reusedClientID = "reused-local-owner"
        let orphanedOwner = TerminalClient(
            id: reusedClientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Studio Mac"),
            connectedAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: orphanedOwner, mode: .owner, paths: paths, attachedAt: "2026-05-20T00:00:00Z")

        let capture = ClientCapture()
        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "owned")
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, host: fakeHost, reusableOwnerClientID: reusedClientID,
            attachClientAction: { client, mode in
                capture.attachedModes.append(mode)
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: "2026-05-20T00:00:02Z")
            }, detachClientAction: { _ in })

        controller.showEmbedded(focus: true)

        let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(controller.clientID, reusedClientID)
        // No daemon re-attach: the pane recognized itself as the existing owner attachment.
        XCTAssertTrue(capture.attachedModes.isEmpty)
        XCTAssertEqual(controller.attachmentMode, .owner)
        XCTAssertEqual(activeAttachments.first { $0.mode == .owner }?.clientID, reusedClientID)
        XCTAssertNil(activeAttachments.first { $0.mode == .owner && $0.clientID != reusedClientID })
        XCTAssertEqual(fakeHost.attachedModes.last, .owner)
        XCTAssertTrue(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsTakeoverButton)
    }

    /// Cross-device safety: a stored owner client id that does NOT match the session's current owner
    /// (another device owns it) never reclaims ownership. The pane attaches as a viewer and leaves the
    /// current owner and the manual takeover UI unchanged — a stale local mapping is inert.
    @MainActor func testStoredOwnerClientIDForForeignOwnerStillAttachesAsViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-foreign-owner"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "foreign", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-20T00:00:01Z"),
            paths: paths)

        let foreignOwner = TerminalClient(
            id: "other-device-owner", kind: .remoteViewer, identity: .init(label: "iPad", hostName: "ipad", deviceName: "iPad Pro 13-inch (M5)"),
            connectedAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: foreignOwner, mode: .owner, paths: paths, attachedAt: "2026-05-20T00:00:00Z")

        let capture = ClientCapture()
        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = false
        // A stale stored id from a prior local attachment; it differs from the foreign current owner.
        let staleStoredClientID = "stale-local-id"
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, host: fakeHost, reusableOwnerClientID: staleStoredClientID,
            attachClientAction: { client, mode in
                capture.attachedClientID = client.id
                capture.attachedMode = mode
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: "2026-05-20T00:00:02Z")
            }, detachClientAction: { _ in })

        controller.showEmbedded(focus: true)

        let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(controller.clientID, staleStoredClientID)
        XCTAssertEqual(capture.attachedMode, .viewer)
        XCTAssertEqual(activeAttachments.first { $0.mode == .owner }?.clientID, foreignOwner.id)
        XCTAssertEqual(activeAttachments.first { $0.clientID == staleStoredClientID }?.mode, .viewer)
        XCTAssertEqual(controller.attachmentMode, .viewer)
    }

    @MainActor func testOwnerSeekingPanePromotesWhenBlockingOwnerDetachesAfterViewerAttach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-owner-detached-after-viewer"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "owner-reopen", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        controller.showEmbedded(focus: true)

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

    @MainActor func testOwnerSeekingPaneKeepsOwnerRequestAfterViewerMirrorDuringFocusRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-owner-viewer-mirror"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "owner-mirror", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        controller.showEmbedded(focus: true)
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

    @MainActor func testOwnerPaneDoesNotReclaimOwnershipAfterRemoteTakeoverDuringPassiveRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-remote-retakeover"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "retakeover", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        controller.showEmbedded(focus: true)
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

    @MainActor func testOwnerSeekingPaneRequestsTakeoverAfterShowWhenAnotherClientOwnsSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-owner-seeking", backend: .ghosttyEmbedded, title: "owner-seeking", workingDirectory: "/tmp/work",
                shell: "/bin/zsh", command: "cat", createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        controller.showEmbedded(focus: true)

        XCTAssertEqual(controller.attachmentMode, .viewer)
        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(controller.debugRenderedOutput.contains("Current owner: iPad Pro 13-inch (M5)"))
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == controller.clientID }?.mode, .viewer)

        controller.requestOwnershipIfNeeded()
        XCTAssertTrue(controller.debugTakeoverPending)
        XCTAssertFalse(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugShowsTakeoverMessage)

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            controller.debugForceRefresh()
            if controller.attachmentMode == .owner && !controller.debugTakeoverPending { break }
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

    @MainActor func testOwnerSeekingPaneRestoresTakeoverControlsAfterFailedOwnerRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-owner-seeking-failed-takeover"
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "owner-seeking", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-20T00:00:01Z"),
            paths: paths)

        let remoteOwner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", hostName: "ipad", deviceName: "iPad Pro 13-inch (M5)"),
            connectedAt: "2026-05-20T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: remoteOwner, mode: .owner, paths: paths, attachedAt: "2026-05-20T00:00:00Z")

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.hasSurface = false
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, host: fakeHost,
            takeoverAction: { _ in TerminalControlResponse(ok: false, message: "Takeover denied.") }, detachClientAction: { _ in })

        controller.showEmbedded(focus: true)

        XCTAssertEqual(controller.attachmentMode, .viewer)
        XCTAssertTrue(controller.debugShowsTakeoverButton)
        XCTAssertTrue(controller.debugTakeoverEnabled)

        controller.requestOwnershipIfNeeded()
        XCTAssertTrue(controller.debugTakeoverPending)
        XCTAssertFalse(controller.debugShowsTakeoverButton)

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if !controller.debugTakeoverPending { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(controller.debugTakeoverPending)
        XCTAssertEqual(controller.attachmentMode, .viewer)
        XCTAssertTrue(controller.debugShowsTakeoverMessage)
        XCTAssertTrue(controller.debugShowsTakeoverButton)
        XCTAssertTrue(controller.debugTakeoverEnabled)
        XCTAssertEqual(controller.debugInputStatus, "Takeover denied.")
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
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
                command: "cat", createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
        controller.showEmbedded(focus: true)

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
                command: "cat", createdAt: "2026-05-19T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        controller.showEmbedded(focus: true)
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
                shell: "/bin/zsh", command: "false", createdAt: "2026-05-15T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pane-copy-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        controller.pasteboardOverrideForTesting = pasteboard

        XCTAssertTrue(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertFalse(controller.debugShowsHeader)
        XCTAssertFalse(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugShowsTakeoverMessage)
        XCTAssertTrue(normalizedRenderedOutput(controller.debugStateDump().renderedOutput).contains("command failed"))
        XCTAssertFalse(normalizedRenderedOutput(controller.debugStateDump().renderedOutput).contains("output log tail should not render"))
        XCTAssertEqual(normalizedRenderedOutput(controller.debugRenderedOutput), "command failed")
        pasteboard.clearContents()
        controller.selectAll(nil)
        controller.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "command failed")
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: final Ghostty render")
    }

    @MainActor func testGhosttyOwnerPaneHidesInlineControls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-4", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

    @MainActor func testGhosttyViewerHidesTakeoverWhenSessionIsNotRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-viewer-exited", backend: .ghosttyEmbedded, title: "viewer", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        let controller = TerminalSessionPaneViewController(
            sessionID: "session-viewer-exited", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })

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
                command: "cat", createdAt: "2026-06-22T12:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-starting-remote", backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .starting,
                updatedAt: "2026-06-22T12:00:00Z"), paths: paths)
        let capture = ClientCapture()
        let controller = makeGhosttyController(
            sessionID: "session-starting-remote", paths: paths, preferredAttachmentMode: .owner,
            attachClientAction: { _, mode in capture.attachedModes.append(mode) }, detachClientAction: { _ in })

        controller.showEmbedded(focus: true)

        XCTAssertTrue(capture.attachedModes.isEmpty)
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
                createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-script-exited", servicePID: 1, childPID: 22, state: .exited, updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let controller = TerminalSessionPaneViewController(
            sessionID: "session-script-exited", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            attachClientAction: persistenceBackedAttachAction(paths), detachClientAction: persistenceBackedDetachAction(paths))

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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-surface", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        try "owner output should stay on the live surface\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let controller = makeGhosttyController(sessionID: "session-owner-surface", paths: paths)
        let window = makeHostWindow(for: controller)
        controller.showEmbedded(focus: true)
        window.layoutIfNeeded()
        controller.debugForceRefresh()

        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertEqual(controller.debugRenderedOutput, "")
        XCTAssertGreaterThan(controller.debugTerminalContainerWidth, 0)
        XCTAssertGreaterThanOrEqual(controller.debugTerminalContainerWidth, controller.debugBodyWidth - 2)
        XCTAssertGreaterThanOrEqual(controller.debugTerminalContainerWidth, controller.view.frame.width - 2)
    }

    @MainActor func testDebugStateDumpPrefersVisibleSurfaceOverStaleSessionSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-visible-debug-dump", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-visible-debug-dump", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-29T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.sessionSnapshotTextValue = "stale session snapshot"
        host.debugVisibleSurfaceTextValue = "fresh visible surface"
        let controller = makeGhosttyController(sessionID: "session-visible-debug-dump", paths: paths, host: host)
        controller.showEmbedded(focus: true)
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
                command: "cat", createdAt: "2026-05-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-snapshot-debug-dump", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-29T00:00:01Z"), paths: paths)

        let snapshot = ghosttySnapshot(text: "OpenAI Codex")
        let host = FakeGhosttySessionHost()
        host.snapshotValue = snapshot
        host.debugVisibleSurfaceTextValue = "stale shell prompt"
        let controller = makeGhosttyController(sessionID: "session-snapshot-debug-dump", paths: paths, host: host)
        controller.showEmbedded(focus: true)
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
                shell: "/bin/zsh", command: "cat", createdAt: "2026-05-12T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-owner-first-responder", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-12T00:00:01Z"), paths: paths)

        let controller = makeGhosttyController(sessionID: "session-owner-first-responder", paths: paths)
        let window = makeHostWindow(for: controller)
        controller.showEmbedded(focus: true)

        XCTAssertEqual(controller.view.window, window)
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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

    @MainActor func testGhosttyOwnerCommandVPastesImageBeforeTextPaste() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = TerminalPasteboardImage(fileExtension: "png", imageData: try imageData(type: .png))

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-image-command-v", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-image-command-v", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        var pastedImages: [TerminalPasteboardImage] = []
        var textPasteCalls = 0
        let pastedImage = expectation(description: "image pasted")
        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        let controller = makeGhosttyController(
            sessionID: "session-image-command-v", paths: paths, host: host,
            pasteClipboardAction: {
                textPasteCalls += 1
                return true
            },
            pasteImageAction: { image in
                pastedImages.append(image)
                pastedImage.fulfill()
                return TerminalControlResponse(ok: true, message: "Pasted image path.")
            }, pasteboardImageReadAction: { .image(image) })

        controller.paste(nil)
        await fulfillment(of: [pastedImage], timeout: 1)

        XCTAssertEqual(pastedImages.count, 1)
        XCTAssertEqual(pastedImages.first?.fileExtension, "png")
        XCTAssertEqual(textPasteCalls, 0)
        XCTAssertFalse(host.pastedClipboard)
    }

    @MainActor func testGhosttyOwnerCommandKeyEquivalentsDispatchEditAndFindActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-command-edit", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-command-edit", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        let controller = makeGhosttyController(sessionID: "session-command-edit", paths: paths, host: host)
        controller.showEmbedded(focus: true)

        XCTAssertTrue(controller.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_V, characters: "v")))
        XCTAssertTrue(controller.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_C, characters: "c")))
        XCTAssertTrue(controller.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_A, characters: "a")))
        XCTAssertTrue(controller.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_F, characters: "f")))
        XCTAssertTrue(controller.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_E, characters: "e")))
        XCTAssertTrue(controller.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_G, characters: "g")))
        XCTAssertTrue(controller.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_G, characters: "G", modifiers: [.command, .shift])))

        XCTAssertEqual(
            host.recordedBindingActions,
            ["copy_to_clipboard", "select_all", "start_search", "search_selection", "navigate_search:next", "navigate_search:previous"])
        XCTAssertTrue(host.pastedClipboard)
    }

    @MainActor func testGhosttyOwnerControlVPastesImageAndConsumesTerminalKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = TerminalPasteboardImage(fileExtension: "png", imageData: try imageData(type: .png))

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-control-v-image", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-control-v-image", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        var pastedImages: [TerminalPasteboardImage] = []
        let pastedImage = expectation(description: "image pasted")
        let controller = makeGhosttyController(
            sessionID: "session-control-v-image", paths: paths, host: host,
            pasteImageAction: { image in
                pastedImages.append(image)
                pastedImage.fulfill()
                return TerminalControlResponse(ok: true, message: "Pasted image path.")
            }, pasteboardImageReadAction: { .image(image) })
        controller.showEmbedded(focus: true)
        let event = try keyEvent(keyCode: kVK_ANSI_V, characters: "\u{16}", modifiers: .control, charactersIgnoringModifiers: "v")

        XCTAssertTrue(controller.handleKeyEvent(event))
        await fulfillment(of: [pastedImage], timeout: 1)

        XCTAssertEqual(pastedImages.count, 1)
        XCTAssertTrue(host.handledKeySpecifiers.isEmpty)
    }

    @MainActor func testGhosttyOwnerControlVWithoutImageReachesTerminalInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-control-v-text", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-control-v-text", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        var pastedImages: [TerminalPasteboardImage] = []
        let controller = makeGhosttyController(
            sessionID: "session-control-v-text", paths: paths, host: host,
            pasteImageAction: { image in
                pastedImages.append(image)
                return TerminalControlResponse(ok: true, message: "Pasted image path.")
            }, pasteboardImageReadAction: { .noImage })
        controller.showEmbedded(focus: true)
        let event = try keyEvent(keyCode: kVK_ANSI_V, characters: "\u{16}", modifiers: .control, charactersIgnoringModifiers: "v")

        XCTAssertTrue(controller.handleKeyEvent(event))

        XCTAssertTrue(pastedImages.isEmpty)
        XCTAssertEqual(host.handledKeySpecifiers, ["ctrl+v"])
    }

    @MainActor func testGhosttyOwnerControlCRemainsTerminalInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-control-c", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-control-c", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        let controller = makeGhosttyController(sessionID: "session-control-c", paths: paths, host: host)
        controller.showEmbedded(focus: true)
        let event = try keyEvent(keyCode: kVK_ANSI_C, characters: "\u{3}", modifiers: .control, charactersIgnoringModifiers: "c")

        XCTAssertFalse(controller.handleCommandKeyEquivalent(event))
        XCTAssertTrue(controller.handleKeyEvent(event))

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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-search-esc", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        host.searchDebugState = .init(isVisible: true, query: "needle", total: nil, selected: nil)
        let controller = makeGhosttyController(sessionID: "session-search-esc", paths: paths, host: host)
        controller.showEmbedded(focus: true)
        let event = try keyEvent(keyCode: kVK_Escape, characters: "\u{1b}", modifiers: [])

        XCTAssertTrue(controller.handleKeyEvent(event))

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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-search-field-typing", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        host.searchDebugState = .init(isVisible: true, query: "", total: nil, selected: nil)
        let controller = makeGhosttyController(sessionID: "session-search-field-typing", paths: paths, host: host)
        let window = makeHostWindow(for: controller)
        controller.showEmbedded(focus: true)
        let fieldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        fieldEditor.isFieldEditor = true
        window.contentView?.addSubview(fieldEditor)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        let typeEvent = try keyEvent(keyCode: kVK_ANSI_Z, characters: "z", modifiers: [])
        XCTAssertFalse(controller.handleKeyEvent(typeEvent))

        XCTAssertEqual(host.handleKeyEventCallCount, 0)
        XCTAssertTrue(host.recordedBindingActions.isEmpty)
        XCTAssertTrue(host.debugSearchState.isVisible)

        let escapeEvent = try keyEvent(keyCode: kVK_Escape, characters: "\u{1b}", modifiers: [])
        XCTAssertTrue(controller.handleKeyEvent(escapeEvent))

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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-search-esc-exited", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "owner")
        host.searchDebugState = .init(isVisible: true, query: "needle", total: nil, selected: nil)
        let controller = makeGhosttyController(sessionID: "session-search-esc-exited", paths: paths, host: host)
        controller.showEmbedded(focus: true)

        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionPaneViewController.hideFind(_:)))))
        XCTAssertFalse(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionPaneViewController.find(_:)))))

        let event = try keyEvent(keyCode: kVK_Escape, characters: "\u{1b}", modifiers: [])
        XCTAssertTrue(controller.handleKeyEvent(event))

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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: viewerPaths)
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
        XCTAssertFalse(viewer.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionPaneViewController.find(_:)))))
        XCTAssertFalse(viewer.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionPaneViewController.useSelectionForFind(_:)))))

        let exitedPaths = TerminalSessionPaths(rootDirectory: root.appendingPathComponent("exited").path)
        try FileManager.default.createDirectory(atPath: exitedPaths.rootDirectory, withIntermediateDirectories: true)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-exited-disabled", backend: .ghosttyEmbedded, title: "exited", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: exitedPaths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-exited-disabled", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: exitedPaths)
        let exitedHost = FakeGhosttySessionHost()
        exitedHost.snapshotValue = ghosttySnapshot(text: "owner")
        let exited = makeGhosttyController(sessionID: "session-exited-disabled", paths: exitedPaths, host: exitedHost)
        exited.showEmbedded(focus: true)

        XCTAssertTrue(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.copy(_:)))))
        XCTAssertTrue(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.selectAll(_:)))))
        XCTAssertFalse(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.paste(_:)))))
        XCTAssertFalse(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionPaneViewController.find(_:)))))
        XCTAssertFalse(exited.validateUserInterfaceItem(ValidatedItem(action: #selector(TerminalSessionPaneViewController.findNext(_:)))))

        XCTAssertTrue(exited.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_C, characters: "c")))
        XCTAssertTrue(exited.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_A, characters: "a")))
        XCTAssertFalse(exited.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_V, characters: "v")))
        XCTAssertFalse(exited.handleCommandKeyEquivalent(try keyEvent(keyCode: kVK_ANSI_F, characters: "f")))
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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

    @MainActor func testGhosttyOwnerResyncsFocusAcrossAppActivationTransitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-focus", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running, updatedAt: "2026-05-09T00:00:01Z"
            ), paths: paths)

        var focusWindowCalls = 0
        var focusedStates: [Bool] = []
        let controller = makeGhosttyController(
            sessionID: "session-focus", paths: paths, ownerWindowFocusAction: { _ in focusWindowCalls += 1 },
            ownerSurfaceFocusAction: { focused in focusedStates.append(focused) })

        controller.showEmbedded(focus: true)
        XCTAssertGreaterThan(focusWindowCalls, 0)

        // App activation transitions resync the owner surface focus without asking the
        // host to bring any window forward.
        let focusWindowCallsBeforeAppTransitions = focusWindowCalls
        let focusedStateCountBeforeAppTransitions = focusedStates.count
        controller.debugSimulateApplicationDidBecomeActive()
        controller.debugSimulateApplicationDidResignActive()

        XCTAssertEqual(focusWindowCalls, focusWindowCallsBeforeAppTransitions)
        XCTAssertGreaterThanOrEqual(focusedStates.count, focusedStateCountBeforeAppTransitions + 2)
        XCTAssertEqual(focusedStates.last, false)
    }

    @MainActor func testFocusEmbeddedTerminalInputReassertsOwnerSurfaceFocus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-focus-window", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-focus-window", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        var focusWindowCalls = 0
        var focusedStates: [Bool] = []
        let controller = makeGhosttyController(
            sessionID: "session-focus-window", paths: paths, ownerWindowFocusAction: { _ in focusWindowCalls += 1 },
            ownerSurfaceFocusAction: { focused in focusedStates.append(focused) })

        let initialWindowFocusCalls = focusWindowCalls
        let initialFocusedStateCount = focusedStates.count
        controller.focusEmbeddedTerminalInput()

        XCTAssertGreaterThan(focusWindowCalls, initialWindowFocusCalls)
        XCTAssertGreaterThan(focusedStates.count, initialFocusedStateCount)
    }

    @MainActor func testFocusEmbeddedTerminalInputDoesNotReattachExistingOwnerSurface() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-focus-fast-path", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-focus-fast-path", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "owner")
        let controller = makeGhosttyController(sessionID: "session-focus-fast-path", paths: paths, host: fakeHost)

        controller.showEmbedded(focus: true)
        let attachCountAfterShow = fakeHost.attachCount

        controller.focusEmbeddedTerminalInput()

        XCTAssertEqual(fakeHost.attachCount, attachCountAfterShow)
        XCTAssertGreaterThan(fakeHost.focusWindowCount, 0)
    }

    @MainActor func testShowEmbeddedRefreshesStaleViewerTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-focus-title-refresh", backend: .ghosttyEmbedded, title: "frontend", workingDirectory: "/tmp/work",
                shell: "/bin/zsh", command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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

        ownerController.showEmbedded(focus: true)
        viewerController.showEmbedded(focus: true)

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-focus-title-refresh", newOwnerClientID: viewer.id, paths: paths, transferredAt: "2026-05-09T00:00:02Z")
        ownerController.debugForceRefresh()
        XCTAssertEqual(ownerController.displayTitle, "ghostty")

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-focus-title-refresh", newOwnerClientID: owner.id, paths: paths, transferredAt: "2026-05-09T00:00:03Z")
        ownerController.showEmbedded(focus: true)

        XCTAssertEqual(ownerController.displayTitle, "ghostty")
    }

    @MainActor func testGhosttyOwnerMetadataRefreshCanSkipLiveAttachUntilShow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-show-focus", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-12T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-show-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-12T00:00:01Z"), paths: paths)

        var focusVisibilityStates: [Bool] = []
        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot()
        let controller = makeGhosttyController(
            sessionID: "session-show-focus", paths: paths, host: host, performInitialRefresh: false,
            ownerWindowFocusAction: { window in focusVisibilityStates.append(window?.isVisible == true) })

        controller.debugForceRefreshSkippingOwnerAttach()

        // A metadata-only refresh must not mount the live owner surface and must never
        // ask the host to focus a visible window before the pane is shown.
        XCTAssertEqual(host.attachCount, 0)
        XCTAssertFalse(focusVisibilityStates.contains(true))
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror")

        controller.showEmbedded(focus: true)

        XCTAssertGreaterThan(host.attachCount, 0)
        XCTAssertEqual(host.attachedModes.first, .owner)
    }

    @MainActor func testGhosttyOwnerScrollRequestsSurfaceRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-scroll-refresh", backend: .ghosttyEmbedded, title: "owner", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "printf 'one\\ntwo\\nthree\\n'", createdAt: "2026-05-12T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-scroll-refresh", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-12T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot()
        let controller = makeGhosttyController(sessionID: "session-scroll-refresh", paths: paths, host: fakeHost)
        controller.showEmbedded(focus: true)
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
                createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-fallback", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let controller = TerminalSessionPaneViewController(
            sessionID: "session-fallback", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            attachClientAction: persistenceBackedAttachAction(paths), detachClientAction: persistenceBackedDetachAction(paths))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("owner-status-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        controller.pasteboardOverrideForTesting = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("paste-from-test", forType: .string)

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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-fallback-exited", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let host = FakeGhosttySessionHost()
        host.hasSurface = false
        host.snapshotValue = ghosttySnapshot(text: "final transcript")
        host.snapshotTextValue = "final transcript"
        let controller = makeGhosttyController(sessionID: "session-fallback-exited", paths: paths, host: host)
        controller.showEmbedded(focus: true)

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
                createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-transcript-config", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)

        let controller = TerminalSessionPaneViewController(
            sessionID: "session-transcript-config", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            attachClientAction: persistenceBackedAttachAction(paths), detachClientAction: persistenceBackedDetachAction(paths))

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
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-viewer-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 4321, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let fakeHost = FakeGhosttySessionHost()
        fakeHost.snapshotValue = ghosttySnapshot(text: "viewer")
        let controller = makeGhosttyController(
            sessionID: "session-viewer-focus", paths: paths, preferredAttachmentMode: .viewer, host: fakeHost, attachClientAction: { _, _ in },
            detachClientAction: { _ in })
        let window = makeHostWindow(for: controller)
        controller.showEmbedded(focus: true)
        window.layoutIfNeeded()

        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertTrue(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugFirstResponderTargetsOutputView)
        XCTAssertFalse(controller.debugFirstResponderTargetsInputField)
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
        XCTAssertGreaterThan(controller.debugTakeoverContainerWidth, 120)
    }

    @MainActor func testCloseEmbeddedInvokesCleanupCallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cleanup = expectation(description: "cleanup callback")
        var closedSessionID: String?
        var closedClientID: String?
        var closedForTermination: Bool?
        let controller = TerminalSessionPaneViewController(
            sessionID: "session-5", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)),
            attachClientAction: persistenceBackedAttachAction(.init(rootDirectory: root.path)),
            detachClientAction: persistenceBackedDetachAction(.init(rootDirectory: root.path)),
            onWindowClose: { sessionID, clientID, isTerminating in
                closedSessionID = sessionID
                closedClientID = clientID
                closedForTermination = isTerminating
                cleanup.fulfill()
            })

        let expectedClientID = controller.clientID
        controller.closeEmbedded()

        wait(for: [cleanup], timeout: 1)
        XCTAssertEqual(closedSessionID, "session-5")
        XCTAssertEqual(closedClientID, expectedClientID)
        XCTAssertEqual(closedForTermination, false)
    }

    @MainActor func testCloseEmbeddedCallbackMarksSessionTerminationClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var closedForTermination: Bool?
        let controller = TerminalSessionPaneViewController(
            sessionID: "session-termination-close", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)),
            attachClientAction: persistenceBackedAttachAction(.init(rootDirectory: root.path)),
            detachClientAction: persistenceBackedDetachAction(.init(rootDirectory: root.path)),
            onWindowClose: { _, _, isTerminating in closedForTermination = isTerminating })

        controller.closeEmbedded(sessionIsTerminating: true)
        if closedForTermination == nil { controller.closeEmbedded() }

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
                command: "npm run dev", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
        XCTAssertEqual(ownerController.displayTitle, "frontend")
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertFalse(ownerController.debugShowsTakeoverButton)
        XCTAssertEqual(viewerController.displayTitle, "frontend")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(viewerController.debugShowsTakeoverButton)
        XCTAssertFalse(viewerController.debugShowsTerminalSurface)

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-6", newOwnerClientID: viewer.id, paths: paths, transferredAt: "2026-05-09T00:00:02Z")

        ownerController.debugForceRefresh()
        viewerController.debugForceRefresh()

        XCTAssertEqual(ownerController.displayTitle, "frontend")
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: takeover status")
        XCTAssertTrue(ownerController.debugShowsTakeoverButton)
        XCTAssertFalse(ownerController.debugShowsTerminalSurface)
        XCTAssertEqual(viewerController.displayTitle, "frontend")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertFalse(viewerController.debugShowsTakeoverButton)

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-6", newOwnerClientID: owner.id, paths: paths, transferredAt: "2026-05-09T00:00:03Z")

        ownerController.debugForceRefresh()
        viewerController.debugForceRefresh()

        XCTAssertEqual(ownerController.displayTitle, "frontend")
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: ghostty-mirror")
        XCTAssertFalse(ownerController.debugShowsTakeoverButton)
        XCTAssertEqual(viewerController.displayTitle, "frontend")
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
                command: "uv run api", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                shell: "/bin/zsh", command: "uv run api", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
        XCTAssertEqual(controller.displayTitle, "backend")
        XCTAssertEqual(controller.representedWorkingDirectoryURL?.path, initialWorkingDirectory.path)
        XCTAssertTrue(controller.debugSummary.contains("work"))

        fakeHost.effectiveTitle = "live api"
        fakeHost.effectiveWorkingDirectory = updatedWorkingDirectory.path
        controller.debugSimulateSessionMetadataDidChange()

        XCTAssertEqual(controller.displayTitle, "live api")
        XCTAssertEqual(controller.representedWorkingDirectoryURL?.path, updatedWorkingDirectory.path)
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
                command: "uv run api", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-runtime", backend: .ghosttyEmbedded, servicePID: 1, childPID: 1111, state: .running,
                updatedAt: "2026-05-09T00:00:01Z"), paths: paths)

        let controller = TerminalSessionPaneViewController(
            sessionID: "session-runtime", paths: paths, stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: paths),
            attachClientAction: persistenceBackedAttachAction(paths), detachClientAction: persistenceBackedDetachAction(paths))
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
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                command: "uv run api", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
                command: "uv run api", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
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
        firstController.showEmbedded(focus: true)
        let firstClientID = firstController.clientID

        firstController.closeEmbedded()

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
        reopenedController.showEmbedded(focus: true)
        reopenedController.debugForceRefresh()

        let snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
        let activeOwners = snapshot.attachments.filter { $0.mode == .owner && $0.detachedAt == nil }

        XCTAssertEqual(activeOwners.count, 1)
        XCTAssertEqual(activeOwners.first?.clientID, reopenedController.clientID)
        XCTAssertNotEqual(reopenedController.clientID, firstClientID)
        XCTAssertTrue(snapshot.attachments.contains { $0.clientID == firstClientID && $0.detachedAt != nil })
        XCTAssertEqual(reopenedController.displayTitle, "backend")
        XCTAssertEqual(reopenedController.debugRendererSummary, "Renderer: ghostty-mirror")
    }

    // MARK: - Ended-session banner

    /// Seeds a ghostty-embedded session whose final render is available, in the given runtime state.
    @MainActor private func makeBannerController(sessionID: String, state: TerminalSessionState, root: URL) throws
        -> TerminalSessionPaneViewController
    {
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try FileManager.default.createDirectory(atPath: paths.rootDirectory, withIntermediateDirectories: true)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "banner", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: state, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)
        let host = FakeGhosttySessionHost()
        host.snapshotValue = ghosttySnapshot(text: "final output")
        let controller = makeGhosttyController(sessionID: sessionID, paths: paths, host: host)
        controller.showEmbedded(focus: true)
        return controller
    }

    /// A pane whose session exited keeps rendering the frozen final Ghostty frame, which is
    /// indistinguishable from a live terminal. The banner is what tells the user it is dead.
    @MainActor func testExitedSessionShowsReadOnlyBanner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-exited", state: .exited, root: root)

        XCTAssertTrue(controller.debugBannerVisible)
        XCTAssertEqual(controller.debugBannerMessage, "Session ended. This pane is read-only.")
    }

    /// A session that died on its own reads as a failure, not as a clean exit the user asked for.
    @MainActor func testFailedSessionShowsFailedBanner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-failed", state: .failed, root: root)

        XCTAssertTrue(controller.debugBannerVisible)
        XCTAssertEqual(controller.debugBannerMessage, "Session failed. The process stopped unexpectedly.")
    }

    @MainActor func testRunningSessionShowsNoBanner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-running", state: .running, root: root)

        XCTAssertFalse(controller.debugBannerVisible)
        XCTAssertFalse(controller.debugBannerHasPersistentNotice)
    }

    /// The case the feature exists for: the user is looking at a live pane when the shell exits
    /// under them. The banner has to appear on that transition, not only on a pane opened afterward.
    @MainActor func testBannerAppearsWhenRunningSessionExitsUnderOpenPane() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-transition", state: .running, root: root)
        XCTAssertFalse(controller.debugBannerVisible)

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-banner-transition", backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .exited,
                updatedAt: "2026-05-09T00:00:02Z"), paths: paths)
        controller.debugSimulateRuntimeStateDidChange()

        XCTAssertTrue(controller.debugBannerVisible)
        XCTAssertEqual(controller.debugBannerMessage, "Session ended. This pane is read-only.")
    }

    /// A restarted session must not keep claiming to be dead.
    @MainActor func testBannerClearsWhenSessionBecomesRunningAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-revive", state: .exited, root: root)
        XCTAssertTrue(controller.debugBannerVisible)

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "session-banner-revive", backend: .ghosttyEmbedded, servicePID: 1, childPID: 22, state: .running,
                updatedAt: "2026-05-09T00:00:03Z"), paths: paths)
        controller.debugSimulateRuntimeStateDidChange()

        XCTAssertFalse(controller.debugBannerVisible)
    }

    // MARK: - Disconnected-device banner

    /// The case this exists for: the device hosting a running session goes away. The pane keeps the
    /// device's last frame — pruning is gated on an authoritative overview — so without the notice the
    /// user is looking at a normal-looking terminal that silently does nothing.
    @MainActor func testRunningSessionOnAnUnreachableDeviceShowsTheDisconnectedNotice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-offline", state: .running, root: root)
        XCTAssertFalse(controller.debugBannerVisible)

        let provider = try XCTUnwrap(controller.stateProvider as? PersistenceBackedTerminalSessionStateProvider)
        provider.isStateStreamDisconnected = true
        controller.debugSimulateStateStreamConnectionDidChange()

        XCTAssertTrue(controller.debugBannerVisible)
        XCTAssertEqual(controller.debugBannerMessage, TerminalPaneBannerNotice.disconnected.message)
    }

    /// The outage ends and the pane goes back to saying nothing: an outage that self-heals in seconds
    /// must not leave a notice behind claiming otherwise.
    @MainActor func testDisconnectedNoticeClearsWhenTheDeviceComesBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-recovered", state: .running, root: root)
        let provider = try XCTUnwrap(controller.stateProvider as? PersistenceBackedTerminalSessionStateProvider)
        provider.isStateStreamDisconnected = true
        controller.debugSimulateStateStreamConnectionDidChange()
        XCTAssertTrue(controller.debugBannerVisible)

        provider.isStateStreamDisconnected = false
        controller.debugSimulateStateStreamConnectionDidChange()

        XCTAssertFalse(controller.debugBannerVisible)
        XCTAssertFalse(controller.debugBannerHasPersistentNotice)
    }

    /// A session that ended keeps saying so even while the link to its device is down: the process is
    /// gone whatever the connection does, and the drop is the daemon's expected refusal to stream an
    /// ended session rather than an outage worth reporting.
    @MainActor func testEndedSessionKeepsItsNoticeWhileTheDeviceIsUnreachable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-ended-offline", state: .exited, root: root)

        let provider = try XCTUnwrap(controller.stateProvider as? PersistenceBackedTerminalSessionStateProvider)
        provider.isStateStreamDisconnected = true
        controller.debugSimulateStateStreamConnectionDidChange()

        XCTAssertEqual(controller.debugBannerMessage, TerminalPaneBannerNotice.sessionEnded.message)
    }

    /// Typing into a pane whose device is unreachable reports the reason instead of the keystrokes
    /// vanishing without a word.
    @MainActor func testTypingIntoADisconnectedSessionReportsTheDroppedConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-typing-offline", state: .running, root: root)
        let provider = try XCTUnwrap(controller.stateProvider as? PersistenceBackedTerminalSessionStateProvider)
        provider.isStateStreamDisconnected = true
        controller.debugSimulateStateStreamConnectionDidChange()

        _ = controller.handleKeyEvent(try keyEvent(keyCode: kVK_ANSI_A, characters: "a", modifiers: []))

        XCTAssertEqual(controller.debugInputStatus, TerminalPaneBannerNotice.disconnected.message)
    }

    /// The reason left on the input status row is retired when the link returns. The row is what the
    /// debug dump reports the pane's input state from, so a stale "connection lost" there describes a
    /// pane that is working again.
    @MainActor func testDisconnectedInputStatusIsRetiredWhenTheLinkReturns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-input-status-recovered", state: .running, root: root)
        let provider = try XCTUnwrap(controller.stateProvider as? PersistenceBackedTerminalSessionStateProvider)
        provider.isStateStreamDisconnected = true
        controller.debugSimulateStateStreamConnectionDidChange()
        _ = controller.handleKeyEvent(try keyEvent(keyCode: kVK_ANSI_A, characters: "a", modifiers: []))
        XCTAssertEqual(controller.debugInputStatus, TerminalPaneBannerNotice.disconnected.message)

        provider.isStateStreamDisconnected = false
        controller.debugSimulateStateStreamConnectionDidChange()

        XCTAssertEqual(controller.debugInputStatus, "")
        XCTAssertFalse(controller.debugShowsInputStatus)
    }

    /// The row holds one message at a time, so the reconnect clears only its own: a status the user is
    /// looking at for an unrelated reason says nothing about the connection and must survive.
    @MainActor func testReconnectingLeavesAnUnrelatedInputStatusAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-input-status-unrelated", state: .running, root: root)
        let provider = try XCTUnwrap(controller.stateProvider as? PersistenceBackedTerminalSessionStateProvider)
        provider.isStateStreamDisconnected = true
        controller.debugSimulateStateStreamConnectionDidChange()
        controller.updateInputStatus(message: "Take over ownership before sending terminal input.", isError: true)

        provider.isStateStreamDisconnected = false
        controller.debugSimulateStateStreamConnectionDidChange()

        XCTAssertEqual(controller.debugInputStatus, "Take over ownership before sending terminal input.")
    }

    /// Precedence between the two facts a pane's persistent notice reports, as a pure rule.
    @MainActor func testPersistentNoticeSelection() {
        XCTAssertNil(TerminalPaneBannerNotice.resolve(runtimeState: .running, isStateStreamDisconnected: false))
        XCTAssertNil(TerminalPaneBannerNotice.resolve(runtimeState: .starting, isStateStreamDisconnected: false))
        XCTAssertNil(TerminalPaneBannerNotice.resolve(runtimeState: nil, isStateStreamDisconnected: false))
        XCTAssertEqual(TerminalPaneBannerNotice.resolve(runtimeState: .running, isStateStreamDisconnected: true), .disconnected)
        // An unreachable device is exactly the case where the session's state is unknown.
        XCTAssertEqual(TerminalPaneBannerNotice.resolve(runtimeState: nil, isStateStreamDisconnected: true), .disconnected)
        // A stopped session wins: the process is gone whatever the link is doing.
        XCTAssertEqual(TerminalPaneBannerNotice.resolve(runtimeState: .exited, isStateStreamDisconnected: true), .sessionEnded)
        XCTAssertEqual(TerminalPaneBannerNotice.resolve(runtimeState: .failed, isStateStreamDisconnected: true), .sessionFailed)
    }

    /// Typing into a dead pane stays unconsumed — the pulse is emphasis only and must not start
    /// swallowing keys that previously fell through.
    @MainActor func testTypingIntoEndedSessionIsNotConsumed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try makeBannerController(sessionID: "session-banner-typing", state: .exited, root: root)

        XCTAssertFalse(controller.handleKeyEvent(try keyEvent(keyCode: kVK_ANSI_A, characters: "a", modifiers: [])))
        XCTAssertTrue(controller.debugBannerVisible)
    }

    /// The pane's last reference can be dropped by a background task (e.g. a finished detached
    /// takeover task holding the final reference), so its deinit must not deallocate its AppKit
    /// members off the main thread. The box makes the off-main last release deterministic; draining
    /// the main queue afterward proves the shipped `mainThreadReleaseBag` release actually runs.
    @MainActor func testControllerLastReleaseOffMainDoesNotTrap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        final class Box: @unchecked Sendable { var controller: TerminalSessionPaneViewController? }
        let box = Box()
        box.controller = TerminalSessionPaneViewController(
            sessionID: "session-1", paths: .init(rootDirectory: root.path),
            stateProvider: PersistenceBackedTerminalSessionStateProvider(paths: .init(rootDirectory: root.path)),
            attachClientAction: persistenceBackedAttachAction(.init(rootDirectory: root.path)),
            detachClientAction: persistenceBackedDetachAction(.init(rootDirectory: root.path)))

        await Task.detached { box.controller = nil }.value
        await Task { @MainActor in }.value
    }

    /// Thread-safe box `DeinitTrackingGhosttySessionHost.deinit` reports into, since deinit for a
    /// `@MainActor` protocol conformer still runs on whatever thread drops the object's last reference.
    private final class HostDeinitThreadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _wasMainThread: Bool?
        var wasMainThread: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return _wasMainThread
        }
        func record(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            _wasMainThread = value
        }
    }

    /// Minimal `TerminalGhosttySessionHosting` fake whose only job is to report which thread tore it
    /// down. Its `attach` is a no-op — unlike `FakeGhosttySessionHost` it never adds anything to
    /// `terminalContainer` — so this test proves the controller's *stored reference* to the host
    /// (`activeGhosttySessionHost`/`clientGhosttySessionHost`) is released on the main thread on its
    /// own merit, independent of whatever the view hierarchy happens to retain.
    @MainActor private final class DeinitTrackingGhosttySessionHost: TerminalGhosttySessionHosting {
        var activeOwnerClientIDValue: String?
        private let recorder: HostDeinitThreadRecorder
        init(recorder: HostDeinitThreadRecorder) { self.recorder = recorder }
        deinit { recorder.record(Thread.isMainThread) }
        func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
            if mode == .owner { activeOwnerClientIDValue = client.id }
        }
        func releaseRendererSurface() {}
        func setFocused(_ focused: Bool, for clientID: String) {}
        func focusWindow(_ window: NSWindow?) {}
        @discardableResult func handleKeyEvent(_ event: NSEvent, for clientID: String) -> Bool { false }
        @discardableResult func synchronizeSurfaceGeometry() -> Bool { true }
        func activeOwnerClientID() -> String? { activeOwnerClientIDValue }
        var effectiveTitle: String { "ghostty" }
        var effectiveWorkingDirectory: String { "/tmp/work" }
        func hasRenderableSurface() -> Bool { true }
        func requestSurfaceRefresh() {}
        func prepareRenderStateExport() {}
        func snapshot() -> GhosttyTerminalSnapshot? { nil }
        func snapshotText() -> String? { nil }
        func sessionSnapshot() -> GhosttyTerminalSnapshot? { nil }
        func sessionSnapshotText() -> String? { nil }
        func copySelectionToPasteboard() -> Bool { false }
        func pasteClipboardContents() -> Bool { false }
        @discardableResult func sendTextAsPaste(_ text: String) -> Bool { false }
        @discardableResult func performBindingAction(_ action: String) -> Bool { false }
        @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)
            -> Bool { false }
        @discardableResult func clearScreenAndScrollback() -> Bool { false }
        var debugSearchState: GhosttyTerminalSearchDebugState {
            GhosttyTerminalSearchDebugState(isVisible: false, query: "", total: nil, selected: nil)
        }
        var debugSurfaceRefreshRequestCount: Int { 0 }
        func debugVisibleSurfaceText() -> String? { nil }
    }

    /// Builds an owner-mode pane whose Ghostty host resolution actually runs — mirroring
    /// `testRuntimeNotificationDuringOwnerHostCreationDoesNotReenterAttachResolution`'s persisted
    /// launch/runtime state plus an owner attachment record, then `debugForceRefresh()` to drive
    /// `ensureGhosttyHostAttached` → `switchGhosttySessionHostIfNeeded`, the only place that stores the
    /// host. `host` is local to this helper so the sole surviving strong references once it returns are
    /// the controller's own (`activeGhosttySessionHost`, `clientGhosttySessionHost`, and the new
    /// `activeGhosttySessionHostForMainThreadRelease` release-bag entry) — nothing in the test body
    /// itself keeps the host alive.
    @MainActor private func makeOwnerControllerWithAttachedTrackedHost(
        sessionID: String, paths: TerminalSessionPaths, recorder: HostDeinitThreadRecorder
    ) throws -> TerminalSessionPaneViewController {
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "host-release", workingDirectory: "/tmp/host-release", shell: "/bin/zsh",
                command: nil, createdAt: "2026-07-23T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-07-23T00:00:01Z"),
            paths: paths)
        let host = DeinitTrackingGhosttySessionHost(recorder: recorder)
        let controller = makeGhosttyController(
            sessionID: sessionID, paths: paths, preferredAttachmentMode: .owner, performInitialRefresh: false,
            sessionHostProvider: { _, _ in host })
        let owner = TerminalClient(
            id: controller.clientID, kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-07-23T00:00:00Z")
        try TerminalSessionPersistence.attachClient(sessionID: sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-07-23T00:00:00Z")
        controller.debugForceRefresh()
        return controller
    }

    /// `switchGhosttySessionHostIfNeeded` resolves a renderer host whose `GhosttyMirrorTerminalView`
    /// is not always inside `view`'s hierarchy (a viewer pane never attaches it, and
    /// `releaseGhosttySurfaceIfNeeded`/this same switch strip `terminalContainer`'s subviews). So the
    /// view-root retain `mainThreadReleaseBag` alone cannot guarantee the host tears down on the main
    /// thread — this proves the controller's dedicated host retain covers it: dropping the controller's
    /// last reference from a detached task must still deallocate the tracked host on the main thread.
    @MainActor func testControllerLastReleaseOffMainReleasesActiveSessionHostOnMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        let recorder = HostDeinitThreadRecorder()
        final class Box: @unchecked Sendable { var controller: TerminalSessionPaneViewController? }
        let box = Box()
        box.controller = try makeOwnerControllerWithAttachedTrackedHost(sessionID: "session-host-release", paths: paths, recorder: recorder)

        await Task.detached { box.controller = nil }.value
        await Task { @MainActor in }.value

        XCTAssertEqual(recorder.wasMainThread, true)
    }
}

/// Exercises `TerminalPaneBanner`'s two state layers. The pane's persistent notice and the link
/// coordinator's transient banners share one instance, so precedence between them is a contract
/// worth pinning: a transient banner wins while it is up, and dismissing it restores the persistent
/// notice instead of leaving the pane looking interactive again.
final class TerminalPaneBannerTests: XCTestCase {
    @MainActor private func makeBanner() -> (TerminalPaneBanner, NSView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        return (TerminalPaneBanner(hostView: host), host)
    }

    /// A banner's last reference can be dropped by a background task (any async caller that
    /// captured its owning pane controller), so deinit must not assert main-actor isolation.
    /// `MainActor.assumeIsolated` in deinit trapped exactly here — a CI-only SIGTRAP, because the
    /// off-main last release needs a slow-scheduled background holder to lose the race. The box
    /// makes that ordering deterministic: the detached task provably performs the final release.
    @MainActor func testLastReleaseOffMainDoesNotTrap() async {
        final class Box: @unchecked Sendable { var banner: TerminalPaneBanner? }
        let box = Box()
        box.banner = TerminalPaneBanner(hostView: NSView())
        await Task.detached { box.banner = nil }.value
    }

    @MainActor func testPersistentNoticeShowsUntilCleared() {
        let (banner, _) = makeBanner()
        XCTAssertFalse(banner.debugIsVisible)

        banner.showPersistent(.sessionEnded)
        XCTAssertTrue(banner.debugIsVisible)
        XCTAssertEqual(banner.debugMessage, TerminalPaneBannerNotice.sessionEnded.message)

        banner.clearPersistent()
        XCTAssertFalse(banner.debugIsVisible)
    }

    @MainActor func testTransientBannerOverridesPersistentNoticeAndRestoresItOnDismiss() {
        let (banner, _) = makeBanner()
        banner.showPersistent(.sessionEnded)

        banner.showProgress(message: "Fetching link…") {}
        XCTAssertEqual(banner.debugMessage, "Fetching link…")

        banner.dismiss()
        XCTAssertTrue(banner.debugIsVisible)
        XCTAssertEqual(banner.debugMessage, TerminalPaneBannerNotice.sessionEnded.message)
    }

    @MainActor func testDismissHidesBannerWhenNoPersistentNoticeIsSet() {
        let (banner, _) = makeBanner()
        banner.showNotice("Heads up.")
        XCTAssertTrue(banner.debugIsVisible)

        banner.dismiss()
        XCTAssertFalse(banner.debugIsVisible)
    }

    /// Clearing the pane's notice while a link fetch is on screen must not yank the transient
    /// banner out from under it.
    @MainActor func testClearingPersistentNoticeLeavesActiveTransientBannerUp() {
        let (banner, _) = makeBanner()
        banner.showPersistent(.sessionEnded)
        banner.showProgress(message: "Fetching link…") {}

        banner.clearPersistent()
        XCTAssertTrue(banner.debugIsVisible)
        XCTAssertEqual(banner.debugMessage, "Fetching link…")

        banner.dismiss()
        XCTAssertFalse(banner.debugIsVisible)
    }
}
