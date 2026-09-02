#if os(macOS)
    import AppKit
    import Foundation
    import XCTest
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// End-to-end coverage that a named key press is encoded against the session's *live* terminal state
    /// rather than a fixed table. The child puts the tty in raw mode and runs `cat -v`, so every byte the
    /// daemon writes comes back through the PTY in a readable form: a carriage return as `^M`, an escape
    /// as `^[`.
    ///
    /// Shift+Enter is the case that motivated this: it must stay a carriage return for an ordinary program
    /// and become `CSI 13;2u` for one that enabled the Kitty keyboard protocol, which is what agent TUIs
    /// rely on to tell Shift+Enter apart from Enter.
    final class GhosttyEmbeddedKeyEncodingTests: XCTestCase {
        private var originalDatabasePath: String?
        private var originalRuntimeDirectory: String?
        private var databaseRoot: URL?

        /// Carries an engine-isolated reference back out to the nonisolated test body; it is only ever used
        /// again from the engine actor.
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
            throw NSError(domain: "GhosttyEmbeddedKeyEncodingTests", code: 1)
        }

        private static func occurrences(of needle: String, in haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }

        /// `stty raw -echo` stops the line discipline from rewriting or echoing input, so `cat -v` reports
        /// exactly the bytes the daemon wrote.
        ///
        /// `programEnables` is emitted by the child before it starts echoing, which is how a real program
        /// announces the modes that change key encoding (the Kitty keyboard protocol, DECCKM). It has to be
        /// written by the program rather than sent as input: `cat -v` renders input escapes as visible text,
        /// so the terminal would never parse them.
        private func startEchoSession(programEnables: String = "", file: StaticString = #filePath, line: UInt = #line) async throws -> (
            host: GhosttyEmbeddedSessionHost, outputPath: String
        ) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            let enableModes = programEnables.isEmpty ? "" : "printf '\(programEnables)'; "
            let command = "stty raw -echo; \(enableModes)printf 'KEYS_READY'; cat -v"

            let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
                let host = GhosttyEmbeddedSessionHost(
                    launchConfiguration: TerminalSessionLaunchConfiguration(
                        sessionID: "key-encoding-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                        workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command,
                        createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
                try host.startIfNeeded()
                return Box(host)
            }
            let outputPath = paths.outputPath
            try await waitUntil(file: file, line: line) { Self.transcript(at: outputPath).contains("KEYS_READY") }
            return (hostBox.value, outputPath)
        }

        private static func transcript(at path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

        private func sendKey(_ key: String, to host: GhosttyEmbeddedSessionHost, file: StaticString = #filePath, line: UInt = #line) {
            let response = TerminalEngineActor.runSynchronously { host.core.handleControlRequest(TerminalControlRequest(command: "key", key: key)) }
            XCTAssertTrue(response.ok, response.message, file: file, line: line)
        }

        func testShiftEnterEncodesAKittySequenceOnceTheProgramEnablesTheProtocol() async throws {
            let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
            guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

            // `CSI > 1 u` pushes the disambiguate flag, the way an agent TUI does on startup.
            let (host, outputPath) = try await startEchoSession(programEnables: "\\033[>1u")
            defer { TerminalEngineActor.runSynchronously { host.terminate() } }

            // Enter keeps its legacy encoding even under the Kitty protocol, so a shell stays usable.
            sendKey("enter", to: host)
            try await waitUntil { Self.transcript(at: outputPath).contains("^M") }

            sendKey("shift+enter", to: host)
            try await waitUntil { Self.transcript(at: outputPath).contains("^[[13;2u") }

            let output = Self.transcript(at: outputPath)
            XCTAssertEqual(Self.occurrences(of: "^M", in: output), 1, "Shift+Enter must not also send a carriage return: \(output)")
        }

        /// Without the Kitty protocol the two still differ, just in xterm's older form. What matters is that
        /// plain Enter keeps submitting: it is the same carriage return every shell and TUI expects.
        func testEnterStaysACarriageReturnAndShiftEnterDoesNotSubmitWithoutTheKittyProtocol() async throws {
            let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
            guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

            let (host, outputPath) = try await startEchoSession()
            defer { TerminalEngineActor.runSynchronously { host.terminate() } }

            sendKey("enter", to: host)
            try await waitUntil { Self.transcript(at: outputPath).contains("^M") }

            sendKey("shift+enter", to: host)
            try await waitUntil { Self.transcript(at: outputPath).contains("^[[27;2;13~") }

            let output = Self.transcript(at: outputPath)
            XCTAssertEqual(Self.occurrences(of: "^M", in: output), 1, "Shift+Enter must not submit the line: \(output)")
        }

        /// Modified arrows produced no bytes at all before keys carried their modifiers: the client dropped
        /// the event outright.
        func testModifiedArrowsEncodeInsteadOfBeingDropped() async throws {
            let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
            guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

            let (host, outputPath) = try await startEchoSession()
            defer { TerminalEngineActor.runSynchronously { host.terminate() } }

            sendKey("shift+up", to: host)
            try await waitUntil { Self.transcript(at: outputPath).contains("^[[1;2A") }
        }

        /// DECCKM: a full-screen program switches arrows to their SS3 form, and a fixed byte table cannot
        /// follow that.
        func testArrowsFollowApplicationCursorKeyMode() async throws {
            let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
            guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

            let (host, outputPath) = try await startEchoSession(programEnables: "\\033[?1h")
            defer { TerminalEngineActor.runSynchronously { host.terminate() } }

            sendKey("up", to: host)
            try await waitUntil { Self.transcript(at: outputPath).contains("^[OA") }
        }

        /// The Mac line-editing chords are fixed byte sequences on purpose, so they must not start varying
        /// with terminal mode the way encoded key presses do.
        func testMacLineEditingChordsKeepTheirReadlineBytes() async throws {
            let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
            guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

            let (host, outputPath) = try await startEchoSession(programEnables: "\\033[>1u")
            defer { TerminalEngineActor.runSynchronously { host.terminate() } }

            sendKey("cmd+left", to: host)
            try await waitUntil { Self.transcript(at: outputPath).contains("^A") }

            sendKey("opt+backspace", to: host)
            try await waitUntil { Self.transcript(at: outputPath).contains("^W") }

            sendKey("opt+left", to: host)
            try await waitUntil { Self.transcript(at: outputPath).contains("^[b") }
        }
    }
#endif
