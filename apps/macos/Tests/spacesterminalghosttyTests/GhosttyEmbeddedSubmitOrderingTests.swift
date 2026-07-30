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
        let firstResponse = TerminalEngineActor.runSynchronously {
            host.core.handleControlRequest(TerminalControlRequest(command: "send", text: firstMarker, appendNewline: true))
        }
        XCTAssertTrue(firstResponse.ok, firstResponse.message)
        let secondResponse = TerminalEngineActor.runSynchronously {
            host.core.handleControlRequest(TerminalControlRequest(command: "send", text: secondMarker, appendNewline: true))
        }
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
        let response = TerminalEngineActor.runSynchronously {
            host.core.handleControlRequest(TerminalControlRequest(command: "send", text: marker, appendNewline: true))
        }
        XCTAssertTrue(response.ok, response.message)

        // Half the 500ms separation in: the text may be echoed, but the CR must not have landed yet —
        // with an immediate CR, `cat` emits the completed line within milliseconds and this trips.
        try? await Task.sleep(for: .milliseconds(250), clock: .continuous)
        let midway = TerminalEngineActor.runSynchronously { () -> String in
            GhosttyEmbeddedAppService.shared.tick()
            return (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
        }
        XCTAssertLessThan(
            Self.occurrences(of: marker, in: midway), 2, "an unframed submit's CR landed immediately instead of waiting out the separation: \(midway)"
        )

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
        let response = TerminalEngineActor.runSynchronously {
            host.core.handleControlRequest(TerminalControlRequest(command: "send", text: marker, appendNewline: true))
        }
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
}
