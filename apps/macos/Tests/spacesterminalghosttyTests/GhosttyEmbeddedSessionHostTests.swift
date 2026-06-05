import AppKit
import Carbon
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class GhosttyEmbeddedSessionHostTests: XCTestCase {
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

    @MainActor private func waitForForegroundPID(
        in sessionDriver: GhosttyEmbeddedTerminalSessionDriver, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Int32 {
        var foregroundPID: Int32?
        try waitUntil(timeout: timeout, file: file, line: line) {
            foregroundPID = sessionDriver.foregroundPID()
            return foregroundPID != nil
        }
        return try XCTUnwrap(foregroundPID, file: file, line: line)
    }

    func testHostManagedPTYLaunchesInteractiveShellAsLoginShell() {
        let command = HostManagedPTYTerminalSessionDriver.execCommand(
            for: TerminalSessionLaunchConfiguration(
                sessionID: "exec-shell", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: "2026-05-29T00:00:00Z"))

        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(command.arguments, ["-zsh"])
    }

    func testHostManagedPTYRunsCommandsThroughLoginShell() {
        let command = HostManagedPTYTerminalSessionDriver.execCommand(
            for: TerminalSessionLaunchConfiguration(
                sessionID: "exec-command", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh",
                command: "echo 'hello'", createdAt: "2026-05-29T00:00:00Z"))

        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(command.arguments, ["zsh", "-l", "-c", "echo 'hello'"])
    }

    func testHostManagedPTYStripsGhosttyCommandPrefixesBeforeShellExecution() {
        let direct = HostManagedPTYTerminalSessionDriver.execCommand(
            for: TerminalSessionLaunchConfiguration(
                sessionID: "exec-direct", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh",
                command: "direct:/bin/cat", createdAt: "2026-05-29T00:00:00Z"))
        let shell = HostManagedPTYTerminalSessionDriver.execCommand(
            for: TerminalSessionLaunchConfiguration(
                sessionID: "exec-shell-prefix", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh",
                command: "shell:printf hello", createdAt: "2026-05-29T00:00:00Z"))

        XCTAssertEqual(direct.arguments, ["zsh", "-l", "-c", "/bin/cat"])
        XCTAssertEqual(shell.arguments, ["zsh", "-l", "-c", "printf hello"])
    }

    func testHostManagedPTYReadLoopDescriptorOwnershipRequiresMatchingGeneration() {
        XCTAssertTrue(HostManagedPTYTerminalSessionDriver.readLoopOwnsDescriptor(currentFD: 12, currentGeneration: 4, readFD: 12, readGeneration: 4))
        XCTAssertFalse(HostManagedPTYTerminalSessionDriver.readLoopOwnsDescriptor(currentFD: 12, currentGeneration: 5, readFD: 12, readGeneration: 4))
        XCTAssertFalse(HostManagedPTYTerminalSessionDriver.readLoopOwnsDescriptor(currentFD: 13, currentGeneration: 4, readFD: 12, readGeneration: 4))
    }

    @MainActor func testRemoteStateScreenSnapshotPolicyPublishesOwnerBootstrapSnapshots() {
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "initial"))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "initial", ownerKind: .localWindow))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "initial", ownerKind: .remoteViewer))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "attachment_state", ownerKind: .localWindow))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "attachment_state", ownerKind: .remoteViewer))
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "input"))
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "input_output"))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "terminated"))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "output", ownerKind: .localWindow))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "output", ownerKind: .remoteViewer))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "state_change", ownerKind: .localWindow))
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "state_change", ownerKind: .remoteViewer))
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "resize"))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "resize", ownerKind: .remoteViewer))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "resize", ownerKind: .localWindow))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "clear_screen"))
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "runtime_state"))
    }

    @MainActor func testInputOutputResyncPublishesScreenStateForLocalOwnerOnly() {
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "input", ownerKind: .remoteViewer))
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "input_output", ownerKind: .remoteViewer))
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "input", ownerKind: .localWindow))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteStateShouldIncludeScreenState(reason: "input_output", ownerKind: .localWindow))
    }

    @MainActor func testScreenStateChangeRequestsLiveSurfaceRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        var refreshRequestCount = 0
        let core = GhosttyEmbeddedSessionCore(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "screen-refresh-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                shell: "/bin/zsh", command: nil, createdAt: "2026-05-29T00:00:00Z"), paths: paths,
            requestSurfaceRefreshAction: { refreshRequestCount += 1 })

        core.applySessionStateChange(.init(flags: [.screen], revision: 1, title: nil, workingDirectory: nil))

        XCTAssertEqual(refreshRequestCount, 1)
    }

    @MainActor func testScreenStateChangePublishesUnexportedLocalOwnerFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-screen-state-change-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
            shell: "/bin/zsh", command: nil, createdAt: "2026-06-02T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        defer { host.terminate() }
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in self.snapshot(text: "state changed") }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        let localOwner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-02T00:00:00Z")
        try host.attach(client: localOwner, mode: .owner, into: nil)

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }
        try waitUntil(timeout: 2) { !receivedPayloads.isEmpty }
        let baseline = try renderBaseline(from: try XCTUnwrap(receivedPayloads.first), baseline: nil)
        receivedPayloads.removeAll()

        let screenRevision: UInt64 = UInt64.max / 2
        host.applySessionStateChange(.init(flags: [.screen], revision: screenRevision, title: nil, workingDirectory: nil))

        try waitUntil(timeout: 2) {
            receivedPayloads.contains {
                $0.reason == TerminalRemoteSessionStateReason.stateChange && $0.screenStateRevision == screenRevision && $0.renderUpdate != nil
            }
        }
        let payload = try XCTUnwrap(receivedPayloads.first { $0.reason == TerminalRemoteSessionStateReason.stateChange })
        let applied = try renderBaseline(from: payload, baseline: baseline)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: applied.snapshot), "state changed")
    }

    @MainActor func testResizeRenderUpdatesStaySelfContainedWhenCoalesced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-resize-self-contained-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
            shell: "/bin/zsh", command: nil, createdAt: "2026-06-03T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        let owner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-03T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-06-03T00:00:00Z")

        var snapshotText = "resize frame one"
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in self.snapshot(text: snapshotText) }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        host.applySessionStateChange(.init(flags: [.screen], revision: 1, title: nil, workingDirectory: nil))
        let initialPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.initial))
        let initialBaseline = try renderBaseline(from: initialPayload, baseline: nil)

        snapshotText = "resize frame two"
        host.applySessionStateChange(.init(flags: [.screen], revision: 2, title: nil, workingDirectory: nil))
        let firstResizePayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.resize))
        let firstResizeUpdate = try XCTUnwrap(firstResizePayload.decodedRenderUpdate)
        XCTAssertEqual(firstResizeUpdate.kind, .full)
        XCTAssertEqual(firstResizeUpdate.fallbackReason, "resize_self_contained")

        snapshotText = "resize frame six"
        host.applySessionStateChange(.init(flags: [.screen], revision: 3, title: nil, workingDirectory: nil))
        let secondResizePayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.resize))
        let secondResizeUpdate = try XCTUnwrap(secondResizePayload.decodedRenderUpdate)
        XCTAssertEqual(secondResizeUpdate.kind, .full)
        XCTAssertEqual(secondResizeUpdate.fallbackReason, "resize_self_contained")

        _ = try GhosttyRenderUpdateApplier.apply(secondResizeUpdate, to: initialBaseline)
    }

    @MainActor func testScrollRenderUpdateAdvancesRevisionWithoutSessionStateChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-scroll-render-revision-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
            shell: "/bin/zsh", command: nil, createdAt: "2026-06-03T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        let owner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-03T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-06-03T00:00:00Z")

        var snapshotText = "frame one"
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in self.snapshot(text: snapshotText) }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        host.applySessionStateChange(.init(flags: [.screen], revision: 1, title: nil, workingDirectory: nil))
        let initialPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.initial))
        let initialBaseline = try renderBaseline(from: initialPayload, baseline: nil)

        snapshotText = "frame two"
        let scrollPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.scroll))
        let scrollUpdate = try XCTUnwrap(scrollPayload.decodedRenderUpdate)

        XCTAssertEqual(scrollPayload.screenStateRevision, 1)
        XCTAssertEqual(scrollUpdate.kind, .delta)
        XCTAssertEqual(scrollUpdate.baseRevision, initialBaseline.sessionRevision)
        XCTAssertNotEqual(scrollUpdate.targetRevision, scrollUpdate.baseRevision)

        let applied = try GhosttyRenderUpdateApplier.apply(scrollUpdate, to: initialBaseline)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: applied.snapshot), "frame two")
    }

    @MainActor func testRemoteScreenStateVisibleContentIgnoresBlankSnapshotsAndText() {
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteScreenStateHasVisibleContent(snapshot: snapshot(text: "   \n  "), snapshotText: nil))
        XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteScreenStateHasVisibleContent(snapshot: nil, snapshotText: " \n\t "))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteScreenStateHasVisibleContent(snapshot: snapshot(text: "Codex"), snapshotText: nil))
        XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteScreenStateHasVisibleContent(snapshot: nil, snapshotText: "OpenAI Codex"))
    }

    @MainActor func testTerminalInputTranslatorSuppressesFunctionKeyPrivateUseText() {
        let event = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}",
                charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: UInt16(kVK_UpArrow)))

        XCTAssertNil(GhosttyTerminalInputTranslator.ghosttyText(for: event))
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: event), "up")
    }

    @MainActor func testTerminalInputTranslatorMapsCommonNavigationAndFunctionFallbackKeys() {
        let rightEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}",
                charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
        let functionRightEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}",
                charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
        let numericFunctionRightEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
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

        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: rightEvent), "right")
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: functionRightEvent), "right")
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: numericFunctionRightEvent), "right")
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: homeEvent), "home")
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: pageDownEvent), "pagedown")
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: backtabEvent), "backtab")
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: f5Event), "f5")
    }

    @MainActor func testTerminalInputTranslatorMapsModifiedLineNavigationFallbacks() {
        let commandLeftEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F702}",
                charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: UInt16(kVK_LeftArrow)))
        let commandRightEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}",
                charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
        let optionLeftEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F702}",
                charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: UInt16(kVK_LeftArrow)))
        let optionRightEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}",
                charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))

        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: commandLeftEvent), "cmd+left")
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: commandRightEvent), "cmd+right")
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: optionLeftEvent), "opt+left")
        XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: optionRightEvent), "opt+right")
    }

    @MainActor func testMirrorTerminalViewMapsCommandKToHostClearAction() {
        let commandKEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "k",
                charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)))
        let commandDeleteEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: UInt16(kVK_Delete)))
        let optionDeleteEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: UInt16(kVK_Delete)))

        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: commandKEvent), "cmd+k")
        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: commandDeleteEvent), "cmd+backspace")
        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: optionDeleteEvent), "opt+backspace")
    }

    @MainActor func testTerminalInputTranslatorUsesPrintableTextForControlKeyEvents() {
        let event = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1F}",
                charactersIgnoringModifiers: "_", isARepeat: false, keyCode: UInt16(kVK_ANSI_U)))

        XCTAssertEqual(GhosttyTerminalInputTranslator.ghosttyText(for: event), "u")
    }

    @MainActor func testTerminalInputTranslatorDefersStandardWindowManagementShortcutsToSystem() {
        XCTAssertTrue(GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_W), modifierFlags: [.command]))
        XCTAssertTrue(GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_M), modifierFlags: [.command]))
        XCTAssertTrue(
            GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_LeftArrow), modifierFlags: [.control, .function]))
        XCTAssertTrue(
            GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_RightArrow), modifierFlags: [.control, .function]))
        XCTAssertFalse(GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_C), modifierFlags: [.command]))
        XCTAssertFalse(GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_UpArrow), modifierFlags: []))
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

    @MainActor func testSessionStateChangesUpdateEffectiveTitleAndWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-state-1", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "cat", createdAt: "2026-05-19T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

        host.applySessionStateChange(
            .init(flags: [.title, .workingDirectory], revision: 1, title: " live-title ", workingDirectory: " /tmp/updated "))

        XCTAssertEqual(host.debugCurrentTitle, "live-title")
        XCTAssertEqual(host.debugCurrentWorkingDirectory, "/tmp/updated")
        XCTAssertEqual(host.effectiveTitle, "live-title")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/updated")
    }

    @MainActor func testBlankSessionStateValuesResetToLaunchConfigurationFallbacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-state-2", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: nil, createdAt: "2026-05-19T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

        host.applySessionStateChange(.init(flags: [.title, .workingDirectory], revision: 1, title: "custom", workingDirectory: "/tmp/custom"))
        host.applySessionStateChange(.init(flags: [.title, .workingDirectory], revision: 2, title: "   ", workingDirectory: "\n"))

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

        XCTAssertTrue((host.rendererHost as AnyObject) is GhosttyHeadlessRendererHost)
        XCTAssertFalse((host.rendererHost as AnyObject) === host)
    }

    @MainActor func testLocalOwnerAttachExportsLiveSessionSnapshotForMacBootstrap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-local-owner-no-snapshot-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-23T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))
        let ownerClient = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-23T00:00:00Z")
        var sessionCaptureCount = 0
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in
            sessionCaptureCount += 1
            return nil
        }
        defer {
            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil
            host.core.terminate()
        }

        try host.attach(client: ownerClient, mode: .owner, into: nil)

        XCTAssertGreaterThanOrEqual(sessionCaptureCount, 1)
    }

    @MainActor func testRemoteTakeoverFromLocalOwnerExportsLiveSessionSnapshotWithoutSurfaceRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-remote-takeover-no-snapshot-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-23T00:00:00Z")
        var surfaceRefreshCount = 0
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths) { surfaceRefreshCount += 1 }
        let localOwner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-23T00:00:00Z")
        let remoteOwner = TerminalClient(
            id: "remote-ipad", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-23T00:00:01Z")
        var sessionCaptureCount = 0
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in
            sessionCaptureCount += 1
            return self.snapshot(text: "OpenAI Codex")
        }
        defer {
            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil
            host.core.terminate()
        }

        try host.attach(client: localOwner, mode: .owner, into: nil)
        let captureCountAfterLocalAttach = sessionCaptureCount
        let surfaceRefreshCountAfterLocalAttach = surfaceRefreshCount
        XCTAssertEqual(host.core.handleControlRequest(.init(command: "attach", client: remoteOwner, attachmentMode: .viewer)).ok, true)
        XCTAssertEqual(host.core.handleControlRequest(.init(command: "takeover", clientID: remoteOwner.id)).ok, true)

        XCTAssertGreaterThan(sessionCaptureCount, captureCountAfterLocalAttach)
        XCTAssertEqual(surfaceRefreshCount, surfaceRefreshCountAfterLocalAttach)
    }

    @MainActor func testRemoteOwnerReconnectInitialStateRefreshesLiveSessionSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-remote-reconnect-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-24T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        let localOwner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-24T00:00:00Z")
        let remoteOwner = TerminalClient(
            id: "remote-ipad", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-24T00:00:01Z")
        var sessionCaptureCount = 0
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in
            sessionCaptureCount += 1
            return self.snapshot(text: sessionCaptureCount == 1 ? "takeover bootstrap" : "fresh reconnect")
        }
        defer {
            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil
            host.core.terminate()
        }

        try host.attach(client: localOwner, mode: .owner, into: nil)
        XCTAssertEqual(host.core.handleControlRequest(.init(command: "attach", client: remoteOwner, attachmentMode: .viewer)).ok, true)
        XCTAssertEqual(host.core.handleControlRequest(.init(command: "takeover", clientID: remoteOwner.id)).ok, true)
        let captureCountBeforeReconnect = sessionCaptureCount

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }

        try waitUntil(timeout: 2) { !receivedPayloads.isEmpty }
        let initialSnapshot = try XCTUnwrap(receivedPayloads.first?.renderSnapshot)

        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: initialSnapshot), "fresh reconnect")
        XCTAssertNil(receivedPayloads.first?.outputEndByteOffset)
        XCTAssertGreaterThan(sessionCaptureCount, captureCountBeforeReconnect)
    }

    @MainActor func testIncomingOutputRequestsSurfaceRefreshImmediately() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-3", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-10T00:00:00Z")
        var refreshCount = 0
        var outputAtRefresh: String?
        let host = GhosttyEmbeddedSessionHost(
            launchConfiguration: launchConfiguration, paths: paths,
            requestSurfaceRefreshAction: {
                refreshCount += 1
                outputAtRefresh = try? String(contentsOfFile: paths.outputPath)
            })

        host.debugHandleIncomingOutput(Data("echo hello\n".utf8))

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(outputAtRefresh, "echo hello\n")
        let output = try String(contentsOfFile: paths.outputPath)
        XCTAssertEqual(output, "echo hello\n")
    }

    @MainActor func testInteractiveLocalOwnerOutputPublishesSnapshotWithoutDelayedInputOutputResync() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-interactive-input-output", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
            shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-28T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        defer { host.terminate() }
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in self.snapshot(text: "echo hello") }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        let localOwner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-28T00:00:00Z")
        try host.attach(client: localOwner, mode: .owner, into: nil)

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }
        try waitUntil(timeout: 2) { receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        receivedPayloads.removeAll()

        let output = Data("e".utf8)
        host.debugHandleOwnerInputActivity(byteCount: output.count)
        host.debugHandleIncomingOutput(output)

        try waitUntil(timeout: 2) {
            receivedPayloads.contains { $0.reason == "output" && $0.outputByteCount == output.count && $0.renderUpdate != nil }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(receivedPayloads.contains { $0.reason == "input_output" })
    }

    @MainActor func testBulkLocalOwnerOutputPublishesSnapshotBeforeInputOutputResync() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-input-output-resync", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-28T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        defer { host.terminate() }
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in self.snapshot(text: "echo hello") }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        let localOwner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-28T00:00:00Z")
        try host.attach(client: localOwner, mode: .owner, into: nil)

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }
        try waitUntil(timeout: 2) { receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        var baseline = try renderBaseline(from: try XCTUnwrap(receivedPayloads.first), baseline: nil)
        receivedPayloads.removeAll()

        let output = Data("echo hello\n".utf8)
        host.debugHandleOwnerInputActivity(byteCount: 4096)
        host.debugHandleIncomingOutput(output)

        try waitUntil(timeout: 2) {
            receivedPayloads.contains { $0.reason == "output" && $0.outputByteCount == output.count }
                && receivedPayloads.contains { $0.reason == "input_output" }
        }

        let outputIndex = try XCTUnwrap(receivedPayloads.firstIndex { $0.reason == "output" && $0.outputByteCount == output.count })
        let inputOutputIndex = try XCTUnwrap(receivedPayloads.firstIndex { $0.reason == "input_output" })
        XCTAssertLessThan(outputIndex, inputOutputIndex)
        XCTAssertNotNil(receivedPayloads[outputIndex].renderUpdate)
        baseline = try renderBaseline(from: receivedPayloads[outputIndex], baseline: baseline)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: baseline.snapshot), "echo hello")
        XCTAssertNotNil(receivedPayloads[inputOutputIndex].renderUpdate)
        baseline = try renderBaseline(from: receivedPayloads[inputOutputIndex], baseline: baseline)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: baseline.snapshot), "echo hello")
    }

    @MainActor func testStateExportFlushesBufferedOutputWithoutNestedOutputBroadcast() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-state-export-flush-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh", createdAt: "2026-06-04T00:00:00Z")
        let core = GhosttyEmbeddedSessionCore(launchConfiguration: launchConfiguration, paths: paths, requestSurfaceRefreshAction: {})
        let host = GhosttyEmbeddedSessionHost(core: core)
        defer { host.debugStopStateStreamServerForTesting() }

        let localOwner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-04T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-06-04T00:00:00Z", title: "shell", workingDirectory: "/tmp/original", columns: 80, rows: 24), paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: localOwner, mode: .owner, paths: paths, attachedAt: "2026-06-04T00:00:00Z")
        try host.debugStartStateStreamServerForTesting()

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }
        try waitUntil(timeout: 2) { receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        receivedPayloads.removeAll()

        let output = Data("queued output\n".utf8)
        host.debugBufferIncomingOutputForStateExport(output)
        host.debugBroadcastCurrentStateForTesting(reason: TerminalRemoteSessionStateReason.stateChange)

        try waitUntil(timeout: 2) { receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.stateChange } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.output && $0.outputByteCount == output.count })
        XCTAssertTrue(try String(contentsOfFile: paths.outputPath).hasSuffix("queued output\n"))
    }

    @MainActor func testIncomingOutputUsesRendererRefreshSchedulerByDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-output-default-refresh", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
            shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-18T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

        XCTAssertEqual(host.debugSurfaceRefreshRequestCount, 0)

        host.debugHandleIncomingOutput(Data("prompt".utf8))

        XCTAssertEqual(host.debugSurfaceRefreshRequestCount, 1)
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

    @MainActor func testStartedRuntimeMarksExitedWhenKnownChildPIDHasDied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-dead-child-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
            shell: "/bin/zsh", command: "printf done", createdAt: "2026-05-10T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        try process.run()
        let childPID = process.processIdentifier
        process.waitUntilExit()

        host.debugSetLastKnownChildPID(childPID)
        host.debugMarkStartedForTesting()
        FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())

        host.debugPersistRuntimeState()

        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertEqual(runtimeState.childPID, childPID)
        XCTAssertNotNil(runtimeState.exitedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlSocketPath))
    }

    @MainActor func testStartedRuntimeKeepsAttachedSessionRunningWhenCachedChildPIDHasDied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-attached-dead-child-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-10T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        try process.run()
        let childPID = process.processIdentifier
        process.waitUntilExit()

        let client = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-10T00:00:01Z")
        try TerminalSessionPersistence.upsertClient(client, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: client, mode: .owner, paths: paths, attachedAt: "2026-05-10T00:00:01Z")
        host.debugSetLastKnownChildPID(childPID)
        host.debugMarkStartedForTesting()

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

    @MainActor func testDeferredRuntimeRefreshDoesNotMarkTerminatedSessionRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-deferred-refresh-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
            shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-10T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

        host.debugMarkStartedForTesting()
        host.debugPersistRuntimeState()
        host.terminate()
        host.debugPersistRuntimeState()

        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertNotNil(runtimeState.exitedAt)
    }

    @MainActor func testSessionCloseMarksRuntimeExitedAndRemovesControlSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-close-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
            shell: "/bin/zsh", command: "printf done", createdAt: "2026-05-10T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        host.debugPersistRuntimeState()
        FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())

        host.debugHandleSessionClosed()

        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertNotNil(runtimeState.exitedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlSocketPath))
    }

    @MainActor func testSessionClosePersistsFinalRenderBeforeRendererTeardown() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-final-render-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "final-render",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "printf final-frame",
            createdAt: "2026-06-04T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        defer { host.terminate() }
        let owner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-06-04T00:00:00Z")

        try host.attach(client: owner, mode: .owner, into: nil)

        try waitUntil(timeout: 5) {
            (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))?.reason == TerminalRemoteSessionStateReason.terminated
        }
        let finalPayload = try TerminalSessionPersistence.readRemoteSessionState(paths: paths)
        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertEqual(finalPayload.reason, TerminalRemoteSessionStateReason.terminated)
        XCTAssertTrue(finalPayload.renderText?.contains("final-frame") == true)
    }

    @MainActor func testHeadlessDriverKeepsHostManagedSessionRunningWithoutWindowSurface() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "host-managed-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "host-managed",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-17T00:00:00Z"))
        defer { sessionDriver.terminate() }
        let transcript = TranscriptBuffer()
        sessionDriver.setOutputHandler { data in transcript.append(data) }

        try sessionDriver.startIfNeeded()
        let originalPID = try XCTUnwrap(sessionDriver.foregroundPID())

        sessionDriver.sendRawBytes(Data("host managed one\n".utf8))
        try waitUntil { transcript.string().contains("host managed one") }
        try waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains("host managed one")
        }
        XCTAssertEqual(try XCTUnwrap(sessionDriver.foregroundPID()), originalPID)

        sessionDriver.sendRawBytes(Data("host managed two\n".utf8))
        try waitUntil { transcript.string().contains("host managed two") }
        try waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains("host managed two")
        }
    }

    @MainActor func testHeadlessDriverClearScreenActionClearsVisibleOutput() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let readyMarker = "host managed clear ready"
        let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "host-managed-clear-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "host-managed-clear",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                command: "stty -echo; printf '\(readyMarker)\\n'; cat", createdAt: "2026-06-03T00:00:00Z"))
        defer { sessionDriver.terminate() }
        let transcript = TranscriptBuffer()
        sessionDriver.setOutputHandler { data in transcript.append(data) }

        try sessionDriver.startIfNeeded()
        try waitUntil { transcript.string().contains(readyMarker) }
        let marker = "host managed clear marker"
        sessionDriver.sendRawBytes(Data("\(marker)\n".utf8))
        try waitUntil { transcript.string().contains(marker) }
        try waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }

        XCTAssertTrue(sessionDriver.clearScreenAndScrollback())
        try waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return !GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }
    }

    @MainActor func testHeadlessDriverExportsHostManagedSnapshotAfterOutputAndResize() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "host-managed-resize-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-19T00:00:00Z"))
        defer { sessionDriver.terminate() }
        let transcript = TranscriptBuffer()
        sessionDriver.setOutputHandler { data in transcript.append(data) }

        try sessionDriver.startIfNeeded()
        let childPID = try waitForForegroundPID(in: sessionDriver)
        XCTAssertTrue(sessionDriver.resizeCellGrid(columns: 100, rows: 30))
        XCTAssertEqual(sessionDriver.surfaceCellSize()?.columns, 100)
        XCTAssertEqual(sessionDriver.surfaceCellSize()?.rows, 30)

        sessionDriver.sendRawBytes(Data("host managed resized\n".utf8))
        try waitUntil { transcript.string().contains("host managed resized") }
        sessionDriver.requestSurfaceRefresh()
        try waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return snapshot.columns == 100 && snapshot.rows == 30
                && GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains("host managed resized")
        }
        XCTAssertEqual(try XCTUnwrap(sessionDriver.foregroundPID()), childPID)
    }

    @MainActor func testHeadlessDriverExportsNativeScrollRectAfterAppendedOutputScrolls() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "host-managed-scrollrect-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                command: "sleep 0.2; printf 'line1\\nline2\\nline3\\nline4\\nline5\\n'; sleep 1", createdAt: "2026-06-03T00:00:00Z"))
        defer { sessionDriver.terminate() }
        let transcript = TranscriptBuffer()
        sessionDriver.setOutputHandler { data in transcript.append(data) }

        try sessionDriver.startIfNeeded()
        XCTAssertTrue(sessionDriver.resizeCellGrid(columns: 20, rows: 4))
        _ = sessionDriver.renderStateSnapshot()

        try waitUntil { transcript.string().contains("line5") }
        let captured = try XCTUnwrap(sessionDriver.renderStateSnapshot())
        let scrollRect = try XCTUnwrap(captured.scrollRects.first)

        XCTAssertEqual(scrollRect.rowStart, 0)
        XCTAssertEqual(scrollRect.rowCount, 4)
        XCTAssertEqual(scrollRect.columnStart, 0)
        XCTAssertEqual(scrollRect.columnCount, 20)
        XCTAssertLessThan(scrollRect.deltaRows, 0)
        XCTAssertGreaterThan(scrollRect.deltaRows, -4)
        XCTAssertEqual(scrollRect.deltaColumns, 0)
    }

    @MainActor func testHeadlessDriverExportsNativeScrollRectAfterViewportScrollback() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "host-managed-scrollback-scrollrect-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                command: "sleep 0.2; for i in 1 2 3 4 5 6 7 8; do printf \"line$i\\n\"; done; sleep 1", createdAt: "2026-06-03T00:00:00Z"))
        defer { sessionDriver.terminate() }
        let transcript = TranscriptBuffer()
        sessionDriver.setOutputHandler { data in transcript.append(data) }

        try sessionDriver.startIfNeeded()
        XCTAssertTrue(sessionDriver.resizeCellGrid(columns: 20, rows: 4))

        try waitUntil { transcript.string().contains("line8") }
        _ = sessionDriver.renderStateSnapshot()

        XCTAssertTrue(sessionDriver.sendScroll(horizontal: 0, vertical: 1))
        let captured = try XCTUnwrap(sessionDriver.renderStateSnapshot())
        let scrollRect = try XCTUnwrap(captured.scrollRects.first)

        XCTAssertEqual(scrollRect.rowStart, 0)
        XCTAssertEqual(scrollRect.rowCount, 4)
        XCTAssertEqual(scrollRect.columnStart, 0)
        XCTAssertEqual(scrollRect.columnCount, 20)
        XCTAssertGreaterThan(scrollRect.deltaRows, 0)
        XCTAssertLessThan(scrollRect.deltaRows, 4)
        XCTAssertEqual(scrollRect.deltaColumns, 0)
    }

    @MainActor func testHeadlessDriverExportsHostManagedSynchronizedOutput() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "host-managed-sync-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-19T00:00:00Z"))
        defer { sessionDriver.terminate() }
        let transcript = TranscriptBuffer()
        sessionDriver.setOutputHandler { data in transcript.append(data) }

        try sessionDriver.startIfNeeded()
        let marker = "OpenAI Codex synchronized marker"
        let output = "\u{1B}[?2026h\u{1B}[3;1H\u{1B}[J\u{1B}[4;1H\(marker)\u{1B}[?2026l"
        sessionDriver.sendRawBytes(Data(output.utf8))
        try waitUntil { transcript.string().contains(marker) }
        sessionDriver.requestSurfaceRefresh()
        try waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }
    }

    @MainActor func testHeadlessDriverExportsCodexStyleHostManagedFrame() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "host-managed-codex-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-19T00:00:00Z"))
        defer { sessionDriver.terminate() }
        let transcript = TranscriptBuffer()
        sessionDriver.setOutputHandler { data in transcript.append(data) }

        try sessionDriver.startIfNeeded()
        let marker = "OpenAI Codex"
        let output =
            "\u{1B}[?2004h\u{1B}[>4;0m\u{1B}[>7u\u{1B}[?1004h\u{1B}[6n\u{1B}]10;?\u{1B}\\\u{1B}]11;?\u{1B}\\\u{1B}[?u\u{1B}[c\u{1B}]0;project\u{7}"
            + "\u{1B}[?2026h\u{1B}[3;1H\u{1B}[J" + "\u{1B}[4;1H\u{1B}[2m\u{1B}[39;49m╭─────────────────────────────────────────────────────────╮"
            + "\u{1B}[5;1H│ >_ \u{1B}[22m\u{1B}[1m\(marker)\u{1B}[22m\u{1B}[2m (v0.135.0)                              │"
            + "\u{1B}[6;1H│                                                         │"
            + "\u{1B}[7;1H│ model:     \u{1B}[22mgpt-5.5 xhigh\u{1B}[2m   \u{1B}[22m\u{1B}[38;5;6;49m/model\u{1B}[2m\u{1B}[39;49m to change             │"
            + "\u{1B}[8;1H│ directory: \u{1B}[22m/private/…/spaces-mobile-demo/project\u{1B}[2m             │"
            + "\u{1B}[9;1H╰─────────────────────────────────────────────────────────╯"
            + "\u{1B}[11;1H  \u{1B}[1mTip:\u{1B}[22m Try the \u{1B}[1mCodex App\u{1B}[22m."
            + "\u{1B}[12;1H\u{1B}[1m›\u{1B}[22m \u{1B}[2mExplain this codebase" + "\u{1B}[13;1H  gpt-5.5 xhigh · /private/var/folders/project · main"
            + "\u{1B}[0m\u{1B}[0 q\u{1B}[?25h\u{1B}[12;3H\u{1B}[?2026l"
        sessionDriver.sendRawBytes(Data(output.utf8))
        try waitUntil { transcript.string().contains(marker) }
        XCTAssertTrue(sessionDriver.resizeCellGrid(columns: 119, rows: 41))
        sessionDriver.requestSurfaceRefresh()
        try waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            let text = GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot)
            return text.contains(marker) && text.contains("Explain this codebase")
        }
    }

    @MainActor func testHostSnapshotUsesRenderableSurfaceForLiveOwnerState() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "host-snapshot-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-21T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        let window = makeHostingWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let ownerClient = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-21T00:00:00Z")

        try host.attach(client: ownerClient, mode: .owner, into: try XCTUnwrap(window.contentView))
        window.makeKeyAndOrderFront(nil)
        try waitUntil { host.rendererHost.hasRenderableSurface() }

        try waitUntil {
            host.core.rendererHost.requestSurfaceRefresh()
            return host.snapshot() != nil
        }
    }

    @MainActor func testHeadlessDriverScrollRequestsHostManagedSnapshotRefresh() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "host-managed-scroll-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "scroll",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-18T00:00:00Z"))
        defer { sessionDriver.terminate() }

        try sessionDriver.startIfNeeded()
        let baselineRefreshCount = sessionDriver.debugRefreshRequestCount

        XCTAssertTrue(sessionDriver.sendScroll(horizontal: 0, vertical: -48))
        XCTAssertEqual(sessionDriver.debugLastScrollMods, 0)

        XCTAssertGreaterThanOrEqual(
            sessionDriver.debugRefreshRequestCount, baselineRefreshCount + 1,
            "Scroll movement should schedule redraws so Ghostty can update the exported viewport.")
    }

    @MainActor func testHeadlessDriverForwardsPreciseScrollMods() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "host-managed-scroll-mods-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "scroll",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-18T00:00:00Z"))
        defer { sessionDriver.terminate() }

        try sessionDriver.startIfNeeded()

        XCTAssertTrue(sessionDriver.sendScroll(horizontal: 0, vertical: -48, scrollMods: 0b0000_0111))
        XCTAssertEqual(sessionDriver.debugLastScrollMods, 0b0000_0111)
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
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
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

    @MainActor func testDetachingRemoteOwnerTransfersOwnershipBackToActiveLocalWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-owner-return", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let localClient = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-17T00:00:00Z")
        let remoteClient = TerminalClient(
            id: "remote-ipad", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-17T00:00:00Z")

        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: localClient, mode: .owner, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        XCTAssertEqual(host.handleControlRequest(.init(command: "attach", client: remoteClient, attachmentMode: .viewer)).ok, true)
        XCTAssertEqual(host.handleControlRequest(.init(command: "takeover", clientID: remoteClient.id)).ok, true)
        XCTAssertEqual(host.activeOwnerClientID(), remoteClient.id)

        let detachResponse = host.handleControlRequest(.init(command: "detach", clientID: remoteClient.id))
        XCTAssertEqual(detachResponse, TerminalControlResponse(ok: true, message: "Detached terminal client."))

        let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(activeAttachments.first(where: { $0.mode == .owner })?.clientID, localClient.id)
        XCTAssertFalse(activeAttachments.contains { $0.clientID == remoteClient.id })
    }

    @MainActor func testControlRejectsStaleOwnerEpochRequestsFromActiveOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-stale-owner-epoch", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-31T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let owner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-31T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-31T00:00:00Z")

        let response = host.handleControlRequest(.init(command: "send", text: "echo stale", clientID: owner.id, ownerEpoch: 1))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.message, "Ignoring stale owner epoch 1; current owner epoch is 0.")
    }

    @MainActor func testControlKeyCommandKClearsScreenThroughHostAction() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let readyMarker = "command k clear ready"
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-command-k-clear-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "stty -echo; printf '\(readyMarker)\\n'; cat",
            createdAt: "2026-06-03T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        defer { host.terminate() }
        let owner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-06-03T00:00:00Z")
        try host.attach(client: owner, mode: .owner, into: nil)
        try waitUntil {
            guard let snapshot = host.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(readyMarker)
        }

        let marker = "command k clear marker"
        XCTAssertTrue(host.handleControlRequest(.init(command: "send", text: "\(marker)\n", clientID: owner.id)).ok)
        try waitUntil {
            guard let snapshot = host.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }

        let response = host.handleControlRequest(.init(command: "key", key: "cmd+k", clientID: owner.id))

        XCTAssertEqual(response, TerminalControlResponse(ok: true, message: "Cleared terminal screen and scrollback."))
        try waitUntil {
            host.prepareRenderStateExport()
            guard let snapshot = host.snapshot() else { return false }
            return !GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }
    }

    @MainActor func testLocalMacCommandKClearsScreenThroughHostAction() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let readyMarker = "local command k clear ready"
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-local-command-k-clear-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "stty -echo; printf '\(readyMarker)\\n'; cat",
            createdAt: "2026-06-03T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        defer { host.terminate() }
        let owner = TerminalClient(id: "local-owner", kind: .localWindow, identity: .init(label: "Mac"), connectedAt: "2026-06-03T00:00:00Z")
        try host.attach(client: owner, mode: .owner, into: nil)
        try waitUntil {
            guard let snapshot = host.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(readyMarker)
        }

        let marker = "local command k clear marker"
        XCTAssertTrue(host.handleControlRequest(.init(command: "send", text: "\(marker)\n", clientID: owner.id)).ok)
        try waitUntil {
            guard let snapshot = host.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }

        let commandKEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "k",
                charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)))

        XCTAssertTrue(host.handleKeyEvent(commandKEvent, for: owner.id))
        try waitUntil {
            host.prepareRenderStateExport()
            guard let snapshot = host.snapshot() else { return false }
            return !GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }
    }

    @MainActor func testControlRejectsInputFromDemotedOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-demoted-owner", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-31T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let previousOwner = TerminalClient(
            id: "iphone-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-31T00:00:00Z")
        let nextOwner = TerminalClient(
            id: "ipad-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-31T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: previousOwner, mode: .owner, paths: paths, attachedAt: "2026-05-31T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: nextOwner, mode: .viewer, paths: paths, attachedAt: "2026-05-31T00:00:01Z")
        try TerminalSessionPersistence.transferOwnership(
            sessionID: launchConfiguration.sessionID, newOwnerClientID: nextOwner.id, paths: paths, transferredAt: "2026-05-31T00:00:02Z")

        let response = host.handleControlRequest(.init(command: "key", key: "enter", clientID: previousOwner.id))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.message, "Only the active owner can key the terminal.")
    }

    @MainActor func testControlRejectsStaleResizeSerialFromActiveOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-stale-resize", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-31T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        host.core.debugSetLastKnownSurfaceSize(columns: 80, rows: 24)
        let owner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-31T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-31T00:00:00Z")

        let accepted = host.handleControlRequest(.init(command: "resize", clientID: owner.id, columns: 80, rows: 24, ownerEpoch: 0, resizeSerial: 2))
        let stale = host.handleControlRequest(.init(command: "resize", clientID: owner.id, columns: 80, rows: 24, ownerEpoch: 0, resizeSerial: 1))

        XCTAssertTrue(accepted.ok)
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(stale.message, "Ignoring stale resize serial 1; latest accepted serial is 2.")
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
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
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
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
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
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
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

    @MainActor func testExpiringStaleRemoteOwnerTransfersOwnershipBackToActiveLocalWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-owner-expiry", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let localClient = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-17T00:00:00Z")
        let remoteClient = TerminalClient(
            id: "stale-remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: localClient, mode: .owner, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: remoteClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.transferOwnership(
            sessionID: launchConfiguration.sessionID, newOwnerClientID: remoteClient.id, paths: paths, transferredAt: "2026-05-17T00:00:01Z")

        let expiredAt = ISO8601DateFormatter().date(from: "2026-05-17T00:01:05Z")!
        XCTAssertEqual(host.expireStaleRemoteClientsIfNeeded(now: expiredAt), [remoteClient.id])

        let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(activeAttachments.first(where: { $0.mode == .owner })?.clientID, localClient.id)
        XCTAssertFalse(activeAttachments.contains { $0.clientID == remoteClient.id })
    }

    func testDetachingViewerKeepsOwnerFocusState() {
        XCTAssertFalse(
            GhosttyEmbeddedSessionHost.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: "owner-client"))
        XCTAssertTrue(GhosttyEmbeddedSessionHost.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: true, remainingOwnerClientID: nil))
        XCTAssertTrue(GhosttyEmbeddedSessionHost.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: nil))
    }

    private func renderBaseline(from payload: GhosttyRemoteSessionStatePayload, baseline: GhosttyRenderUpdateBaseline?) throws
        -> GhosttyRenderUpdateBaseline
    {
        let update = try XCTUnwrap(payload.decodedRenderUpdate)
        return try GhosttyRenderUpdateApplier.apply(update, to: baseline)
    }

    private func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = rows.map(\.count).max() ?? 0
        let paddedRows = rows.map { row in row.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedRows.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: paddedRows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000, cells: cells)
    }
}
