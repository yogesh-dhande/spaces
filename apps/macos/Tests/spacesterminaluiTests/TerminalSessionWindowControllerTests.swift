import XCTest
import spacesterminalcore

@testable import spacesterminalghostty
@testable import spacesterminalui

final class TerminalSessionWindowControllerTests: XCTestCase {
    private final class ClientCapture: @unchecked Sendable {
        var attachedClientID: String?
        var detachedClientID: String?
    }

    private final class ValidatedItem: NSObject, NSValidatedUserInterfaceItem {
        let action: Selector?

        init(action: Selector?) { self.action = action }

        var tag: Int { 0 }
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

    @MainActor func testControllerLoadsRecentOutputIntoTextView() throws {
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
        XCTAssertEqual(controller.debugRenderedOutput, "echo hello\necho hello")
        XCTAssertTrue(controller.debugRendererSummary.contains("Renderer:"))
        XCTAssertTrue(controller.debugRendererSummary.contains("script-pty"))
    }

    @MainActor func testControllerCanSkipInitialRefreshUntilShow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-skip-initial-refresh", title: "session title", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-skip-initial-refresh", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-09T00:00:01Z"),
            paths: paths)
        try "hello\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let controller = TerminalSessionWindowController(sessionID: "session-skip-initial-refresh", paths: paths, performInitialRefresh: false)

        XCTAssertEqual(controller.debugRenderedOutput, "")

        controller.show()

        XCTAssertEqual(controller.debugRenderedOutput, "hello")
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

    @MainActor func testViewerWindowShowsViewerTitleAndOwnerLabel() throws {
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

        XCTAssertEqual(controller.debugWindowTitle, "frontend (viewer)")
        XCTAssertTrue(controller.debugState.contains("owner: Yogesh Mac"))
        XCTAssertTrue(controller.debugRendererSummary.contains("viewer"))
        XCTAssertFalse(controller.debugShowsInlineControls)
        XCTAssertTrue(controller.debugShowsTakeoverButton)
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
        let controller = TerminalSessionWindowController(sessionID: "session-4", paths: paths)

        XCTAssertFalse(controller.debugShowsInlineControls)
        XCTAssertFalse(controller.debugShowsTakeoverButton)
        XCTAssertFalse(controller.debugShowsRendererLabel)
        XCTAssertFalse(controller.debugShowsTitleLabel)
        XCTAssertFalse(controller.debugShowsSummaryLabel)
        XCTAssertFalse(controller.debugShowsStateLabel)
        XCTAssertFalse(controller.debugShowsHeader)
        XCTAssertEqual(controller.debugState, "state: running    child: 22")
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
        let controller = TerminalSessionWindowController(sessionID: "session-owner-status", paths: paths)

        XCTAssertTrue(controller.debugShowsHeader)
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

        let controller = TerminalSessionWindowController(sessionID: "session-owner-refresh", paths: paths)

        XCTAssertEqual(controller.debugRefreshIntervalMS, 2000)
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

        let controller = TerminalSessionWindowController(sessionID: "session-owner-surface", paths: paths)
        controller.show()
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.debugForceRefresh()

        XCTAssertEqual(controller.debugRendererSummary, "Renderer: libghostty (owner)")
        XCTAssertEqual(controller.debugRenderedOutput, "")
        XCTAssertGreaterThan(controller.debugTerminalContainerWidth, 0)
        XCTAssertGreaterThanOrEqual(controller.debugTerminalContainerWidth, controller.debugBodyWidth - 2)
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
        let controller = TerminalSessionWindowController(
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
        controller.debugSimulateApplicationDidBecomeActive()
        controller.windowDidResignMain(Notification(name: NSWindow.didResignMainNotification))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        controller.debugSimulateApplicationDidResignActive()

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

    @MainActor func testFallbackWindowPasteTargetsInlineInputAndSelectAllStaysEnabled() throws {
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

        XCTAssertEqual(controller.debugInputFieldValue, "paste-from-test")
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.copy(_:)))))
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.paste(_:)))))
        XCTAssertTrue(controller.validateUserInterfaceItem(ValidatedItem(action: #selector(NSText.selectAll(_:)))))
    }

    @MainActor func testFallbackWindowPreservesSelectionAndScrollOffsetWhenNewOutputArrives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "session-scrollback", title: "scrollback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "tail -f log",
                createdAt: "2026-05-09T00:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(sessionID: "session-scrollback", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-09T00:00:01Z"), paths: paths)
        let initialOutput = (0..<240).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try initialOutput.write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let controller = TerminalSessionWindowController(sessionID: "session-scrollback", paths: paths)
        controller.show()
        controller.debugSelectRenderedRange(NSRange(location: 12, length: 6))
        controller.debugScrollOutputToOffsetFromBottom(140)
        let initialOffset = controller.debugOutputOffsetFromBottom

        let updatedOutput = initialOutput + "tail-a\ntail-b\ntail-c\n"
        try updatedOutput.write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        controller.debugForceRefresh()

        XCTAssertEqual(controller.debugSelectedRange.location, 12)
        XCTAssertEqual(controller.debugSelectedRange.length, 6)
        XCTAssertGreaterThan(controller.debugOutputOffsetFromBottom, 64)
        XCTAssertLessThan(abs(controller.debugOutputOffsetFromBottom - initialOffset), 48)
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

        let ownerController = TerminalSessionWindowController(sessionID: "session-6", paths: paths)
        let viewerController = TerminalSessionWindowController(
            sessionID: "session-6", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in })

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
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: libghostty (owner)")
        XCTAssertFalse(ownerController.debugShowsTakeoverButton)
        XCTAssertEqual(viewerController.debugWindowTitle, "frontend (viewer)")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: viewer tail")
        XCTAssertTrue(viewerController.debugShowsTakeoverButton)

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-6", newOwnerClientID: viewer.id, paths: paths, transferredAt: "2026-05-09T00:00:02Z")

        ownerController.debugForceRefresh()
        viewerController.debugForceRefresh()

        XCTAssertEqual(ownerController.debugWindowTitle, "frontend (viewer)")
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: viewer tail")
        XCTAssertTrue(ownerController.debugShowsTakeoverButton)
        XCTAssertEqual(viewerController.debugWindowTitle, "frontend")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: libghostty (owner)")
        XCTAssertFalse(viewerController.debugShowsTakeoverButton)
    }

    @MainActor func testGhosttyControllersRefreshOwnershipImmediatelyFromAttachmentChangeNotification() throws {
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

        let ownerController = TerminalSessionWindowController(sessionID: "session-notify", paths: paths)
        let viewerController = TerminalSessionWindowController(
            sessionID: "session-notify", paths: paths, preferredAttachmentMode: .viewer, attachClientAction: { _, _ in }, detachClientAction: { _ in }
        )

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
        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: libghostty (owner)")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: viewer tail")

        try TerminalSessionPersistence.transferOwnership(
            sessionID: "session-notify", newOwnerClientID: viewer.id, paths: paths, transferredAt: "2026-05-09T00:00:02Z")

        ownerController.debugSimulateAttachmentStateDidChange()
        viewerController.debugSimulateAttachmentStateDidChange()

        XCTAssertEqual(ownerController.debugRendererSummary, "Renderer: viewer tail")
        XCTAssertEqual(viewerController.debugRendererSummary, "Renderer: libghostty (owner)")
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

        let controller = TerminalSessionWindowController(sessionID: "session-metadata", paths: paths)
        let owner = TerminalClient(
            id: controller.clientID, kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: "2026-05-09T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-metadata", client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-09T00:00:00Z")

        controller.debugForceRefresh()
        XCTAssertEqual(controller.debugWindowTitle, "backend")
        XCTAssertEqual(controller.debugWindowRepresentedPath, initialWorkingDirectory.path)
        XCTAssertTrue(controller.debugSummary.contains("work"))

        guard let host = GhosttyEmbeddedSessionRegistry.shared.existingHost(sessionID: "session-metadata") else {
            XCTFail("expected ghostty host")
            return
        }

        host.applyActionEvent(.setTitle(" live api "))
        host.applyActionEvent(.setWorkingDirectory(" \(updatedWorkingDirectory.path) "))

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

        let firstController = TerminalSessionWindowController(
            sessionID: "session-7", paths: paths,
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

        let reopenedController = TerminalSessionWindowController(
            sessionID: "session-7", paths: paths,
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
        XCTAssertEqual(reopenedController.debugRendererSummary, "Renderer: libghostty (owner)")
    }
}
