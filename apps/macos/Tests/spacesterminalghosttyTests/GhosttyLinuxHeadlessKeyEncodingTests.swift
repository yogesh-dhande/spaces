#if os(Linux)
    import Foundation
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Linux mirror of `GhosttyEmbeddedKeyEncodingTests`. The two hosts encode keys through different
    /// libraries — the macOS daemon hands the press to its ghostty surface, this one runs libghostty-vt's
    /// key encoder against the vt session — so the same key press must still produce the same bytes, or a
    /// remote terminal would behave differently from a local one.
    ///
    /// The child puts the tty in raw mode and runs `cat -v`, so every byte the daemon writes comes back
    /// through the PTY in a readable form: a carriage return as `^M`, an escape as `^[`.
    ///
    /// Swift Testing (not XCTest) on purpose: the swift-testing runner executes tests from an async main,
    /// so async tests make progress on Linux, where an async XCTest method deadlocks. The headless core is
    /// `TerminalEngineActor`-isolated, so the test body stays nonisolated and hops onto the engine for
    /// every core call. `.serialized` because each test mutates the process-wide SPACES_* environment and
    /// owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessKeyEncodingTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference back out to the nonisolated test body; it is only ever used
        /// again through an engine bridge.
        private final class Box<Value>: @unchecked Sendable {
            let value: Value
            init(_ value: Value) { self.value = value }
        }

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseRoot = root
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
            setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        }

        deinit {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: databaseRoot)
        }

        // MARK: - Helpers

        private static func transcript(at path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

        private static func occurrences(of needle: String, in haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }

        /// Nonisolated poller so its suspensions don't hold the engine's queue while the engine runs the
        /// queued writes the condition is waiting on.
        private func waitUntil(timeout: TimeInterval = 15, _ comment: Comment, condition: @escaping @Sendable () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            #expect(condition(), comment)
        }

        /// `stty raw -echo` stops the line discipline from rewriting or echoing input, so `cat -v` reports
        /// exactly the bytes the daemon wrote. `programEnables` is emitted by the child before it starts
        /// echoing, which is how a real program announces the modes that change key encoding; it cannot be
        /// sent as input because `cat -v` renders input escapes as visible text.
        private func startEchoSession(programEnables: String = "") async throws -> (core: Box<GhosttyEmbeddedSessionCore>, outputPath: String) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let enableModes = programEnables.isEmpty ? "" : "printf '\(programEnables)'; "
            let command = "stty raw -echo; \(enableModes)printf 'KEYS_READY'; cat -v"

            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(
                    launchConfiguration: TerminalSessionLaunchConfiguration(
                        sessionID: "key-encoding-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                        workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command,
                        createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
                try core.startIfNeeded()
                return Box(core)
            }
            let outputPath = paths.outputPath
            try await waitUntil("the child must reach its echo loop") { Self.transcript(at: outputPath).contains("KEYS_READY") }
            return (coreBox, outputPath)
        }

        private func terminate(_ core: Box<GhosttyEmbeddedSessionCore>) { TerminalEngineActor.runSynchronously { core.value.terminate() } }

        private func sendKey(_ key: String, to core: Box<GhosttyEmbeddedSessionCore>) {
            let response = TerminalEngineActor.runSynchronously { core.value.handleControlRequest(TerminalControlRequest(command: "key", key: key)) }
            #expect(response.ok, "sending \(key) must succeed: \(response.message)")
        }

        // MARK: - Tests

        @Test func shiftEnterEncodesAKittySequenceOnceTheProgramEnablesTheProtocol() async throws {
            // `CSI > 1 u` pushes the disambiguate flag, the way an agent TUI does on startup.
            let (core, outputPath) = try await startEchoSession(programEnables: "\\033[>1u")
            defer { terminate(core) }

            // Enter keeps its legacy encoding even under the Kitty protocol, so a shell stays usable.
            sendKey("enter", to: core)
            try await waitUntil("Enter must send a carriage return") { Self.transcript(at: outputPath).contains("^M") }

            sendKey("shift+enter", to: core)
            try await waitUntil("Shift+Enter must send the Kitty sequence") { Self.transcript(at: outputPath).contains("^[[13;2u") }

            let output = Self.transcript(at: outputPath)
            #expect(Self.occurrences(of: "^M", in: output) == 1, "Shift+Enter must not also send a carriage return: \(output)")
        }

        @Test func enterStaysACarriageReturnAndShiftEnterDoesNotSubmitWithoutTheKittyProtocol() async throws {
            let (core, outputPath) = try await startEchoSession()
            defer { terminate(core) }

            sendKey("enter", to: core)
            try await waitUntil("Enter must send a carriage return") { Self.transcript(at: outputPath).contains("^M") }

            sendKey("shift+enter", to: core)
            try await waitUntil("Shift+Enter must send xterm's modified-key form") { Self.transcript(at: outputPath).contains("^[[27;2;13~") }

            let output = Self.transcript(at: outputPath)
            #expect(Self.occurrences(of: "^M", in: output) == 1, "Shift+Enter must not submit the line: \(output)")
        }

        @Test func arrowsFollowApplicationCursorKeyMode() async throws {
            let (core, outputPath) = try await startEchoSession(programEnables: "\\033[?1h")
            defer { terminate(core) }

            sendKey("up", to: core)
            try await waitUntil("DECCKM must switch the arrow to its SS3 form") { Self.transcript(at: outputPath).contains("^[OA") }
        }

        /// The Mac line-editing chords are fixed byte sequences on purpose, so they must not start varying
        /// with terminal mode the way encoded key presses do.
        @Test func macLineEditingChordsKeepTheirReadlineBytes() async throws {
            let (core, outputPath) = try await startEchoSession(programEnables: "\\033[>1u")
            defer { terminate(core) }

            sendKey("cmd+left", to: core)
            try await waitUntil("cmd+left must stay ctrl+a") { Self.transcript(at: outputPath).contains("^A") }

            sendKey("opt+backspace", to: core)
            try await waitUntil("opt+backspace must stay ctrl+w") { Self.transcript(at: outputPath).contains("^W") }

            sendKey("opt+left", to: core)
            try await waitUntil("opt+left must stay meta-b") { Self.transcript(at: outputPath).contains("^[b") }
        }
    }
#endif
