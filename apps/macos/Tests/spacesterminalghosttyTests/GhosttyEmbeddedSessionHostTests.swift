import AppKit
import Carbon
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class GhosttyEmbeddedSessionHostTests: XCTestCase {
    private final class TranscriptBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
        }

        func string() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    @MainActor private func makeHostingWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        return window
    }

    @MainActor private func attach(_ terminalView: GhosttyEmbeddedTerminalView, to window: NSWindow) {
        guard let contentView = window.contentView else {
            XCTFail("Missing content view")
            return
        }

        terminalView.removeFromSuperview()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: contentView.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        contentView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
    }

    @MainActor private func waitUntil(
        timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.05, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
        }

        XCTFail("Timed out waiting for condition.", file: file, line: line)
        throw NSError(domain: "GhosttyEmbeddedSessionHostTests", code: 1)
    }

    @MainActor func testEmbeddedViewSuppressesFunctionKeyPrivateUseText() {
        let event = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}",
                charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: UInt16(kVK_UpArrow)))

        XCTAssertNil(GhosttyEmbeddedTerminalView.ghosttyText(for: event))
        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: event), "up")
    }

    @MainActor func testEmbeddedViewMapsCommonNavigationAndFunctionFallbackKeys() {
        let homeEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F729}",
                charactersIgnoringModifiers: "\u{F729}", isARepeat: false, keyCode: UInt16(kVK_Home)))
        let pageDownEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F72D}",
                charactersIgnoringModifiers: "\u{F72D}", isARepeat: false, keyCode: UInt16(kVK_PageDown)))
        let backtabEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{19}",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: UInt16(kVK_Tab)))
        let f5Event = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F708}",
                charactersIgnoringModifiers: "\u{F708}", isARepeat: false, keyCode: UInt16(kVK_F5)))

        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: homeEvent), "home")
        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: pageDownEvent), "pagedown")
        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: backtabEvent), "backtab")
        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: f5Event), "f5")
    }

    @MainActor func testEmbeddedViewDoesNotInventModifiedNavigationFallbacks() {
        let optionLeftEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F702}",
                charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: UInt16(kVK_LeftArrow)))

        XCTAssertNil(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: optionLeftEvent))
    }

    @MainActor func testEmbeddedViewUsesPrintableTextForControlKeyEvents() {
        let event = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1F}",
                charactersIgnoringModifiers: "_", isARepeat: false, keyCode: UInt16(kVK_ANSI_U)))

        XCTAssertEqual(GhosttyEmbeddedTerminalView.ghosttyText(for: event), "u")
    }

    @MainActor func testEmbeddedViewDefersStandardWindowManagementShortcutsToSystem() {
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_W), modifierFlags: [.command]))
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_M), modifierFlags: [.command]))
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_LeftArrow), modifierFlags: [.control, .function]))
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_RightArrow), modifierFlags: [.control, .function]))
        XCTAssertFalse(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_C), modifierFlags: [.command]))
        XCTAssertFalse(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_UpArrow), modifierFlags: []))
    }

    @MainActor func testEmbeddedViewPacksPreciseAndMomentumScrollModsLikeNativeGhostty() {
        XCTAssertEqual(Int32(GhosttyEmbeddedTerminalView.makeScrollMods(hasPreciseDeltas: true, momentumPhase: .changed)), Int32(0b0000_0111))
        XCTAssertEqual(Int32(GhosttyEmbeddedTerminalView.makeScrollMods(hasPreciseDeltas: false, momentumPhase: .ended)), Int32(0b0000_1000))
        XCTAssertEqual(Int32(GhosttyEmbeddedTerminalView.makeScrollMods(hasPreciseDeltas: false, momentumPhase: [])), Int32(0))
    }

    @MainActor func testSurfaceDataOutputDispatchRequiresHandlerAndBytes() {
        XCTAssertFalse(GhosttyEmbeddedTerminalView.shouldDispatchSurfaceDataOutput(hasHandler: false, byteCount: 32))
        XCTAssertFalse(GhosttyEmbeddedTerminalView.shouldDispatchSurfaceDataOutput(hasHandler: true, byteCount: 0))
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDispatchSurfaceDataOutput(hasHandler: true, byteCount: 32))
    }

    @MainActor func testActionEventsUpdateEffectiveTitleAndWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-1", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "cat", createdAt: "2026-05-09T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

        XCTAssertEqual(host.effectiveTitle, "fallback-title")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/original")

        host.applyActionEvent(.setTitle(" live-title "))
        host.applyActionEvent(.setWorkingDirectory(" /tmp/updated "))

        XCTAssertEqual(host.debugCurrentTitle, "live-title")
        XCTAssertEqual(host.debugCurrentWorkingDirectory, "/tmp/updated")
        XCTAssertEqual(host.effectiveTitle, "live-title")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/updated")
    }

    @MainActor func testBlankActionValuesResetToLaunchConfigurationFallbacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-2", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: nil, createdAt: "2026-05-09T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

        host.applyActionEvent(.setTitle("custom"))
        host.applyActionEvent(.setWorkingDirectory("/tmp/custom"))
        host.applyActionEvent(.setTitle("   "))
        host.applyActionEvent(.setWorkingDirectory("\n"))

        XCTAssertNil(host.debugCurrentTitle)
        XCTAssertNil(host.debugCurrentWorkingDirectory)
        XCTAssertEqual(host.effectiveTitle, "fallback-title")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/original")
    }

    @MainActor func testEmbeddedHostExposesDistinctRendererAdapter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-renderer-adapter", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: nil, createdAt: "2026-05-18T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

        XCTAssertTrue((host.rendererHost as AnyObject) is GhosttyEmbeddedRendererHost)
        XCTAssertFalse((host.rendererHost as AnyObject) === host)
    }

    @MainActor func testIncomingOutputRequestsSurfaceRefreshImmediately() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-3", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-10T00:00:00Z")
        var refreshCount = 0
        let host = GhosttyEmbeddedSessionHost(
            launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path), requestSurfaceRefreshAction: { refreshCount += 1 })

        host.debugHandleIncomingOutput(Data("echo hello\n".utf8))

        XCTAssertEqual(refreshCount, 1)
        let output = try String(contentsOfFile: TerminalSessionPaths(rootDirectory: root.path).outputPath)
        XCTAssertEqual(output, "echo hello\n")
    }

    @MainActor func testRuntimeStateRemainsRunningWhenCachedChildPIDHasDied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-4", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-10T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        try process.run()
        let childPID = process.processIdentifier
        process.waitUntilExit()

        host.debugSetLastKnownChildPID(childPID)
        host.debugPersistRuntimeState()

        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .running)
        XCTAssertEqual(runtimeState.childPID, childPID)
        XCTAssertNil(runtimeState.exitedAt)
    }

    @MainActor func testTerminateMarksRuntimeExited() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-5", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-10T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

        host.terminate()

        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertNotNil(runtimeState.exitedAt)
    }

    @MainActor func testEmbeddedViewRebindsLiveSurfaceAcrossWindowsWithoutRestartingShell() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let terminalView = GhosttyEmbeddedTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "rebind-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "rebind",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-17T00:00:00Z"))
        defer { terminalView.terminateSession() }
        let transcript = TranscriptBuffer()
        terminalView.setOutputHandler { data in transcript.append(data) }

        let firstWindow = makeHostingWindow()
        let secondWindow = makeHostingWindow()
        defer {
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
            firstWindow.close()
            secondWindow.close()
        }

        let surfaceReady = expectation(description: "embedded ghostty surface ready")
        terminalView.onSurfaceReady = { surface in if surface != nil { surfaceReady.fulfill() } }

        attach(terminalView, to: firstWindow)
        firstWindow.makeKeyAndOrderFront(nil)
        wait(for: [surfaceReady], timeout: 15)

        let originalPID = try XCTUnwrap(terminalView.foregroundPID())
        let originalSurface = try XCTUnwrap(terminalView.surface)
        terminalView.sendRawBytes(Data("first window\n".utf8))
        try waitUntil { transcript.string().contains("first window") }
        XCTAssertEqual(terminalView.surface, originalSurface)

        terminalView.parkInHiddenHostWindowIfNeeded()
        try waitUntil { terminalView.window !== nil && terminalView.window !== firstWindow }
        XCTAssertEqual(try XCTUnwrap(terminalView.foregroundPID()), originalPID)
        XCTAssertEqual(terminalView.surface, originalSurface)

        terminalView.sendRawBytes(Data("hidden host\n".utf8))
        try waitUntil { transcript.string().contains("hidden host") }
        XCTAssertEqual(terminalView.surface, originalSurface)

        attach(terminalView, to: secondWindow)
        secondWindow.makeKeyAndOrderFront(nil)
        try waitUntil { terminalView.window === secondWindow }
        XCTAssertEqual(try XCTUnwrap(terminalView.foregroundPID()), originalPID)
        XCTAssertEqual(terminalView.surface, originalSurface)

        terminalView.sendRawBytes(Data("second window\n".utf8))
        try waitUntil { transcript.string().contains("second window") }
        let reboundTranscript = transcript.string()
        XCTAssertTrue(reboundTranscript.contains("first window"))
        XCTAssertTrue(reboundTranscript.contains("hidden host"))
        XCTAssertTrue(reboundTranscript.contains("second window"))
    }

    @MainActor func testControlAttachAndDetachRequestsUpdatePersistenceAndPostAttachmentChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-6", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-17T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        let client = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-17T00:00:00Z")
        let attachmentNotifications = expectation(description: "attachment notifications")
        attachmentNotifications.expectedFulfillmentCount = 2
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalAttachmentStateDidChange, object: nil, queue: .main) {
            notification in
            guard notification.userInfo?["sessionID"] as? String == "session-6" else { return }
            attachmentNotifications.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let attachResponse = host.handleControlRequest(.init(command: "attach", client: client, attachmentMode: .viewer))
        XCTAssertEqual(attachResponse, TerminalControlResponse(ok: true, message: "Attached viewer client."))
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).map(\.clientID), [client.id])

        let detachResponse = host.handleControlRequest(.init(command: "detach", clientID: client.id))
        XCTAssertEqual(detachResponse, TerminalControlResponse(ok: true, message: "Detached terminal client."))
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty)

        wait(for: [attachmentNotifications], timeout: 2)
    }

    @MainActor func testControlAttachUsesServerTimeForRemoteLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-server-time", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        let staleTimestampedClient = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2000-01-01T00:00:00Z")

        let attachResponse = host.handleControlRequest(.init(command: "attach", client: staleTimestampedClient, attachmentMode: .viewer))
        XCTAssertEqual(attachResponse, TerminalControlResponse(ok: true, message: "Attached viewer client."))
        XCTAssertEqual(try TerminalSessionPersistence.liveAttachments(paths: paths, now: Date()).map(\.clientID), [staleTimestampedClient.id])

        let snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
        XCTAssertNotEqual(snapshot.clients.first?.connectedAt, staleTimestampedClient.connectedAt)
    }

    @MainActor func testControlHeartbeatRefreshesOnlySpecifiedRemoteViewerLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-heartbeat", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        let refreshedClient = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-17T00:00:00Z")
        let staleClient = TerminalClient(
            id: "stale-remote-client", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-heartbeat", client: refreshedClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-heartbeat", client: staleClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")

        let response = host.handleControlRequest(.init(command: "heartbeat", clientID: refreshedClient.id))
        XCTAssertEqual(response, TerminalControlResponse(ok: true, message: "Refreshed terminal client lease."))

        let now = ISO8601DateFormatter().date(from: "2026-05-17T00:01:01Z")!
        XCTAssertEqual(try TerminalSessionPersistence.liveAttachments(paths: paths, now: now).map(\.clientID), [refreshedClient.id])
        XCTAssertEqual(try TerminalSessionPersistence.staleRemoteClientIDs(paths: paths, now: now), [staleClient.id])
    }

    @MainActor func testExpireStaleRemoteClientsDetachesLeaseExpiredViewerAndPostsAttachmentChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-7", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-17T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        let client = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "session-7", client: client, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        let attachmentNotifications = expectation(description: "attachment expiry notification")
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalAttachmentStateDidChange, object: nil, queue: .main) {
            notification in
            guard notification.userInfo?["sessionID"] as? String == "session-7" else { return }
            attachmentNotifications.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let expiredAt = ISO8601DateFormatter().date(from: "2026-05-17T00:01:05Z")!
        XCTAssertEqual(host.expireStaleRemoteClientsIfNeeded(now: expiredAt), ["remote-client"])
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty)

        wait(for: [attachmentNotifications], timeout: 2)
    }

    func testDetachingViewerKeepsOwnerFocusState() {
        XCTAssertFalse(
            GhosttyEmbeddedSessionHost.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: "owner-client"))
        XCTAssertTrue(GhosttyEmbeddedSessionHost.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: true, remainingOwnerClientID: nil))
        XCTAssertTrue(GhosttyEmbeddedSessionHost.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: nil))
    }
}
