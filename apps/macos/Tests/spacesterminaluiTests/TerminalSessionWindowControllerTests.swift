import Carbon
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty
@testable import spacesterminalui

final class TerminalSessionWindowControllerTests: XCTestCase {
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
        @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
            debugSurfaceRefreshRequestCount += 1
            return true
        }
        func debugVisibleSurfaceText() -> String? { debugVisibleSurfaceTextValue ?? snapshotTextValue }
    }

    private final class ClientCapture: @unchecked Sendable {
        var attachedClientID: String?
        var detachedClientID: String?
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

    @MainActor private func makeGhosttyController(
        sessionID: String, paths: TerminalSessionPaths, preferredAttachmentMode: TerminalAttachmentMode = .owner, host: FakeGhosttySessionHost? = nil,
        performInitialRefresh: Bool = true, attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil, detachClientAction: (@Sendable (String) throws -> Void)? = nil,
        copySelectionAction: (@MainActor () -> Bool)? = nil, detachClientSynchronouslyOnClose: Bool = true,
        pasteClipboardAction: (@MainActor () -> Bool)? = nil, ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil,
        ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil, onWindowClose: (@MainActor (String, String) -> Void)? = nil,
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

        try await Task.sleep(for: .milliseconds(250))

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
        XCTAssertEqual(normalizedRenderedOutput(controller.debugRenderedOutput), "Preparing the live terminal renderer…")
        XCTAssertFalse(controller.debugRenderedOutput.contains("echo hello"))
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: preparing owner surface")
    }

    @MainActor func testGhosttyOwnerShowsSnapshotTextWhenSurfaceIsUnavailable() throws {
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
        XCTAssertEqual(normalizedRenderedOutput(controller.debugRenderedOutput), "owner snapshot")
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: ghostty-mirror text debug")
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
            attachClientAction: { client, requestedMode in
                XCTAssertEqual(requestedMode, .owner)
                try TerminalSessionPersistence.attachClient(
                    sessionID: "session-owner-seeking", client: client, mode: .viewer, paths: paths, attachedAt: "2026-05-20T00:00:01Z")
            },
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

    @MainActor func testGhosttyViewerHidesPassiveRenderAfterSessionExit() throws {
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
        try "command failed\nexit 1\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
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
        fakeHost.snapshotTextValue = "command failed\nexit 1"
        let controller = makeGhosttyController(
            sessionID: "session-viewer-final-output", paths: paths, preferredAttachmentMode: .viewer, host: fakeHost, attachClientAction: { _, _ in },
            detachClientAction: { _ in })

        XCTAssertFalse(controller.debugShowsTerminalSurface)
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertFalse(controller.debugShowsHeader)
        XCTAssertFalse(controller.debugShowsTakeoverButton)
        XCTAssertTrue(controller.debugShowsTakeoverMessage)
        XCTAssertTrue(controller.debugRenderedOutput.contains("Terminal session exited."))
        XCTAssertFalse(normalizedRenderedOutput(controller.debugRenderedOutput).contains("command failed"))
        XCTAssertFalse(normalizedRenderedOutput(controller.debugRenderedOutput).contains("exit 1"))
        XCTAssertEqual(controller.debugRendererSummary, "Renderer: takeover status")
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

        XCTAssertTrue(controller.debugShowsHeader)
        XCTAssertTrue(controller.debugShowsSummaryLabel)
        XCTAssertTrue(controller.debugShowsStateLabel)
        XCTAssertEqual(controller.debugState, "state: exited    child: 22")
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
        XCTAssertFalse(controller.debugShowsTextRenderer)
        XCTAssertFalse(controller.debugShowsHeader)
        XCTAssertTrue(controller.debugShowsTakeoverMessage)
        XCTAssertTrue(controller.debugRenderedOutput.contains("Terminal session exited."))
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
        XCTAssertFalse(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.selectAll(_:)))))
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

        XCTAssertTrue(focusVisibilityStates.isEmpty)
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
        let controller = TerminalSessionWindowController(
            sessionID: "session-5", paths: .init(rootDirectory: root.path),
            onWindowClose: { sessionID, clientID in
                closedSessionID = sessionID
                closedClientID = clientID
                cleanup.fulfill()
            })

        let expectedClientID = controller.clientID
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        wait(for: [cleanup], timeout: 1)
        XCTAssertEqual(closedSessionID, "session-5")
        XCTAssertEqual(closedClientID, expectedClientID)
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
