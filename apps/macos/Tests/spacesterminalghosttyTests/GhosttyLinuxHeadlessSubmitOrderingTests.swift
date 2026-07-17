#if os(Linux)
    import Foundation
    import XCTest
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Linux mirror of `GhosttyEmbeddedSubmitOrderingTests`: two submit-style sends arriving within
    /// the submit-CR delay must reach the child as two separately submitted lines, never as one
    /// merged line with a stray Enter (the daemon's notification flush delivers queued lines
    /// back-to-back like this).
    final class GhosttyLinuxHeadlessSubmitOrderingTests: XCTestCase {
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

        @MainActor private func waitAsync(
            timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertTrue(condition(), "waitAsync timed out", file: file, line: line)
        }

        private func occurrences(of needle: String, in haystack: String) -> Int {
            haystack.components(separatedBy: needle).count - 1
        }

        @MainActor func testRapidSubmitSendsReachChildAsSeparateSubmissions() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = TerminalSessionPaths(rootDirectory: root.path)

            // `cat` echoes each submitted line back, so the transcript shows exactly how the input
            // was grouped into lines by the PTY line discipline.
            let core = GhosttyEmbeddedSessionCore(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "submit-ordering-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "echo SUBMIT_READY; cat",
                    createdAt: "2026-07-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            defer { core.terminate() }
            try core.startIfNeeded()

            let transcript = { (try? String(contentsOfFile: paths.outputPath, encoding: .utf8)) ?? "" }
            try await waitAsync { transcript().contains("SUBMIT_READY") }

            let firstMarker = "SUBMIT_ORDER_FIRST"
            let secondMarker = "SUBMIT_ORDER_SECOND"
            let firstResponse = core.handleControlRequest(TerminalControlRequest(command: "send", text: firstMarker, appendNewline: true))
            XCTAssertTrue(firstResponse.ok, firstResponse.message)
            let secondResponse = core.handleControlRequest(TerminalControlRequest(command: "send", text: secondMarker, appendNewline: true))
            XCTAssertTrue(secondResponse.ok, secondResponse.message)

            // Each marker appears once as the PTY echo of the typed line and once as `cat`'s output
            // of the submitted line, so two occurrences of the second marker means both Enters landed.
            try await waitAsync { self.occurrences(of: secondMarker, in: transcript()) >= 2 }

            let output = transcript()
            XCTAssertFalse(
                output.contains(firstMarker + secondMarker),
                "the second submit's text was written before the first submit's carriage return, merging both commands: \(output)")
            XCTAssertGreaterThanOrEqual(
                occurrences(of: firstMarker, in: output), 2, "the first submit must be echoed and submitted on its own line")
        }
    }
#endif
