import AppKit
import Carbon
import Foundation
import GhosttyKit
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class RemoteGhosttySessionHostTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?
    private final class TranscriptFetchAttempts: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// A transcript provider whose fetches suspend until the test explicitly resolves them, in call
    /// order. Lets a test hold one ended run's transcript fetch in flight across a relaunch and a
    /// second exit, then resolve the stale and current fetches independently.
    private final class ManualTranscriptProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<RemoteGhosttyTranscript, Error>] = []

        var pendingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return continuations.count
        }

        func fetch() async throws -> RemoteGhosttyTranscript {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                continuations.append(continuation)
                lock.unlock()
            }
        }

        func resolveNext(with data: Data, runIdentity: String? = nil) {
            lock.lock()
            let continuation = continuations.isEmpty ? nil : continuations.removeFirst()
            lock.unlock()
            continuation?.resume(returning: RemoteGhosttyTranscript(data: data, runIdentity: runIdentity))
        }
    }

    private final class DirectTerminalServiceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [GhosttyRemoteSessionStatePayload]
        private var recordedRequests: [TerminalServiceRequest] = []

        init(payload: GhosttyRemoteSessionStatePayload) { payloads = [payload] }

        init(payloads: [GhosttyRemoteSessionStatePayload]) { self.payloads = payloads }

        func send(_ request: TerminalServiceRequest) throws -> TerminalServiceResponse {
            lock.lock()
            recordedRequests.append(request)
            let currentPayload: GhosttyRemoteSessionStatePayload?
            if case .state = request.command, payloads.count > 1 { currentPayload = payloads.removeFirst() } else { currentPayload = payloads.first }
            lock.unlock()

            switch request.command {
            case .state: return TerminalServiceResponse(ok: true, message: "state", sessionState: currentPayload)
            case .control:
                return TerminalServiceResponse(
                    ok: true, message: "controlled", controlResponse: TerminalControlResponse(ok: true, message: "controlled"))
            default: return TerminalServiceResponse(ok: false, message: "Unexpected command '\(request.commandName)'.")
            }
        }

        func setPayload(_ payload: GhosttyRemoteSessionStatePayload) {
            lock.lock()
            payloads = [payload]
            lock.unlock()
        }

        /// Serves `payloads` in order, one per `.state` request, then repeats the last one — so a test can
        /// put a payload the host applies but does not cache (a clipboard write) behind a fence payload it
        /// does cache, and know the first was served and consumed once the fence is observable.
        func setPayloads(_ payloads: [GhosttyRemoteSessionStatePayload]) {
            lock.lock()
            self.payloads = payloads
            lock.unlock()
        }

        func requests() -> [TerminalServiceRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }
    }

    /// A `terminalServiceRequestSender` whose `.control` responses fail on demand instead of opening a
    /// real socket — `.state` always answers with a fixed running payload so the host attaches normally.
    /// `failFirstControlRequestOnly` fails only the first `.control` request and lets every later one
    /// succeed, so a test can prove a later send was never *attempted* (not merely that it also failed)
    /// once the queue that would have carried it is discarded.
    private final class ScriptedControlRequestSender: @unchecked Sendable {
        private let lock = NSLock()
        private let payload: GhosttyRemoteSessionStatePayload
        private let controlError: any Error
        private let failFirstControlRequestOnly: Bool
        private var controlRequestCount = 0
        private var recordedControlCommands: [String] = []
        private var recordedControlTexts: [String] = []
        /// Fires synchronously, under the lock, the instant a control request with this command name is
        /// recorded — before the scripted error is thrown. Lets a test await one specific command (e.g.
        /// "scroll") reaching the daemon instead of an unrelated one (attach's own owner-handoff resize)
        /// that happens to arrive first.
        private var awaitedCommandName: String?
        private var awaitedCommandContinuation: CheckedContinuation<Void, Never>?

        init(payload: GhosttyRemoteSessionStatePayload, controlError: any Error, failFirstControlRequestOnly: Bool = false) {
            self.payload = payload
            self.controlError = controlError
            self.failFirstControlRequestOnly = failFirstControlRequestOnly
        }

        /// Suspends until a control request named `commandName` (e.g. "scroll", "resize") is recorded.
        /// Returns immediately if one already was before this call. The check-or-register happens in a
        /// single locked critical section (shared with `send`'s resume-on-match below), so a request
        /// recorded concurrently can never land in the gap between checking and registering.
        func awaitControlRequest(named commandName: String) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if recordedControlCommands.contains(commandName) {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                awaitedCommandName = commandName
                awaitedCommandContinuation = continuation
                lock.unlock()
            }
        }

        var controlRequestCommands: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedControlCommands
        }

        /// The `text` field of every `.send` control request that reached this sender, in order — empty
        /// for command kinds that carry no text (scroll, resize, clear-screen).
        var controlRequestTexts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedControlTexts
        }

        func send(_ request: TerminalServiceRequest) throws -> TerminalServiceResponse {
            switch request.command {
            case .state: return TerminalServiceResponse(ok: true, message: "state", sessionState: payload)
            case .control(let controlPayload):
                lock.lock()
                controlRequestCount += 1
                let requestNumber = controlRequestCount
                let commandName = controlPayload.controlRequest.command
                recordedControlCommands.append(commandName)
                if let text = controlPayload.controlRequest.text { recordedControlTexts.append(text) }
                var resumingContinuation: CheckedContinuation<Void, Never>?
                if awaitedCommandName == commandName {
                    resumingContinuation = awaitedCommandContinuation
                    awaitedCommandContinuation = nil
                    awaitedCommandName = nil
                }
                lock.unlock()
                resumingContinuation?.resume()
                if !failFirstControlRequestOnly || requestNumber == 1 { throw controlError }
                return TerminalServiceResponse(
                    ok: true, message: "controlled", controlResponse: TerminalControlResponse(ok: true, message: "controlled"))
            default: return TerminalServiceResponse(ok: false, message: "Unexpected command '\(request.commandName)'.")
            }
        }
    }

    private struct SimulatedTransportFailure: Error {}

    /// Thread-safe counter for `inputFailureHandler` invocations. An actor rather than a locked class
    /// because the handler itself is `async`, so incrementing can simply `await` straight into it.
    private actor FailureReportCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    /// Stands in for a reachable daemon's coded rejection (e.g. "another client owns this session"),
    /// which the host flattens into an opaque message-carrying error before `inputFailureHandler` ever
    /// sees it — see `RemoteGhosttySessionHost.sendControlRequest`. Distinct from
    /// `SimulatedTransportFailure` only so a test can tell which one a fixture threw; the host itself
    /// never distinguishes the two, which is the point of `testCodedRejectionNeitherReportsALostLinkNorDropsInput`.
    private struct SimulatedRejectionError: Error {}

    /// Stands in for a bare request timeout — the production shapes are
    /// `SpacesDeviceAPIRequestClientError.timeout` / `SpacesPinnedTLSConnectionError.timeout`, whose
    /// classification (`SpacesDeviceClient.isDeviceAPIRequestTimeout`) and the resulting
    /// `reportFailedInputSend` verdict (`false` — not conclusive proof the link is down) are pinned by
    /// `DeviceTerminalSessionStateModelStreamConnectionTests`, not here. This host has no visibility
    /// into that classification either way — `inputFailureHandler` is injected exactly like it is for
    /// `SimulatedTransportFailure` and `SimulatedRejectionError` above — so this type exists only to let
    /// `testRequestTimeoutReportsFailureButDoesNotDiscardQueuedInput` document, at this layer, that a
    /// handler answering `false` for what is semantically a timeout must still report the failure while
    /// leaving the backlog queued, the same way it must for a coded rejection.
    private struct SimulatedTimeoutFailure: Error {}

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

    @MainActor private final class FocusableView: NSView { override var acceptsFirstResponder: Bool { true } }
    @MainActor private final class KeyTestWindow: NSWindow { override var isKeyWindow: Bool { true } }
    @MainActor private final class ActivatingTestWindow: NSWindow {
        var keyWindowState = false
        override var isKeyWindow: Bool { keyWindowState }
        override func makeKeyAndOrderFront(_ sender: Any?) { keyWindowState = true }
    }

    @MainActor private func searchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField, searchField.accessibilityIdentifier() == "terminal-search-field" { return searchField }
        for subview in view.subviews { if let searchField = searchField(in: subview) { return searchField } }
        return nil
    }

    @MainActor private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition.", file: file, line: line)
    }

    @MainActor func testRemoteMirrorForwardsModifiedBackspaceSpecs() throws {
        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: keyEvent(keyCode: UInt16(kVK_Delete))), "backspace")
        XCTAssertEqual(
            GhosttyMirrorTerminalView.remoteKeySpecifier(for: keyEvent(keyCode: UInt16(kVK_Delete), modifierFlags: .option)), "opt+backspace")
        XCTAssertEqual(
            GhosttyMirrorTerminalView.remoteKeySpecifier(for: keyEvent(keyCode: UInt16(kVK_Delete), modifierFlags: .command)), "cmd+backspace")
        XCTAssertEqual(
            GhosttyMirrorTerminalView.remoteKeySpecifier(
                for: keyEvent(keyCode: UInt16(kVK_Delete), modifierFlags: [.command, .numericPad, .function])), "cmd+backspace")
    }

    @MainActor func testRemoteMirrorMapsCommandKToClearScreenControl() throws {
        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: keyEvent(keyCode: UInt16(kVK_ANSI_K), modifierFlags: .command)), "cmd+k")
    }

    @MainActor func testRemoteMirrorClipboardPasteMarksTextAsPaste() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-paste", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        var sentText: [(String, Bool)] = []
        mirrorView.onSendText = { text, asPaste in sentText.append((text, asPaste)) }
        mirrorView.acceptsTerminalInput = true
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("remote-mirror-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        mirrorView.pasteboardOverrideForTesting = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("line one\nline two", forType: .string)

        XCTAssertTrue(mirrorView.pasteClipboardContents())

        XCTAssertEqual(sentText.count, 1)
        XCTAssertEqual(sentText.first?.0, "line one\nline two")
        XCTAssertEqual(sentText.first?.1, true)
    }

    // MARK: - Owner-targeted clipboard writes

    /// The product behavior: a program's copy inside the session lands on the clipboard of the machine
    /// the user is typing on. The daemon addresses the write to the owning client; this client owns the
    /// session, so it writes its own pasteboard.
    @MainActor func testOwnerAppliesAClipboardWriteAddressedToIt() throws {
        let fixture = try makeClipboardFixture(sessionID: "remote-clipboard-owner")
        defer { fixture.tearDown() }

        fixture.recorder.setPayload(clipboardPayload(sessionID: "remote-clipboard-owner", targetClientID: fixture.clientID, text: "copied text"))
        waitForCondition("owner applies the clipboard write") {
            _ = fixture.host.effectiveTitle
            return fixture.pasteboard.string(forType: .string) == "copied text"
        }
    }

    /// The write fans out to every subscriber of the session, so a client that is not its target must
    /// leave its own clipboard alone — otherwise a copy made on the Mac the user is typing on would also
    /// overwrite the clipboard of every other device watching the session.
    @MainActor func testNonTargetClientIgnoresAClipboardWrite() throws {
        let fixture = try makeClipboardFixture(sessionID: "remote-clipboard-other")
        defer { fixture.tearDown() }

        // The clipboard payload is not cached by the host (it is an event, not state), so a following
        // state payload the host DOES cache is the fence proving the clipboard payload was served first.
        fixture.recorder.setPayloads([
            clipboardPayload(sessionID: "remote-clipboard-other", targetClientID: "someone-elses-client", text: "not for us"),
            remoteStatePayloadWithTitle(sessionID: "remote-clipboard-other", reason: TerminalRemoteSessionStateReason.output, title: "settled"),
        ])
        waitForCondition("the payload after the clipboard write is applied") {
            _ = fixture.host.effectiveTitle
            return fixture.host.effectiveTitle == "settled"
        }
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
    }

    /// A clipboard write is an event, not state: the host applies the copy and reduces nothing, so an
    /// out-of-order one cannot regress the title, runtime state, or ownership the pane is showing.
    @MainActor func testClipboardWritePayloadDoesNotBecomeCachedState() throws {
        let fixture = try makeClipboardFixture(sessionID: "remote-clipboard-not-state")
        defer { fixture.tearDown() }

        fixture.recorder.setPayloads([
            clipboardPayload(sessionID: "remote-clipboard-not-state", targetClientID: fixture.clientID, text: "copied", title: "clipboard"),
            remoteStatePayloadWithTitle(sessionID: "remote-clipboard-not-state", reason: TerminalRemoteSessionStateReason.output, title: "settled"),
        ])
        waitForCondition("owner applies the clipboard write") {
            _ = fixture.host.effectiveTitle
            return fixture.pasteboard.string(forType: .string) == "copied"
        }
        waitForCondition("the payload after the clipboard write is applied") {
            _ = fixture.host.effectiveTitle
            return fixture.host.effectiveTitle == "settled"
        }
        XCTAssertNotEqual(fixture.host.effectiveTitle, "clipboard")
    }

    /// A clipboard write is a one-shot: it rides exactly the payload that announced it. The client's
    /// stored state drops the field on merge, so the payloads that follow — output, metadata, anything —
    /// must not re-paste the same text over whatever the user has copied since.
    @MainActor func testALaterPayloadDoesNotRepeatTheClipboardWrite() throws {
        let fixture = try makeClipboardFixture(sessionID: "remote-clipboard-once")
        defer { fixture.tearDown() }

        fixture.recorder.setPayload(clipboardPayload(sessionID: "remote-clipboard-once", targetClientID: fixture.clientID, text: "copied once"))
        waitForCondition("owner applies the clipboard write") {
            _ = fixture.host.effectiveTitle
            return fixture.pasteboard.string(forType: .string) == "copied once"
        }

        fixture.pasteboard.clearContents()
        fixture.recorder.setPayload(
            remoteStatePayloadWithTitle(sessionID: "remote-clipboard-once", reason: TerminalRemoteSessionStateReason.output, title: "later"))
        waitForCondition("the later payload is applied") {
            _ = fixture.host.effectiveTitle
            return fixture.host.effectiveTitle == "later"
        }
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
    }

    /// Another device took the session over. This pane's requested attachment mode still reads `.owner` —
    /// a demotion releases the surface without re-attaching as a viewer — so gating the copy on that mode
    /// would let a write addressed to the former owner land on this Mac's clipboard while somebody else
    /// owns the session. Ownership has to come from the state the host holds, which says otherwise.
    @MainActor func testDemotedOwnerIgnoresAClipboardWriteAddressedToIt() throws {
        let fixture = try makeClipboardFixture(sessionID: "remote-clipboard-demoted")
        defer { fixture.tearDown() }

        let takeover = payloadClaimingOwner(
            remoteStatePayloadWithTitle(
                sessionID: "remote-clipboard-demoted", reason: TerminalRemoteSessionStateReason.attachmentState, title: "taken-over"),
            ownerClientID: "another-mac")
        fixture.recorder.setPayloads([
            takeover, clipboardPayload(sessionID: "remote-clipboard-demoted", targetClientID: fixture.clientID, text: "not ours any more"),
            remoteStatePayloadWithTitle(sessionID: "remote-clipboard-demoted", reason: TerminalRemoteSessionStateReason.output, title: "settled"),
        ])
        waitForCondition("the takeover is applied") {
            _ = fixture.host.effectiveTitle
            return fixture.host.activeOwnerClientID() == "another-mac"
        }
        waitForCondition("the payload after the clipboard write is applied") {
            _ = fixture.host.effectiveTitle
            return fixture.host.effectiveTitle == "settled"
        }
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
    }

    private struct ClipboardFixture {
        let host: RemoteGhosttySessionHost
        let recorder: DirectTerminalServiceRecorder
        let pasteboard: NSPasteboard
        let clientID: String
        let tearDown: () -> Void
    }

    /// A running remote session this client owns, with a uniquely-named pasteboard injected so the tests
    /// never touch the developer's real clipboard.
    @MainActor private func makeClipboardFixture(sessionID: String) throws -> ClipboardFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        let clientID = "mac-owner-\(sessionID)"
        // The daemon's payload says this client owns the session, which is what the host reads to decide
        // it is the live owner — the attachment it requested is not evidence of that on its own.
        let ownerPayload = payloadClaimingOwner(fixture.payload, ownerClientID: clientID)
        let recorder = DirectTerminalServiceRecorder(payload: ownerPayload)
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: recorder.send)
        waitForCondition("host renders the running session") { host.snapshotText() != nil }

        try host.attach(
            client: TerminalClient(
                id: clientID, kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-28T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("remote-clipboard-\(UUID().uuidString)"))
        pasteboard.clearContents()
        host.clipboardPasteboardOverrideForTesting = pasteboard
        return ClipboardFixture(
            host: host, recorder: recorder, pasteboard: pasteboard, clientID: clientID,
            tearDown: {
                pasteboard.releaseGlobally()
                try? FileManager.default.removeItem(at: root)
            })
    }

    /// Re-emits a running payload with an attachment snapshot naming `ownerClientID` as the live owner.
    private func payloadClaimingOwner(_ payload: GhosttyRemoteSessionStatePayload, ownerClientID: String) -> GhosttyRemoteSessionStatePayload {
        let owner = TerminalClient(
            id: ownerClientID, kind: .localWindow, identity: TerminalClientIdentity(label: ownerClientID), connectedAt: "2026-07-28T00:00:00Z")
        return GhosttyRemoteSessionStatePayload(
            sessionID: payload.sessionID, reason: payload.reason, emittedAt: payload.emittedAt, sessionStateRevision: payload.sessionStateRevision,
            sessionStateFlags: payload.sessionStateFlags, screenStateRevision: payload.screenStateRevision, runtimeState: payload.runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                clients: [owner],
                attachments: [
                    TerminalAttachment(sessionID: payload.sessionID, clientID: ownerClientID, mode: .owner, attachedAt: "2026-07-28T00:00:00Z")
                ]), title: payload.title, workingDirectory: payload.workingDirectory, outputByteCount: payload.outputByteCount,
            outputEndByteOffset: payload.outputEndByteOffset, renderUpdate: payload.renderUpdate)
    }

    private func clipboardPayload(sessionID: String, targetClientID: String, text: String, title: String = "remote")
        -> GhosttyRemoteSessionStatePayload
    {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.clipboardWrite, emittedAt: "2026-07-28T00:00:03Z",
            sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: title,
            workingDirectory: "/tmp/work", outputByteCount: nil,
            clipboardWrite: TerminalClipboardWritePayload(targetClientID: targetClientID, text: text))
    }

    private func remoteStatePayloadWithTitle(sessionID: String, reason: String, title: String) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: reason, emittedAt: "2026-07-28T00:00:04Z", sessionStateRevision: nil, sessionStateFlags: nil,
            screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: title, workingDirectory: "/tmp/work", outputByteCount: nil)
    }

    @MainActor func testRemoteMirrorEncodesPreciseScrollMods() {
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .changed), 0b0000_0111)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended), 0b0000_1001)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .cancelled), 0b0000_1011)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .mayBegin), 0b0000_1101)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: []), 0b0000_0001)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: false, phase: []), 0)
    }

    @MainActor func testRemoteMirrorMapsMouseModifiersButtonsAndCoordinatesLikeGhosttyAppKitSurface() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let mods = GhosttyMirrorTerminalView.ghosttyMouseModifiers(for: flags).rawValue

        XCTAssertNotEqual(mods & GHOSTTY_MODS_SHIFT.rawValue, 0)
        XCTAssertNotEqual(mods & GHOSTTY_MODS_CTRL.rawValue, 0)
        XCTAssertNotEqual(mods & GHOSTTY_MODS_ALT.rawValue, 0)
        XCTAssertNotEqual(mods & GHOSTTY_MODS_SUPER.rawValue, 0)
        XCTAssertEqual(GhosttyMirrorTerminalView.ghosttyMouseButton(for: 0), GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(GhosttyMirrorTerminalView.ghosttyMouseButton(for: 1), GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(GhosttyMirrorTerminalView.ghosttyMouseButton(for: 2), GHOSTTY_MOUSE_MIDDLE)
        XCTAssertEqual(GhosttyMirrorTerminalView.ghosttyMouseButton(for: 3), GHOSTTY_MOUSE_EIGHT)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let view = NSView(frame: NSRect(x: 10, y: 20, width: 200, height: 100))
        container.addSubview(view)

        let position = GhosttyMirrorTerminalView.ghosttyMousePosition(for: NSPoint(x: 60, y: 70), in: view)
        let scrollPosition = GhosttyMirrorTerminalView.scrollPointerPosition(for: NSPoint(x: 60, y: 70), in: view, mods: mods)

        XCTAssertEqual(position.x, 50, accuracy: 0.01)
        XCTAssertEqual(position.y, 50, accuracy: 0.01)
        XCTAssertEqual(scrollPosition, .init(x: 0.25, y: 0.5, mods: mods))
    }

    @MainActor func testRemoteMirrorSuppressesFocusOnlyMouseClickBeforeForwarding() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-focus-only-mouse", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = ActivatingTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.addSubview(mirrorView)
        mirrorView.frame = container.bounds
        mirrorView.acceptsTerminalInput = true
        mirrorView.debugMouseEventHandler = { _ in true }
        defer { window.close() }

        XCTAssertFalse(window.isKeyWindow)

        mirrorView.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: window.windowNumber))
        mirrorView.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: window.windowNumber))

        XCTAssertTrue(window.isKeyWindow)
        XCTAssertEqual(mirrorView.debugRecordedMouseEvents, [])

        mirrorView.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: window.windowNumber))
        mirrorView.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: window.windowNumber))

        XCTAssertEqual(mirrorView.debugRecordedMouseEvents.count, 4)
        XCTAssertEqual(mirrorView.debugRecordedMouseEvents.first, "position")
        XCTAssertTrue(mirrorView.debugRecordedMouseEvents.contains("button:press:\(GHOSTTY_MOUSE_LEFT.rawValue)"))
        XCTAssertTrue(mirrorView.debugRecordedMouseEvents.contains("button:release:\(GHOSTTY_MOUSE_LEFT.rawValue)"))
    }

    /// A click belongs to the pane's own selection until the application on the other end takes the
    /// mouse; only then does it also travel to the session that can deliver it.
    @MainActor func testRemoteMirrorForwardsClicksOnlyWhileTheApplicationTracksTheMouse() throws {
        let mirrorView = try makeKeyWindowMirrorView(sessionID: "remote-mouse-forwarding")
        var forwarded: [(button: UInt8, pressed: Bool, pointer: TerminalScrollPointerPosition?)] = []
        mirrorView.view.onSendMouseButton = { button, pressed, pointer in forwarded.append((button, pressed, pointer)) }

        mirrorView.view.debugMouseCapturedForTesting = false
        mirrorView.view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: mirrorView.windowNumber))
        mirrorView.view.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: mirrorView.windowNumber))
        XCTAssertTrue(forwarded.isEmpty, "a click must stay local while nothing is tracking the mouse")

        mirrorView.view.debugMouseCapturedForTesting = true
        mirrorView.view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: mirrorView.windowNumber))
        mirrorView.view.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: mirrorView.windowNumber))

        XCTAssertEqual(forwarded.map(\.pressed), [true, false], "the application must see both the press and the release")
        XCTAssertEqual(forwarded.map(\.button), [UInt8(GHOSTTY_MOUSE_LEFT.rawValue), UInt8(GHOSTTY_MOUSE_LEFT.rawValue)])
        XCTAssertNotNil(forwarded.first?.pointer, "the click must carry the cell it landed on")
    }

    /// A session that exits with tracking still enabled leaves a final frame that says the
    /// application owns the mouse, but there is nothing left to receive a report: once the host
    /// marks the session non-interactive, clicks stay local.
    @MainActor func testRemoteMirrorStopsForwardingClicksOnceTheSessionEnds() throws {
        let mirrorView = try makeKeyWindowMirrorView(sessionID: "remote-mouse-ended")
        var forwardedCount = 0
        mirrorView.view.onSendMouseButton = { _, _, _ in forwardedCount += 1 }
        mirrorView.view.debugMouseCapturedForTesting = true

        mirrorView.view.sessionPermitsMouseCapture = false
        mirrorView.view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: mirrorView.windowNumber))
        mirrorView.view.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: mirrorView.windowNumber))

        XCTAssertEqual(forwardedCount, 0, "an ended session must not receive clicks its application can no longer read")
    }

    /// Shift is the escape hatch that keeps a click local so text can still be selected out of an
    /// application that has taken the mouse — unless that application explicitly asked for shift.
    @MainActor func testRemoteMirrorKeepsShiftClickLocalUnlessTheTerminalRequestsShiftCapture() throws {
        let mirrorView = try makeKeyWindowMirrorView(sessionID: "remote-mouse-shift")
        var forwardedCount = 0
        mirrorView.view.onSendMouseButton = { _, _, _ in forwardedCount += 1 }
        mirrorView.view.debugMouseCapturedForTesting = true
        mirrorView.view.debugRenderFrameApplyHandler = { _, _ in true }

        mirrorView.view.update(
            frame: GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha", mouseReportingActive: true)),
            renderStateKey: "runtime=5x1|frame=5x1|ownerEpoch=0")
        mirrorView.view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: mirrorView.windowNumber, modifierFlags: [.shift]))
        XCTAssertEqual(forwardedCount, 0, "shift-clicking must select text rather than report to the application")

        mirrorView.view.update(
            frame: GhosttyRenderFrame(
                sessionRevision: 2, ownerEpoch: 0,
                snapshot: snapshot(text: "alpha", mouseReportingActive: true, mouseShiftCapture: GhosttyTerminalSnapshot.mouseShiftCaptureEnabled)),
            renderStateKey: "runtime=5x1|frame=5x1|ownerEpoch=0")
        mirrorView.view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: mirrorView.windowNumber, modifierFlags: [.shift]))
        XCTAssertEqual(forwardedCount, 1, "a terminal that asks for shift capture must receive the shift-click")
    }

    /// Builds a mirror view in a key window with its mouse events shunted away from a real surface, which
    /// is what the focus-only-press suppression and the forwarding decision both need.
    @MainActor private func makeKeyWindowMirrorView(sessionID: String) throws -> (view: GhosttyMirrorTerminalView, windowNumber: Int) {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, createdAt: "2026-07-26T00:00:00Z",
            workspaceID: "workspace-1", kind: .shell)
        let view = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = ActivatingTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.addSubview(view)
        view.frame = container.bounds
        view.acceptsTerminalInput = true
        view.debugMouseEventHandler = { _ in true }
        addTeardownBlock { MainActor.assumeIsolated { window.close() } }
        // The first press only makes the window key; the pane's own handling starts after that.
        view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: window.windowNumber))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: window.windowNumber))
        XCTAssertTrue(window.isKeyWindow)
        return (view, window.windowNumber)
    }

    @MainActor func testRemoteMirrorDoesNotReapplyIdenticalRevisionedRenderFrame() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-idempotent-frame", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-06T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugRenderFrameApplyHandler = { _, _ in true }
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let nextFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 0, snapshot: snapshot(text: "beta"))

        mirrorView.update(frame: firstFrame, renderStateKey: "runtime=5x1|frame=5x1|ownerEpoch=0")
        mirrorView.update(frame: firstFrame, renderStateKey: "runtime=5x1|frame=5x1|ownerEpoch=0")
        mirrorView.update(frame: nextFrame, renderStateKey: "runtime=5x1|frame=5x1|ownerEpoch=0")
        mirrorView.update(frame: nextFrame, renderStateKey: "runtime=4x1|frame=4x1|ownerEpoch=0")

        XCTAssertEqual(mirrorView.debugRenderFrameApplyCount, 3)
    }

    @MainActor func testRemoteMirrorReappliesSameRevisionFrameWhenSnapshotChanges() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-same-revision-changed-frame", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugRenderFrameApplyHandler = { _, _ in true }
        let staleFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let correctedFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha\n% "))

        mirrorView.update(frame: staleFrame, renderStateKey: "runtime=5x2|frame=5x2|ownerEpoch=0")
        mirrorView.update(frame: correctedFrame, renderStateKey: "runtime=5x2|frame=5x2|ownerEpoch=0")

        XCTAssertEqual(mirrorView.debugRenderFrameApplyCount, 2)
    }

    @MainActor func testRemoteMirrorReappliesSnapshotFrameWhenContentChangesWithoutRevision() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-idempotent-snapshot", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-06T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugRenderFrameApplyHandler = { _, _ in true }
        let firstFrame = GhosttyRenderFrame(sessionRevision: nil, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let changedFrame = GhosttyRenderFrame(sessionRevision: nil, ownerEpoch: 0, snapshot: snapshot(text: "bravo"))

        mirrorView.update(frame: firstFrame, renderStateKey: "snapshot=5x1")
        mirrorView.update(frame: firstFrame, renderStateKey: "snapshot=5x1")
        mirrorView.update(frame: changedFrame, renderStateKey: "snapshot=5x1")

        XCTAssertEqual(mirrorView.debugRenderFrameApplyCount, 2)
    }

    @MainActor func testRemoteMirrorSearchActionEventsUpdateOverlayState() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-actions", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-02T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)

        mirrorView.applyActionEvent(.startSearch("needle"))
        mirrorView.applyActionEvent(.searchTotal(3))
        mirrorView.applyActionEvent(.searchSelected(1))

        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "needle")
        XCTAssertEqual(mirrorView.debugSearchState.total, 3)
        XCTAssertEqual(mirrorView.debugSearchState.selected, 1)

        mirrorView.applyActionEvent(.startSearch(nil))

        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "needle")

        mirrorView.applyActionEvent(.endSearch)

        XCTAssertFalse(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "")
    }

    @MainActor func testRemoteMirrorStartSearchWithNeedleSubmitsSeededQuery() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-selection", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugBindingActionHandler = { _ in true }

        mirrorView.applyActionEvent(.startSearch("selected-token"))

        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "selected-token")
        XCTAssertNil(mirrorView.debugSearchState.total)
        XCTAssertNil(mirrorView.debugSearchState.selected)
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:selected-token"])

        mirrorView.applyActionEvent(.startSearch(nil))

        XCTAssertEqual(mirrorView.debugSearchState.query, "selected-token")
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:selected-token"])
    }

    @MainActor func testRemoteMirrorIgnoresStaleSearchResultsAfterClose() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-stale-results", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugBindingActionHandler = { _ in true }

        mirrorView.applyActionEvent(.startSearch("needle"))
        mirrorView.applyActionEvent(.searchTotal(3))
        mirrorView.applyActionEvent(.searchSelected(1))
        XCTAssertEqual(mirrorView.debugSearchState.total, 3)
        XCTAssertEqual(mirrorView.debugSearchState.selected, 1)

        mirrorView.applyActionEvent(.endSearch)
        mirrorView.applyActionEvent(.searchTotal(9))
        mirrorView.applyActionEvent(.searchSelected(4))

        XCTAssertFalse(mirrorView.debugSearchState.isVisible)
        XCTAssertNil(mirrorView.debugSearchState.total)
        XCTAssertNil(mirrorView.debugSearchState.selected)

        mirrorView.applyActionEvent(.startSearch(nil))
        mirrorView.applyActionEvent(.searchTotal(9))
        mirrorView.applyActionEvent(.searchSelected(4))

        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "")
        XCTAssertNil(mirrorView.debugSearchState.total)
        XCTAssertNil(mirrorView.debugSearchState.selected)
    }

    @MainActor func testRemoteMirrorSearchFieldEditSubmitsQueryOnce() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-single-edit", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugBindingActionHandler = { _ in true }
        mirrorView.applyActionEvent(.startSearch(nil))
        let field = try XCTUnwrap(searchField(in: mirrorView))

        field.stringValue = "needle"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.sendAction(field.action, to: field.target)

        XCTAssertEqual(mirrorView.debugSearchState.query, "needle")
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:needle"])
    }

    @MainActor func testRemoteMirrorSearchFieldEditDebouncesShortQueries() async throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-short-debounce", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugBindingActionHandler = { _ in true }
        mirrorView.applyActionEvent(.startSearch(nil))
        let field = try XCTUnwrap(searchField(in: mirrorView))

        field.stringValue = "n"
        field.sendAction(field.action, to: field.target)
        await Task.yield()
        XCTAssertEqual(mirrorView.debugSearchState.query, "n")
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, [])

        field.stringValue = "ne"
        field.sendAction(field.action, to: field.target)
        await Task.yield()
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, [])

        try await waitUntil { mirrorView.debugRecordedBindingActions == ["search:ne"] }
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:ne"])

        field.stringValue = "nee"
        field.sendAction(field.action, to: field.target)

        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:ne", "search:nee"])
    }

    @MainActor func testRemoteMirrorReleaseSurfaceResetsSearchOverlay() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-release", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)

        mirrorView.applyActionEvent(.startSearch("needle"))
        mirrorView.applyActionEvent(.searchTotal(2))
        mirrorView.applyActionEvent(.searchSelected(0))
        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "needle")

        mirrorView.releaseSurface()

        XCTAssertFalse(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "")
        XCTAssertNil(mirrorView.debugSearchState.total)
        XCTAssertNil(mirrorView.debugSearchState.selected)
    }

    @MainActor func testRemoteMirrorInstallsMouseMoveTrackingArea() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-mouse-tracking", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)

        mirrorView.updateTrackingAreas()

        let trackingArea = mirrorView.trackingAreas.first { $0.owner === mirrorView }
        XCTAssertNotNil(trackingArea)
        XCTAssertEqual(trackingArea?.options.contains(.mouseMoved), true)
        XCTAssertEqual(trackingArea?.options.contains(.mouseEnteredAndExited), true)
        XCTAssertEqual(trackingArea?.options.contains(.activeAlways), true)
        XCTAssertEqual(trackingArea?.options.contains(.inVisibleRect), true)
    }

    @MainActor func testRemoteMirrorSearchOverlayDoesNotReserveBlankStatusOrLoseFocus() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-focus", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.addSubview(mirrorView)
        mirrorView.frame = container.bounds
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        mirrorView.acceptsTerminalInput = true
        XCTAssertTrue(window.firstResponder === mirrorView)

        mirrorView.applyActionEvent(.startSearch(nil))
        XCTAssertTrue(mirrorView.debugSearchFieldHasFocus)
        XCTAssertFalse(mirrorView.debugSearchStatusVisible)
        XCTAssertEqual(mirrorView.debugSearchUpBindingAction, "navigate_search:next")
        XCTAssertEqual(mirrorView.debugSearchDownBindingAction, "navigate_search:previous")

        mirrorView.focusWindow(window)

        XCTAssertTrue(mirrorView.debugSearchFieldHasFocus)

        mirrorView.acceptsTerminalInput = false
        mirrorView.acceptsTerminalInput = true

        XCTAssertTrue(mirrorView.debugSearchFieldHasFocus)

        mirrorView.applyActionEvent(.startSearch("missing"))
        mirrorView.applyActionEvent(.searchTotal(0))

        XCTAssertTrue(mirrorView.debugSearchStatusVisible)
    }

    /// The bell is a tag-only action, so the parser must recognize it from the tag alone — it carries no
    /// payload to validate, and an unrecognized tag is silently dropped.
    func testGhosttyActionEventParserParsesRingBell() {
        var bell = ghostty_action_s()
        bell.tag = GHOSTTY_ACTION_RING_BELL
        XCTAssertEqual(GhosttyActionEventParser.parse(bell), .ringBell)
    }

    func testGhosttyActionEventParserParsesSearchEvents() {
        var start = ghostty_action_s()
        start.tag = GHOSTTY_ACTION_START_SEARCH
        "needle".withCString { pointer in
            start.action.start_search.needle = pointer
            XCTAssertEqual(GhosttyActionEventParser.parse(start), .startSearch("needle"))
        }

        var end = ghostty_action_s()
        end.tag = GHOSTTY_ACTION_END_SEARCH
        XCTAssertEqual(GhosttyActionEventParser.parse(end), .endSearch)

        var total = ghostty_action_s()
        total.tag = GHOSTTY_ACTION_SEARCH_TOTAL
        total.action.search_total = ghostty_action_search_total_s(total: 4)
        XCTAssertEqual(GhosttyActionEventParser.parse(total), .searchTotal(4))
        total.action.search_total = ghostty_action_search_total_s(total: -1)
        XCTAssertEqual(GhosttyActionEventParser.parse(total), .searchTotal(nil))

        var selected = ghostty_action_s()
        selected.tag = GHOSTTY_ACTION_SEARCH_SELECTED
        selected.action.search_selected = ghostty_action_search_selected_s(selected: 2)
        XCTAssertEqual(GhosttyActionEventParser.parse(selected), .searchSelected(2))
        selected.action.search_selected = ghostty_action_search_selected_s(selected: -1)
        XCTAssertEqual(GhosttyActionEventParser.parse(selected), .searchSelected(nil))
    }

    func testGhosttyActionEventParserParsesOpenURLAndMouseOverLinkEvents() {
        var open = ghostty_action_s()
        open.tag = GHOSTTY_ACTION_OPEN_URL
        "https://example.com/image.png".withCString { pointer in
            open.action.open_url = ghostty_action_open_url_s(
                kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, url: pointer, len: UInt("https://example.com/image.png".utf8.count))
            XCTAssertEqual(GhosttyActionEventParser.parse(open), .openURL(kind: .text, value: "https://example.com/image.png"))
        }

        var hover = ghostty_action_s()
        hover.tag = GHOSTTY_ACTION_MOUSE_OVER_LINK
        "/tmp/screenshot.png".withCString { pointer in
            hover.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: pointer, len: "/tmp/screenshot.png".utf8.count)
            XCTAssertEqual(GhosttyActionEventParser.parse(hover), .mouseOverLink("/tmp/screenshot.png"))
        }

        hover.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: nil, len: 0)
        XCTAssertEqual(GhosttyActionEventParser.parse(hover), .mouseOverLink(nil))
    }

    @MainActor func testMirrorTerminalViewOpensSupportedLinksAndTracksHover() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-open-link", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-08T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        var openedURLs: [URL] = []
        mirrorView.debugOpenURLHandler = { url in
            openedURLs.append(url)
            return true
        }
        let macRecordingPath = "/Users/yogesh/Desktop/Screen Recording 2026-05-07 at 10.11.01\u{202F}AM.mov"

        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "/tmp/screenshot.png"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "file:///tmp/movie.mp4"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "file://localhost/tmp/local-report.png"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: macRecordingPath))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "file://build-host/tmp/remote-report.png"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "https://example.com/report"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "relative/path.png"))

        let openedLinkRepresentations = openedURLs.map { url in url.isFileURL ? url.path : url.absoluteString }
        XCTAssertEqual(openedURLs.count, 5)
        XCTAssertEqual(
            openedLinkRepresentations,
            ["/tmp/screenshot.png", "/tmp/movie.mp4", "/tmp/local-report.png", macRecordingPath, "https://example.com/report"])

        mirrorView.applyActionEvent(.mouseOverLink("https://example.com/report"))
        XCTAssertEqual(mirrorView.debugHoveredLink, "https://example.com/report")
        mirrorView.applyActionEvent(.mouseOverLink(nil))
        XCTAssertNil(mirrorView.debugHoveredLink)
    }

    @MainActor func testMirrorTerminalViewOnOpenLinkTakesPrecedenceOverLegacyOpener() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-on-open-link", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-08T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        var routedLinks: [String] = []
        var legacyOpens = 0
        // When `onOpenLink` is set it fully replaces the legacy local-only opener path, so the
        // per-pane coordinator can route web/loopback/remote-file clicks. The legacy
        // `debugOpenURLHandler` seam must not fire.
        mirrorView.onOpenLink = { routedLinks.append($0) }
        mirrorView.debugOpenURLHandler = { _ in
            legacyOpens += 1
            return true
        }

        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "https://example.com/report"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "/tmp/screenshot.png"))

        XCTAssertEqual(routedLinks, ["https://example.com/report", "/tmp/screenshot.png"])
        XCTAssertEqual(legacyOpens, 0)
    }

    @MainActor func testRemoteMirrorWindowKeyHandoffRestoresFirstResponderAndSendsEnter() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-key-handoff", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-02T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.addSubview(mirrorView)
        mirrorView.frame = container.bounds
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let dummyResponder = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(dummyResponder)
        var sentKeys: [String] = []
        mirrorView.acceptsTerminalInput = true
        mirrorView.onSendKey = { sentKeys.append($0) }
        XCTAssertTrue(window.makeFirstResponder(dummyResponder))
        XCTAssertTrue(window.firstResponder === dummyResponder)

        XCTAssertTrue(mirrorView.handleTerminalKeyEvent(keyEvent(keyCode: UInt16(kVK_Return)), requireFirstResponder: false))

        XCTAssertEqual(sentKeys, ["enter"])
        XCTAssertTrue(window.firstResponder === mirrorView)
    }

    func testSnapshotTextCaptureReadsVisibleViewport() {
        let selection = GhosttyTerminalSnapshotCapture.visibleViewportSelection(columns: 80, rows: 24)

        XCTAssertEqual(selection.top_left.tag, GHOSTTY_POINT_VIEWPORT)
        XCTAssertEqual(selection.top_left.coord, GHOSTTY_POINT_COORD_TOP_LEFT)
        XCTAssertEqual(selection.bottom_right.tag, GHOSTTY_POINT_VIEWPORT)
        XCTAssertEqual(selection.bottom_right.coord, GHOSTTY_POINT_COORD_BOTTOM_RIGHT)
    }

    func testRemoteHostSendsResizeWhenRuntimeStillHasPreviousOwnerSize() {
        XCTAssertTrue(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: (columns: 120, rows: 40), pendingSize: nil,
                runtimeSize: (columns: 60, rows: 20), force: false))
        XCTAssertFalse(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: (columns: 120, rows: 40), pendingSize: nil,
                runtimeSize: (columns: 120, rows: 40), force: false))
        XCTAssertFalse(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: nil, pendingSize: (columns: 120, rows: 40),
                runtimeSize: (columns: 60, rows: 20), force: false))
        XCTAssertTrue(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: nil, pendingSize: (columns: 120, rows: 40),
                runtimeSize: (columns: 60, rows: 20), force: true))
    }

    /// Re-attaching as owner is not itself a reason to resize. An attach that finds the same surface at the
    /// size the session already runs at sends nothing — every refocus of an open pane re-attaches, and the
    /// daemon answers such a resize by early-outing as a no-op after a control hop onto the queue that
    /// carries every session's keystrokes. The attach's force, which it sets when the mirror surface was
    /// rebuilt, cannot revive a request the session's own size proves is a no-op; what it does is override
    /// the two skips that assume the last requested size still describes a live surface.
    func testOwnerAttachResendsTheViewportOnlyForARebuiltSurface() {
        // Same size, already attached, and the session runs at that size: nothing to say, rebuilt or not.
        for force in [false, true] {
            XCTAssertFalse(
                RemoteGhosttySessionHost.shouldSendViewportResize(
                    requestedSize: (columns: 120, rows: 40), lastRequestedSize: (columns: 120, rows: 40), pendingSize: nil,
                    runtimeSize: (columns: 120, rows: 40), force: force))
        }
        // A rebuilt surface with no observed session size: the last requested size was measured against a
        // surface that no longer exists, so the attach re-sends rather than trusting it.
        XCTAssertFalse(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: (columns: 120, rows: 40), pendingSize: nil, runtimeSize: nil, force: false
            ))
        XCTAssertTrue(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: (columns: 120, rows: 40), pendingSize: nil, runtimeSize: nil, force: true)
        )
        // A first owner attach has requested no size yet, so it sends without needing the force.
        XCTAssertTrue(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: nil, pendingSize: nil, runtimeSize: (columns: 120, rows: 40), force: false
            ))
    }

    @MainActor func testStateStreamClientPreservesOutputBeforeInputOutputResync() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-state-stream-preserve-events")
        let initialPayload = remoteStatePayload(sessionID: "stream-preserve-events", reason: TerminalRemoteSessionStateReason.initial)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }

        waitForCondition("initial stream payload") { receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        receivedPayloads.removeAll()

        server.broadcast(
            remoteStatePayload(
                sessionID: "stream-preserve-events", reason: TerminalRemoteSessionStateReason.output, outputByteCount: 11, outputEndByteOffset: 42))
        server.broadcast(remoteStatePayload(sessionID: "stream-preserve-events", reason: TerminalRemoteSessionStateReason.inputOutput))

        waitForCondition("output before input-output resync") {
            receivedPayloads.count >= 2 && receivedPayloads[0].reason == TerminalRemoteSessionStateReason.output
                && receivedPayloads[1].reason == TerminalRemoteSessionStateReason.inputOutput
        }
        XCTAssertEqual(receivedPayloads[0].outputByteCount, 11)
        XCTAssertEqual(receivedPayloads[0].outputEndByteOffset, 42)
    }

    @MainActor func testEndedRemoteHostRendersFinalStateFromRequestSender() throws {
        // The final render of an ended session comes from the owning device's `.state`
        // response, not a local `spaces.db` mirror. The host renders it in memory and
        // writes no mirror row.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-final-reentry"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-04T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-04T00:00:01Z",
            exitedAt: "2026-06-04T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 5, rows: 1)
        let recorder = DirectTerminalServiceRecorder(
            payload: GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-04T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "done", sessionRevision: 1)))

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send)
        waitForCondition("ended host renders final state") { host.snapshotText() == "done" }
        XCTAssertEqual(host.effectiveTitle, "final-title")
        XCTAssertEqual(host.snapshotText(), "done")
        XCTAssertThrowsError(try TerminalSessionPersistence.readRemoteSessionState(paths: paths))
    }

    @MainActor func testEndedRemoteHostPermitsReadOnlyBindingsForFinalRenderViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-final-read-only-bindings"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-05T00:00:01Z",
            exitedAt: "2026-06-05T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 4, rows: 1)
        let recorder = DirectTerminalServiceRecorder(
            payload: GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-05T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "done", sessionRevision: 1)))

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send)
        waitForCondition("ended host renders final state") { host.snapshotText() == "done" }
        host.debugSetBindingActionHandler { _ in true }
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        XCTAssertEqual(host.snapshotText(), "done")
        XCTAssertTrue(host.performBindingAction("select_all"))
        XCTAssertTrue(host.performBindingAction("copy_to_clipboard"))
        XCTAssertTrue(host.performBindingAction("end_search"))
        XCTAssertFalse(host.performBindingAction("start_search"))
        XCTAssertFalse(host.performBindingAction("search:done"))
        XCTAssertFalse(host.performBindingAction("clear_screen"))
        XCTAssertEqual(host.debugRecordedBindingActions, ["select_all", "copy_to_clipboard", "end_search"])
    }

    @MainActor func testEndedRemoteHostScrollsIntoScrollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-ended-scrollback"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        // Final frame + runtime grid at 8x5 so the replay wraps like the ended pane's final frame and a
        // scrolled viewport shows several transcript lines.
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-05T00:00:01Z",
            exitedAt: "2026-06-05T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let finalText = "final-01\nfinal-02\nfinal-03\nfinal-04\nfinal-05"
        let recorder = DirectTerminalServiceRecorder(
            payload: GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-05T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: finalText, sessionRevision: 1)))

        // The session's full transcript survives in output.log: 200 CRLF-terminated numbered lines.
        let transcript = Data((1...200).map { String(format: "row-%03d", $0) }.joined(separator: "\r\n").utf8)

        // The transcript reports the ended run's identity, matching the run the replay arms against, so
        // it replays normally (the positive counterpart to the mismatched-identity rejection test).
        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _ in RemoteGhosttyTranscript(data: transcript, runIdentity: runtimeState.runIdentity) })
        waitForCondition("ended host renders final state") { host.snapshotText()?.contains("final-01") == true }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        // A positive vertical with precise deltas scrolls up into scrollback (the normalizer maps it to
        // a negative row delta). The scroll is accepted immediately; the replay frame lands async.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        waitForCondition("ended host reveals earlier scrollback lines") {
            guard let text = host.snapshotText() else { return false }
            return text.contains("row-0") && !text.contains("row-200") && !text.contains("final-01")
        }

        // Refresh and re-attach are how pane refreshNow paths repaint an ended pane; while the replay
        // is showing a scrolled viewport they must not clobber it with the daemon's final frame.
        host.requestSurfaceRefresh()
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        guard let text = host.snapshotText() else { return XCTFail("ended host lost its rendered surface after refresh") }
        XCTAssertTrue(text.contains("row-0"), "refresh clobbered the scrolled ended viewport: \(text)")
        XCTAssertFalse(text.contains("final-01"), "re-attach restored the final frame over the scrolled viewport: \(text)")
    }

    @MainActor func testEndedRemoteHostRetriesTranscriptFetchAfterTransientFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-ended-scrollback-retry"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-05T00:00:01Z",
            exitedAt: "2026-06-05T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let finalText = "final-01\nfinal-02\nfinal-03\nfinal-04\nfinal-05"
        let recorder = DirectTerminalServiceRecorder(
            payload: GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-05T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: finalText, sessionRevision: 1)))

        let transcript = Data((1...200).map { String(format: "row-%03d", $0) }.joined(separator: "\r\n").utf8)
        // The first fetch fails like a transport timeout would; the host must return to idle and
        // retry on a later scroll gesture instead of latching scrollback unavailable.
        let attempts = TranscriptFetchAttempts()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _ in
                if attempts.next() == 1 { throw POSIXError(.ETIMEDOUT) }
                return RemoteGhosttyTranscript(data: transcript, runIdentity: runtimeState.runIdentity)
            })
        waitForCondition("ended host renders final state") { host.snapshotText()?.contains("final-01") == true }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        waitForCondition("ended host retries the transcript fetch and scrolls into scrollback", timeout: 4) {
            _ = host.sendScroll(horizontal: 0, vertical: 400, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            guard let text = host.snapshotText() else { return false }
            return text.contains("row-0") && !text.contains("final-01")
        }
        XCTAssertGreaterThanOrEqual(attempts.count, 2, "the failed first fetch should have been retried")
    }

    @MainActor func testEndedRemoteHostRepaintsScrolledReplayAfterSurfaceReleaseAndReattach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-ended-scrollback-release-reattach"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-05T00:00:01Z",
            exitedAt: "2026-06-05T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let finalText = "final-01\nfinal-02\nfinal-03\nfinal-04\nfinal-05"
        let recorder = DirectTerminalServiceRecorder(
            payload: GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-05T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: finalText, sessionRevision: 1)))
        let transcript = Data((1...200).map { String(format: "row-%03d", $0) }.joined(separator: "\r\n").utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _ in RemoteGhosttyTranscript(data: transcript, runIdentity: runtimeState.runIdentity) })
        waitForCondition("ended host renders final state") { host.snapshotText()?.contains("final-01") == true }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
            mode: .viewer, into: container)

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("ended host reveals earlier scrollback lines") {
            guard let text = host.snapshotText() else { return false }
            return text.contains("row-0") && !text.contains("final-01")
        }

        // The pane controller releases the mirror surface (clearing its rendered frame) before it
        // reattaches an ended viewer during lifecycle transitions. The replay guard suppresses the
        // live-frame repaint, so the recreated surface must be repainted from the scrolled replay
        // instead of being left blank until the next scroll gesture.
        host.releaseRendererSurface()
        XCTAssertFalse(host.hasRenderableSurface())

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
            mode: .viewer, into: container)
        host.requestSurfaceRefresh()

        guard let text = host.snapshotText() else { return XCTFail("released-and-reattached ended surface stayed blank") }
        XCTAssertTrue(text.contains("row-0"), "re-attach did not repaint the scrolled replay viewport: \(text)")
        XCTAssertFalse(text.contains("final-01"), "re-attach restored the final frame over the scrolled viewport: \(text)")
        XCTAssertTrue(host.hasRenderableSurface(), "released-and-reattached ended surface did not become renderable again")
    }

    @MainActor func testEndedRemoteHostRejectsStaleTranscriptFetchAcrossRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-ended-scrollback-relaunch"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        // The ended run's final frame and the relaunched (running) run share the 8x5 grid so the
        // replay wraps like the ended pane's final frame.
        let exitedState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-05T00:00:01Z",
            exitedAt: "2026-06-05T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let runningState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 3, state: .running, updatedAt: "2026-06-05T00:00:02Z",
            title: "live-title", workingDirectory: "/tmp/live", columns: 8, rows: 5)
        let endedPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-05T00:00:01Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: exitedState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "final-01", sessionRevision: 1))
        let runningPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-06-05T00:00:02Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runningState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "live-title", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "RUNNING", sessionRevision: 2))
        let recorder = DirectTerminalServiceRecorder(payload: endedPayload)

        // Each fetch suspends until the test resolves it, so the test controls when the OLD run's
        // transcript resumes relative to the relaunch and the NEW run's fetch.
        let transcriptGate = ManualTranscriptProvider()
        let oldTranscript = Data((1...200).map { String(format: "OLD-%04d", $0) }.joined(separator: "\r\n").utf8)
        let newTranscript = Data((1...200).map { String(format: "NEW-%04d", $0) }.joined(separator: "\r\n").utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _ in try await transcriptGate.fetch() })
        waitForCondition("ended host renders final state") { host.snapshotText()?.contains("final-01") == true }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        // Fetch A begins for the first ended run and suspends on the gate.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("first transcript fetch is in flight") { transcriptGate.pendingCount >= 1 }

        // The session relaunches (interactive again), which discards the ended replay and bumps the
        // load generation while fetch A is still suspended.
        recorder.setPayload(runningPayload)
        waitForCondition("session relaunches into a running frame") {
            host.requestSurfaceRefresh()
            return host.snapshotText()?.contains("RUNNING") == true
        }

        // The relaunched session exits again, arming a fresh ended replay.
        recorder.setPayload(endedPayload)
        waitForCondition("relaunched session exits again") {
            host.requestSurfaceRefresh()
            guard let text = host.snapshotText() else { return false }
            return text.contains("final-01") && !text.contains("RUNNING")
        }

        // Fetch B begins for the second ended run and suspends on the gate.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("second transcript fetch is in flight") { transcriptGate.pendingCount >= 2 }

        // Resolve fetch A last: its stale OLD-run transcript must not install under the new run.
        transcriptGate.resolveNext(with: oldTranscript)
        // Give the rejected continuation time to run, then confirm the OLD run never rendered.
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(host.snapshotText()?.contains("OLD-") == true, "stale OLD-run transcript replaced the current viewport")

        // Resolve fetch B: the current run's transcript replays and scrolls into scrollback.
        transcriptGate.resolveNext(with: newTranscript)
        waitForCondition("current-run transcript scrolls into scrollback", timeout: 4) {
            _ = host.sendScroll(horizontal: 0, vertical: 400, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            guard let text = host.snapshotText() else { return false }
            return text.contains("NEW-") && !text.contains("OLD-") && !text.contains("final-01")
        }
    }

    @MainActor func testEndedRemoteHostDiscardsStaleReplayWhenNewerEndedRunArrivesUnobserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-ended-scrollback-unobserved-relaunch"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        // Two ended runs of the same session on the shared 8x5 grid. The client never observes the
        // interactive frame between them (disconnected, or between refreshes), so both observed payloads
        // are `.exited`; only the run identity (childPID + exitedAt) distinguishes them.
        let exitedStateA = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-05T00:00:01Z",
            exitedAt: "2026-06-05T00:00:01Z", title: "final-title-A", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let exitedStateB = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 4, state: .exited, updatedAt: "2026-06-05T00:00:02Z",
            exitedAt: "2026-06-05T00:00:02Z", title: "final-title-B", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let endedPayloadA = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-05T00:00:01Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: exitedStateA, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "final-title-A", workingDirectory: "/tmp/final", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "final-A", sessionRevision: 1))
        let endedPayloadB = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-05T00:00:02Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: exitedStateB, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "final-title-B", workingDirectory: "/tmp/final", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "final-B", sessionRevision: 2))
        let recorder = DirectTerminalServiceRecorder(payload: endedPayloadA)

        // The first fetch returns run A's transcript, the second run B's, so the test can prove the
        // replay is re-fetched for the new run rather than reusing the stale run's rows. Counting the
        // attempts confirms the second scroll actually re-issues the fetch after the discard.
        let attempts = TranscriptFetchAttempts()
        let transcriptA = Data((1...200).map { String(format: "OLDRUN-%04d", $0) }.joined(separator: "\r\n").utf8)
        let transcriptB = Data((1...200).map { String(format: "NEWRUN-%04d", $0) }.joined(separator: "\r\n").utf8)

        // Each fetch reports the run identity of the run it belongs to (A's first, B's second), matching
        // whichever run the replay is armed against, so identity never blocks the discard-and-re-fetch.
        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _ in
                attempts.next() == 1
                    ? RemoteGhosttyTranscript(data: transcriptA, runIdentity: exitedStateA.runIdentity)
                    : RemoteGhosttyTranscript(data: transcriptB, runIdentity: exitedStateB.runIdentity)
            })
        waitForCondition("ended host renders run A final state") { host.snapshotText()?.contains("final-A") == true }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        // Scroll run A into its transcript replay; the scrolled viewport shows the old run's rows.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("run A transcript scrolls into scrollback") {
            guard let text = host.snapshotText() else { return false }
            return text.contains("OLDRUN-") && !text.contains("final-A")
        }
        XCTAssertEqual(attempts.count, 1, "run A should have fetched its transcript exactly once")

        // The session relaunched and exited again without this client ever seeing the interactive frame:
        // the next observed payload is another ended run. The stale replay must be discarded so the new
        // run's final frame renders instead of the previous run's transcript continuing to suppress it.
        recorder.setPayload(endedPayloadB)
        waitForCondition("run B final frame replaces the stale run A replay") {
            host.requestSurfaceRefresh()
            guard let text = host.snapshotText() else { return false }
            return text.contains("final-B") && !text.contains("OLDRUN-")
        }

        // Scrolling again arms a fresh replay for run B, which re-fetches the transcript (a second
        // attempt) and shows the new run's rows, not the stale ones.
        waitForCondition("run B transcript re-fetches and scrolls into scrollback", timeout: 4) {
            _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            guard let text = host.snapshotText() else { return false }
            return text.contains("NEWRUN-") && !text.contains("OLDRUN-") && !text.contains("final-B")
        }
        XCTAssertGreaterThanOrEqual(attempts.count, 2, "the new ended run should have re-fetched its own transcript")
    }

    @MainActor func testEndedRemoteHostRejectsTranscriptReportedForADifferentRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-ended-scrollback-mismatched-identity"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        // The replay arms against run A (childPID 2, exitedAt T1) shown as "final-A".
        let exitedStateA = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-05T00:00:01Z",
            exitedAt: "2026-06-05T00:00:01Z", title: "final-title-A", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let recorder = DirectTerminalServiceRecorder(
            payload: GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-05T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: exitedStateA, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-title-A", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "final-A", sessionRevision: 1)))

        // The fetch resolves with a transcript the server read from a *different* run (childPID 4,
        // exitedAt T2): the session relaunched after the fetch started but before this client observed a
        // new state payload, truncating output.log so the bytes belong to the newer run. The host must
        // reject it by the reported run identity — the armed run's transcript is definitively gone.
        let attempts = TranscriptFetchAttempts()
        let newRunTranscript = Data((1...200).map { String(format: "NEWRUN-%04d", $0) }.joined(separator: "\r\n").utf8)
        let differentRunIdentity = "4|2026-06-05T00:00:02Z"
        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _ in
                _ = attempts.next()
                return RemoteGhosttyTranscript(data: newRunTranscript, runIdentity: differentRunIdentity)
            })
        waitForCondition("ended host renders run A final state") { host.snapshotText()?.contains("final-A") == true }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        // The scroll arms the replay and fetches; the mismatched-identity response latches `.unavailable`.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("mismatched-identity transcript fetch completes") { attempts.count >= 1 }

        // The viewport keeps the run A final frame and never shows the rejected new run's rows.
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard let text = host.snapshotText() else { return XCTFail("ended host lost its rendered surface") }
        XCTAssertTrue(text.contains("final-A"), "the armed run's final frame was replaced: \(text)")
        XCTAssertFalse(text.contains("NEWRUN-"), "the mismatched-run transcript replaced the viewport: \(text)")

        // Further scroll gestures must not re-fetch: `.unavailable` latched, so the attempt count stays 1.
        for _ in 0..<5 {
            _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(attempts.count, 1, "a mismatched-identity rejection must latch .unavailable and not re-fetch")
        XCTAssertFalse(host.snapshotText()?.contains("NEWRUN-") == true, "the rejected transcript must never render")
    }

    @MainActor func testRunningRemoteHostRejectsViewerBindingActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-running-viewer-bindings"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "live", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try seedSessionRow(sessionID: sessionID, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-06-05T00:00:01Z",
                title: "live", workingDirectory: "/tmp/work", columns: 4, rows: 1), paths: paths)

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths)
        host.debugSetBindingActionHandler { _ in true }
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        XCTAssertFalse(host.performBindingAction("select_all"))
        XCTAssertFalse(host.performBindingAction("copy_to_clipboard"))
        XCTAssertFalse(host.performBindingAction("end_search"))
        XCTAssertEqual(host.debugRecordedBindingActions, [])
    }

    @MainActor func testRemoteHostIgnoresStaleFinalStateWhenRuntimeIsRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-stale-final-live"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-04T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runningState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-06-04T00:00:02Z",
            title: "live-title", workingDirectory: "/tmp/live", columns: 4, rows: 1)
        let staleExitedState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-04T00:00:01Z",
            exitedAt: "2026-06-04T00:00:01Z", title: "stale-title", workingDirectory: "/tmp/stale", columns: 5, rows: 1)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runningState, paths: paths)
        try TerminalSessionPersistence.writeRemoteSessionState(
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-04T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: staleExitedState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "stale-title", workingDirectory: "/tmp/stale", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "stale", sessionRevision: 1)), paths: paths)

        let liveRenderUpdate = try renderUpdate(text: "live", sessionRevision: 2)
        let server = GhosttyRemoteSessionStateStreamServer(
            socketPath: paths.subscriptionSocketPath, queue: DispatchQueue(label: "spaces.remote-device.stale-final-live-test")
        ) {
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-06-04T00:00:02Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runningState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "live-title", workingDirectory: "/tmp/live", outputByteCount: nil, renderUpdate: liveRenderUpdate)
        }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths)

        waitForCondition("live stream supersedes stale final state") { host.snapshotText() == "live" }
        XCTAssertEqual(host.effectiveTitle, "live-title")
    }

    @MainActor func testStateStreamClientReceivesRenderUpdatePayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "stream-render-update", reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-06-03T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "live",
            workingDirectory: "/tmp/live", outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
        let server = GhosttyRemoteSessionStateStreamServer(
            socketPath: paths.subscriptionSocketPath, queue: DispatchQueue(label: "spaces.remote-state-stream-render-update-only")
        ) { initialPayload }
        try server.start()
        defer { server.stop() }

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(
            socketPath: paths.subscriptionSocketPath, onEvent: { payload in receivedPayloads.append(payload) })
        try client.start()
        defer { client.stop() }

        waitForCondition("render-update stream payload") { receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        let payload = try XCTUnwrap(receivedPayloads.first { $0.reason == TerminalRemoteSessionStateReason.initial })
        XCTAssertNotNil(payload.renderUpdate)
        let snapshot = try XCTUnwrap(payload.renderSnapshot)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: snapshot), "alpha")
    }

    func testStateStreamClientDoesNotCoalesceDeltaRenderUpdatePayloads() throws {
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let secondFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 0, snapshot: snapshot(text: "bravo"))
        let thirdFrame = GhosttyRenderFrame(sessionRevision: 3, ownerEpoch: 0, snapshot: snapshot(text: "charl"))
        let firstBaseline = GhosttyRenderUpdateBaseline(frame: firstFrame)
        let firstDelta = GhosttyRenderUpdateFactory.makeUpdate(target: secondFrame, baseline: firstBaseline)
        let secondBaseline = try GhosttyRenderUpdateApplier.apply(firstDelta, to: firstBaseline)
        let secondDelta = GhosttyRenderUpdateFactory.makeUpdate(target: thirdFrame, baseline: secondBaseline)
        XCTAssertEqual(firstDelta.kind, .delta)
        XCTAssertEqual(secondDelta.kind, .delta)

        func payload(_ update: GhosttyRenderUpdate, revision: UInt64) throws -> GhosttyRemoteSessionStatePayload {
            GhosttyRemoteSessionStatePayload(
                sessionID: "stream-delta-coalescing", reason: TerminalRemoteSessionStateReason.stateChange,
                emittedAt: "2026-06-03T00:00:0\(revision)Z", sessionStateRevision: revision, sessionStateFlags: 1, screenStateRevision: revision,
                runtimeState: nil, attachmentSnapshot: nil, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(update))
        }

        let pendingDeltaPayload = try payload(firstDelta, revision: 2)
        let incomingDeltaPayload = try payload(secondDelta, revision: 3)
        let incomingFullPayload = try payload(.full(thirdFrame), revision: 3)
        let pendingMetadataPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "stream-delta-coalescing", reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-06-03T00:00:01Z",
            sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "live",
            workingDirectory: "/tmp/live", outputByteCount: nil)

        XCTAssertFalse(GhosttyRemoteSessionStateStreamClient.canCoalescePendingEvent(pendingDeltaPayload, with: incomingDeltaPayload))
        XCTAssertFalse(GhosttyRemoteSessionStateStreamClient.canCoalescePendingEvent(pendingDeltaPayload, with: incomingFullPayload))
        XCTAssertFalse(GhosttyRemoteSessionStateStreamClient.canCoalescePendingEvent(pendingMetadataPayload, with: incomingDeltaPayload))
        XCTAssertTrue(GhosttyRemoteSessionStateStreamClient.canCoalescePendingEvent(pendingMetadataPayload, with: pendingMetadataPayload))
    }

    @MainActor func testRemoteHostPrefersRenderFrameSnapshotWhenAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.stream-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-live", reason: "initial", emittedAt: "2026-05-18T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-live", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-18T00:00:00Z",
                title: "live", workingDirectory: "/tmp/live", columns: 5, rows: 1), attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "live", workingDirectory: "/tmp/live", outputByteCount: nil, renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-live", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-18T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        waitForCondition("initial live snapshot") { host.snapshotText() == "alpha" }
        XCTAssertEqual(host.effectiveTitle, "live")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/live")

        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-live", reason: "output", emittedAt: "2026-05-18T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1,
                screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-live", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-18T00:00:01Z", title: "live", workingDirectory: "/tmp/live", columns: 4, rows: 2),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: 9,
                renderUpdate: try renderUpdate(text: "beta\ngamm", sessionRevision: 2)))

        waitForCondition("updated live snapshot") { host.snapshotText() == "beta\ngamm" }
        XCTAssertEqual(host.snapshot()?.rows, 2)

        let ownerClient = TerminalClient(
            id: "owner-client", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPad"), connectedAt: "2026-05-18T00:00:02Z")
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [ownerClient],
            attachments: [TerminalAttachment(sessionID: "remote-live", clientID: ownerClient.id, mode: .owner, attachedAt: "2026-05-18T00:00:02Z")])
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-live", reason: "attachment_state", emittedAt: "2026-05-18T00:00:02Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: attachmentSnapshot, title: "live",
                workingDirectory: "/tmp/live", outputByteCount: nil))

        waitForCondition("owner update without snapshot") { host.activeOwnerClientID() == ownerClient.id }
        XCTAssertEqual(host.snapshotText(), "beta\ngamm")
        XCTAssertNil(host.snapshot())
    }

    @MainActor func testRemoteHostDoesNotUseOutputLogWhenSnapshotSizeIsStale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try seedSessionRow(sessionID: "remote-stale-size", paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-stale-size", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-22T00:00:00Z", columns: 12, rows: 2), paths: paths)
        try "from-log\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-stale-size", reason: "resize", emittedAt: "2026-05-22T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-stale-size", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-22T00:00:00Z", title: "live", workingDirectory: "/tmp/live", columns: 12, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "tiny", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(
            socketPath: paths.subscriptionSocketPath, queue: DispatchQueue(label: "spaces.remote-device.stale-size-test")
        ) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-stale-size", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-22T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse((host.snapshotText() ?? "").contains("from-log"))
        XCTAssertFalse(host.snapshotText()?.contains("tiny") == true)
    }

    @MainActor func testRemoteHostDoesNotBuildTerminalRenderFromOutputLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try seedSessionRow(sessionID: "remote-render", paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-render", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-17T00:00:00Z",
                columns: 4, rows: 2), paths: paths)
        let transcript = "\u{001B}[31mAB\u{001B}[0mCD\u{001B}[2;1HEF"
        try transcript.write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-render", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        XCTAssertNil(host.snapshot())
        XCTAssertNil(host.snapshotText())
    }

    @MainActor func testRemoteHostIgnoresOutputLogChangesWithoutRenderFrameSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try seedSessionRow(sessionID: "remote-truncate", paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-truncate", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-17T00:00:00Z", columns: 8, rows: 2), paths: paths)
        try "hello world".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-truncate", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        XCTAssertNil(host.snapshotText())

        try "reset".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        XCTAssertNil(host.snapshotText())
    }

    @MainActor func testRemoteHostExposesViewerSnapshotWhenLiveStateIsAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.renderable-viewer-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-renderable", reason: "initial", emittedAt: "2026-05-19T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-renderable", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-19T00:00:00Z", title: "renderable", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "renderable", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-renderable", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-19T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-19T00:00:00Z"),
            mode: .viewer, into: container)

        waitForCondition("rendered viewer text") { (host.snapshotText() ?? "").contains("alpha") }

        XCTAssertTrue((host.snapshotText() ?? "").contains("beta"))
        if host.hasRenderableSurface() { XCTAssertTrue(normalize(host.debugVisibleSurfaceText()).contains("alpha")) }
    }

    /// Render frames arrive continuously, so the mirror may reclaim first responder only when
    /// focus fell back to the window itself (the state re-parenting leaves behind). A frame
    /// update must never steal focus from another focused control — that is exactly how the
    /// tab-rename editor and sidebar editors used to lose their editing session.
    @MainActor func testRemoteOwnerFrameUpdateReclaimsFirstResponderOnlyFromWindowFloor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.owner-focus-render-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-owner-focus", reason: "initial", emittedAt: "2026-06-02T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-owner-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-06-02T00:00:00Z", title: "owner", workingDirectory: "/tmp/live", columns: 8, rows: 1),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "owner", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-owner-focus", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-06-02T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(
                id: "owner-client", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-02T00:00:00Z"),
            mode: .owner, into: container)
        waitForCondition("initial owner first responder") { window.firstResponder is GhosttyMirrorTerminalView }

        let dummyResponder = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(dummyResponder)
        XCTAssertTrue(window.makeFirstResponder(dummyResponder))
        XCTAssertTrue(window.firstResponder === dummyResponder)

        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-owner-focus", reason: "state_change", emittedAt: "2026-06-02T00:00:01Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-owner-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-06-02T00:00:01Z", title: "owner", workingDirectory: "/tmp/live", columns: 8, rows: 1),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "owner", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "beta", sessionRevision: 2)))

        // The frame update must not steal focus from the control the user is in.
        let stealDeadline = Date().addingTimeInterval(0.5)
        while Date() < stealDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(window.firstResponder === dummyResponder, "Render frame stole first responder from a focused control")
        }

        // Once focus falls back to the window floor, the next frame reclaims it for the mirror.
        XCTAssertTrue(window.makeFirstResponder(nil))
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-owner-focus", reason: "state_change", emittedAt: "2026-06-02T00:00:02Z", sessionStateRevision: 3,
                sessionStateFlags: 1, screenStateRevision: 3,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-owner-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-06-02T00:00:02Z", title: "owner", workingDirectory: "/tmp/live", columns: 8, rows: 1),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "owner", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "gamma", sessionRevision: 3)))

        waitForCondition("owner first responder restored from window floor") { window.firstResponder is GhosttyMirrorTerminalView }
    }

    /// `setFocused` is a passive focus-state sync driven by metadata refreshes and app
    /// activation (a coding agent rewriting the terminal title fires it many times per second).
    /// It must never steal first responder from another focused control such as the sidebar or
    /// tab rename editor; deliberate focus goes through `focusWindow`.
    @MainActor func testSetFocusedDoesNotStealFirstResponderFromOtherControl() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.set-focused-no-steal-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-set-focused", reason: "initial", emittedAt: "2026-06-02T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-set-focused", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-06-02T00:00:00Z", title: "owner", workingDirectory: "/tmp/live", columns: 8, rows: 1),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "owner", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-set-focused", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-06-02T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let client = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-02T00:00:00Z")
        try host.attach(client: client, mode: .owner, into: container)
        waitForCondition("initial owner first responder") { window.firstResponder is GhosttyMirrorTerminalView }

        // The user is editing another control (stands in for the sidebar/tab rename NSTextField).
        let renameEditor = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(renameEditor)
        XCTAssertTrue(window.makeFirstResponder(renameEditor))
        XCTAssertTrue(window.firstResponder === renameEditor)

        host.setFocused(true, for: client.id)
        XCTAssertTrue(window.firstResponder === renameEditor, "setFocused stole first responder from a focused control")

        // The reclaim schedules a deferred restore task; let it run and confirm it also leaves the
        // editor alone (its guard only reclaims from the window floor).
        let stealDeadline = Date().addingTimeInterval(0.3)
        while Date() < stealDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(window.firstResponder === renameEditor, "deferred restore stole first responder from a focused control")
        }
    }

    /// The reclaim path stays intact: when focus has fallen back to the window floor (mirror
    /// re-parenting resigns it during structural updates), a passive `setFocused` restores the
    /// mirror as first responder so surface re-parenting recovery is not broken.
    @MainActor func testSetFocusedReclaimsFirstResponderWhenFocusFellBackToWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.set-focused-reclaim-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-set-focused-reclaim", reason: "initial", emittedAt: "2026-06-02T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-set-focused-reclaim", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-06-02T00:00:00Z", title: "owner", workingDirectory: "/tmp/live", columns: 8, rows: 1),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "owner", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-set-focused-reclaim", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-06-02T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let client = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-02T00:00:00Z")
        try host.attach(client: client, mode: .owner, into: container)
        waitForCondition("initial owner first responder") { window.firstResponder is GhosttyMirrorTerminalView }

        // Focus falls back to the window floor, as it does when the mirror resigns during re-parenting.
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertTrue(window.firstResponder === window)

        host.setFocused(true, for: client.id)
        XCTAssertTrue(window.firstResponder is GhosttyMirrorTerminalView, "setFocused did not reclaim first responder from the window floor")
    }

    @MainActor func testRemoteRenderableViewerPreservesSnapshotAcrossAttachmentStateChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.attachment-state-render-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-attachment-state", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-attachment-state", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-20T00:00:00Z", title: "renderable", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "renderable", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-attachment-state", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-20T00:00:00Z"),
            mode: .viewer, into: container)

        waitForCondition("initial rendered viewer text") { self.normalize(self.visibleText(for: host)).contains("alpha") }

        let ownerClient = TerminalClient(
            id: "ipad-owner", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPad"), connectedAt: "2026-05-20T00:00:01Z")
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [ownerClient],
            attachments: [
                TerminalAttachment(sessionID: "remote-attachment-state", clientID: ownerClient.id, mode: .owner, attachedAt: "2026-05-20T00:00:01Z")
            ])
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-attachment-state", reason: "attachment_state", emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: attachmentSnapshot, title: "renderable",
                workingDirectory: "/tmp/live", outputByteCount: nil))

        waitForCondition("attachment state owner update") { host.activeOwnerClientID() == ownerClient.id }
        waitForCondition("viewer retains rendered text after attachment state") {
            self.normalize(self.visibleText(for: host)).contains("alpha") && self.normalize(self.visibleText(for: host)).contains("beta")
        }

        XCTAssertEqual(normalize(visibleText(for: host)), normalize("alpha\nbeta "))
    }

    @MainActor func testRemoteRenderableViewerPrefersSnapshotWhenFreshUpdateAlsoIncludesIncrementalOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.snapshot-precedence-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-snapshot-precedence", reason: "initial", emittedAt: "2026-05-21T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: nil,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-snapshot-precedence", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-21T00:00:00Z", title: "renderable", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "renderable", workingDirectory: "/tmp/live", outputByteCount: nil)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-snapshot-precedence", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-21T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-21T00:00:00Z"),
            mode: .viewer, into: container)

        try "WRONG\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-snapshot-precedence", reason: "output", emittedAt: "2026-05-21T00:00:01Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 1,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-snapshot-precedence", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-21T00:00:01Z", title: "renderable", workingDirectory: "/tmp/live", columns: 8, rows: 2),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "renderable", workingDirectory: "/tmp/live", outputByteCount: 5,
                renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 2)))

        waitForCondition("viewer renders snapshot instead of output history") {
            self.normalize(self.visibleText(for: host)).contains("alpha") && self.normalize(self.visibleText(for: host)).contains("beta")
        }

        XCTAssertFalse(normalize(visibleText(for: host)).contains("WRONG"))
        XCTAssertFalse(normalize(host.snapshotText()).contains("WRONG"))
        XCTAssertEqual(normalize(visibleText(for: host)), normalize("alpha\nbeta "))
    }

    @MainActor func testRemoteRenderableOwnerPrefersHandoffSnapshotOverOutputLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try seedSessionRow(sessionID: "remote-handoff-snapshot", paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-handoff-snapshot", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-29T00:00:00Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2), paths: paths)
        let queue = DispatchQueue(label: "spaces.remote-device.handoff-snapshot-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-handoff-snapshot", reason: "initial", emittedAt: "2026-05-29T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: nil,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-handoff-snapshot", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-29T00:00:00Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: nil)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-handoff-snapshot", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-29T00:00:00Z")
        try host.attach(client: client, mode: .owner, into: container)

        try "WRONG\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [client],
            attachments: [
                TerminalAttachment(sessionID: "remote-handoff-snapshot", clientID: client.id, mode: .owner, attachedAt: "2026-05-29T00:00:01Z")
            ])
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-handoff-snapshot", reason: "attachment_state", emittedAt: "2026-05-29T00:00:01Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-handoff-snapshot", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-29T00:00:01Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2),
                attachmentSnapshot: attachmentSnapshot, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 2)))

        waitForCondition("owner handoff snapshot") {
            self.normalize(self.visibleText(for: host)).contains("alpha") && self.normalize(self.visibleText(for: host)).contains("beta")
        }

        XCTAssertFalse(normalize(visibleText(for: host)).contains("WRONG"))
        XCTAssertEqual(normalize(visibleText(for: host)), normalize("alpha\nbeta "))
    }

    @MainActor func testRemoteMirrorRecreatesNativeSurfaceAfterRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-30T00:00:00Z")
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [client],
            attachments: [
                TerminalAttachment(sessionID: "remote-recreate-surface", clientID: client.id, mode: .owner, attachedAt: "2026-05-30T00:00:00Z")
            ])
        let queue = DispatchQueue(label: "spaces.remote-device.recreate-surface-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-recreate-surface", reason: "initial", emittedAt: "2026-05-30T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-recreate-surface", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-30T00:00:00Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: attachmentSnapshot, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-recreate-surface", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-30T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(client: client, mode: .owner, into: container)
        waitForCondition("initial native mirror") { host.hasRenderableSurface() && self.normalize(self.visibleText(for: host)).contains("alpha") }

        host.releaseRendererSurface()
        XCTAssertFalse(host.hasRenderableSurface())

        try host.attach(client: client, mode: .owner, into: container)
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-recreate-surface", reason: "output", emittedAt: "2026-05-30T00:00:01Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-recreate-surface", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-30T00:00:01Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2),
                attachmentSnapshot: attachmentSnapshot, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "gamma\ndelta", sessionRevision: 2)))

        waitForCondition("recreated native mirror") { host.hasRenderableSurface() && self.normalize(self.visibleText(for: host)).contains("gamma") }
        XCTAssertEqual(normalize(visibleText(for: host)), normalize("gamma\ndelta"))
    }

    @MainActor func testRemoteHostDoesNotRefreshRenderFromOutputHistoryWhenHistoryAdvances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try seedSessionRow(sessionID: "remote-history-refresh", paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-history-refresh", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-22T00:00:00Z", columns: 24, rows: 4), paths: paths)
        try "first\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-history-refresh", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-22T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-22T00:00:00Z"),
            mode: .owner, into: container)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(normalize(visibleText(for: host)).contains("first"))

        try "first\nsecond\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(normalize(visibleText(for: host)).contains("second"))
    }

    @MainActor func testRemoteMirrorViewDoesNotRenderOutputLogQueryResponses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try seedSessionRow(sessionID: "remote-query-responses", paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-query-responses", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-28T00:00:00Z", columns: 80, rows: 8), paths: paths)
        let transcript = "before\r\n\u{1B}[6n\u{1B}]10;?\u{7}after\r\n"
        try transcript.write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-query-responses", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-28T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-28T00:00:00Z"),
            mode: .owner, into: container)

        let renderedText = normalize(visibleText(for: host))
        XCTAssertFalse(renderedText.contains("before"))
        XCTAssertFalse(renderedText.contains("after"))
        XCTAssertFalse(renderedText.contains("^["))
        XCTAssertFalse(renderedText.contains("^]"))
        XCTAssertFalse(renderedText.contains("rgb:"))
        XCTAssertFalse(renderedText.contains(";R"))
    }

    @MainActor func testRemoteHostFetchesStateAndSendsDirectDaemonControls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-direct-daemon"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "remote", workingDirectory: "/tmp/work", shell: "/bin/bash", command: "cat",
            createdAt: "2026-06-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-06-10T00:00:00Z",
            title: "remote", workingDirectory: "/tmp/work", columns: 5, rows: 1)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-06-10T00:00:01Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil, renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        let recorder = DirectTerminalServiceRecorder(payload: payload)

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send)

        waitForCondition("direct daemon state render") { host.snapshotText() == "alpha" }
        // The GUI host renders device state in memory and writes no local mirror row.
        XCTAssertThrowsError(try TerminalSessionPersistence.readRemoteSessionState(paths: paths))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-10T00:00:02Z")
        try host.attach(client: client, mode: .owner, into: container)

        XCTAssertTrue(host.clearScreenAndScrollback())
        waitForCondition("direct daemon control") {
            recorder.requests().contains {
                if case .control(let payload) = $0.command {
                    return payload.sessionID == sessionID && payload.controlRequest.command == "clearScreen"
                        && payload.controlRequest.clientID == client.id
                }
                return false
            }
        }
        XCTAssertTrue(
            recorder.requests().contains { request in
                if case .state(let payload) = request.command { return payload.sessionID == sessionID }
                return false
            })
    }

    /// A host attaches before any frame has reached it: the subscription it joined carries deltas, and a
    /// delta is meaningless without the full frame it was computed against. Nothing else on the attach
    /// path asks for one — the attach's own viewport resize is dropped when the grid has not moved, and a
    /// delta failing to apply is the only other trigger — so the pane would sit blank until the session
    /// happened to send a full frame. The attach has to ask for one itself.
    @MainActor func testAttachWithoutARenderFrameAsksTheSessionForAFullFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-attach-without-baseline"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        let recorder = DirectTerminalServiceRecorder(payload: fixture.payload)
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: recorder.send,
            stateStreamSubscriber: subscriber.subscribe)
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }
        XCTAssertFalse(recorder.requests().contains { if case .state = $0.command { return true } else { return false } })

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)))

        waitForCondition("attach requests a full frame") {
            recorder.requests().contains { request in
                if case .state(let payload) = request.command { return payload.sessionID == sessionID }
                return false
            }
        }
    }

    /// A resync the reducer required must never be lost to the throttle.
    ///
    /// The `.state` read a resync makes can come back with no render update at all — the session exports
    /// none while its capture holds nothing visible — but it still stamps the throttle. A delta that
    /// arrives inside that window then fails to apply, asks for the resync that would repair the chain,
    /// and is turned away with nothing left to ask again: a session that emits one delta and goes quiet
    /// leaves the pane baseline-less until some unrelated later event. The throttle's job is pacing, not
    /// discarding, so a suppressed request is owed exactly one delayed retry at the window boundary.
    @MainActor func testResyncSuppressedByTheThrottleStillFiresAtTheWindowBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-resync-trailing-retry"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        // The first `.state` answers with no render update (nothing visible to export), the second with a
        // full frame — so the throttle is stamped by a fetch that repaired nothing.
        let recorder = DirectTerminalServiceRecorder(payloads: [framelessPayload(for: fixture), fixture.payload])
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: recorder.send,
            stateStreamSubscriber: subscriber.subscribe)
        host.renderUpdateResyncIntervalForTesting = 0.2
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }

        // The attach's own eager resync stamps the throttle and comes back with nothing to paint.
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)))
        waitForCondition("the attach's state fetch lands") { self.stateRequestCount(recorder) == 1 }

        // One delta, on a host with no baseline, and then silence.
        subscriber.emit(try deltaPayloadWithoutABaseline(sessionID: sessionID, runtimeState: fixture.payload.runtimeState))

        waitForCondition("the suppressed resync fires at the window boundary") { self.stateRequestCount(recorder) >= 2 }
        XCTAssertEqual(stateRequestCount(recorder), 2, "the retry is one coalesced request, not a run of them")
        waitForCondition("the retried frame paints") { host.snapshotText() == "alpha" }
    }

    /// A `.state` response describes the screen as it was when the session answered, so one that arrives
    /// after the subscription has already painted something newer is stale by construction. Applying it
    /// walks the pane backwards to a picture the session has moved past, and the render-update applier has
    /// no monotonicity check to stop it: a full frame replaces the baseline whatever revision it carries.
    /// The eager attach fetch makes that overlap ordinary, so a response is dropped when a frame applied
    /// while it was in flight.
    @MainActor func testStateResponseThatLandsAfterANewerFrameIsDiscarded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-stale-state-response"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        // The held read answers with the screen as it was at attach time; the subscription paints a newer
        // one while it is still in flight.
        let sender = HeldStateRequestSender(payloads: [
            try fullFramePayload(sessionID: sessionID, runtimeState: fixture.payload.runtimeState, text: "alpha", sessionRevision: 1)
        ])
        defer { sender.releaseHeldState() }
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            stateStreamSubscriber: subscriber.subscribe)
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)))
        waitForCondition("the attach's state fetch is in flight") { sender.stateRequestCount == 1 }

        subscriber.emit(
            try fullFramePayload(
                sessionID: sessionID, runtimeState: fixture.payload.runtimeState, text: "bravo", sessionRevision: 2, emittedAt: "2026-08-09T00:00:05Z"
            ))
        waitForCondition("the streamed frame paints") { host.snapshotText() == "bravo" }

        sender.releaseHeldState()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(host.snapshotText(), "bravo", "a response older than what the pane already shows must not walk it backwards")
        XCTAssertEqual(sender.stateRequestCount, 1, "a frame applied, so nothing is owed and no retry is armed")
    }

    /// The trailing retry must survive firing into a fetch that is already in flight.
    ///
    /// The `.state` read a resync would make is refused while another one is in flight, and that other
    /// read was issued before this resync was owed — it can come back with no render update and repair
    /// nothing. Consuming the retry on that refusal puts the pane back in the state the retry exists to
    /// prevent: baseline-less, with nothing left to ask again. So a retry that finds a fetch in flight
    /// stays owed and waits out another window instead.
    @MainActor func testTrailingResyncRetryFiringIntoAnInFlightFetchStaysOwed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-resync-retry-in-flight"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        // The held first read answers with no render update; only a later read carries the frame.
        let sender = HeldStateRequestSender(payloads: [framelessPayload(for: fixture), fixture.payload])
        defer { sender.releaseHeldState() }
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            stateStreamSubscriber: subscriber.subscribe)
        host.renderUpdateResyncIntervalForTesting = 0.2
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }

        // The attach's eager resync stamps the throttle and its read is held open.
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)))
        waitForCondition("the attach's state fetch is in flight") { sender.stateRequestCount == 1 }

        // A delta the host has no baseline for lands inside the throttle window and arms the retry.
        subscriber.emit(try deltaPayloadWithoutABaseline(sessionID: sessionID, runtimeState: fixture.payload.runtimeState))
        // Past the boundary, so the retry fires while the held read is still in flight.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(sender.stateRequestCount, 1, "the in-flight read is what the retry ran into")

        // The held read finally answers, with nothing to paint, and the session goes quiet.
        sender.releaseHeldState()

        waitForCondition("the still-owed resync fires once the link is free") { sender.stateRequestCount >= 2 }
        waitForCondition("the retried frame paints") { host.snapshotText() == "alpha" }
    }

    /// The open-throttle sibling of the case above: a resync required AFTER the window has expired, while
    /// the attach's read is still in flight, must also stay owed. The unthrottled path used to stamp the
    /// throttle and call straight into the fetch, which refused on the in-flight guard — consuming the
    /// request unsent, the same swallowed resync one branch over.
    @MainActor func testResyncRequiredAfterTheWindowWhileAFetchIsInFlightStaysOwed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-resync-open-throttle-in-flight"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        // The held first read answers with no render update; only a later read carries the frame.
        let sender = HeldStateRequestSender(payloads: [framelessPayload(for: fixture), fixture.payload])
        defer { sender.releaseHeldState() }
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            stateStreamSubscriber: subscriber.subscribe)
        host.renderUpdateResyncIntervalForTesting = 0.2
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }

        // The attach's eager resync stamps the throttle and its read is held open.
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)))
        waitForCondition("the attach's state fetch is in flight") { sender.stateRequestCount == 1 }

        // Let the throttle window expire with the read still held, THEN fail a reduction: the resync
        // request takes the unthrottled path while the fetch is still in flight.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        subscriber.emit(try deltaPayloadWithoutABaseline(sessionID: sessionID, runtimeState: fixture.payload.runtimeState))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(sender.stateRequestCount, 1, "the in-flight read is what the resync ran into")

        // The held read finally answers, with nothing to paint, and the session goes quiet.
        sender.releaseHeldState()

        waitForCondition("the still-owed resync fires once the link is free") { sender.stateRequestCount >= 2 }
        waitForCondition("the retried frame paints") { host.snapshotText() == "alpha" }
    }

    /// The other direction: a trailing retry is owed only while the pane still needs it. A full frame that
    /// lands before the boundary repairs the chain, so the armed retry must be dropped rather than firing
    /// a `.state` read for a frame the host already has.
    @MainActor func testTrailingResyncRetryIsCancelledByAFullFrameThatLandsFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-resync-trailing-retry-cancel"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        let recorder = DirectTerminalServiceRecorder(payloads: [framelessPayload(for: fixture), fixture.payload])
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: recorder.send,
            stateStreamSubscriber: subscriber.subscribe)
        host.renderUpdateResyncIntervalForTesting = 0.2
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)))
        waitForCondition("the attach's state fetch lands") { self.stateRequestCount(recorder) == 1 }

        subscriber.emit(try deltaPayloadWithoutABaseline(sessionID: sessionID, runtimeState: fixture.payload.runtimeState))
        // The session's own full frame arrives before the window expires.
        subscriber.emit(fixture.payload)
        waitForCondition("the streamed frame paints") { host.snapshotText() == "alpha" }

        // Well past the boundary the retry would have fired at.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(stateRequestCount(recorder), 1, "a repaired chain owes no retry")
    }

    private func stateRequestCount(_ recorder: DirectTerminalServiceRecorder) -> Int {
        recorder.requests().filter { if case .state = $0.command { return true } else { return false } }.count
    }

    /// A request sender whose first `.state` read is held open until the test releases it, so a fetch can
    /// still be in flight when the resync throttle's window expires. Later reads answer immediately, in
    /// order, repeating the last payload — the same serving rule as `DirectTerminalServiceRecorder`.
    private final class HeldStateRequestSender: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [GhosttyRemoteSessionStatePayload]
        private var requestCount = 0
        private let heldRead = DispatchSemaphore(value: 0)
        private var isReleased = false

        init(payloads: [GhosttyRemoteSessionStatePayload]) { self.payloads = payloads }

        var stateRequestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requestCount
        }

        /// Idempotent so the test's `defer` can guarantee the held send is never left blocking a thread.
        func releaseHeldState() {
            lock.lock()
            let alreadyReleased = isReleased
            isReleased = true
            lock.unlock()
            guard !alreadyReleased else { return }
            heldRead.signal()
        }

        func send(_ request: TerminalServiceRequest) throws -> TerminalServiceResponse {
            switch request.command {
            case .state:
                lock.lock()
                requestCount += 1
                let isFirst = requestCount == 1
                lock.unlock()
                if isFirst { heldRead.wait() }
                lock.lock()
                let payload = payloads.count > 1 ? payloads.removeFirst() : payloads.first
                lock.unlock()
                return TerminalServiceResponse(ok: true, message: "state", sessionState: payload)
            case .control:
                return TerminalServiceResponse(
                    ok: true, message: "controlled", controlResponse: TerminalControlResponse(ok: true, message: "controlled"))
            default: return TerminalServiceResponse(ok: false, message: "Unexpected command '\(request.commandName)'.")
            }
        }
    }

    /// A `.state` response with no render update: what the session exports when its capture holds nothing
    /// visible. It repairs no baseline, but it does stamp the client's resync throttle.
    private func framelessPayload(for fixture: RunningSessionFixture) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: fixture.launchConfiguration.sessionID, reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-08-09T00:00:03Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: fixture.payload.runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil)
    }

    /// A payload carrying one full frame of `text`.
    private func fullFramePayload(
        sessionID: String, runtimeState: TerminalSessionRuntimeState?, text: String, sessionRevision: UInt64,
        emittedAt: String = "2026-08-09T00:00:03Z"
    ) throws -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output, emittedAt: emittedAt, sessionStateRevision: sessionRevision,
            sessionStateFlags: 1, screenStateRevision: sessionRevision, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: text, sessionRevision: sessionRevision))
    }

    /// A delta whose baseline this host never saw, so its reduction fails and asks for a resync.
    private func deltaPayloadWithoutABaseline(sessionID: String, runtimeState: TerminalSessionRuntimeState?) throws
        -> GhosttyRemoteSessionStatePayload
    {
        let first = GhosttyRenderFrame(sessionRevision: 7, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let second = GhosttyRenderFrame(sessionRevision: 8, ownerEpoch: 0, snapshot: snapshot(text: "bravo"))
        let delta = GhosttyRenderUpdateFactory.makeUpdate(target: second, baseline: GhosttyRenderUpdateBaseline(frame: first))
        XCTAssertEqual(delta.kind, .delta)
        return GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-08-09T00:00:04Z", sessionStateRevision: 8,
            sessionStateFlags: 1, screenStateRevision: 8, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(delta))
    }

    /// The lazy pane open, in the order production performs it: the host is built, its registration with
    /// the session's state model replays the model's cached full frame straight into the reduction
    /// pipeline, and the pane attaches in the same main-actor turn — before that detached pipeline has
    /// reduced anything. The frame the host will paint from is already on its way, so asking the device
    /// for another one buys nothing and costs a grid-sized export on every pane open.
    @MainActor func testAttachInTheSameTurnAsAReplayedFullFrameAsksTheSessionForNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-attach-replayed-frame"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        let recorder = DirectTerminalServiceRecorder(payload: fixture.payload)
        let subscriber = ReplayingStateStreamSubscriber(replayPayload: fixture.payload)
        // No run loop turn between construction (which registers and replays) and the attach.
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: recorder.send,
            stateStreamSubscriber: subscriber.subscribe)
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)))

        XCTAssertFalse(
            recorder.requests().contains { if case .state = $0.command { return true } else { return false } },
            "the replayed frame is queued for this host; attach must not ask the device for another")
        waitForCondition("host renders the replayed frame") { host.snapshotText() == "alpha" }
        XCTAssertFalse(recorder.requests().contains { if case .state = $0.command { return true } else { return false } })
    }

    /// Hands the host a payload synchronously at registration, the way `DeviceTerminalSessionStateModel`
    /// replays its cached payload to a newly registered listener.
    private final class ReplayingStateStreamSubscriber: @unchecked Sendable {
        private final class Client: TerminalRemoteStateStreamClient, @unchecked Sendable { func stop() {} }

        private let replayPayload: GhosttyRemoteSessionStatePayload

        init(replayPayload: GhosttyRemoteSessionStatePayload) { self.replayPayload = replayPayload }

        func subscribe(
            _: String, onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void,
            onDisconnect _: @escaping @Sendable ((any Error)?) -> Void
        ) throws -> any TerminalRemoteStateStreamClient {
            onEvent(replayPayload)
            return Client()
        }
    }

    /// The other half of the rule: an attach that already holds a full frame paints from it and asks the
    /// session for nothing. A `.state` fetch per attach would put a grid-sized export on the daemon every
    /// time a pane is focused.
    @MainActor func testAttachWithARenderFrameAsksTheSessionForNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-attach-with-baseline"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        let recorder = DirectTerminalServiceRecorder(payload: fixture.payload)
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: recorder.send,
            stateStreamSubscriber: subscriber.subscribe)
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }
        subscriber.emit(fixture.payload)
        waitForCondition("host renders the streamed frame") { host.snapshotText() == "alpha" }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertFalse(recorder.requests().contains { if case .state = $0.command { return true } else { return false } })
    }

    /// A subscription's payloads reach the host on the stream's own thread and are reduced off the main
    /// actor, so what this proves is that the whole chained series still lands, in order, on the mirror:
    /// a full frame followed by deltas each built against the one before it renders the last frame's
    /// text and nothing earlier. A payload reduced against the wrong baseline drops instead of
    /// rendering, so an out-of-order apply leaves the pane showing an earlier frame.
    @MainActor func testSubscriptionDeltaSeriesRendersTheFinalFrameInOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-stream-delta-series"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, stateStreamSubscriber: subscriber.subscribe)
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }

        var frames: [GhosttyRenderFrame] = []
        for index in 0..<12 {
            frames.append(GhosttyRenderFrame(sessionRevision: UInt64(index + 1), ownerEpoch: 0, snapshot: snapshot(text: "fram\(index % 10)")))
        }
        var updates: [GhosttyRenderUpdate] = [.full(frames[0])]
        for index in 1..<frames.count {
            updates.append(
                GhosttyRenderUpdateFactory.makeUpdate(target: frames[index], baseline: GhosttyRenderUpdateBaseline(frame: frames[index - 1])))
        }
        // Emitted from a background thread, exactly as the device state model delivers them.
        let emitQueue = DispatchQueue(label: "spaces.test.remote-state-emit")
        for (index, update) in updates.enumerated() {
            let payload = GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output,
                emittedAt: "2026-07-24T00:01:\(String(format: "%02d", index))Z", sessionStateRevision: UInt64(index + 1), sessionStateFlags: 1,
                screenStateRevision: UInt64(index + 1), runtimeState: fixture.payload.runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(update))
            emitQueue.sync { subscriber.emit(payload) }
        }

        waitForCondition("host renders the last frame of the delta series") { host.snapshotText() == "fram1" }
    }

    /// Captures the host's state-stream callback so a test can emit payloads the way the device state
    /// model does: off the main actor, in a known order.
    private final class RecordingStateStreamSubscriber: @unchecked Sendable {
        private final class Client: TerminalRemoteStateStreamClient, @unchecked Sendable { func stop() {} }

        private let lock = NSLock()
        private var onEvent: (@Sendable (GhosttyRemoteSessionStatePayload) -> Void)?

        var isSubscribed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return onEvent != nil
        }

        func subscribe(
            _: String, onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void,
            onDisconnect _: @escaping @Sendable ((any Error)?) -> Void
        ) throws -> any TerminalRemoteStateStreamClient {
            lock.lock()
            self.onEvent = onEvent
            lock.unlock()
            return Client()
        }

        func emit(_ payload: GhosttyRemoteSessionStatePayload) {
            lock.lock()
            let onEvent = self.onEvent
            lock.unlock()
            onEvent?(payload)
        }
    }

    /// Guards Change 1 (report a lost link from every interactive control path, not just typed input)
    /// and Change 2 (a link the model reports gone discards this pane's queued input rather than
    /// delivering it late) from `RemoteGhosttySessionHost`'s own send paths, using
    /// `ScriptedControlRequestSender` and an injected `inputFailureHandler` in place of a real socket —
    /// the daemon side of these failures is exercised elsewhere (transport timeouts, coded rejections);
    /// here the host's wiring from "the send threw" to "the pane's queued input is gone" is what is
    /// under test.
    @MainActor func testFailedScrollReportsTheLostLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRunningSessionFixture(sessionID: "remote-scroll-lost-link", root: root)
        // Every control request fails, so whichever ones attach's own owner handoff happens to send are
        // just as informative as the deliberate scroll below — the assertion below waits specifically for
        // the "scroll" command by name, not for the first (possibly unrelated) reported failure.
        let sender = ScriptedControlRequestSender(payload: fixture.payload, controlError: SimulatedTransportFailure())
        let reportedFailures = FailureReportCounter()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            inputFailureHandler: { _ in
                await reportedFailures.increment()
                return true
            })

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
        try host.attach(client: client, mode: .owner, into: container)

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 3, scrollMods: 0, pointerPosition: nil))
        // The coalescer batches scroll deltas for a short real interval before enqueuing the control send
        // (see `TerminalScrollCoalescer`); wait for that specific send to land instead of guessing its
        // timing, then drain the queue so its `onError` (awaited before the enqueued task completes) has
        // definitely run by the time this checks the counter.
        await sender.awaitControlRequest(named: "scroll")
        await host.drainInputQueueForTesting()

        let failureCount = await reportedFailures.count
        XCTAssertGreaterThanOrEqual(failureCount, 1, "the scroll's failure must reach inputFailureHandler")
    }

    /// See `testFailedScrollReportsTheLostLink`; the resize send runs off `inputQueue` in its own
    /// detached task (a `try?` there used to swallow the thrown error entirely — see Change 1), so this
    /// pins the resize path separately rather than assuming the queued paths' fix covers it too.
    @MainActor func testFailedResizeReportsTheLostLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRunningSessionFixture(sessionID: "remote-resize-lost-link", root: root)
        let sender = ScriptedControlRequestSender(payload: fixture.payload, controlError: SimulatedTransportFailure())
        let reportedFailures = FailureReportCounter()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            inputFailureHandler: { _ in
                await reportedFailures.increment()
                return true
            })

        // The container has to be in a visible window. A resize is only sent for a viewport the mirror
        // can measure, and an off-screen pane deliberately reports no size at all rather than an
        // estimate from a font Ghostty does not render with, so a windowless container guards the send
        // out and the failure this test is about is never attempted.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
        try host.attach(client: client, mode: .owner, into: container)
        // `attach` already sends the initial viewport size for an owner; drain that attempt (whether or
        // not one actually started) before forcing a second, deliberate resize request, so the second's
        // own outcome is unambiguously the one `drainPendingResizeForTesting` below observes.
        await host.drainPendingResizeForTesting()
        XCTAssertTrue(host.synchronizeSurfaceGeometry())
        await host.drainPendingResizeForTesting()

        let failureCount = await reportedFailures.count
        XCTAssertGreaterThanOrEqual(failureCount, 1, "the resize's failure must reach inputFailureHandler")
    }

    /// The regression Change 2 fixes: a keystroke typed while the link is down used to keep buffering
    /// behind the failed one, then deliver in full — including any Enter — once the link recovered
    /// minutes later. `TerminalInputSerialQueue.enqueue` chains every send behind its predecessor, so
    /// enqueuing three sends back to back before any of them has run guarantees the second and third are
    /// still queued behind the first when it fails; `inputFailureHandler` answering `true` (the model's
    /// verdict that the link is gone) must make the host discard that backlog instead of letting the
    /// second and third sends reach the daemon once it "recovers" (the sender scripted to fail only the
    /// first).
    @MainActor func testTransportFailureDiscardsQueuedInputInsteadOfDeliveringItLate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRunningSessionFixture(sessionID: "remote-drops-queued-input", root: root)
        // Only the first control request fails; every later one would succeed — proving a later send was
        // never attempted, not merely that it also failed.
        let sender = ScriptedControlRequestSender(
            payload: fixture.payload, controlError: SimulatedTransportFailure(), failFirstControlRequestOnly: true)
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            inputFailureHandler: { _ in true })

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
        try host.attach(client: client, mode: .owner, into: container)

        XCTAssertTrue(host.sendTextAsPaste("first"))
        XCTAssertTrue(host.sendTextAsPaste("second"))
        XCTAssertTrue(host.sendTextAsPaste("third"))

        await host.drainInputQueueForTesting()
        XCTAssertEqual(
            sender.controlRequestTexts, ["first"], "the link-is-gone verdict on the first send must discard the queued backlog rather than deliver it"
        )
    }

    /// The other half of Change 2's contract: a reachable daemon's coded rejection is not evidence the
    /// link is gone, so `inputFailureHandler` answering `false` must leave the queue running — the next
    /// keystroke is still delivered rather than silently dropped alongside a rejected one.
    @MainActor func testCodedRejectionNeitherReportsALostLinkNorDropsInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRunningSessionFixture(sessionID: "remote-coded-rejection", root: root)
        let sender = ScriptedControlRequestSender(
            payload: fixture.payload, controlError: SimulatedRejectionError(), failFirstControlRequestOnly: true)
        let reported = expectation(description: "the rejection reached inputFailureHandler")
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            inputFailureHandler: { _ in
                reported.fulfill()
                // A reachable daemon's coded rejection is not evidence of a lost link.
                return false
            })

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
        try host.attach(client: client, mode: .owner, into: container)

        XCTAssertTrue(host.sendTextAsPaste("first"))
        XCTAssertTrue(host.sendTextAsPaste("second"))

        await fulfillment(of: [reported], timeout: 2)
        await host.drainInputQueueForTesting()
        XCTAssertEqual(sender.controlRequestTexts, ["first", "second"], "a coded rejection must not drop the next send behind it")
    }

    /// The fix for the main-thread-stall keystroke drop: a REQUEST TIMEOUT — the round trip did not
    /// answer inside the interactive control deadline — is not by itself proof the link is down (an
    /// app-side stall busy past the deadline looks identical to a slow network from here), so
    /// `DeviceTerminalSessionStateModel.reportFailedInputSend` answers `false` for one, the same as a
    /// coded rejection. The timed-out send must still reach `inputFailureHandler` — the failure itself
    /// is reported exactly as before (Change 1's contract) — but a `false` answer must leave the queued
    /// backlog alone, so the keystrokes typed during the stall are not silently discarded. Only the
    /// timed-out ("first") request fails; "second" and "third" are scripted to succeed, so seeing all
    /// three land proves they were actually attempted, not merely that the queue was not cancelled.
    @MainActor func testRequestTimeoutReportsFailureButDoesNotDiscardQueuedInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRunningSessionFixture(sessionID: "remote-request-timeout", root: root)
        let sender = ScriptedControlRequestSender(
            payload: fixture.payload, controlError: SimulatedTimeoutFailure(), failFirstControlRequestOnly: true)
        let reportedFailures = FailureReportCounter()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            inputFailureHandler: { _ in
                await reportedFailures.increment()
                // A bare request timeout is not conclusive proof the link is gone.
                return false
            })

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
        try host.attach(client: client, mode: .owner, into: container)

        XCTAssertTrue(host.sendTextAsPaste("first"))
        XCTAssertTrue(host.sendTextAsPaste("second"))
        XCTAssertTrue(host.sendTextAsPaste("third"))

        await host.drainInputQueueForTesting()

        let failureCount = await reportedFailures.count
        XCTAssertGreaterThanOrEqual(failureCount, 1, "the timed-out send itself must still reach inputFailureHandler")
        XCTAssertEqual(
            sender.controlRequestTexts, ["first", "second", "third"],
            "a bare request timeout must not discard the queued backlog behind the timed-out send")
    }

    @MainActor func testRemoteHostRequestsDirectStateResyncAfterMissingDeltaBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-direct-resync"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "remote", workingDirectory: "/tmp/work", shell: "/bin/bash", command: "cat",
            createdAt: "2026-06-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-06-10T00:00:00Z",
            title: "remote", workingDirectory: "/tmp/work", columns: 5, rows: 1)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let secondFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 0, snapshot: snapshot(text: "bravo"))
        let missingBaselineDelta = GhosttyRenderUpdateFactory.makeUpdate(
            target: secondFrame, baseline: GhosttyRenderUpdateBaseline(frame: firstFrame))
        XCTAssertEqual(missingBaselineDelta.kind, .delta)
        let deltaPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-06-10T00:00:01Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
            renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(missingBaselineDelta))
        let fullPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-06-10T00:00:02Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
            renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(secondFrame)))
        let recorder = DirectTerminalServiceRecorder(payloads: [deltaPayload, fullPayload])

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send)

        waitForCondition("direct state resync request") {
            recorder.requests().filter { request in
                if case .state = request.command { return true }
                return false
            }.count >= 2 && host.snapshotText() == "bravo"
        }
    }

    @MainActor private func waitForCondition(_ label: String, timeout: TimeInterval = 30, condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    /// Writes the `terminal_sessions` row a session's runtime state hangs off. The session host writes its
    /// launch configuration as the first thing `startIfNeeded` does, before any runtime-state write, and
    /// every other per-session table is keyed off that row — so a fixture that persists runtime state for a
    /// session has to establish it the same way.
    private func seedSessionRow(sessionID: String, paths: TerminalSessionPaths) throws {
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: sessionID, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
    }

    private func snapshot(text: String, mouseReportingActive: Bool = false, mouseShiftCapture: UInt8 = GhosttyTerminalSnapshot.mouseShiftCaptureUnset)
        -> GhosttyTerminalSnapshot
    {
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
            defaultBackgroundRGB: 0x000000, cells: cells, mouseReportingActive: mouseReportingActive, mouseShiftCapture: mouseShiftCapture)
    }

    private func renderUpdate(text: String, sessionRevision: UInt64? = nil, ownerEpoch: UInt64 = 0) throws -> Data {
        let frame = GhosttyRenderFrame(sessionRevision: sessionRevision, ownerEpoch: ownerEpoch, snapshot: snapshot(text: text))
        return try GhosttyRenderUpdateBinaryCodec.encode(.full(frame))
    }

    /// A running remote session's launch/paths/final-frame payload, shared by the lost-link tests above:
    /// each needs a running (interactive) session so its control sends are not turned away by
    /// `isInteractiveRuntimeStateForControl()`.
    private struct RunningSessionFixture {
        let launchConfiguration: TerminalSessionLaunchConfiguration
        let paths: TerminalSessionPaths
        let payload: GhosttyRemoteSessionStatePayload
    }

    private func makeRunningSessionFixture(sessionID: String, root: URL) throws -> RunningSessionFixture {
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "remote", workingDirectory: "/tmp/work", shell: "/bin/bash", command: "cat",
            createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-07-24T00:00:00Z",
            title: "remote", workingDirectory: "/tmp/work", columns: 80, rows: 24)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-07-24T00:00:01Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil, renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        return RunningSessionFixture(launchConfiguration: launchConfiguration, paths: paths, payload: payload)
    }

    private func remoteStatePayload(sessionID: String, reason: String, outputByteCount: Int? = nil, outputEndByteOffset: Int? = nil)
        -> GhosttyRemoteSessionStatePayload
    {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: reason, emittedAt: "2026-06-03T00:00:00Z", sessionStateRevision: nil, sessionStateFlags: nil,
            screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: "live", workingDirectory: "/tmp/live",
            outputByteCount: outputByteCount, outputEndByteOffset: outputEndByteOffset)
    }

    private func normalize(_ text: String?) -> String {
        (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private func visibleText(for host: RemoteGhosttySessionHost) -> String? { host.debugVisibleSurfaceText() ?? host.snapshotText() }

    @MainActor private func keyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifierFlags, timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: keyCode))
    }

    @MainActor private func mouseEvent(type: NSEvent.EventType, windowNumber: Int, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 20, y: 30), modifierFlags: modifierFlags, timestamp: 0, windowNumber: windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
