import AppKit
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// Ordering coverage for submit-style control sends. A text send with `appendNewline` becomes two writes
/// — the text (paste-encoded) and then the carriage return that submits it — and that pair must stay
/// adjacent and ordered against every later control-request input write. Two submit sends enqueued
/// back-to-back (the daemon's notification flush delivers queued lines like this) must reach the child as
/// two separately submitted lines, never as one merged line with a stray Enter. `cat` leaves bracketed
/// paste off, so the pasted text reaches the PTY verbatim and the transcript shows the raw grouping.
final class GhosttyEmbeddedSubmitOrderingTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

    /// Carries an engine-isolated reference (created inside a `TerminalEngineActor.run` block) back out to
    /// the nonisolated test body; the value is only ever *used* on the engine actor via a later bridge.
    private final class Box<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

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

    /// Nonisolated poller so its `Task.sleep` suspensions don't hold the engine's queue while the engine
    /// runs the tick pump + sequencer writes the condition is waiting on. Each poll hops onto the engine
    /// synchronously to tick and evaluate the (engine-isolated) condition together.
    private func waitUntil(
        timeout: TimeInterval = 30, pollInterval: TimeInterval = 0.05, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping @TerminalEngineActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let satisfied = TerminalEngineActor.runSynchronously { () -> Bool in
                if condition() { return true }
                GhosttyEmbeddedAppService.shared.tick()
                return false
            }
            if satisfied { return }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        XCTFail("Timed out waiting for condition.", file: file, line: line)
        throw NSError(domain: "GhosttyEmbeddedSubmitOrderingTests", code: 1)
    }

    /// Engine-isolated; call from inside a `TerminalEngineActor.run`/`runSynchronously` bridge.
    @TerminalEngineActor private static func snapshotText(of host: GhosttyEmbeddedSessionHost) -> String {
        host.core.rendererHost.requestSurfaceRefresh()
        GhosttyEmbeddedAppService.shared.tick()
        return host.core.rendererHost.snapshotText() ?? ""
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }

    func testRapidSubmitSendsReachChildAsSeparateSubmissions() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        // `cat` echoes each submitted line back, so the transcript shows exactly how the input was
        // grouped into lines by the PTY line discipline.
        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "submit-ordering-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "echo SUBMIT_READY; cat",
                    createdAt: "2026-07-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            try host.startIfNeeded()
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }

        // Capture only the Sendable output path in the engine-isolated `waitUntil` conditions (not the
        // non-Sendable `transcript` closure); the nonisolated test body below still uses `transcript`.
        let outputPath = paths.outputPath
        let transcript = { (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "" }
        try await waitUntil { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

        let firstMarker = "SUBMIT_ORDER_FIRST"
        let secondMarker = "SUBMIT_ORDER_SECOND"
        // Handled from here, off the engine: a send waits for its writes to reach the PTY, and that wait
        // must not be held on the engine those writes run on.
        let firstResponse = host.core.handleControlRequest(TerminalControlRequest(command: "send", text: firstMarker, appendNewline: true))
        XCTAssertTrue(firstResponse.ok, firstResponse.message)
        let secondResponse = host.core.handleControlRequest(TerminalControlRequest(command: "send", text: secondMarker, appendNewline: true))
        XCTAssertTrue(secondResponse.ok, secondResponse.message)

        // Each marker appears once as the PTY echo of the typed line and once as `cat`'s output of the
        // submitted line, so two occurrences of the second marker means both Enters have landed.
        try await waitUntil { Self.occurrences(of: secondMarker, in: (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "") >= 2 }

        let output = transcript()
        XCTAssertFalse(
            output.contains(firstMarker + secondMarker),
            "the second submit's text was written before the first submit's carriage return, merging both commands into one line: \(output)")
        XCTAssertGreaterThanOrEqual(Self.occurrences(of: firstMarker, in: output), 2, "the first submit must be echoed and submitted on its own line")
    }

    private func startSubmitHost(command: String, paths: TerminalSessionPaths) async throws -> GhosttyEmbeddedSessionHost {
        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "submit-framing-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command,
                    createdAt: "2026-07-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            try host.startIfNeeded()
            return Box(host)
        }
        return hostBox.value
    }

    /// A submit whose receiver has NOT enabled bracketed paste goes out unframed, so its CR must be
    /// temporally separated from the text (issue #187): an agent TUI that is already reading stdin but
    /// has not enabled DECSET 2004 yet — right after a detection-based spawn — would otherwise fold a
    /// coalesced text+CR into one paste and leave the prompt unsubmitted. `cat` never enables bracketed
    /// paste, and in canonical mode the PTY line discipline delivers the line to it only when the CR
    /// lands, so "cat produced the line" is exactly "the CR arrived".
    func testSubmitToUnframedReceiverSeparatesItsCarriageReturn() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        let host = try await startSubmitHost(command: "echo SUBMIT_READY; cat", paths: paths)
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }
        let outputPath = paths.outputPath
        try await waitUntil { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

        let marker = "SUBMIT_UNFRAMED_MARKER"
        let sentAt = ContinuousClock.now
        let response = host.core.handleControlRequest(TerminalControlRequest(command: "send", text: marker, appendNewline: true))
        XCTAssertTrue(response.ok, response.message)
        // The send answers only once its bytes have reached the PTY, so the round trip itself measures the
        // separation the CR waited out: an immediate CR would return within milliseconds.
        XCTAssertGreaterThanOrEqual(
            sentAt.duration(to: .now), .milliseconds(450), "an unframed submit's CR landed immediately instead of waiting out the separation")

        try await waitUntil { Self.occurrences(of: marker, in: (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "") >= 2 }
    }

    /// A submit whose receiver HAS enabled bracketed paste is framed by the paste markers, which is what
    /// keeps its CR a distinct Enter — so the CR follows immediately and the submit pays no pacing cost
    /// (issue #389). The child enables DECSET 2004 before signaling readiness; `cat` then receives and
    /// re-emits the frame's escape bytes, so the transcript showing the open marker proves the framed
    /// path, and the line completing well inside the 500ms separation proves the CR was not delayed.
    func testSubmitToBracketedPasteReceiverSubmitsImmediately() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        let host = try await startSubmitHost(command: "printf '\\033[?2004h'; echo SUBMIT_READY; cat", paths: paths)
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }
        let outputPath = paths.outputPath
        try await waitUntil { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

        let marker = "SUBMIT_FRAMED_MARKER"
        let sentAt = ContinuousClock.now
        let response = host.core.handleControlRequest(TerminalControlRequest(command: "send", text: marker, appendNewline: true))
        XCTAssertTrue(response.ok, response.message)

        try await waitUntil(pollInterval: 0.02) {
            Self.occurrences(of: marker, in: (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "") >= 2
        }
        let elapsed = sentAt.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(400), "a framed submit's CR must follow immediately, not after the unframed separation")
        XCTAssertTrue(
            ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("\u{1b}[200~"),
            "the receiver enabled bracketed paste, so the submit's text must have gone out framed")
    }

    /// An embedded submit answers for the host-PTY write ghostty produced for it, not for ghostty having
    /// accepted the text. Ghostty hands input to its own IO thread, which calls back into the host PTY
    /// driver, so the proof is temporal: the child here never reads its stdin, so writing a payload this
    /// size takes real time, and a send that returned once ghostty took the text would come back in
    /// milliseconds. The receiver enables bracketed paste, so the submit pays no separation delay and the
    /// round trip measures the PTY write alone.
    func testEmbeddedSubmitAnswersOnlyOnceItsHostPTYWriteCompleted() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        let host = try await startSubmitHost(command: "printf '\\033[?2004h'; echo SUBMIT_READY; sleep 30", paths: paths)
        let hostBox = Box(host)
        defer { TerminalEngineActor.runSynchronously { hostBox.value.terminate() } }
        let outputPath = paths.outputPath
        try await waitUntil { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

        let sentAt = ContinuousClock.now
        let response = host.core.handleControlRequest(
            TerminalControlRequest(command: "send", text: String(repeating: "A", count: 8 << 20), appendNewline: true))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertGreaterThanOrEqual(
            sentAt.duration(to: .now), .milliseconds(150),
            "the submit answered before its bytes could have reached the PTY, so it answered for ghostty's queue instead")
    }

    /// The failure half of the same contract, and the case the acknowledgement exists for: the submit's
    /// bytes are in the host PTY write queue when the child dies, so they never reach it. The CHILD is
    /// killed rather than the session torn down deliberately — the ghostty surface stays alive, so the
    /// only thing that can fail the send is the PTY write itself.
    func testEmbeddedSubmitWhoseHostPTYWriteFailsReportsFailure() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        let host = try await startSubmitHost(command: "printf '\\033[?2004h'; echo SUBMIT_READY; sleep 30", paths: paths)
        let hostBox = Box(host)
        defer { TerminalEngineActor.runSynchronously { hostBox.value.terminate() } }
        let outputPath = paths.outputPath
        try await waitUntil { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

        let childPID = try XCTUnwrap(TerminalEngineActor.runSynchronously { hostBox.value.core.childPID() })
        let killer = Task.detached {
            try? await Task.sleep(for: .milliseconds(100), clock: .continuous)
            kill(childPID, SIGKILL)
        }
        let response = host.core.handleControlRequest(
            TerminalControlRequest(command: "send", text: String(repeating: "A", count: 8 << 20), appendNewline: true))
        await killer.value

        XCTAssertFalse(response.ok, "a submit whose bytes never reached the PTY must not report success")
        XCTAssertEqual(response.errorCode, .sessionNotRunning)
    }

    /// A send answers for its bytes, not for its enqueue: a session torn down while the submit still had a
    /// write outstanding must report failure. This is the case that made an automation record a seed
    /// prompt as delivered that no agent ever received — the write found no surface and silently did
    /// nothing while the request had already been answered ok. `cat` leaves bracketed paste off, so the
    /// submit's CR is still waiting out its separation when the session goes away.
    func testSubmitWhoseSessionIsTornDownBeforeItsCarriageReturnReportsFailure() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        let host = try await startSubmitHost(command: "echo SUBMIT_READY; cat", paths: paths)
        let hostBox = Box(host)
        defer { TerminalEngineActor.runSynchronously { hostBox.value.terminate() } }
        let outputPath = paths.outputPath
        try await waitUntil { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

        let teardown = Task.detached {
            try? await Task.sleep(for: .milliseconds(150), clock: .continuous)
            TerminalEngineActor.runSynchronously { hostBox.value.terminate() }
        }
        let response = host.core.handleControlRequest(TerminalControlRequest(command: "send", text: "SUBMIT_TORN_DOWN", appendNewline: true))
        await teardown.value

        XCTAssertFalse(response.ok, "a submit whose carriage return never reached the PTY must not report success")
        XCTAssertEqual(response.errorCode, .sessionNotRunning)
    }

    /// The barrier a submit waits on must not touch the terminal, and the only way to prove that is to
    /// submit while the parser is in a state where *any* byte would change what the child's output
    /// renders as. The child emits the lead byte of `\u{2713}` (0xE2), pauses, then completes the
    /// codepoint: the parser sits parked mid-UTF-8 for the whole window. A barrier that posted a payload
    /// byte (a NUL was the obvious candidate) would be consumed as the sequence's continuation byte and
    /// the child's own output would render as replacement characters — and, worse, the corrupted screen
    /// would disagree with output.log, which records what the child actually wrote.
    func testSubmitBarrierLeavesOutputParkedMidCodepointUntouched() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        // `/usr/bin/printf` rather than the shell builtin: an exiting process flushes, so the lead byte is
        // in the PTY before the pause instead of possibly sitting in the shell's stdio buffer. Echo is off
        // and nothing reads stdin, so the submitted bytes never come back as output of their own.
        let host = try await startSubmitHost(
            command: "stty -echo; /usr/bin/printf '\\033[?2004h'; echo SUBMIT_READY; /usr/bin/printf '\\342'; sleep 2;"
                + " /usr/bin/printf '\\234\\223UTF8_TAIL\\n'; sleep 30",
            paths: paths)
        let hostBox = Box(host)
        defer { TerminalEngineActor.runSynchronously { hostBox.value.terminate() } }

        // output.log is written from Ghostty's data callback, which fires while `process_output` is
        // processing those bytes — so the log ending in the lead byte means the parser has already taken
        // it and is waiting for the continuation bytes.
        let outputPath = paths.outputPath
        try await waitUntil {
            guard let data = FileManager.default.contents(atPath: outputPath), let last = data.last else { return false }
            return last == 0xE2 && (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)).contains("SUBMIT_READY")
        }

        let response = host.core.handleControlRequest(TerminalControlRequest(command: "send", text: "MID_SEQUENCE_SUBMIT", appendNewline: true))
        XCTAssertTrue(response.ok, response.message)

        let renderedAtSubmit = TerminalEngineActor.runSynchronously { Self.snapshotText(of: hostBox.value) }
        XCTAssertFalse(
            renderedAtSubmit.contains("UTF8_TAIL"),
            "the child finished its codepoint before the submit landed, so this run never exercised a parked parser")

        try await waitUntil { Self.snapshotText(of: hostBox.value).contains("UTF8_TAIL") }
        let rendered = TerminalEngineActor.runSynchronously { Self.snapshotText(of: hostBox.value) }
        XCTAssertTrue(rendered.contains("\u{2713}UTF8_TAIL"), "the submit disturbed output the child wrote around it: \(rendered)")
        XCTAssertFalse(rendered.contains("\u{FFFD}"), "the barrier injected a byte into the child's incomplete codepoint: \(rendered)")
    }
}
