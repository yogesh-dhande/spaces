import AppKit
import Carbon
import Foundation
import GhosttyKit
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// The transcript file every faked read in this file reports its bytes as coming from. A continuation
/// carries it back, which is what lets a test assert the pane continues the file it built its replay
/// from rather than one a head-trim replaced.
private let fakeTranscriptFileIdentity: UInt64 = 91

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

    /// The bytes a fake transcript read answers with, which a test can swap between reads when its fake
    /// daemon changes what `output.log` holds partway through.
    private final class MutableTranscript: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data

        init(_ value: Data) { self.value = value }

        var current: Data {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                value = newValue
            }
        }
    }

    /// The run identity a fake transcript read labels its bytes with, which a test can swap between reads
    /// when its fake daemon's runtime state catches up with a relaunch partway through.
    private final class MutableRunIdentity: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        init(_ value: String?) { self.value = value }

        var current: String? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                value = newValue
            }
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
            continuation?.resume(
                returning: RemoteGhosttyTranscript(
                    data: data, startByteOffset: 0, endByteOffset: UInt64(data.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runIdentity))
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
        /// Holds the first control request inside `send` until the test releases it, so a test can finish
        /// enqueuing a backlog before that request's scripted failure is allowed to act on the queue.
        private let firstControlRequestGate: DispatchSemaphore?

        init(
            payload: GhosttyRemoteSessionStatePayload, controlError: any Error, failFirstControlRequestOnly: Bool = false,
            holdFirstControlRequest: Bool = false
        ) {
            self.payload = payload
            self.controlError = controlError
            self.failFirstControlRequestOnly = failFirstControlRequestOnly
            self.firstControlRequestGate = holdFirstControlRequest ? DispatchSemaphore(value: 0) : nil
        }

        /// Lets the held first control request proceed to its scripted outcome. Safe to call from the main
        /// actor: the request blocks a queue worker, never the caller.
        func releaseFirstControlRequest() { firstControlRequestGate?.signal() }

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
                // Waits outside the lock so `awaitControlRequest` and `controlRequestTexts` stay live while
                // this request is held.
                if requestNumber == 1 { firstControlRequestGate?.wait() }
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

    /// The drag-commit copy-on-select write arrives a round trip after the drag. A copy the user
    /// made inside that window must win: the guarded write yields when the pasteboard's change count
    /// moved past the one captured at commit, and still writes when it did not.
    @MainActor func testSelectionResponseWriteYieldsToACopyMadeDuringTheRoundTrip() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-selection-copy", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("remote-mirror-selection-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        mirrorView.pasteboardOverrideForTesting = pasteboard

        let countAtCommit = mirrorView.selectionPasteboardChangeCount
        mirrorView.writeSelectionTextToPasteboard("dragged text", ifPasteboardUnchangedSince: countAtCommit)
        XCTAssertEqual(pasteboard.string(forType: .string), "dragged text")

        let staleCount = mirrorView.selectionPasteboardChangeCount
        pasteboard.clearContents()
        pasteboard.setString("user copy during round trip", forType: .string)
        mirrorView.writeSelectionTextToPasteboard("older dragged text", ifPasteboardUnchangedSince: staleCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy during round trip")
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
            remoteStatePayloadWithTitle(
                sessionID: "remote-clipboard-other", reason: TerminalRemoteSessionStateReason.output.rawValue, title: "settled"),
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
            remoteStatePayloadWithTitle(
                sessionID: "remote-clipboard-not-state", reason: TerminalRemoteSessionStateReason.output.rawValue, title: "settled"),
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

        // Served behind the fence pattern `setPayloads` documents: the recorder hands the clipboard
        // payload to exactly one `.state` request and every later fetch gets "later", so a fetch landing
        // between the clear below and the next arrival cannot re-serve the write. Re-serving is a fixture
        // artifact anyway — a real daemon clears a one-shot clipboard event after delivering it.
        fixture.recorder.setPayloads([
            clipboardPayload(sessionID: "remote-clipboard-once", targetClientID: fixture.clientID, text: "copied once"),
            remoteStatePayloadWithTitle(sessionID: "remote-clipboard-once", reason: TerminalRemoteSessionStateReason.output.rawValue, title: "later"),
        ])
        waitForCondition("owner applies the clipboard write") {
            _ = fixture.host.effectiveTitle
            return fixture.pasteboard.string(forType: .string) == "copied once"
        }

        fixture.pasteboard.clearContents()
        waitForCondition("the later payload is applied") {
            _ = fixture.host.effectiveTitle
            return fixture.host.effectiveTitle == "later"
        }
        // One more observed apply past the clear proves later payloads leave the pasteboard alone.
        fixture.recorder.setPayload(
            remoteStatePayloadWithTitle(
                sessionID: "remote-clipboard-once", reason: TerminalRemoteSessionStateReason.output.rawValue, title: "settled"))
        waitForCondition("the payload after the clear is applied") {
            _ = fixture.host.effectiveTitle
            return fixture.host.effectiveTitle == "settled"
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
                sessionID: "remote-clipboard-demoted", reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, title: "taken-over"),
            ownerClientID: "another-mac")
        fixture.recorder.setPayloads([
            takeover, clipboardPayload(sessionID: "remote-clipboard-demoted", targetClientID: fixture.clientID, text: "not ours any more"),
            remoteStatePayloadWithTitle(
                sessionID: "remote-clipboard-demoted", reason: TerminalRemoteSessionStateReason.output.rawValue, title: "settled"),
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
        // Registered right away so a throw from any of the calls below still cleans up `root`. Ownership
        // moves to the returned fixture's `tearDown` once construction succeeds, so this does not also
        // remove `root` out from under a fixture the caller is still using.
        var ownsRootCleanup = true
        defer { if ownsRootCleanup { try? FileManager.default.removeItem(at: root) } }
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        let clientID = "mac-owner-\(sessionID)"
        // The daemon's payload says this client owns the session, which is what the host reads to decide
        // it is the live owner — the attachment it requested is not evidence of that on its own.
        let ownerPayload = payloadClaimingOwner(fixture.payload, ownerClientID: clientID)
        let recorder = DirectTerminalServiceRecorder(payload: ownerPayload)
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: recorder.send)
        waitForCondition("host renders the running session") { host.snapshotText() != nil }

        // On screen, because these tests fence on a payload the pane applies: a pane the user is typing
        // in — the only pane an owner-targeted clipboard write is addressed to — is the selected tab's.
        let display = makeDisplayedPaneContainer(width: 320, height: 180)
        try host.attach(
            client: TerminalClient(
                id: clientID, kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-28T00:00:02Z"),
            mode: .owner, into: display.container)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("remote-clipboard-\(UUID().uuidString)"))
        pasteboard.clearContents()
        host.clipboardPasteboardOverrideForTesting = pasteboard
        ownsRootCleanup = false
        return ClipboardFixture(
            host: host, recorder: recorder, pasteboard: pasteboard, clientID: clientID,
            tearDown: {
                MainActor.assumeIsolated { display.window.orderOut(nil) }
                pasteboard.releaseGlobally()
                try? FileManager.default.removeItem(at: root)
            })
    }

    /// Re-emits a running payload with an attachment snapshot naming `ownerClientID` as the live owner.
    private func payloadClaimingOwner(_ payload: GhosttyRemoteSessionStatePayload, ownerClientID: String) -> GhosttyRemoteSessionStatePayload {
        let owner = TerminalClient(
            id: ownerClientID, kind: .local, identity: TerminalClientIdentity(label: ownerClientID), connectedAt: "2026-07-28T00:00:00Z")
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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.clipboardWrite.rawValue, emittedAt: "2026-07-28T00:00:03Z",
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
        // Which cell the click carries is pinned by
        // `GhosttyMirrorForwardedClickTests.testMirrorForwardsTheClickedCellAcrossACellBoundary`: it needs
        // a real mirror surface to quantize against, and this harness deliberately keeps mouse events away
        // from one.
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

    /// Cmd+click is the local link-activation gesture; forwarding it would reach the session as a plain
    /// click that a Ghostty-aware TUI reads as "open this link", double-opening it (issue #465).
    @MainActor func testRemoteMirrorSuppressesCommandClickFromForwarding() throws {
        let mirrorView = try makeKeyWindowMirrorView(sessionID: "remote-mouse-command-click")
        var forwarded: [(button: UInt8, pressed: Bool, pointer: TerminalScrollPointerPosition?)] = []
        mirrorView.view.onSendMouseButton = { button, pressed, pointer in forwarded.append((button, pressed, pointer)) }
        mirrorView.view.debugMouseCapturedForTesting = true

        mirrorView.view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: mirrorView.windowNumber, modifierFlags: [.command]))
        mirrorView.view.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: mirrorView.windowNumber, modifierFlags: [.command]))

        XCTAssertTrue(forwarded.isEmpty, "a cmd+click must stay local so it cannot double-open a link the mirror already activated")
    }

    /// A press that did not carry command forwards as today even if command is held down by the time the
    /// matching release arrives: suppression is decided once, at the press.
    @MainActor func testRemoteMirrorForwardsReleaseThatGainsCommandAfterAnUnmodifiedPress() throws {
        let mirrorView = try makeKeyWindowMirrorView(sessionID: "remote-mouse-command-after-press")
        var forwarded: [(button: UInt8, pressed: Bool, pointer: TerminalScrollPointerPosition?)] = []
        mirrorView.view.onSendMouseButton = { button, pressed, pointer in forwarded.append((button, pressed, pointer)) }
        mirrorView.view.debugMouseCapturedForTesting = true

        mirrorView.view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: mirrorView.windowNumber))
        mirrorView.view.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: mirrorView.windowNumber, modifierFlags: [.command]))

        XCTAssertEqual(
            forwarded.map(\.pressed), [true, false], "an unmodified press must still forward its release even if command is held at release")
    }

    /// The release of a cmd+click press stays suppressed even if command has been released by then: the
    /// press and release are withheld as a pair so the session never sees a dangling release.
    @MainActor func testRemoteMirrorSuppressesReleaseThatLosesCommandAfterACommandPress() throws {
        let mirrorView = try makeKeyWindowMirrorView(sessionID: "remote-mouse-command-before-press")
        var forwarded: [(button: UInt8, pressed: Bool, pointer: TerminalScrollPointerPosition?)] = []
        mirrorView.view.onSendMouseButton = { button, pressed, pointer in forwarded.append((button, pressed, pointer)) }
        mirrorView.view.debugMouseCapturedForTesting = true

        mirrorView.view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: mirrorView.windowNumber, modifierFlags: [.command]))
        mirrorView.view.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: mirrorView.windowNumber))

        XCTAssertTrue(forwarded.isEmpty, "a cmd+click press must suppress its release even after command is no longer held")
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

    /// `clearSharedSelectionIfNeeded` runs before any window/surface setup, so it is reachable on a bare
    /// view with no window at all: `suppressesFocusOnlyMousePress` only suppresses when there is a window
    /// that is not yet key, and `focusWindow()` safely no-ops on a nil `window`.
    @MainActor func testMirrorClearsSharedSelectionOnPlainLeftClickAfterAppliedSelection() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "mirror-clear-shared-selection-plain-click", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-08-18T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugRenderFrameApplyHandler = { _, _ in true }
        var clearCount = 0
        mirrorView.onClearSelection = { clearCount += 1 }
        let selection = GhosttyTerminalSelectionRange(
            startColumn: 0, startRow: 0, endColumn: 3, endRow: 0, isRectangle: false, extendsAbove: false, extendsBelow: false)
        let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha", selection: selection))
        mirrorView.update(frame: frame, renderStateKey: "snapshot=5x1")

        mirrorView.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: 0))

        XCTAssertEqual(clearCount, 1)
    }

    /// Shift is the local escape hatch for extending a selection, so a shift-click must never clear it.
    @MainActor func testMirrorDoesNotClearSharedSelectionOnShiftClick() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "mirror-shift-click-preserves-shared-selection", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh",
            command: nil, createdAt: "2026-08-18T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugRenderFrameApplyHandler = { _, _ in true }
        var clearCount = 0
        mirrorView.onClearSelection = { clearCount += 1 }
        let selection = GhosttyTerminalSelectionRange(
            startColumn: 0, startRow: 0, endColumn: 3, endRow: 0, isRectangle: false, extendsAbove: false, extendsBelow: false)
        let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha", selection: selection))
        mirrorView.update(frame: frame, renderStateKey: "snapshot=5x1")

        mirrorView.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: 0, modifierFlags: [.shift]))

        XCTAssertEqual(clearCount, 0)
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
        let macRecordingPath = "/fixtures/recordings/Screen Recording 2026-05-07 at 10.11.01\u{202F}AM.mov"

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
        let initialPayload = remoteStatePayload(sessionID: "stream-preserve-events", reason: TerminalRemoteSessionStateReason.initial.rawValue)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }

        waitForCondition("initial stream payload") { receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.initial.rawValue } }
        receivedPayloads.removeAll()

        server.broadcast(
            remoteStatePayload(
                sessionID: "stream-preserve-events", reason: TerminalRemoteSessionStateReason.output.rawValue, outputByteCount: 11,
                outputEndByteOffset: 42))
        server.broadcast(remoteStatePayload(sessionID: "stream-preserve-events", reason: TerminalRemoteSessionStateReason.inputOutput.rawValue))

        waitForCondition("output before input-output resync") {
            receivedPayloads.count >= 2 && receivedPayloads[0].reason == TerminalRemoteSessionStateReason.output.rawValue
                && receivedPayloads[1].reason == TerminalRemoteSessionStateReason.inputOutput.rawValue
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
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-04T00:00:01Z",
                sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
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
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-05T00:00:01Z",
                sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "done", sessionRevision: 1)))

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send)
        waitForCondition("ended host renders final state") { host.snapshotText() == "done" }
        host.debugSetBindingActionHandler { _ in true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
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
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-05T00:00:01Z",
                sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: finalText, sessionRevision: 1)))

        // The session's full transcript survives in output.log: 200 CRLF-terminated numbered lines.
        let transcript = Data((1...200).map { String(format: "row-%03d", $0) }.joined(separator: "\r\n").utf8)

        // The transcript reports the ended run's identity, matching the run the replay arms against, so
        // it replays normally (the positive counterpart to the mismatched-identity rejection test).
        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _, _, _ in
                RemoteGhosttyTranscript(
                    data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runtimeState.runIdentity)
            })
        waitForCondition("ended host renders final state") { host.snapshotText()?.contains("final-01") == true }

        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
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
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-05T00:00:01Z",
                sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: finalText, sessionRevision: 1)))

        let transcript = Data((1...200).map { String(format: "row-%03d", $0) }.joined(separator: "\r\n").utf8)
        // The first fetch fails like a transport timeout would; the host must return to idle and
        // retry on a later scroll gesture instead of latching scrollback unavailable.
        let attempts = TranscriptFetchAttempts()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _, _, _ in
                if attempts.next() == 1 { throw POSIXError(.ETIMEDOUT) }
                return RemoteGhosttyTranscript(
                    data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runtimeState.runIdentity)
            })
        waitForCondition("ended host renders final state") { host.snapshotText()?.contains("final-01") == true }

        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
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
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-05T00:00:01Z",
                sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: finalText, sessionRevision: 1)))
        let transcript = Data((1...200).map { String(format: "row-%03d", $0) }.joined(separator: "\r\n").utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _, _, _ in
                RemoteGhosttyTranscript(
                    data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runtimeState.runIdentity)
            })
        waitForCondition("ended host renders final state") { host.snapshotText()?.contains("final-01") == true }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
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
        // The ended run's final frame and the relaunched (running) run share a grid, in the runtime rows
        // and in the frames themselves, so the replay wraps like the ended pane's final frame and no
        // payload in this sequence reads as a resize (which would discard the replay on its own).
        let exitedState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-05T00:00:01Z",
            exitedAt: "2026-06-05T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let runningState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 3, state: .running, updatedAt: "2026-06-05T00:00:02Z",
            title: "live-title", workingDirectory: "/tmp/live", columns: 8, rows: 5)
        let endedPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-05T00:00:01Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: exitedState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "final-01", sessionRevision: 1))
        let runningPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-06-05T00:00:02Z",
            sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runningState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live-title", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "RUNNING1", sessionRevision: 2))
        // The relaunched run's own exit: a distinct child process, its own exit time, and a later emission
        // than the live state it follows — which is what the daemon serves for a second exit, and what
        // makes the two runs distinguishable to everything that orders by run rather than by arrival.
        let secondExitState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 3, state: .exited, updatedAt: "2026-06-05T00:00:03Z",
            exitedAt: "2026-06-05T00:00:03Z", title: "final-title", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let secondExitPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-05T00:00:03Z",
            sessionStateRevision: 3, sessionStateFlags: 1, screenStateRevision: 3, runtimeState: secondExitState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "final-01", sessionRevision: 3))
        let recorder = DirectTerminalServiceRecorder(payload: endedPayload)

        // Each fetch suspends until the test resolves it, so the test controls when the OLD run's
        // transcript resumes relative to the relaunch and the NEW run's fetch.
        let transcriptGate = ManualTranscriptProvider()
        let oldTranscript = Data((1...200).map { String(format: "OLD-%04d", $0) }.joined(separator: "\r\n").utf8)
        let newTranscript = Data((1...200).map { String(format: "NEW-%04d", $0) }.joined(separator: "\r\n").utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _, _, _ in try await transcriptGate.fetch() })
        waitForCondition("ended host renders final state") { host.snapshotText()?.contains("final-01") == true }

        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
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
        recorder.setPayload(secondExitPayload)
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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-05T00:00:01Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: exitedStateA,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title-A", workingDirectory: "/tmp/final", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "final-A", sessionRevision: 1))
        let endedPayloadB = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-05T00:00:02Z",
            sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: exitedStateB,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title-B", workingDirectory: "/tmp/final", outputByteCount: nil,
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
            transcriptProvider: { _, _, _ in
                attempts.next() == 1
                    ? RemoteGhosttyTranscript(
                        data: transcriptA, startByteOffset: 0, endByteOffset: UInt64(transcriptA.count), fileIdentity: fakeTranscriptFileIdentity,
                        runIdentity: exitedStateA.runIdentity)
                    : RemoteGhosttyTranscript(
                        data: transcriptB, startByteOffset: 0, endByteOffset: UInt64(transcriptB.count), fileIdentity: fakeTranscriptFileIdentity,
                        runIdentity: exitedStateB.runIdentity)
            })
        waitForCondition("ended host renders run A final state") { host.snapshotText()?.contains("final-A") == true }

        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
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

    /// A transcript labelled with a run other than the one the replay is armed against is rejected, and
    /// the rejection is retryable rather than final: the label is read from runtime state the daemon
    /// commits write-behind, so a pane that paints before that commit lands sees the new run's bytes under
    /// the previous run's identity. The pane returns to idle and the next gesture reads again, which is
    /// what keeps scrolling alive once the labels agree.
    @MainActor func testEndedRemoteHostRetriesATranscriptReportedForADifferentRun() throws {
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
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-05T00:00:01Z",
                sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: exitedStateA,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title-A", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "final-A", sessionRevision: 1)))

        // Every fetch resolves with a transcript labelled with a *different* run (childPID 4, exitedAt T2)
        // until the test swaps the label, which is what a relaunch whose runtime-state commit has not
        // landed yet looks like from here: the bytes the endpoint serves carry a run this pane's armed run
        // key does not match.
        let attempts = TranscriptFetchAttempts()
        let transcript = MutableTranscript(Data((1...200).map { String(format: "NEWRUN-%04d", $0) }.joined(separator: "\r\n").utf8))
        let servedRunIdentity = MutableRunIdentity("4|2026-06-05T00:00:02Z")
        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: { _, _, _ in
                _ = attempts.next()
                let data = transcript.current
                return RemoteGhosttyTranscript(
                    data: data, startByteOffset: 0, endByteOffset: UInt64(data.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: servedRunIdentity.current)
            })
        waitForCondition("ended host renders run A final state") { host.snapshotText()?.contains("final-A") == true }

        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:03Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        // The scroll arms the replay and fetches; the mismatched-identity response is rejected.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("mismatched-identity transcript fetch completes") { attempts.count >= 1 }

        // The viewport keeps the run A final frame and never shows the rejected run's rows, however many
        // gestures ask again while the label stays wrong.
        for _ in 0..<5 {
            _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        guard let text = host.snapshotText() else { return XCTFail("ended host lost its rendered surface") }
        XCTAssertTrue(text.contains("final-A"), "the armed run's final frame was replaced: \(text)")
        XCTAssertFalse(text.contains("NEWRUN-"), "the mismatched-run transcript replaced the viewport: \(text)")

        // Each of those gestures read again rather than being absorbed by a latched verdict.
        let mismatchedAttempts = attempts.count
        XCTAssertGreaterThanOrEqual(mismatchedAttempts, 2, "a rejected run label must be read again rather than latching scrollback off")

        // The runtime state catches up, so the endpoint labels the same bytes with the run the pane is
        // armed against: the next gesture builds its replay and scrolls it.
        transcript.current = Data((1...200).map { String(format: "OLDRUN-%04d", $0) }.joined(separator: "\r\n").utf8)
        servedRunIdentity.current = exitedStateA.runIdentity
        waitForCondition("the retried read scrolls once the labels agree", timeout: 4) {
            _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            guard let text = host.snapshotText() else { return false }
            return text.contains("OLDRUN-") && !text.contains("final-A")
        }
        XCTAssertGreaterThan(attempts.count, mismatchedAttempts, "the healing gesture must have read the transcript again")
        XCTAssertFalse(host.snapshotText()?.contains("NEWRUN-") == true, "the rejected transcript must never render")
    }

    // MARK: - Client-local scrollback on a live pane

    /// A live pane reads its first page of transcript as soon as it has painted a frame, so the user's
    /// first wheel event scrolls instead of waiting out a round trip. The read is the page size, not the
    /// whole budget, and it is a suffix read rather than a continuation.
    @MainActor func testLivePanePrefetchesItsScrollbackAfterTheFirstPaintedFrame() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-prefetch", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: Self.transcript(rows: 1...200), startByteOffset: 0, endByteOffset: UInt64(Self.transcript(rows: 1...200).count),
                fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }

        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.maxBytes, TerminalScrollbackBudget.initialLocalScrollbackPageBytes)
        XCTAssertNil(request.fromByteOffset, "the first read builds a replay, so it must be a suffix read rather than a continuation")
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "prefetching must not put the pane into its replay before the user scrolls")
    }

    /// The feature itself (issue #693): scrolling a live pane scrolls the pane's own replay of the
    /// session's transcript and tells the daemon nothing, so the session's viewport - which every other
    /// viewer shares - stays where it is.
    @MainActor func testLivePaneScrollsItsOwnReplayWithoutTellingTheDaemon() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-local", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        waitForCondition("the pane shows its own transcript rows") {
            guard let text = host.snapshotText() else { return false }
            return text.contains("row-0") && !text.contains("live-01")
        }
        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame)
        XCTAssertFalse(controlCommands(recorder).contains("scroll"), "a local scroll must not move the session's shared viewport")
        XCTAssertTrue(host.debugJumpToBottomControlIsVisible, "a pane showing its own history must offer the jump back to the live screen")
    }

    /// A full-screen program owns the wheel: the alternate screen has no scrollback of its own, so every
    /// event is forwarded exactly as it was before panes had a local viewport.
    @MainActor func testAlternateScreenSessionForwardsWheelEventsToTheDaemon() throws {
        try assertWheelIsForwarded(sessionID: "live-scrollback-alt-screen", alternateScreenActive: true, mouseReportingActive: false)
    }

    /// A program tracking the mouse wants the wheel as a mouse report, so it is forwarded too.
    @MainActor func testMouseReportingSessionForwardsWheelEventsToTheDaemon() throws {
        try assertWheelIsForwarded(sessionID: "live-scrollback-mouse-reporting", alternateScreenActive: false, mouseReportingActive: true)
    }

    @MainActor private func assertWheelIsForwarded(sessionID: String, alternateScreenActive: Bool, mouseReportingActive: Bool) throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: sessionID, root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(
            payload: try liveScrollbackPayload(
                session, text: Self.liveScreen, revision: 1, alternateScreenActive: alternateScreenActive, mouseReportingActive: mouseReportingActive)
        )
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        waitForCondition("the wheel event reaches the session") { self.controlCommands(recorder).contains("scroll") }
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "a forwarded gesture must leave the pane showing the session's own frames")
    }

    /// A program can enable the alternate screen while a stale replay is still on screen from an earlier
    /// gesture. The next gesture reroutes to the daemon (the session it would scroll is no longer the
    /// replay's own primary screen), and that reroute must not leave the pane showing history while the
    /// wheel drives a screen nobody can see: the pane has to return to the live frame first.
    @MainActor func testGestureReroutedToTheDaemonLeavesTheStaleReplayBeforeDrivingTheHiddenScreen() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-alt-screen-while-replaying", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        // Scroll the primary screen's replay into history, then end the gesture the same way a flick ends
        // elsewhere in this file, so the next wheel event starts a fresh gesture and re-decides its route.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane shows its own transcript rows") { host.debugIsShowingLocalScrollbackFrame }
        _ = host.sendScroll(
            horizontal: 0, vertical: 0, scrollMods: GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended),
            pointerPosition: nil)

        // The session switches to the alternate screen while the stale replay is still on screen. This
        // frame is applied underneath the replay without repainting it (see `applyReducedState`), so the
        // transcript end offset it also carries is what a poll can observe to know the frame landed.
        recorder.setPayload(
            try liveScrollbackPayload(session, text: Self.liveScreen, revision: 2, outputEndByteOffset: transcript.count, alternateScreenActive: true)
        )
        waitForCondition("the pane observes the session switching to the alternate screen") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == UInt64(transcript.count)
        }
        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame, "the frame underneath updates without repainting the stale replay on screen")

        // The next gesture reroutes to the daemon and must leave the stale replay before its wheel reaches
        // the program that changed screens underneath it.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the wheel event reaches the session") { self.controlCommands(recorder).contains("scroll") }
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "the rerouted gesture must put the pane back on the live screen")
    }

    /// Typing does not cancel a gesture the session owns. The full-screen program reading those wheel
    /// events decides for itself what a keystroke in the middle of them means, and none of them can paint
    /// this pane's history over the keystroke's screen, so the rest of the flick is forwarded as usual.
    @MainActor func testTypingDuringAnAlternateScreenFlickKeepsForwardingIt() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-alt-screen-typing", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(
            payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1, alternateScreenActive: true, mouseReportingActive: false))
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        let momentum = GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .changed)
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: momentum, pointerPosition: nil))
        waitForCondition("the flick reaches the session") { self.scrollControlCount(recorder) >= 1 }
        let forwardedBeforeTheKeystroke = scrollControlCount(recorder)

        XCTAssertTrue(host.sendTextAsPaste("echo hi"))

        _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: momentum, pointerPosition: nil)
        waitForCondition("the rest of the flick still reaches the session") { self.scrollControlCount(recorder) > forwardedBeforeTheKeystroke }
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "a forwarded gesture must leave the pane showing the session's own frames")
    }

    /// One read per gesture of whatever the session wrote since the last one, asked for as a continuation
    /// from where the replay ends and proved with the bytes the replay already holds there.
    @MainActor func testSecondGestureReadsWhatTheSessionWroteSinceTheFirst() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-continuation", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let firstHalf = Self.transcript(rows: 1...100)
        let secondHalf = Data("\r\n".utf8) + Self.transcript(rows: 101...200)
        let totalBytes = UInt64(firstHalf.count + secondHalf.count)
        let provider = RecordingTranscriptProvider { request in
            guard let fromByteOffset = request.fromByteOffset else {
                return RemoteGhosttyTranscript(
                    data: firstHalf, startByteOffset: 0, endByteOffset: UInt64(firstHalf.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runIdentity)
            }
            return RemoteGhosttyTranscript(
                data: secondHalf, startByteOffset: fromByteOffset, endByteOffset: totalBytes, fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        // A pane that is genuinely on screen: an off-screen pane holds its screen updates, and this test
        // needs the payload that reports the session's new output to actually reach the host.
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        // One gesture, ended by its momentum, against the page the pane already holds.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the first gesture scrolls the replay") { host.snapshotText()?.contains("row-0") == true }
        _ = host.sendScroll(
            horizontal: 0, vertical: 0, scrollMods: GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended),
            pointerPosition: nil)
        XCTAssertEqual(provider.requests.count, 1, "a gesture must not read anything while the session has written nothing new")

        // The session writes: the next state payload reports where `output.log` now ends.
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.liveScreen, revision: 2, outputEndByteOffset: Int(totalBytes)))
        waitForCondition("the pane observes where the session's output now ends") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == totalBytes
        }

        // The next gesture reads exactly the bytes since the replay's end, naming the transcript file its
        // replay was built from.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture reads the continuation") { provider.requests.count >= 2 }
        let continuation = try XCTUnwrap(provider.requests.last)
        XCTAssertEqual(continuation.fromByteOffset, UInt64(firstHalf.count))
        XCTAssertEqual(
            continuation.fileIdentity, fakeTranscriptFileIdentity,
            "a continuation must name the transcript file the replay was built from, which is what proves the offset still names its bytes")

        // The appended rows are in the replay: scrolling back down reaches them. One row per step, and
        // stopping at the first appended row, because a step onto the replay's newest row hands the pane
        // back to the session's own screen.
        waitForCondition("the appended rows are reachable in the replay") {
            _ = host.sendScroll(horizontal: 0, vertical: -18, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            return host.snapshotText()?.contains("row-101") == true
        }
    }

    /// A continuation's bytes are replayed into the replay off the main actor, because replaying a page
    /// through libghostty-vt is tens of milliseconds the pane would otherwise spend frozen: no scrolling,
    /// no rendering, no input. The replay belongs to that hop while it runs, so the gesture that is still
    /// moving buffers its rows instead of scrolling a replay that is not here, and the install applies
    /// them - the flick lands where the finger left it, over a replay that now holds the appended rows.
    @MainActor func testAGestureDuringTheContinuationAppendLandsWhenTheReplayComesBack() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-append-gesture", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let page = Self.transcript(rows: 1...200)
        let writtenSince = Data("\r\n".utf8) + Self.transcript(rows: 201...260)
        let totalBytes = UInt64(page.count + writtenSince.count)
        let provider = GatedTranscriptProvider()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        // A pane that is genuinely on screen: an off-screen pane holds its screen updates, and this test
        // needs the payload that reports the session's new output to actually reach the host.
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("the pane starts reading its scrollback page") { provider.requests.count >= 1 }
        let gestureEnd = GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended)

        // A replay on screen, a little way back into the page the pane holds.
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: page, startByteOffset: 0, endByteOffset: UInt64(page.count), fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        )
        waitForCondition("the first gesture scrolls the replay") {
            _ = host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            return host.debugIsShowingLocalScrollbackFrame
        }
        _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)

        // The session writes, so the next gesture reads what it wrote.
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.liveScreen, revision: 2, outputEndByteOffset: Int(totalBytes)))
        waitForCondition("the pane observes where the session's output now ends") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == totalBytes
        }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture starts its continuation read") { provider.requests.count >= 2 }
        let rowsBeforeTheAppend = try XCTUnwrap(topVisibleTranscriptRow(host))

        // The read is answered and the gesture keeps moving while its bytes are replayed off the main
        // actor.
        let scrolledDuringTheAppend = MainActorFlag()
        host.debugOnLocalScrollbackReplayHandedToLoad = { [weak host] in
            guard let host, !scrolledDuringTheAppend.isSet else { return }
            scrolledDuringTheAppend.isSet = true
            _ = host.sendScroll(horizontal: 0, vertical: 360, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
        }
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: writtenSince, startByteOffset: UInt64(page.count), endByteOffset: totalBytes, fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity))
        waitForCondition("the appended bytes land and the replay comes back") {
            scrolledDuringTheAppend.isSet && !host.debugLoadHoldsLocalScrollbackReplay
        }

        // The rows the gesture scrolled while the replay was away are applied: the pane is further back in
        // history than the append left it, rather than sitting exactly where the gesture found it.
        let rowsAfterTheAppend = try XCTUnwrap(topVisibleTranscriptRow(host))
        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame)
        XCTAssertLessThanOrEqual(
            rowsAfterTheAppend, rowsBeforeTheAppend - 15,
            "the rows scrolled while the append held the replay were dropped: \(rowsBeforeTheAppend) -> \(rowsAfterTheAppend)")

        // And the appended rows are in the replay. One row per step, stopping at the first appended row,
        // because a step onto the replay's newest row hands the pane back to the session's own screen.
        waitForCondition("the appended rows are reachable in the replay") {
            _ = host.sendScroll(horizontal: 0, vertical: -18, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            return host.snapshotText()?.contains("row-201") == true
        }
    }

    /// Jumping to the bottom while a continuation is being replayed into the replay off the main actor
    /// has to reach that replay too. The pane goes back to the live screen straight away, but the replay
    /// is with the append, so the rewind is owed and paid at the install: otherwise the replay comes back
    /// parked where the reader left it and their next gesture jumps into history they already walked away
    /// from, instead of starting at the live bottom.
    @MainActor func testJumpingToTheBottomDuringTheContinuationAppendStartsTheNextGestureAtTheLiveBottom() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-jump-mid-append", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let page = Self.transcript(rows: 1...200)
        let writtenSince = Data("\r\n".utf8) + Self.transcript(rows: 201...260)
        let totalBytes = UInt64(page.count + writtenSince.count)
        let provider = GatedTranscriptProvider()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("the pane starts reading its scrollback page") { provider.requests.count >= 1 }
        let gestureEnd = GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended)

        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: page, startByteOffset: 0, endByteOffset: UInt64(page.count), fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        )
        waitForCondition("the first gesture scrolls the replay") {
            _ = host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            return host.debugIsShowingLocalScrollbackFrame
        }
        _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.liveScreen, revision: 2, outputEndByteOffset: Int(totalBytes)))
        waitForCondition("the pane observes where the session's output now ends") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == totalBytes
        }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture starts its continuation read") { provider.requests.count >= 2 }

        // The reader jumps back to the live screen while the appended bytes are being replayed.
        let jumpedDuringTheAppend = MainActorFlag()
        host.debugOnLocalScrollbackReplayHandedToLoad = { [weak host] in
            guard let host, !jumpedDuringTheAppend.isSet else { return }
            jumpedDuringTheAppend.isSet = true
            host.debugActivateJumpToBottom()
        }
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: writtenSince, startByteOffset: UInt64(page.count), endByteOffset: totalBytes, fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity))
        waitForCondition("the appended bytes land and the replay comes back") {
            jumpedDuringTheAppend.isSet && !host.debugLoadHoldsLocalScrollbackReplay
        }
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "the jump must leave the replay")
        XCTAssertEqual(host.snapshotText()?.contains("live-01"), true, "the jump must put the session's own screen back")

        // The wheel goes quiet past the idle boundary, which ends the gesture the jump cancelled, and the
        // next one reads back from the live bottom: the newest rows the replay holds, which are the ones
        // the continuation appended, rather than the rows the reader jumped away from.
        let idleDeadline = Date().addingTimeInterval(Self.scrollGestureIdlePause)
        while Date() < idleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 180, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame)
        let topRow = try XCTUnwrap(topVisibleTranscriptRow(host))
        XCTAssertGreaterThan(
            topRow, 200, "the gesture after the jump started from the offset the reader left rather than from the live bottom: row-\(topRow)")
    }

    /// The other half of a continuation: a transcript the daemon could not serve as one comes back as a
    /// fresh suffix, and the replay is rebuilt from it off the main actor. The rebuilt replay is put back
    /// at the distance above its newest row the reader was at, so a jump to the bottom while that build
    /// holds the replay has to reach it too: otherwise the install restores the offset the reader just
    /// left and their next gesture reads back from history instead of from the live bottom.
    @MainActor func testJumpingToTheBottomDuringASuffixRebuildStartsTheNextGestureAtTheLiveBottom() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-jump-mid-rebuild", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let page = Self.transcript(rows: 1...400)
        // What a head-trim left behind: a file the replay's own offset no longer names, so the daemon
        // answers the continuation with a replayable suffix instead of the bytes since that offset.
        let rebuilt = Self.transcript(rows: 1...600)
        let provider = GatedTranscriptProvider()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("the pane starts reading its scrollback page") { provider.requests.count >= 1 }
        let gestureEnd = GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended)

        // A reader well back into the page the pane holds.
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: page, startByteOffset: 0, endByteOffset: UInt64(page.count), fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        )
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the first gesture scrolls the replay") { host.debugIsShowingLocalScrollbackFrame }
        _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)

        // The transcript's end moves, so the next gesture reads from the replay's own end.
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.liveScreen, revision: 2, outputEndByteOffset: rebuilt.count))
        waitForCondition("the pane observes the transcript's end moving") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == UInt64(rebuilt.count)
        }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture starts its continuation read") { provider.requests.count >= 2 }

        // The reader jumps back to the live screen while the served suffix is being replayed into the
        // replacement replay.
        let jumpedDuringTheRebuild = MainActorFlag()
        host.debugOnLocalScrollbackReplayHandedToLoad = { [weak host] in
            guard let host, !jumpedDuringTheRebuild.isSet else { return }
            jumpedDuringTheRebuild.isSet = true
            host.debugActivateJumpToBottom()
        }
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: rebuilt, startByteOffset: 0, endByteOffset: UInt64(rebuilt.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity, isSuffixRebuild: true))
        waitForCondition("the rebuilt replay is installed") { jumpedDuringTheRebuild.isSet && !host.debugLoadHoldsLocalScrollbackReplay }
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "the jump must leave the replay")
        XCTAssertEqual(host.snapshotText()?.contains("live-01"), true, "the jump must put the session's own screen back")

        // The wheel goes quiet past the idle boundary, which ends the gesture the jump cancelled, and the
        // next one reads back from the rebuilt replay's newest rows rather than from the distance above
        // them the reader jumped away from.
        let idleDeadline = Date().addingTimeInterval(Self.scrollGestureIdlePause)
        while Date() < idleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 180, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame)
        let topRow = try XCTUnwrap(topVisibleTranscriptRow(host))
        XCTAssertGreaterThan(
            topRow, 550, "the gesture after the jump started from the offset the reader left rather than from the live bottom: row-\(topRow)")
    }

    /// Reaching the oldest row the page holds reads the whole retained history once, and the rebuilt
    /// replay keeps the rows the user is looking at exactly where they were.
    @MainActor func testReachingTheOldestRowReadsTheWholeBudgetAndKeepsTheRowsOnScreen() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-budget", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let whole = Self.transcript(rows: 1...200)
        let tail = Self.transcript(rows: 101...200)
        // The page-sized read is served as a suffix starting partway into `output.log`, which is what says
        // a deeper read could return more; the budget-sized read returns the whole file.
        let provider = RecordingTranscriptProvider { request in
            request.maxBytes >= TerminalScrollbackBudget.defaultMaxBytes
                ? RemoteGhosttyTranscript(
                    data: whole, startByteOffset: 0, endByteOffset: UInt64(whole.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runIdentity)
                : RemoteGhosttyTranscript(
                    data: tail, startByteOffset: UInt64(whole.count - tail.count), endByteOffset: UInt64(whole.count),
                    fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        // One gesture of 2000 points: 111 rows at the 18-point cell height the normalizer assumes. The
        // page holds 100 rows, so 95 of them are applied (the viewport is five rows tall) and the
        // remaining 16 are what the deeper replay has to carry.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture reaches the oldest row the page holds and reads the whole budget") { provider.requests.count >= 2 }
        XCTAssertEqual(provider.requests.last?.maxBytes, TerminalScrollbackBudget.defaultMaxBytes)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        // 111 rows above the newest row of a 200-row replay: the rows continue where the gesture left off
        // rather than restarting at either end of the transcript.
        let rebuiltText = try XCTUnwrap(host.snapshotText())
        XCTAssertTrue(rebuiltText.contains("row-085"), "the rebuilt replay did not continue where the gesture left off: \(rebuiltText)")

        // And the deeper history is now reachable.
        waitForCondition("the deeper history is reachable") {
            _ = host.sendScroll(horizontal: 0, vertical: 4000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            return host.snapshotText()?.contains("row-001") == true
        }
        XCTAssertEqual(provider.requests.count, 2, "the whole budget is read once, not once per gesture that sits at the top")
    }

    /// Typing belongs at the session's own bottom row, so an input send leaves the replay and puts the
    /// live screen back.
    @MainActor func testTypingLeavesTheReplayAndShowsTheLiveScreen() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-typing", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane shows its own transcript rows") { host.snapshotText()?.contains("row-0") == true }

        XCTAssertTrue(host.sendTextAsPaste("echo hi"))

        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "typing must leave the replay")
        XCTAssertEqual(host.snapshotText()?.contains("live-01"), true, "typing must put the session's own screen back")
        XCTAssertFalse(host.debugJumpToBottomControlIsVisible)
    }

    /// Cmd+K clears the session's screen and scrollback, and the daemon records that clear in the
    /// transcript. The page this pane read before the clear still holds the rows the clear removed, so
    /// the replay is dropped outright: the next gesture reads again, replays the recorded clear, and
    /// scrolls only what the session has printed since.
    @MainActor func testClearingTheScreenDropsTheReplayThatPredatesIt() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-clear", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        // What the daemon's `output.log` holds after it performs the clear: the history it already had,
        // the clear it records for anyone replaying those bytes, and what the session prints afterwards.
        var clearedTranscript = Self.transcript(rows: 1...200)
        clearedTranscript.append(GhosttyTerminalTranscriptMutation.clearScreenAndScrollback)
        clearedTranscript.append(Data("\r\n".utf8))
        clearedTranscript.append(Data((1...200).map { String(format: "new-%03d", $0) }.joined(separator: "\r\n").utf8))
        let transcript = MutableTranscript(Self.transcript(rows: 1...200))
        let provider = RecordingTranscriptProvider { _ in
            let data = transcript.current
            return RemoteGhosttyTranscript(
                data: data, startByteOffset: 0, endByteOffset: UInt64(data.count), fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane shows its own transcript rows") { host.snapshotText()?.contains("row-0") == true }
        // Back down onto the live screen by hand, and the gesture ends there. The replay survives that
        // return, which is the state this is about: the clear is sent from the live bottom, with a replay
        // of the pre-clear history cached behind it.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: -4000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "setup: the pane is back on the session's own screen")
        _ = host.sendScroll(
            horizontal: 0, vertical: 0, scrollMods: GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended),
            pointerPosition: nil)
        let readsBeforeTheClear = provider.requests.count

        // The daemon performs the clear and its transcript records it. Swapped in before the request is
        // sent so no read can be answered from the pre-clear transcript in between.
        transcript.current = clearedTranscript
        XCTAssertTrue(host.clearScreenAndScrollback())

        waitForCondition("the clear reaches the session") { [self] in controlCommands(recorder).contains("clearScreen") }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        waitForCondition("the gesture after the clear scrolls the rows printed since") { host.snapshotText()?.contains("new-") == true }
        XCTAssertGreaterThan(provider.requests.count, readsBeforeTheClear, "the gesture after the clear must read the transcript again")
        let text = try XCTUnwrap(host.snapshotText())
        XCTAssertFalse(text.contains("row-"), "the rows the clear removed must not come back from the replay read before it: \(text)")
    }

    /// A clear another client sent reaches this pane as a `.clearScreen` state payload, which stamps no
    /// transcript end and so proves nothing new by the offset rule the jump control reads. The replay this
    /// pane cached predates that clear all the same, so the payload's reason is what drops it: without
    /// that, the gesture after ownership comes back scrolls the rows the clear removed.
    @MainActor func testAClearBroadcastByAnotherClientDropsTheReplayThatPredatesIt() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-clear-broadcast", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        // What the daemon's `output.log` holds after the other client's clear: the history it already had,
        // the clear it records for anyone replaying those bytes, and what the session prints afterwards.
        var clearedTranscript = Self.transcript(rows: 1...200)
        clearedTranscript.append(GhosttyTerminalTranscriptMutation.clearScreenAndScrollback)
        clearedTranscript.append(Data("\r\n".utf8))
        clearedTranscript.append(Data((1...200).map { String(format: "new-%03d", $0) }.joined(separator: "\r\n").utf8))
        let transcript = MutableTranscript(Self.transcript(rows: 1...200))
        let provider = RecordingTranscriptProvider { _ in
            let data = transcript.current
            return RemoteGhosttyTranscript(
                data: data, startByteOffset: 0, endByteOffset: UInt64(data.count), fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        // A pane that is genuinely on screen: an off-screen pane holds its screen updates, and this test
        // needs the clear the other client sent to actually reach the host.
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane shows its own transcript rows") { host.snapshotText()?.contains("row-0") == true }
        // Back down onto the live screen by hand, and the gesture ends there. The replay survives that
        // return, which is the state this is about: the other client's clear lands with a replay of the
        // pre-clear history cached behind it.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: -4000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "setup: the pane is back on the session's own screen")
        _ = host.sendScroll(
            horizontal: 0, vertical: 0, scrollMods: GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended),
            pointerPosition: nil)
        let readsBeforeTheClear = provider.requests.count

        // The other client's clear: the daemon performs it, records it in the transcript, and broadcasts
        // the screen it left behind under reason `.clearScreen` with no transcript end stamped on it.
        //
        // Queued as a one-shot ahead of the screen it left behind, which is how the daemon serves it: the
        // clear travels as one broadcast, and every `.state` read after it is answered with the current
        // screen under `.stateChange` (`currentRemoteStatePayload`), never the clear again. Serving the
        // clear to every read instead would let the refresh still in flight when the wait below ends
        // deliver it once more, after the gesture has already put its rows on the load the first clear's
        // discard started, and that second discard drops them with no later event to scroll.
        transcript.current = clearedTranscript
        recorder.setPayloads([
            try liveScrollbackPayload(session, text: Self.newerLiveScreen, revision: 2, reason: .clearScreen),
            try liveScrollbackPayload(session, text: Self.newerLiveScreen, revision: 3),
        ])
        waitForCondition("the clear broadcast reaches the pane") {
            host.requestSurfaceRefresh()
            return host.snapshotText()?.contains("done-01") == true
        }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        waitForCondition("the gesture after the clear scrolls the rows printed since") { host.snapshotText()?.contains("new-") == true }
        XCTAssertGreaterThan(provider.requests.count, readsBeforeTheClear, "the clear broadcast must leave the pane reading the transcript again")
        let text = try XCTUnwrap(host.snapshotText())
        XCTAssertFalse(text.contains("row-"), "the rows the clear removed must not come back from the replay read before it: \(text)")
    }

    /// A main actor that falls behind leaves the apply mailbox folding the `.output` payload that reported
    /// where `output.log` now ends into a later full frame whose reason stamps no offset at all. Only the
    /// survivor applies, so a pane that read the survivor's own fields would never learn the session
    /// printed, and the replay it cached before that output would sit behind the session with no later
    /// payload to heal it. The fold is produced the way production produces it: an off-screen pane holds
    /// its screen updates, so the queued output is still waiting when the next full frame collapses it.
    @MainActor func testAnOutputFoldedIntoALaterFrameStillPagesInWhatTheSessionPrinted() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-coalesced-output", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let firstHalf = Self.transcript(rows: 1...100)
        let secondHalf = Data("\r\n".utf8) + Self.transcript(rows: 101...200)
        let totalBytes = UInt64(firstHalf.count + secondHalf.count)
        let provider = RecordingTranscriptProvider { request in
            guard let fromByteOffset = request.fromByteOffset else {
                return RemoteGhosttyTranscript(
                    data: firstHalf, startByteOffset: 0, endByteOffset: UInt64(firstHalf.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runIdentity)
            }
            return RemoteGhosttyTranscript(
                data: secondHalf, startByteOffset: fromByteOffset, endByteOffset: totalBytes, fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        // Payloads reach the pane over its subscription rather than through a request sender, because only
        // subscription payloads go through the apply mailbox: a direct `.state` response is out-of-band and
        // `ApplyMailbox.mayCollapse` refuses to collapse one in either direction.
        let queue = DispatchQueue(label: "spaces.test.coalesced-output-stream")
        let initialPayload = try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1, reason: .initial)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: session.paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }

        // The pane's terminal container is a subview of a visible window, so hiding it takes the pane off
        // screen exactly the way switching to another tab does.
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        let container = NSView(frame: contentView.bounds)
        contentView.addSubview(container)
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: container)
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the first gesture scrolls the replay") { host.snapshotText()?.contains("row-0") == true }
        _ = host.sendScroll(
            horizontal: 0, vertical: 0, scrollMods: GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended),
            pointerPosition: nil)
        XCTAssertEqual(provider.requests.count, 1, "setup: the session has written nothing new, so the first gesture read nothing more")

        container.isHidden = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // The payload that reports the session's new output, queued while nobody can see the pane.
        server.broadcast(
            try liveScrollbackPayload(session, text: Self.newerLiveScreen, revision: 2, outputEndByteOffset: Int(totalBytes), reason: .output))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNotEqual(
            host.debugLatestTranscriptEndByteOffset, totalBytes, "setup: the held pane must still be holding the output payload, not applying it")
        // The full frame that folds it away. Its own reason stamps no transcript end, so this apply is the
        // pane's only news of what the payload it replaced reported.
        server.broadcast(try liveScrollbackPayload(session, text: Self.newerLiveScreen, revision: 3, reason: .stateChange))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        container.isHidden = false

        waitForCondition("the coalesced apply reports where the session's output now ends") { host.debugLatestTranscriptEndByteOffset == totalBytes }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture reads the continuation") { provider.requests.count >= 2 }
        let continuation = try XCTUnwrap(provider.requests.last)
        XCTAssertEqual(continuation.fromByteOffset, UInt64(firstHalf.count), "the gesture must read exactly the bytes since the replay's end")
        waitForCondition("the appended rows are reachable in the replay") {
            _ = host.sendScroll(horizontal: 0, vertical: -18, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            return host.snapshotText()?.contains("row-101") == true
        }
    }

    /// The same fold, carrying a clear instead: another client's `.clearScreen` broadcast is folded into
    /// the next full frame while this pane is off screen. The clear removed rows the cached replay still
    /// holds, so the apply that replaces it has to drop that replay even though its own reason says
    /// nothing about a clear.
    @MainActor func testAClearFoldedIntoALaterFrameDropsTheReplayThatPredatesIt() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-coalesced-clear", root: root)
        let runIdentity = session.runtimeState.runIdentity
        // What the daemon's `output.log` holds after the other client's clear: the history it already had,
        // the clear it records for anyone replaying those bytes, and what the session prints afterwards.
        var clearedTranscript = Self.transcript(rows: 1...200)
        clearedTranscript.append(GhosttyTerminalTranscriptMutation.clearScreenAndScrollback)
        clearedTranscript.append(Data("\r\n".utf8))
        clearedTranscript.append(Data((1...200).map { String(format: "new-%03d", $0) }.joined(separator: "\r\n").utf8))
        let transcript = MutableTranscript(Self.transcript(rows: 1...200))
        let provider = RecordingTranscriptProvider { _ in
            let data = transcript.current
            return RemoteGhosttyTranscript(
                data: data, startByteOffset: 0, endByteOffset: UInt64(data.count), fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        }
        let queue = DispatchQueue(label: "spaces.test.coalesced-clear-stream")
        let initialPayload = try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1, reason: .initial)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: session.paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }

        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        let container = NSView(frame: contentView.bounds)
        contentView.addSubview(container)
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: container)
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane shows its own transcript rows") { host.snapshotText()?.contains("row-0") == true }
        // Back down onto the live screen by hand, so the clear lands with a replay of the pre-clear
        // history cached behind it rather than on screen.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: -4000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "setup: the pane is back on the session's own screen")
        _ = host.sendScroll(
            horizontal: 0, vertical: 0, scrollMods: GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended),
            pointerPosition: nil)
        let readsBeforeTheClear = provider.requests.count

        container.isHidden = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        transcript.current = clearedTranscript
        server.broadcast(try liveScrollbackPayload(session, text: Self.newerLiveScreen, revision: 2, reason: .clearScreen))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(provider.requests.count, readsBeforeTheClear, "setup: the held pane must still be holding the clear, not applying it")
        server.broadcast(try liveScrollbackPayload(session, text: Self.newerLiveScreen, revision: 3, reason: .stateChange))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        container.isHidden = false
        // The drain the redisplay schedules is a main-actor task, so the collapsed apply lands after this
        // call returns; the gesture below has to come after it, not race it.
        waitForCondition("the collapsed apply paints the screen the pane was held on") { host.snapshotText()?.contains("done-01") == true }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture after the clear scrolls the rows printed since") { host.snapshotText()?.contains("new-") == true }
        XCTAssertGreaterThan(provider.requests.count, readsBeforeTheClear, "the folded-away clear must leave the pane reading the transcript again")
        let text = try XCTUnwrap(host.snapshotText())
        XCTAssertFalse(text.contains("row-"), "the rows the clear removed must not come back from the replay read before it: \(text)")
    }

    /// The jump control returns a pane to the live screen with no request at all: the session's viewport
    /// never moved, so the frame the pane already holds is the current screen. Output that arrived while
    /// the user was reading back is marked on the control until they come back.
    @MainActor func testJumpToBottomLeavesTheReplayWithoutAskingTheDaemon() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-jump", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        // A pane that is genuinely on screen: an off-screen pane holds its screen updates, and this test
        // needs the output that arrives while the user reads back to actually reach the host.
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane shows its own transcript rows") { host.snapshotText()?.contains("row-0") == true }

        // The session prints while the user reads back: an output broadcast, which reports where
        // `output.log` now ends. That report is what says the session wrote something, and it is what the
        // new-output mark is driven by - a frame's mere arrival is not, since repaint-only broadcasts
        // carry one too.
        recorder.setPayload(
            try liveScrollbackPayload(
                session, text: "live-06\nlive-07\nlive-08\nlive-09\nlive-10", revision: 2, outputEndByteOffset: transcript.count + 8, reason: .output)
        )
        waitForCondition("the control marks the output that arrived underneath") {
            host.requestSurfaceRefresh()
            return host.debugJumpToBottomControlShowsNewOutput
        }
        XCTAssertTrue(host.snapshotText()?.contains("row-0") == true, "new output must not yank the reader off the rows they are on")

        host.debugActivateJumpToBottom()

        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame)
        XCTAssertEqual(host.snapshotText()?.contains("live-10"), true, "the jump must show the session's current screen")
        XCTAssertFalse(host.debugJumpToBottomControlShowsNewOutput, "coming back to the live screen clears the new-output mark")
        XCTAssertFalse(
            controlCommands(recorder).contains("scrollToBottom"), "a pane showing its own history jumps locally, without asking the session")
    }

    /// Scrolling by hand back down onto the replay's newest row is the third way back to the live screen,
    /// and the one a reader reaches without touching the control: the pane paints the session's own frame
    /// again and the control goes away, because the replay's newest row is only as fresh as the transcript
    /// page it was read from. The gesture is not cancelled, so scrolling straight back up re-enters the
    /// replay it rewound, with no read of the transcript to pay for.
    @MainActor func testScrollingBackDownToTheBottomShowsTheLiveScreenAgain() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-back-down", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane shows its own transcript rows") { host.snapshotText()?.contains("row-0") == true }
        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame)
        let readsWhileReadingBack = provider.requests.count

        // The same gesture reverses and runs past the replay's newest row.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: -4000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "the replay's bottom is not the current screen, the session's own frame is")
        XCTAssertEqual(host.snapshotText()?.contains("live-01"), true, "scrolling back down by hand must hand the pane back to the live frame")
        XCTAssertFalse(host.debugJumpToBottomControlIsVisible, "a pane back on the live screen has nothing to jump to")

        // Nothing cancelled the gesture, so the next upward delta reads the history again from the replay
        // that survived, rather than paying for a fresh page.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame, "an upward delta re-enters the replay the return rewound")
        XCTAssertTrue(host.snapshotText()?.contains("row-0") == true)
        XCTAssertEqual(provider.requests.count, readsWhileReadingBack, "the replay survived the return, so re-entering it reads nothing")
        XCTAssertFalse(controlCommands(recorder).contains("scroll"), "none of this moves the session's shared viewport")
    }

    /// The jump control's new-output mark says the session *wrote* something while the user was reading
    /// back, not that a frame arrived. The daemon broadcasts a full frame for repaint-only events too -
    /// another viewer changing the shared selection is one - and a reader scrolled into history must not
    /// be told there is something new to come back to when nothing was written, nor pay for a
    /// continuation read that has nothing to read.
    @MainActor func testARepaintOnlyFrameDuringAReplayMarksNoNewOutput() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-repaint-only", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let page = Self.transcript(rows: 1...400)
        let appended = Data("\r\nrow-401".utf8)
        let appendedEndByteOffset = page.count + appended.count
        let recorder = DirectTerminalServiceRecorder(
            payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1, outputEndByteOffset: page.count))
        let provider = RecordingTranscriptProvider { request in
            guard let fromByteOffset = request.fromByteOffset else {
                return RemoteGhosttyTranscript(
                    data: page, startByteOffset: 0, endByteOffset: UInt64(page.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runIdentity)
            }
            return RemoteGhosttyTranscript(
                data: appended, startByteOffset: fromByteOffset, endByteOffset: UInt64(appendedEndByteOffset),
                fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        // The payloads below have to actually reach the host, and an off-screen pane holds its screen
        // updates.
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        let gestureEnd = GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended)
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane shows its own transcript rows") { host.debugIsShowingLocalScrollbackFrame }
        _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)

        // Another viewer changes the shared selection. A Linux daemon stamps every payload with where
        // `output.log` ends, so this one carries a full frame at a transcript end that has not moved.
        recorder.setPayload(
            try liveScrollbackPayload(
                session, text: "sel-001\nsel-002\nsel-003\nsel-004\nsel-005", revision: 2, outputEndByteOffset: page.count, reason: .selection))
        for _ in 0..<30 {
            host.requestSurfaceRefresh()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(host.debugJumpToBottomControlShowsNewOutput, "a repaint-only broadcast marked new output the session never wrote")
        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame, "the repaint-only frame must not yank the reader off the rows they are on")

        // And the gesture after it has nothing to read: the replay is already level with the transcript.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(provider.requests.count, 1, "a gesture read the transcript again for a broadcast that wrote nothing")

        // The same broadcast from a Mac daemon, which stamps that field on output payloads only: a full
        // frame with no transcript end at all, under a reason that is not output.
        recorder.setPayload(try liveScrollbackPayload(session, text: "sel-011\nsel-012\nsel-013\nsel-014\nsel-015", revision: 3, reason: .selection))
        for _ in 0..<30 {
            host.requestSurfaceRefresh()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(host.debugJumpToBottomControlShowsNewOutput, "a repaint-only broadcast that stamps no transcript end marked new output")
        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame, "the repaint-only frame must not yank the reader off the rows they are on")

        // The jump proves those frames did reach the host, so the assertions above were not made against
        // payloads still in flight.
        host.debugActivateJumpToBottom()
        XCTAssertEqual(host.snapshotText()?.contains("sel-011"), true, "the repaint-only frames never reached the host")

        // Real output, on the other hand, both marks the control and is what the next gesture reads.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane is back in its own history") { host.debugIsShowingLocalScrollbackFrame }
        _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)
        recorder.setPayload(
            try liveScrollbackPayload(
                session, text: "out-001\nout-002\nout-003\nout-004\nout-005", revision: 4, outputEndByteOffset: appendedEndByteOffset, reason: .output
            ))
        waitForCondition("the pane observes where the session's output now ends") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == UInt64(appendedEndByteOffset)
        }

        XCTAssertTrue(host.debugJumpToBottomControlShowsNewOutput, "output that arrived while the user reads back must mark the jump control")
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture reads what the session appended") { provider.requests.count >= 2 }
        XCTAssertEqual(try XCTUnwrap(provider.requests.last).fromByteOffset, UInt64(page.count))
    }

    /// The shared selection is anchored in the session's own screen, which a pane showing its replay is
    /// not looking at: a drag over replayed rows names rows of this client's own copy of the transcript.
    /// Committing those would move the selection every other viewer sees onto text nobody selected, so
    /// while a replay frame is on screen no selection request leaves the host at all - neither the commit
    /// a drag's release makes nor the clear a plain click makes. Both resume the moment the pane is back
    /// on the session's own screen.
    @MainActor func testADragOnTheReplayCommitsNoSharedSelection() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-selection", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...400)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        let container = try XCTUnwrap(window.contentView)
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: container)
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the pane shows its own transcript rows") { host.debugIsShowingLocalScrollbackFrame }
        // The two callbacks the mirror view fires from its own mouse handling: the clear a plain
        // mouse-down makes, and the commit a drag's release makes (`commitLocalSelectionIfPresent`),
        // reporting rows of whatever viewport the pane last painted.
        let mirrorView = try XCTUnwrap(
            container.subviews.compactMap { $0 as? GhosttyMirrorTerminalView }.first, "the pane never installed its mirror view")

        mirrorView.onClearSelection?()
        mirrorView.onSetSelection?(1, 12, 6, 12, false)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        let commandsDuringReplay = controlCommands(recorder)
        XCTAssertFalse(
            commandsDuringReplay.contains("setSelection"), "a drag over replayed rows committed replay coordinates as the session's shared selection")
        XCTAssertFalse(
            commandsDuringReplay.contains("clearSelection"), "a click on a replay frame cleared the selection every other viewer is looking at")

        // Back on the session's own screen, where the pane's rows are the session's rows again, both
        // requests reach the daemon. The repaint the jump makes is also what drops any highlight the
        // local drag left on the surface: applying a frame paints the selection that frame carries and
        // clears one it does not.
        host.debugActivateJumpToBottom()
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame)
        XCTAssertEqual(host.snapshotText()?.contains("live-01"), true, "the jump must put the session's own screen back")

        mirrorView.onSetSelection?(1, 2, 6, 2, false)

        waitForCondition("the commit made on the live screen reaches the session") { self.controlCommands(recorder).contains("setSelection") }
    }

    /// Discarding a replay (a keystroke, a resize, a relaunch) leaves any continuation read it started
    /// running. That read resolving must not retire the mark the *current* replay's own read set: a
    /// gesture would then start a second read of the same range while the first is still in flight, and
    /// both would append those bytes to the replay.
    @MainActor func testAStaleContinuationReadDoesNotUnlockTheCurrentReplaysRead() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-stale-continuation", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let page = Self.transcript(rows: 1...400)
        let pageTranscript = RemoteGhosttyTranscript(
            data: page, startByteOffset: 0, endByteOffset: UInt64(page.count), fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity)
        let writtenSince = Data("\r\nrow-401".utf8)
        let transcriptEndByteOffset = page.count + writtenSince.count
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let provider = GatedTranscriptProvider()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("the pane starts reading its scrollback page") { provider.requests.count >= 1 }
        let gestureEnd = GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended)

        // A replay, scrolled onto the screen.
        provider.resolveLast(pageTranscript)
        waitForCondition("the first replay is ready and scrolls") {
            _ = host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)
            return host.debugIsShowingLocalScrollbackFrame
        }

        // The session writes, so the next gesture reads what it wrote. That read is left in flight.
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.liveScreen, revision: 2, outputEndByteOffset: transcriptEndByteOffset))
        waitForCondition("the pane observes where the session's output now ends") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == UInt64(transcriptEndByteOffset)
        }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)
        waitForCondition("the gesture starts its continuation read") { provider.requests.count >= 2 }
        XCTAssertEqual(try XCTUnwrap(provider.requests.last).fromByteOffset, UInt64(page.count))

        // The user types: the replay is discarded with that read still in flight, and the pane reads a
        // fresh page and opens a second replay over the same session.
        XCTAssertTrue(host.sendTextAsPaste("echo hi"))
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "typing must leave the replay")
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.liveScreen, revision: 3, outputEndByteOffset: transcriptEndByteOffset))
        waitForCondition("the pane reads a fresh page for the replay it reopens") {
            host.requestSurfaceRefresh()
            return provider.requests.count >= 3
        }
        provider.resolveLast(pageTranscript)
        waitForCondition("the reopened replay's gesture starts its own continuation read") {
            _ = host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)
            return provider.requests.count >= 4
        }

        // The read the first replay left behind lands now, against a replay that is gone.
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: writtenSince, startByteOffset: UInt64(page.count), endByteOffset: UInt64(transcriptEndByteOffset),
                fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity))
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        _ = host.sendScroll(horizontal: 0, vertical: 0, scrollMods: gestureEnd, pointerPosition: nil)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertEqual(
            provider.requests.count, 4,
            "a stale read's completion unlocked the current replay's read, so a gesture stacked a second read of the same range on it")
    }

    /// A keystroke that lands mid-flick has to end that flick. The pane is back on the live screen the
    /// keystroke belongs to, while the momentum events still arriving carry the route the gesture
    /// latched: without cancelling the gesture, the very next delta reads a fresh page and paints the
    /// history the user just left right back over the screen they typed into.
    @MainActor func testTypingDuringMomentumDropsTheRestOfTheFlick() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-typing-momentum", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        let momentum = GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .changed)
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: momentum, pointerPosition: nil))
        waitForCondition("the flick scrolls the pane into its own history") { host.snapshotText()?.contains("row-0") == true }

        XCTAssertTrue(host.sendTextAsPaste("echo hi"))
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "typing must leave the replay")

        // The flick is still travelling. Everything left of it goes nowhere: not to the replay, and not
        // to the daemon either, since the user left history on purpose.
        _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: momentum, pointerPosition: nil)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "a cancelled flick's momentum put the pane back into its replay")
        let text = try XCTUnwrap(host.snapshotText())
        XCTAssertFalse(text.contains("row-"), "a cancelled flick's momentum painted history over the live screen: \(text)")
        XCTAssertTrue(text.contains("live-01"), "the keystroke's own screen must stay showing: \(text)")
        XCTAssertFalse(controlCommands(recorder).contains("scroll"), "a cancelled gesture's deltas must not reach the session either")

        // The momentum ending is the gesture's end, so the next flick scrolls like any other.
        _ = host.sendScroll(
            horizontal: 0, vertical: 0, scrollMods: GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended),
            pointerPosition: nil)
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture after the cancelled one scrolls the replay again") { host.snapshotText()?.contains("row-0") == true }
    }

    /// A gesture latches on its first event, which can be a fraction of a row: nothing is painted, and the
    /// pane is still showing the session's own screen. Typing there has no replay to leave, but the gesture
    /// behind the keystroke is still travelling, and its remaining deltas would scroll the replay and paint
    /// history over the screen the keystroke belongs to, so the latch is cancelled on input whether or not
    /// the replay was showing.
    @MainActor func testTypingDuringAGestureThatHasNotCrossedARowDropsTheRestOfIt() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-typing-sub-row", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        // A wheel gesture whose first event is worth less than one row: the route latches, and the pane
        // paints nothing.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 5, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "a sub-row delta must not put the pane into its replay")

        XCTAssertTrue(host.sendTextAsPaste("echo hi"))

        // The rest of the gesture, worth many rows, goes nowhere: not to the replay, and not to the daemon.
        for _ in 0..<4 { _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil) }
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "a cancelled gesture's deltas put the pane into its replay")
        let text = try XCTUnwrap(host.snapshotText())
        XCTAssertFalse(text.contains("row-"), "a cancelled gesture painted history over the live screen: \(text)")
        XCTAssertTrue(text.contains("live-01"), "the keystroke's own screen must stay showing: \(text)")
        XCTAssertFalse(controlCommands(recorder).contains("scroll"), "a cancelled gesture's deltas must not reach the session either")
        XCTAssertEqual(provider.requests.count, 1, "a cancelled gesture must not read another page of the transcript")

        // The idle boundary ends the cancelled gesture, so the next one scrolls the replay like any other.
        let idleDeadline = Date().addingTimeInterval(Self.scrollGestureIdlePause)
        while Date() < idleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture after the cancelled one scrolls the replay again") { host.snapshotText()?.contains("row-0") == true }
    }

    /// The jump control cancels the gesture it lands in for the same reason, and it has more to lose: the
    /// replay survives the jump, so the flick's remaining momentum would scroll the user straight back
    /// off the live screen they just asked for.
    @MainActor func testJumpToBottomDuringMomentumDropsTheRestOfTheFlick() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-jump-momentum", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        let momentum = GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .changed)
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: momentum, pointerPosition: nil))
        waitForCondition("the flick scrolls the pane into its own history") { host.snapshotText()?.contains("row-0") == true }

        host.debugActivateJumpToBottom()
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "the jump must show the live screen")

        _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: momentum, pointerPosition: nil)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "the flick's momentum scrolled the pane back off the screen it jumped to")
        let text = try XCTUnwrap(host.snapshotText())
        XCTAssertTrue(text.contains("live-01"), "the jump's own screen must stay showing: \(text)")
        XCTAssertFalse(controlCommands(recorder).contains("scroll"), "a cancelled gesture's deltas must not reach the session either")

        _ = host.sendScroll(
            horizontal: 0, vertical: 0, scrollMods: GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended),
            pointerPosition: nil)
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture after the jump scrolls the replay again") { host.snapshotText()?.contains("row-0") == true }
    }

    /// A live pane can paint its first frame before the child has written a byte, and a session whose
    /// `output.log` does not exist yet reads back as an empty transcript too. Neither says anything final
    /// about a session that is still running, so the pane stays retryable: latching the verdict would
    /// absorb every scroll gesture for the rest of the run, however much the session printed afterwards.
    @MainActor func testALivePaneWhoseFirstReadFoundNoOutputReadsAgainOnTheNextGesture() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-empty-prefetch", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let attempts = TranscriptFetchAttempts()
        // The prefetch finds nothing; the session has written its 200 rows by the time the user scrolls.
        let provider = RecordingTranscriptProvider { _ in
            guard attempts.next() > 1 else {
                return RemoteGhosttyTranscript(data: Data(), startByteOffset: 0, endByteOffset: 0, fileIdentity: nil, runIdentity: nil)
            }
            return RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        XCTAssertEqual(provider.requests.count, 1, "an empty read must not put every later frame back on the read path")

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        waitForCondition("the gesture reads again and scrolls the pane into the session's history") { host.snapshotText()?.contains("row-0") == true }
        XCTAssertGreaterThanOrEqual(provider.requests.count, 2, "the gesture after an empty read must pay for another one")
        XCTAssertTrue(host.debugIsShowingLocalScrollbackFrame)
    }

    /// A flick at a device that cannot answer must cost one read, not one per delta. The read a gesture
    /// starts lands in the state a delta reads from, so a failure that only returned the pane to idle
    /// would have every later delta of the same flick start another read that fails the same way. The
    /// failure cancels the gesture instead, and the gesture after the idle boundary is the retry.
    @MainActor func testAGestureWhoseReadFailsAbsorbsTheRestOfTheFlick() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-failed-gesture-read", root: root)
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let provider = GatedTranscriptProvider()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        // The flick's deltas are stamped on a clock the test holds still, so the settling the async read
        // failure needs cannot drift past the idle interval and split one flick into two gestures.
        let clock = ScrollGestureTestClock()
        host.scrollGestureClock = { clock.now }
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("the pane starts its prefetch") { provider.requests.count >= 1 }

        // The prefetch fails on its own, with no gesture behind it, so it leaves the pane retryable.
        provider.failNext(SimulatedTransportFailure())
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        // The flick's first delta pays for the read the prefetch did not deliver, and that read fails too.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture pays for its own read") { provider.requests.count >= 2 }
        provider.failNext(SimulatedTransportFailure())
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        for _ in 0..<5 { _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil) }
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertEqual(provider.requests.count, 2, "each delta of the flick started another read of a transcript the device cannot serve")
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "a flick whose read failed must leave the pane on the session's own screen")

        // The idle boundary ends the cancelled gesture, and the gesture after it reads again.
        clock.advance(by: Self.scrollGestureIdlePause)
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture after the idle boundary retries the read") { provider.requests.count >= 3 }
        let page = Self.transcript(rows: 1...200)
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: page, startByteOffset: 0, endByteOffset: UInt64(page.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: session.runtimeState.runIdentity))
        waitForCondition("the retry scrolls the pane into the session's history") { host.snapshotText()?.contains("row-0") == true }
    }

    /// The same rule for the other outcome that installs nothing and stays retryable: a live session whose
    /// transcript has no bytes yet. One flick must not spend a read per delta discovering that.
    @MainActor func testAGestureWhoseReadFindsNoOutputAbsorbsTheRestOfTheFlick() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-empty-gesture-read", root: root)
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let provider = GatedTranscriptProvider()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        // The flick's deltas are stamped on a clock the test holds still, so the settling the empty read
        // needs to propagate cannot drift past the idle interval and split one flick into two gestures.
        let clock = ScrollGestureTestClock()
        host.scrollGestureClock = { clock.now }
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("the pane starts its prefetch") { provider.requests.count >= 1 }

        let empty = RemoteGhosttyTranscript(data: Data(), startByteOffset: 0, endByteOffset: 0, fileIdentity: nil, runIdentity: nil)
        // The prefetch finds nothing, with no gesture behind it, so it leaves the pane retryable.
        provider.resolveNext(empty)
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture pays for its own read") { provider.requests.count >= 2 }
        provider.resolveNext(empty)
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        for _ in 0..<5 { _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil) }
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertEqual(provider.requests.count, 2, "each delta of the flick started another read of a transcript that had no bytes yet")
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "a flick whose read found no output must leave the pane on the session's own screen")

        clock.advance(by: Self.scrollGestureIdlePause)
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the gesture after the idle boundary retries the read") { provider.requests.count >= 3 }
        let page = Self.transcript(rows: 1...200)
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: page, startByteOffset: 0, endByteOffset: UInt64(page.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: session.runtimeState.runIdentity))
        waitForCondition("the retry scrolls the pane into the session's history") { host.snapshotText()?.contains("row-0") == true }
    }

    /// The other half of that rule: an ended session's transcript is complete, so an empty one is
    /// definitive. The pane latches the verdict instead of paying for a read on every gesture for as long
    /// as it stays open.
    @MainActor func testAnEndedPaneWhoseTranscriptIsEmptyStopsReadingIt() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "ended-scrollback-empty"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "final", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-09-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-09-16T00:00:01Z",
            exitedAt: "2026-09-16T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 8, rows: 5)
        let recorder = DirectTerminalServiceRecorder(
            payload: GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-09-16T00:00:01Z",
                sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "final-01\nfinal-02\nfinal-03\nfinal-04\nfinal-05", sessionRevision: 1)))
        let provider = RecordingTranscriptProvider { _ in
            RemoteGhosttyTranscript(data: Data(), startByteOffset: 0, endByteOffset: 0, fileIdentity: nil, runIdentity: nil)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send, transcriptProvider: provider.fetch)
        waitForCondition("ended host renders final state") { host.snapshotText()?.contains("final-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("the ended pane reads its transcript once") { provider.requests.count >= 1 }

        for _ in 0..<3 {
            _ = host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        XCTAssertEqual(provider.requests.count, 1, "an ended session's empty transcript is final, so the pane must stop asking for it")
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame)
        XCTAssertEqual(host.snapshotText()?.contains("final-01"), true, "a pane with nothing to replay stays on the session's final frame")
    }

    /// A page load that ends without installing a replay has to paint the session's own frame. The rows a
    /// gesture puts on a load in flight suppress every live paint while that load runs, so the frames
    /// landing meanwhile are only cached; a load that then fails installs nothing, and without the repaint
    /// the pane keeps the frame it had when the gesture started. A live session would paint over it with
    /// its next frame, but a session that ended during the load never sends another one.
    @MainActor func testAFailedPageLoadPaintsTheLiveFrameItSuppressed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try makePaneHoldingAGestureOnAGatedLoad(sessionID: "live-scrollback-failed-load-repaint", root: root)
        defer { pane.window.orderOut(nil) }

        // The read fails, so the load ends with no replay to show.
        pane.provider.failNext(SimulatedTransportFailure())

        waitForCondition("the pane paints the frame the load suppressed") { pane.host.snapshotText()?.contains("done-01") == true }
        XCTAssertFalse(pane.host.debugIsShowingLocalScrollbackFrame, "a load that installed no replay leaves the pane on the session's own screen")
    }

    /// The same repaint for the other exit that installs nothing: a read the daemon answers with no bytes
    /// at all, which is what a live session ahead of its own output returns.
    @MainActor func testAnEmptyPageResponsePaintsTheLiveFrameItSuppressed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try makePaneHoldingAGestureOnAGatedLoad(sessionID: "live-scrollback-empty-load-repaint", root: root)
        defer { pane.window.orderOut(nil) }

        pane.provider.resolveNext(RemoteGhosttyTranscript(data: Data(), startByteOffset: 0, endByteOffset: 0, fileIdentity: nil, runIdentity: nil))

        waitForCondition("the pane paints the frame the load suppressed") { pane.host.snapshotText()?.contains("done-01") == true }
        XCTAssertFalse(pane.host.debugIsShowingLocalScrollbackFrame, "a load that installed no replay leaves the pane on the session's own screen")
    }

    /// A load can install its replay and still owe those paints: a downward flick started while the read
    /// was in flight parks its rows on the load, and applying them at the install leaves the replay on its
    /// newest row, where the pane belongs to the session's own frame rather than to any replay frame.
    @MainActor func testAPageLoadLandingOnItsNewestRowPaintsTheLiveFrameItSuppressed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try makePaneHoldingAGestureOnAGatedLoad(sessionID: "live-scrollback-bottom-load-repaint", root: root, scrollVertical: -200)
        defer { pane.window.orderOut(nil) }

        let page = Self.transcript(rows: 1...200)
        pane.provider.resolveNext(
            RemoteGhosttyTranscript(
                data: page, startByteOffset: 0, endByteOffset: UInt64(page.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: pane.session.runtimeState.runIdentity))

        waitForCondition("the pane paints the frame the load suppressed") { pane.host.snapshotText()?.contains("done-01") == true }
        XCTAssertFalse(pane.host.debugIsShowingLocalScrollbackFrame, "a replay sitting on its newest row leaves the pane on the session's own screen")
    }

    /// A gesture that latches onto the replay before its first page has even come back is still committed
    /// to it: output the session writes while that page is in flight has to mark the jump control, even
    /// though no replay frame is on screen yet for the mark to sit next to, and the mark has to survive the
    /// page installing and painting the history the gesture was waiting on.
    @MainActor func testOutputDuringTheFirstPageLoadMarksTheJumpControlOnceTheReplayInstalls() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try makePaneHoldingAGestureOnAGatedLoad(sessionID: "live-scrollback-first-page-new-output", root: root)
        defer { pane.window.orderOut(nil) }

        let page = Self.transcript(rows: 1...200)
        pane.provider.resolveNext(
            RemoteGhosttyTranscript(
                data: page, startByteOffset: 0, endByteOffset: UInt64(page.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: pane.session.runtimeState.runIdentity))

        waitForCondition("the page installs and paints the replay the gesture was waiting on") { pane.host.debugIsShowingLocalScrollbackFrame }
        XCTAssertTrue(
            pane.host.debugJumpToBottomControlShowsNewOutput,
            "output that arrived while the first page was still loading must mark the jump control once the replay it belongs to is showing")
    }

    /// A pane whose gated page load is holding a gesture's rows, with the session's newest frame delivered
    /// and left unpainted by that load: the setup the suppressed-frame tests share, up to the point where
    /// the load ends. The caller ends the load its own way and asserts what the pane paints.
    /// `scrollVertical` is that gesture's direction, since the rows waiting on the load are what decide
    /// where the install puts the replay: up into history, or back onto its newest row.
    @MainActor private func makePaneHoldingAGestureOnAGatedLoad(sessionID: String, root: URL, scrollVertical: CGFloat = 200) throws -> (
        host: RemoteGhosttySessionHost, provider: GatedTranscriptProvider, window: NSWindow, session: LiveScrollbackSession
    ) {
        let session = try makeLiveScrollbackSession(sessionID: sessionID, root: root)
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let provider = GatedTranscriptProvider()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        // A pane that is genuinely on screen: an off-screen pane holds its screen updates, and this setup
        // needs the payload carrying the session's newest frame to actually reach the host.
        let window = makeVisiblePaneWindow()
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("the pane starts reading its scrollback page") { provider.requests.count >= 1 }

        // A gesture while the read is held puts its rows on the load, and a load holding rows is what
        // suppresses live paints: a frame painted here would be replaced the moment the page lands.
        XCTAssertTrue(
            host.sendScroll(horizontal: 0, vertical: scrollVertical, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        // The session's newest frame lands while the load holds those rows, so it is cached rather than
        // painted. It is carried at the grid the first frame established, which is what keeps it from
        // discarding the load instead.
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.newerLiveScreen, revision: 2, outputEndByteOffset: 4096))
        waitForCondition("the pane applies the session's newest frame") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == 4096
        }
        XCTAssertEqual(host.snapshotText()?.contains("done-01"), false, "a load holding a gesture's rows must not let the session's own frame paint")
        return (host, provider, window, session)
    }

    /// A mouse wheel's clicks and a slow trackpad drag never report a momentum phase, so the pause
    /// between two bursts is the only thing that ends such a gesture. The burst after the pause is a new
    /// gesture: it reads what the session wrote while the wheel was still, which would otherwise be
    /// missing from everything the user scrolls back through for the rest of the pane's life.
    @MainActor func testAWheelBurstAfterAPauseReadsWhatTheSessionWroteBetweenBursts() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-idle-gesture", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let firstHalf = Self.transcript(rows: 1...100)
        let secondHalf = Data("\r\n".utf8) + Self.transcript(rows: 101...200)
        let totalBytes = UInt64(firstHalf.count + secondHalf.count)
        let provider = RecordingTranscriptProvider { request in
            guard let fromByteOffset = request.fromByteOffset else {
                return RemoteGhosttyTranscript(
                    data: firstHalf, startByteOffset: 0, endByteOffset: UInt64(firstHalf.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runIdentity)
            }
            return RemoteGhosttyTranscript(
                data: secondHalf, startByteOffset: fromByteOffset, endByteOffset: totalBytes, fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }

        // One burst of wheel events, which report no momentum phase at all and so end with nothing.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the first burst scrolls the replay") { host.snapshotText()?.contains("row-0") == true }
        XCTAssertEqual(provider.requests.count, 1)

        // The session writes while the wheel is still.
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.liveScreen, revision: 2, outputEndByteOffset: Int(totalBytes)))
        waitForCondition("the pane observes where the session's output now ends") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == totalBytes
        }
        // And the wheel stays still past the idle boundary, which is what ends the burst's gesture.
        let idleDeadline = Date().addingTimeInterval(Self.scrollGestureIdlePause)
        while Date() < idleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        waitForCondition("the burst after the pause reads the continuation") { provider.requests.count >= 2 }
        XCTAssertEqual(try XCTUnwrap(provider.requests.last).fromByteOffset, UInt64(firstHalf.count))
        // One row per step, and stopping at the first row written between the bursts, because a step onto
        // the replay's newest row hands the pane back to the session's own screen.
        waitForCondition("the rows written between the bursts are reachable in the replay") {
            _ = host.sendScroll(horizontal: 0, vertical: -18, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            return host.snapshotText()?.contains("row-101") == true
        }
    }

    /// Typing while the pane's first page is still being read has to drop the rows the gesture put on
    /// that read: the page lands after the keystroke, and the rows it would paint are history over the
    /// live screen the keystroke belongs to.
    @MainActor func testTypingWhileThePageIsLoadingDropsTheRowsItWouldHavePainted() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-typing-mid-load", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let transcript = Self.transcript(rows: 1...200)
        let provider = GatedTranscriptProvider()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))
        waitForCondition("the pane starts reading its scrollback page") { provider.requests.count >= 1 }

        // The gesture lands on a replay that does not exist yet, so its rows wait on the read.
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "there is nothing to show yet: the page is still being read")

        XCTAssertTrue(host.sendTextAsPaste("echo hi"))

        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: transcript, startByteOffset: 0, endByteOffset: UInt64(transcript.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity))
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "a page that lands after a keystroke must not put the pane into its replay")
        let text = try XCTUnwrap(host.snapshotText())
        XCTAssertFalse(text.contains("row-"), "history painted over the live screen after the keystroke: \(text)")
        XCTAssertTrue(text.contains("live-01"), "typing must leave the session's own screen showing: \(text)")
    }

    /// A head-trim rewrites `output.log` and moves its end BACKWARDS. The pane has to hear that its
    /// replay no longer matches the file, or it keeps replaying bytes at offsets the file no longer holds
    /// until the session writes past the pre-trim size; the transcript file the read names is what turns
    /// the gesture's continuation into the rebuild that repairs it.
    @MainActor func testATrimmedTranscriptIsRebuiltOnTheNextGesture() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-trim", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let original = Self.transcript(rows: 1...200)
        // What the trim left behind: a shorter file whose rows are labelled so the rebuild is visible.
        let trimmed = Data((1...150).map { String(format: "trim-%03d", $0) }.joined(separator: "\r\n").utf8)
        let provider = RecordingTranscriptProvider { request in
            guard request.fromByteOffset != nil else {
                return RemoteGhosttyTranscript(
                    data: original, startByteOffset: 0, endByteOffset: UInt64(original.count), fileIdentity: fakeTranscriptFileIdentity,
                    runIdentity: runIdentity)
            }
            return RemoteGhosttyTranscript(
                data: trimmed, startByteOffset: 0, endByteOffset: UInt64(trimmed.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity, isSuffixRebuild: true)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("live pane prefetches its scrollback page") { provider.requests.count >= 1 }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        waitForCondition("the first gesture scrolls the replay") { host.snapshotText()?.contains("row-0") == true }
        _ = host.sendScroll(
            horizontal: 0, vertical: 0, scrollMods: GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended),
            pointerPosition: nil)

        // The daemon trims the head: the same session now reports a transcript that ends EARLIER than the
        // replay's own end.
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.liveScreen, revision: 2, outputEndByteOffset: trimmed.count))
        waitForCondition("the pane observes the transcript's end moving backwards") {
            host.requestSurfaceRefresh()
            return host.debugLatestTranscriptEndByteOffset == UInt64(trimmed.count)
        }

        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))

        waitForCondition("the gesture reads again from the replay's end") { provider.requests.count >= 2 }
        XCTAssertEqual(try XCTUnwrap(provider.requests.last).fromByteOffset, UInt64(original.count))
        waitForCondition("the replay is rebuilt from what the trimmed file holds") { host.snapshotText()?.contains("trim-") == true }
    }

    /// A resize reflows every row, and a page read that is still in flight would install a replay wrapped
    /// at the grid it was started at. It is dropped exactly as a built replay is, and the pane reads
    /// again at the grid the session is on.
    @MainActor func testAResizeWhileThePageIsLoadingReadsAgainAtTheNewGrid() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeLiveScrollbackSession(sessionID: "live-scrollback-resize-mid-load", root: root)
        let runIdentity = session.runtimeState.runIdentity
        let recorder = DirectTerminalServiceRecorder(payload: try liveScrollbackPayload(session, text: Self.liveScreen, revision: 1))
        let provider = GatedTranscriptProvider()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: session.launchConfiguration, paths: session.paths, terminalServiceRequestSender: recorder.send,
            transcriptProvider: provider.fetch)
        waitForCondition("live host paints its first frame") { host.snapshotText()?.contains("live-01") == true }
        let window = makeVisiblePaneWindow()
        defer { window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-09-16T00:00:02Z"),
            mode: .owner, into: try XCTUnwrap(window.contentView))
        waitForCondition("the pane starts reading its scrollback page") { provider.requests.count >= 1 }

        // The session resizes while that read is in flight: a wider, taller grid than the 7x5 the read
        // was started at.
        recorder.setPayload(try liveScrollbackPayload(session, text: Self.resizedLiveScreen, revision: 2))
        waitForCondition("the resized frame reaches the pane") {
            host.requestSurfaceRefresh()
            return host.snapshotText()?.contains("wide-01") == true
        }

        waitForCondition("the pane reads again at the grid the session is on") { provider.requests.count >= 2 }

        // The read started at the old grid resolves into nothing: its replay would wrap every row at a
        // grid the session has left.
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: Self.transcript(rows: 1...200), startByteOffset: 0, endByteOffset: UInt64(Self.transcript(rows: 1...200).count),
                fileIdentity: fakeTranscriptFileIdentity, runIdentity: runIdentity))
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(host.sendScroll(horizontal: 0, vertical: 2000, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil))
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(host.debugIsShowingLocalScrollbackFrame, "the discarded read must not install a replay wrapped at the old grid")
        XCTAssertEqual(host.snapshotText()?.contains("wide-01"), true)

        // The read the resize started does install one.
        let rebuilt = Data((1...200).map { String(format: "wide-row-%03d", $0) }.joined(separator: "\r\n").utf8)
        provider.resolveNext(
            RemoteGhosttyTranscript(
                data: rebuilt, startByteOffset: 0, endByteOffset: UInt64(rebuilt.count), fileIdentity: fakeTranscriptFileIdentity,
                runIdentity: runIdentity))
        waitForCondition("the replay read at the new grid is what the pane scrolls") {
            _ = host.sendScroll(horizontal: 0, vertical: 200, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: nil)
            return host.snapshotText()?.contains("wide-row-") == true
        }
    }

    // MARK: - Client-local scrollback helpers

    /// Records every transcript read a host makes and answers it from a script, so a test can assert what
    /// the pane asked for - page size, continuation offset, transcript file - as well as what it
    /// rendered.
    private final class RecordingTranscriptProvider: @unchecked Sendable {
        struct Request: Sendable {
            let maxBytes: Int
            let fromByteOffset: UInt64?
            let fileIdentity: UInt64?
        }

        private let lock = NSLock()
        private var recorded: [Request] = []
        private let respond: @Sendable (Request) -> RemoteGhosttyTranscript

        init(respond: @escaping @Sendable (Request) -> RemoteGhosttyTranscript) { self.respond = respond }

        var requests: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func fetch(maxBytes: Int, fromByteOffset: UInt64?, fileIdentity: UInt64?) async throws -> RemoteGhosttyTranscript {
            let request = Request(maxBytes: maxBytes, fromByteOffset: fromByteOffset, fileIdentity: fileIdentity)
            record(request)
            return respond(request)
        }

        private func record(_ request: Request) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request)
        }
    }

    /// A transcript provider that records what was asked for and holds every fetch suspended until the
    /// test resolves it, so a test can put the pane in its loading state and then do something to it.
    private final class GatedTranscriptProvider: @unchecked Sendable {
        struct Request: Sendable {
            let maxBytes: Int
            let fromByteOffset: UInt64?
            let fileIdentity: UInt64?
        }

        private let lock = NSLock()
        private var recorded: [Request] = []
        private var continuations: [CheckedContinuation<RemoteGhosttyTranscript, Error>] = []

        var requests: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func fetch(maxBytes: Int, fromByteOffset: UInt64?, fileIdentity: UInt64?) async throws -> RemoteGhosttyTranscript {
            record(Request(maxBytes: maxBytes, fromByteOffset: fromByteOffset, fileIdentity: fileIdentity))
            return try await withCheckedThrowingContinuation { continuation in hold(continuation) }
        }

        private func record(_ request: Request) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request)
        }

        private func hold(_ continuation: CheckedContinuation<RemoteGhosttyTranscript, Error>) {
            lock.lock()
            defer { lock.unlock() }
            continuations.append(continuation)
        }

        func resolveNext(_ transcript: RemoteGhosttyTranscript) {
            lock.lock()
            let continuation = continuations.isEmpty ? nil : continuations.removeFirst()
            lock.unlock()
            continuation?.resume(returning: transcript)
        }

        /// Fails the oldest fetch in flight, for the transport failures (timeout, daemon restarting,
        /// device offline) a read ends on without any bytes to install.
        func failNext(_ error: Error) {
            lock.lock()
            let continuation = continuations.isEmpty ? nil : continuations.removeFirst()
            lock.unlock()
            continuation?.resume(throwing: error)
        }

        /// Resolves the most recently started fetch, leaving earlier ones suspended, so a test can answer
        /// a later read while an older one is still in flight.
        func resolveLast(_ transcript: RemoteGhosttyTranscript) {
            lock.lock()
            let continuation = continuations.popLast()
            lock.unlock()
            continuation?.resume(returning: transcript)
        }
    }

    /// A flag a main-actor block sets for the test that enqueued it. A task cannot capture a mutable
    /// local, and what these tests have to observe happens inside one.
    @MainActor private final class MainActorFlag { var isSet = false }

    /// The clock a test hands the host for its scroll-gesture timing. The deltas of one flick are stamped
    /// at whatever instant the test has the clock on, so they stay inside the host's idle interval however
    /// long the run loop takes, and the idle boundary between two gestures is crossed by advancing it.
    @MainActor private final class ScrollGestureTestClock {
        private(set) var now = Date(timeIntervalSince1970: 1_758_000_000)

        func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
    }

    /// The topmost numbered transcript row the pane is showing, so a test can say where a gesture left the
    /// replay without hard-coding the line arithmetic of a replayed page.
    @MainActor private func topVisibleTranscriptRow(_ host: RemoteGhosttySessionHost) -> Int? {
        guard let text = host.snapshotText(), let match = text.range(of: "row-[0-9]{3}", options: .regularExpression) else { return nil }
        return Int(text[match].dropFirst(4))
    }

    /// A running remote session whose frames are the 8x5 grid the local-scrollback tests replay their
    /// numbered transcript at.
    private struct LiveScrollbackSession {
        let launchConfiguration: TerminalSessionLaunchConfiguration
        let paths: TerminalSessionPaths
        let runtimeState: TerminalSessionRuntimeState
    }

    private static let liveScreen = "live-01\nlive-02\nlive-03\nlive-04\nlive-05"
    /// The screen the session prints later in the run, at `liveScreen`'s own grid so the frame carrying it
    /// does not discard the pane's replay on the way in.
    private static let newerLiveScreen = "done-01\ndone-02\ndone-03\ndone-04\ndone-05"
    /// The same session after a resize: a wider, taller grid than `liveScreen`'s 7x5.
    private static let resizedLiveScreen = "wide-01--\nwide-02--\nwide-03--\nwide-04--\nwide-05--\nwide-06--"
    /// Longer than the host's own 250 ms scroll-gesture idle interval, which is what separates two turns
    /// of a phase-less wheel into two gestures.
    private static let scrollGestureIdlePause: TimeInterval = 0.4

    private static func transcript(rows: ClosedRange<Int>) -> Data {
        Data(rows.map { String(format: "row-%03d", $0) }.joined(separator: "\r\n").utf8)
    }

    /// A key window holding a pane-sized content view. A pane in no window is off screen, and an
    /// off-screen pane holds its screen updates, so any test that needs a later payload to actually reach
    /// the host has to put the pane on the screen.
    @MainActor private func makeVisiblePaneWindow() -> NSWindow {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeLiveScrollbackSession(sessionID: String, root: URL) throws -> LiveScrollbackSession {
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "live", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-09-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-09-16T00:00:01Z",
            title: "live", workingDirectory: "/tmp/work", columns: 8, rows: 5)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        return LiveScrollbackSession(launchConfiguration: launchConfiguration, paths: paths, runtimeState: runtimeState)
    }

    /// One state payload for a live-scrollback session: the frame it paints, and where `output.log` ends
    /// as of that payload when the test needs the pane to know the session has written something.
    private func liveScrollbackPayload(
        _ session: LiveScrollbackSession, text: String, revision: UInt64, outputEndByteOffset: Int? = nil, alternateScreenActive: Bool = false,
        mouseReportingActive: Bool = false, reason: TerminalRemoteSessionStateReason = .stateChange
    ) throws -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: session.launchConfiguration.sessionID, reason: reason.rawValue, emittedAt: "2026-09-16T00:00:01Z",
            sessionStateRevision: revision, sessionStateFlags: 1, screenStateRevision: revision, runtimeState: session.runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/work", outputByteCount: nil,
            outputEndByteOffset: outputEndByteOffset,
            renderUpdate: try renderUpdate(
                text: text, sessionRevision: revision, alternateScreenActive: alternateScreenActive, mouseReportingActive: mouseReportingActive))
    }

    /// The control commands a recorder saw, in order, so a test can assert what did - and did not - reach
    /// the session.
    private func scrollControlCount(_ recorder: DirectTerminalServiceRecorder) -> Int { controlCommands(recorder).filter { $0 == "scroll" }.count }

    private func controlCommands(_ recorder: DirectTerminalServiceRecorder) -> [String] {
        recorder.requests().compactMap { request in
            guard case .control(let payload) = request.command else { return nil }
            return payload.controlRequest.command
        }
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
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
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-04T00:00:01Z",
                sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: staleExitedState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "stale-title", workingDirectory: "/tmp/stale", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "stale", sessionRevision: 1)), paths: paths)

        let liveRenderUpdate = try renderUpdate(text: "live", sessionRevision: 2)
        let server = GhosttyRemoteSessionStateStreamServer(
            socketPath: paths.subscriptionSocketPath, queue: DispatchQueue(label: "spaces.remote-device.stale-final-live-test")
        ) {
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-06-04T00:00:02Z",
                sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runningState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live-title", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: liveRenderUpdate)
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
            sessionID: "stream-render-update", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-06-03T00:00:00Z",
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

        waitForCondition("render-update stream payload") {
            receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.initial.rawValue }
        }
        let payload = try XCTUnwrap(receivedPayloads.first { $0.reason == TerminalRemoteSessionStateReason.initial.rawValue })
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
                sessionID: "stream-delta-coalescing", reason: TerminalRemoteSessionStateReason.stateChange.rawValue,
                emittedAt: "2026-06-03T00:00:0\(revision)Z", sessionStateRevision: revision, sessionStateFlags: 1, screenStateRevision: revision,
                runtimeState: nil, attachmentSnapshot: nil, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(update))
        }

        let pendingDeltaPayload = try payload(firstDelta, revision: 2)
        let incomingDeltaPayload = try payload(secondDelta, revision: 3)
        let incomingFullPayload = try payload(.full(thirdFrame), revision: 3)
        let pendingMetadataPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "stream-delta-coalescing", reason: TerminalRemoteSessionStateReason.stateChange.rawValue, emittedAt: "2026-06-03T00:00:01Z",
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
            sessionID: "remote-live", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-05-18T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1,
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

        // On screen: this test follows the frames the pane paints, and an off-screen pane holds them.
        let display = makeDisplayedPaneContainer()
        defer { display.window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-18T00:00:00Z"),
            mode: .viewer, into: display.container)

        waitForCondition("initial live snapshot") { host.snapshotText() == "alpha" }
        XCTAssertEqual(host.effectiveTitle, "live")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/live")

        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-live", reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: "2026-05-18T00:00:01Z",
                sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-live", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-18T00:00:01Z", title: "live", workingDirectory: "/tmp/live", columns: 4, rows: 2),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: 9,
                renderUpdate: try renderUpdate(text: "beta\ngamm", sessionRevision: 2)))

        waitForCondition("updated live snapshot") { host.snapshotText() == "beta\ngamm" }
        XCTAssertEqual(host.snapshot()?.rows, 2)

        let ownerClient = TerminalClient(
            id: "owner-client", kind: .remote, identity: TerminalClientIdentity(label: "iPad"), connectedAt: "2026-05-18T00:00:02Z")
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [ownerClient],
            attachments: [TerminalAttachment(sessionID: "remote-live", clientID: ownerClient.id, mode: .owner, attachedAt: "2026-05-18T00:00:02Z")])
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-live", reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, emittedAt: "2026-05-18T00:00:02Z",
                sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: attachmentSnapshot,
                title: "live", workingDirectory: "/tmp/live", outputByteCount: nil))

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
            sessionID: "remote-stale-size", reason: TerminalRemoteSessionStateReason.resize.rawValue, emittedAt: "2026-05-22T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1,
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
            sessionID: "remote-renderable", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-05-19T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1,
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-19T00:00:00Z"),
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
            sessionID: "remote-owner-focus", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-06-02T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1,
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
                id: "owner-client", kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-02T00:00:00Z"),
            mode: .owner, into: container)
        waitForCondition("initial owner first responder") { window.firstResponder is GhosttyMirrorTerminalView }

        let dummyResponder = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(dummyResponder)
        XCTAssertTrue(window.makeFirstResponder(dummyResponder))
        XCTAssertTrue(window.firstResponder === dummyResponder)

        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-owner-focus", reason: TerminalRemoteSessionStateReason.stateChange.rawValue, emittedAt: "2026-06-02T00:00:01Z",
                sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2,
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
                sessionID: "remote-owner-focus", reason: TerminalRemoteSessionStateReason.stateChange.rawValue, emittedAt: "2026-06-02T00:00:02Z",
                sessionStateRevision: 3, sessionStateFlags: 1, screenStateRevision: 3,
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
            sessionID: "remote-set-focused", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-06-02T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1,
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
            id: "owner-client", kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-02T00:00:00Z")
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
            sessionID: "remote-set-focused-reclaim", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-06-02T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1,
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
            id: "owner-client", kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-02T00:00:00Z")
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
            sessionID: "remote-attachment-state", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-05-20T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1,
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-20T00:00:00Z"),
            mode: .viewer, into: container)

        waitForCondition("initial rendered viewer text") { self.normalize(self.visibleText(for: host)).contains("alpha") }

        let ownerClient = TerminalClient(
            id: "ipad-owner", kind: .remote, identity: TerminalClientIdentity(label: "iPad"), connectedAt: "2026-05-20T00:00:01Z")
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [ownerClient],
            attachments: [
                TerminalAttachment(sessionID: "remote-attachment-state", clientID: ownerClient.id, mode: .owner, attachedAt: "2026-05-20T00:00:01Z")
            ])
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-attachment-state", reason: TerminalRemoteSessionStateReason.attachmentState.rawValue,
                emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil,
                attachmentSnapshot: attachmentSnapshot, title: "renderable", workingDirectory: "/tmp/live", outputByteCount: nil))

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
            sessionID: "remote-snapshot-precedence", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-05-21T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: nil,
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-21T00:00:00Z"),
            mode: .viewer, into: container)

        try "WRONG\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-snapshot-precedence", reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: "2026-05-21T00:00:01Z",
                sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 1,
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
            sessionID: "remote-handoff-snapshot", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-05-29T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: nil,
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

        let client = TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-29T00:00:00Z")
        try host.attach(client: client, mode: .owner, into: container)

        try "WRONG\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [client],
            attachments: [
                TerminalAttachment(sessionID: "remote-handoff-snapshot", clientID: client.id, mode: .owner, attachedAt: "2026-05-29T00:00:01Z")
            ])
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-handoff-snapshot", reason: TerminalRemoteSessionStateReason.attachmentState.rawValue,
                emittedAt: "2026-05-29T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2,
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
        let client = TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-30T00:00:00Z")
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [client],
            attachments: [
                TerminalAttachment(sessionID: "remote-recreate-surface", clientID: client.id, mode: .owner, attachedAt: "2026-05-30T00:00:00Z")
            ])
        let queue = DispatchQueue(label: "spaces.remote-device.recreate-surface-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-recreate-surface", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-05-30T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1,
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
                sessionID: "remote-recreate-surface", reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: "2026-05-30T00:00:01Z",
                sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2,
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-22T00:00:00Z"),
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-28T00:00:00Z"),
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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange.rawValue, emittedAt: "2026-06-10T00:00:01Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        let recorder = DirectTerminalServiceRecorder(payload: payload)

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send)

        waitForCondition("direct daemon state render") { host.snapshotText() == "alpha" }
        // The GUI host renders device state in memory and writes no local mirror row.
        XCTAssertThrowsError(try TerminalSessionPersistence.readRemoteSessionState(paths: paths))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let client = TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-10T00:00:02Z")
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
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

    /// The other side of the staleness rule: a `.state` response can be the ONLY carrier of the newest
    /// screen. Exporting state flushes the session's pending output into its surface without broadcasting
    /// and without moving the stream's delta baseline, so the frame that read returns can be newer than
    /// anything the subscription has sent — with no broadcast coming to repeat it. Ordering by arrival
    /// alone would discard exactly that frame, so the guard orders by revision instead.
    @MainActor func testStateResponseNewerThanTheAppliedFrameIsStillApplied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-newer-state-response"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        // The held read carries the newest screen (revision 3); the subscription paints an older one while
        // it is in flight.
        let sender = HeldStateRequestSender(payloads: [
            try fullFramePayload(sessionID: sessionID, runtimeState: fixture.payload.runtimeState, text: "charl", sessionRevision: 3)
        ])
        defer { sender.releaseHeldState() }
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            stateStreamSubscriber: subscriber.subscribe)
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }

        // On screen: this test asserts on the frames the pane paints, and an off-screen pane holds them.
        let display = makeDisplayedPaneContainer()
        defer { display.window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: display.container)
        waitForCondition("the attach's state fetch is in flight") { sender.stateRequestCount == 1 }

        subscriber.emit(
            try fullFramePayload(
                sessionID: sessionID, runtimeState: fixture.payload.runtimeState, text: "bravo", sessionRevision: 2, emittedAt: "2026-08-09T00:00:05Z"
            ))
        waitForCondition("the streamed frame paints") { host.snapshotText() == "bravo" }

        sender.releaseHeldState()

        waitForCondition("the newer fetched frame paints") { host.snapshotText() == "charl" }
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
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
    /// covers the failed delta's target and lands before the boundary repairs the chain, so the armed
    /// retry must be dropped rather than firing a `.state` read for a frame the host already has. That is
    /// the session's own recovery: the forced full-frame broadcast a resync request provokes describes the
    /// screen the failed delta was building toward, so it is never behind that delta's target.
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)))
        waitForCondition("the attach's state fetch lands") { self.stateRequestCount(recorder) == 1 }

        subscriber.emit(try deltaPayloadWithoutABaseline(sessionID: sessionID, runtimeState: fixture.payload.runtimeState))
        // The session's own full frame arrives before the window expires, at revision 9 — past the
        // revision 8 the failed delta targeted.
        subscriber.emit(
            try fullFramePayload(
                sessionID: sessionID, runtimeState: fixture.payload.runtimeState, text: "alpha", sessionRevision: 9, emittedAt: "2026-08-09T00:00:05Z"
            ))
        waitForCondition("the streamed frame paints") { host.snapshotText() == "alpha" }

        // Well past the boundary the retry would have fired at.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(stateRequestCount(recorder), 1, "a repaired chain owes no retry")
    }

    /// The limit of that rule: the frame has to cover the failure the retry was armed for.
    ///
    /// A `.state` read still in flight when a delta fails was issued before that failure was owed, so it
    /// answers with the screen the session captured beforehand. That frame applies — the failure nilled
    /// the baseline, so nothing refuses a newer revision — and retiring the retry on it cancels a request
    /// for a gap it does not fill. The pane is then parked behind the session, and a session that goes
    /// quiet leaves it there indefinitely.
    @MainActor func testTrailingResyncRetryOutlivesAFrameOlderThanTheFailureThatArmedIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-resync-retry-older-frame"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        // The held read answers for revision 3 — the screen as it was before the delta below failed — and
        // only the retry's read carries revision 9, which covers that delta's target of 8.
        let sender = HeldStateRequestSender(payloads: [
            try fullFramePayload(sessionID: sessionID, runtimeState: fixture.payload.runtimeState, text: "charl", sessionRevision: 3),
            try fullFramePayload(sessionID: sessionID, runtimeState: fixture.payload.runtimeState, text: "delta", sessionRevision: 9),
        ])
        defer { sender.releaseHeldState() }
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            stateStreamSubscriber: subscriber.subscribe)
        host.renderUpdateResyncIntervalForTesting = 0.2
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }

        // The attach's eager resync stamps the throttle and its read is held open.
        // On screen: this test asserts on the frames the pane paints, and an off-screen pane holds them.
        let display = makeDisplayedPaneContainer()
        defer { display.window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
            mode: .owner, into: display.container)
        waitForCondition("the attach's state fetch is in flight") { sender.stateRequestCount == 1 }

        // The frame the pane holds when the delta fails against it.
        subscriber.emit(
            try fullFramePayload(
                sessionID: sessionID, runtimeState: fixture.payload.runtimeState, text: "bravo", sessionRevision: 2, emittedAt: "2026-08-09T00:00:05Z"
            ))
        waitForCondition("the streamed frame paints") { host.snapshotText() == "bravo" }
        // A delta for revision 8, which this pane has no baseline for: it fails and arms the retry.
        subscriber.emit(try deltaPayloadWithoutABaseline(sessionID: sessionID, runtimeState: fixture.payload.runtimeState))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // The held read finally answers, with the pre-failure screen, and the session goes quiet.
        sender.releaseHeldState()

        waitForCondition("the still-owed retry fires") { sender.stateRequestCount >= 2 }
        waitForCondition("the covering frame paints") { host.snapshotText() == "delta" }
        // Well past two more boundaries, so a retry the covering frame failed to retire would have fired.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(sender.stateRequestCount, 2, "a frame that covers the failure retires the retry")
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
            sessionID: fixture.launchConfiguration.sessionID, reason: TerminalRemoteSessionStateReason.initial.rawValue,
            emittedAt: "2026-08-09T00:00:03Z", sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1,
            runtimeState: fixture.payload.runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote",
            workingDirectory: "/tmp/work", outputByteCount: nil)
    }

    /// A payload carrying one full frame of `text`.
    private func fullFramePayload(
        sessionID: String, runtimeState: TerminalSessionRuntimeState?, text: String, sessionRevision: UInt64,
        emittedAt: String = "2026-08-09T00:00:03Z"
    ) throws -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: emittedAt,
            sessionStateRevision: sessionRevision, sessionStateFlags: 1, screenStateRevision: sessionRevision, runtimeState: runtimeState,
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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: "2026-08-09T00:00:04Z",
            sessionStateRevision: 8, sessionStateFlags: 1, screenStateRevision: 8, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
            renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(delta))
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
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
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-09T00:00:02Z"),
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
        // On screen: this test asserts on the frame the pane paints, and an off-screen pane holds them.
        let display = makeDisplayedPaneContainer()
        defer { display.window.orderOut(nil) }
        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:00Z"),
            mode: .viewer, into: display.container)

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
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output.rawValue,
                emittedAt: "2026-07-24T00:01:\(String(format: "%02d", index))Z", sessionStateRevision: UInt64(index + 1), sessionStateFlags: 1,
                screenStateRevision: UInt64(index + 1), runtimeState: fixture.payload.runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(update))
            emitQueue.sync { subscriber.emit(payload) }
        }

        waitForCondition("host renders the last frame of the delta series") { host.snapshotText() == "fram1" }
    }

    /// The handle the host holds for its state subscription is a listener on the state model's shared
    /// fan-out, and the model keeps that listener attached until the handle says otherwise. Dropping the
    /// handle on a disconnect without stopping it therefore left this host's callbacks in the fan-out for
    /// the life of the session, with the next subscribe registering a second listener on top of them
    /// (issue #537).
    @MainActor func testStateStreamDisconnectStopsTheSubscriptionHandleItDrops() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-disconnect-detaches-listener"
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        let recorder = DirectTerminalServiceRecorder(payload: fixture.payload)
        let subscriber = RecordingStateStreamSubscriber()
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: recorder.send,
            stateStreamSubscriber: subscriber.subscribe)
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }

        subscriber.disconnect(nil)

        waitForCondition("the host stops the subscription handle it drops") { subscriber.stoppedClientCount >= 1 }
        withExtendedLifetime(host) {}
    }

    /// A host's last reference can be dropped by a background thread — any async caller holding the pane
    /// controller that owns it — in which case its `deinit` runs there. Cleanup that runs only on the main
    /// thread leaves the device's state subscription installed and this host's callbacks in the model's
    /// fan-out for the life of the session, which is the leak `deinit` exists to prevent.
    @MainActor func testLastReleaseOffMainStopsTheStateStreamSubscription() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let subscriber = RecordingStateStreamSubscriber()
        let box = SessionHostBox()
        let weakReference = WeakSessionHostReference()
        try autoreleasepool {
            try makeHostReadyForRelease(sessionID: "remote-release-off-main", root: root, subscriber: subscriber, into: box)
            weakReference.host = box.host
        }

        let releaseFinished = DispatchSemaphore(value: 0)
        let deallocatedOnReleasingThread = ReleasingThreadOutcome()
        Thread.detachNewThread {
            autoreleasepool { box.host = nil }
            // Read from the releasing thread: a host that is gone by the time this line runs was
            // deallocated by that thread's release, which is the scenario under test.
            deallocatedOnReleasingThread.value = weakReference.host == nil
            releaseFinished.signal()
        }
        waitForCondition("the releasing thread finishes") { releaseFinished.wait(timeout: .now()) == .success }

        XCTAssertTrue(deallocatedOnReleasingThread.value, "the background thread did not perform the host's last release")
        waitForCondition("the released host stops its subscription handle") { subscriber.stoppedClientCount >= 1 }
    }

    /// The control: the same host released on the main thread, where the cleanup runs inline.
    @MainActor func testLastReleaseOnMainStopsTheStateStreamSubscription() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let subscriber = RecordingStateStreamSubscriber()
        let box = SessionHostBox()
        let weakReference = WeakSessionHostReference()
        try autoreleasepool {
            try makeHostReadyForRelease(sessionID: "remote-release-on-main", root: root, subscriber: subscriber, into: box)
            weakReference.host = box.host
        }

        autoreleasepool { box.host = nil }

        XCTAssertNil(weakReference.host, "the host was still referenced, so its deinit never ran")
        waitForCondition("the released host stops its subscription handle") { subscriber.stoppedClientCount >= 1 }
    }

    /// Builds a host subscribed to `subscriber`'s stream into `box`, which then holds its only strong
    /// reference: the caller alone decides which thread performs the host's last release.
    @MainActor private func makeHostReadyForRelease(
        sessionID: String, root: URL, subscriber: RecordingStateStreamSubscriber, into box: SessionHostBox
    ) throws {
        let fixture = try makeRunningSessionFixture(sessionID: sessionID, root: root)
        let recorder = DirectTerminalServiceRecorder(payload: fixture.payload)
        box.host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: recorder.send,
            stateStreamSubscriber: subscriber.subscribe)
        waitForCondition("host subscribes to the state stream") { subscriber.isSubscribed }
        XCTAssertEqual(subscriber.stoppedClientCount, 0, "the subscription was already stopped before the host was released")
    }

    /// Carries the host across to the thread that performs its last release, and watches it without
    /// keeping it alive. `@unchecked Sendable` because the host is `@MainActor` and not `Sendable`: each
    /// box is written once by the test and once by the releasing thread, never concurrently.
    private final class SessionHostBox: @unchecked Sendable { var host: RemoteGhosttySessionHost? }
    private final class WeakSessionHostReference: @unchecked Sendable { weak var host: RemoteGhosttySessionHost? }
    /// Carries the releasing thread's verdict back to the test.
    private final class ReleasingThreadOutcome: @unchecked Sendable { var value = false }

    /// Captures the host's state-stream callbacks so a test can emit payloads the way the device state
    /// model does: off the main actor, in a known order. It also stands in for the model's listener
    /// handle, counting the handles the host stops so a test can prove the host detaches from the
    /// fan-out rather than silently dropping its subscription.
    private final class RecordingStateStreamSubscriber: @unchecked Sendable {
        private final class Client: TerminalRemoteStateStreamClient, @unchecked Sendable {
            private let onStop: @Sendable () -> Void

            init(onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }

            func stop() { onStop() }
        }

        private let lock = NSLock()
        private var onEvent: (@Sendable (GhosttyRemoteSessionStatePayload) -> Void)?
        private var onDisconnect: (@Sendable ((any Error)?) -> Void)?
        private var stoppedClients = 0

        var isSubscribed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return onEvent != nil
        }

        var stoppedClientCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return stoppedClients
        }

        func subscribe(
            _: String, onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void,
            onDisconnect: @escaping @Sendable ((any Error)?) -> Void
        ) throws -> any TerminalRemoteStateStreamClient {
            lock.lock()
            self.onEvent = onEvent
            self.onDisconnect = onDisconnect
            lock.unlock()
            return Client(onStop: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.stoppedClients += 1
                self.lock.unlock()
            })
        }

        /// Reports the drop the model reports to a listener when the shared subscription goes away.
        func disconnect(_ error: (any Error)?) {
            lock.lock()
            let onDisconnect = self.onDisconnect
            lock.unlock()
            onDisconnect?(error)
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
        // On the alternate screen the wheel belongs to the full-screen program, so the gesture is
        // forwarded rather than scrolling the pane's own replay - which is what makes this a test of a
        // forwarded scroll's failure at all.
        let fixture = try makeRunningSessionFixture(sessionID: "remote-scroll-lost-link", root: root, alternateScreenActive: true)
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
        let client = TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
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
        let client = TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
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
    /// minutes later. `TerminalInputSerialQueue.enqueue` chains every send behind its predecessor, so the
    /// second and third sends are still queued behind the first when it fails; `inputFailureHandler`
    /// answering `true` (the model's verdict that the link is gone) must make the host discard that
    /// backlog instead of letting them reach the daemon once it "recovers" (the sender scripted to fail
    /// only the first).
    ///
    /// The first send is held inside the sender until all three are enqueued. Without that hold the first
    /// send's task can fail while the test is still enqueuing, and `cancelAll`'s generation bump then
    /// lands mid-backlog: a send enqueued after the bump carries the new generation, survives the discard,
    /// and reaches the daemon — the queue behaving correctly, but the test measuring a backlog it never
    /// actually assembled.
    @MainActor func testTransportFailureDiscardsQueuedInputInsteadOfDeliveringItLate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRunningSessionFixture(sessionID: "remote-drops-queued-input", root: root)
        // Only the first control request fails; every later one would succeed — proving a later send was
        // never attempted, not merely that it also failed.
        let sender = ScriptedControlRequestSender(
            payload: fixture.payload, controlError: SimulatedTransportFailure(), failFirstControlRequestOnly: true, holdFirstControlRequest: true)
        let host = RemoteGhosttySessionHost(
            launchConfiguration: fixture.launchConfiguration, paths: fixture.paths, terminalServiceRequestSender: sender.send,
            inputFailureHandler: { _ in true })

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        let client = TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
        try host.attach(client: client, mode: .owner, into: container)

        XCTAssertTrue(host.sendTextAsPaste("first"))
        XCTAssertTrue(host.sendTextAsPaste("second"))
        XCTAssertTrue(host.sendTextAsPaste("third"))
        // The whole backlog is queued under one generation; let the first send fail against it.
        sender.releaseFirstControlRequest()

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
        let client = TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
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
        let client = TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:02Z")
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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange.rawValue, emittedAt: "2026-06-10T00:00:01Z",
            sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
            renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(missingBaselineDelta))
        let fullPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange.rawValue, emittedAt: "2026-06-10T00:00:02Z",
            sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
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

    /// A pane whose tab is not selected is off screen, and while it is there it applies no screen
    /// updates at all. What it paints when its tab comes back is the session's CURRENT screen, because
    /// the reduction never stopped and the one update it held is a materialized full frame.
    ///
    /// A title change is not screen content, so it lands while the pane is off screen — that is what
    /// keeps an unselected tab's label live — and the screen the pane was holding applies with it.
    @MainActor func testOffScreenPaneHoldsScreenUpdatesAndPaintsTheCurrentScreenWhenDisplayedAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-offscreen-hold"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try seedSessionRow(sessionID: sessionID, paths: paths)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-08-20T00:00:00Z",
            title: "live", workingDirectory: "/tmp/live", columns: 5, rows: 1)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        let queue = DispatchQueue(label: "spaces.remote-device.offscreen-hold-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-08-20T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: nil, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: nil)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: sessionID, title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-08-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        // The pane's terminal container is a subview rather than the window's content view, so hiding it
        // takes the pane off screen exactly the way switching to another tab does.
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let container = NSView(frame: contentView.bounds)
        contentView.addSubview(container)
        let window = NSWindow(contentRect: contentView.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-20T00:00:00Z"),
            mode: .owner, into: container)

        func screenPayload(text: String, sequence: Int) throws -> GhosttyRemoteSessionStatePayload {
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: "2026-08-20T00:00:0\(sequence)Z",
                sessionStateRevision: UInt64(sequence + 1), sessionStateFlags: 1, screenStateRevision: UInt64(sequence + 1),
                runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live",
                outputByteCount: nil, renderUpdate: try renderUpdate(text: text, sessionRevision: UInt64(sequence + 1)))
        }

        server.broadcast(try screenPayload(text: "alpha", sequence: 1))
        waitForCondition("the displayed pane painted its first frame") { self.normalize(self.visibleText(for: host)) == "alpha" }

        container.isHidden = true
        server.broadcast(try screenPayload(text: "bravo", sequence: 2))
        // Long enough that an ungated pane would have applied several times over.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(normalize(visibleText(for: host)), "alpha", "an off-screen pane applied a screen update")

        server.broadcast(try screenPayload(text: "charlie", sequence: 3))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(normalize(visibleText(for: host)), "alpha")

        // A title change is a state transition, so it applies while the pane is still off screen, and it
        // brings the screen the pane was holding with it.
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.sessionMetadata.rawValue, emittedAt: "2026-08-20T00:00:04Z",
                sessionStateRevision: 5, sessionStateFlags: 1, screenStateRevision: nil, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "renamed", workingDirectory: "/tmp/live", outputByteCount: nil))
        waitForCondition("the off-screen pane's title kept up with the session") { host.effectiveTitle == "renamed" }
        XCTAssertEqual(normalize(visibleText(for: host)), "charlie", "the transition painted an older screen than the one being held")

        // Back on screen: the pane repaints from the newest frame, not from the one it left on.
        server.broadcast(try screenPayload(text: "delta", sequence: 5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(normalize(visibleText(for: host)), "charlie", "the pane resumed applying screen updates while still off screen")
        container.isHidden = false
        waitForCondition("the pane painted the session's current screen") { self.normalize(self.visibleText(for: host)) == "delta" }
    }

    /// A pane opens with its terminal container hidden and stays hidden until it reports it has content
    /// to show, so its FIRST frame can never be held: holding it would leave the pane waiting to be
    /// displayed so it could apply the frame that is what would let it be displayed.
    @MainActor func testPaneThatHasNeverPaintedAppliesItsFirstFrameWhileOffScreen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-offscreen-first-frame"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try seedSessionRow(sessionID: sessionID, paths: paths)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-08-20T00:00:00Z",
            title: "live", workingDirectory: "/tmp/live", columns: 5, rows: 1)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        let queue = DispatchQueue(label: "spaces.remote-device.offscreen-first-frame-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-08-20T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: nil, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: nil)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: sessionID, title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-08-20T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let container = NSView(frame: contentView.bounds)
        container.isHidden = true
        contentView.addSubview(container)
        let window = NSWindow(contentRect: contentView.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-08-20T00:00:00Z"),
            mode: .owner, into: container)

        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: "2026-08-20T00:00:01Z",
                sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 2)))

        waitForCondition("the pane reports content the controller can unhide it for") { host.hasRenderableSurface() }
        XCTAssertEqual(normalize(host.snapshotText()), "alpha")
    }

    /// A pane container inside a visible window: a host attached into it is ON SCREEN, the way an
    /// installed pane in the selected tab is.
    ///
    /// A pane that is off screen holds its screen updates until it comes back
    /// (`TerminalRemoteStateReductionPipeline.setHoldsScreenUpdates`), so a test that asserts on what a
    /// pane paints — or that uses a screen-content payload as a fence — has to put the pane on screen.
    /// The container is a subview of the window's content view rather than the content view itself, so a
    /// test can also take the pane off screen with `container.isHidden = true`, which is what switching
    /// to another tab amounts to.
    @MainActor private func makeDisplayedPaneContainer(width: CGFloat = 420, height: CGFloat = 180) -> (container: NSView, window: NSWindow) {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let container = NSView(frame: contentView.bounds)
        contentView.addSubview(container)
        let window = NSWindow(contentRect: contentView.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        return (container, window)
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

    private func snapshot(
        text: String, mouseReportingActive: Bool = false, mouseShiftCapture: UInt8 = GhosttyTerminalSnapshot.mouseShiftCaptureUnset,
        alternateScreenActive: Bool = false, selection: GhosttyTerminalSelectionRange? = nil
    ) -> GhosttyTerminalSnapshot {
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
            defaultBackgroundRGB: 0x000000, cells: cells, mouseReportingActive: mouseReportingActive, mouseShiftCapture: mouseShiftCapture,
            alternateScreenActive: alternateScreenActive, selection: selection)
    }

    private func renderUpdate(
        text: String, sessionRevision: UInt64? = nil, ownerEpoch: UInt64 = 0, alternateScreenActive: Bool = false, mouseReportingActive: Bool = false
    ) throws -> Data {
        let frame = GhosttyRenderFrame(
            sessionRevision: sessionRevision, ownerEpoch: ownerEpoch,
            snapshot: snapshot(text: text, mouseReportingActive: mouseReportingActive, alternateScreenActive: alternateScreenActive))
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

    private func makeRunningSessionFixture(sessionID: String, root: URL, alternateScreenActive: Bool = false) throws -> RunningSessionFixture {
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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange.rawValue, emittedAt: "2026-07-24T00:00:01Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1, alternateScreenActive: alternateScreenActive))
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
