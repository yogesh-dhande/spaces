import AppKit
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// Ordering coverage for submit-style control sends. A text send with `appendNewline` writes the text
/// and a delayed carriage return so agent TUIs read the Enter as a distinct keystroke; that text+CR
/// pair must stay ordered against every later control-request input write. Two submit sends arriving
/// within the CR delay (the daemon's notification flush delivers queued lines back-to-back like this)
/// must reach the child as two separately submitted lines, never as one merged line with a stray Enter.
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
        timeout: TimeInterval = 15, pollInterval: TimeInterval = 0.05, file: StaticString = #filePath, line: UInt = #line,
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
}
