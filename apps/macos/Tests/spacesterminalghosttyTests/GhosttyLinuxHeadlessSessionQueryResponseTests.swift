#if os(Linux)
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Verifies the Linux headless core answers the questions a running program asks its terminal.
    /// Full-screen programs, shells, and coding agents all probe the terminal at startup — cursor
    /// position (DSR), mode support (DECRQM), colors, version — and block or misconfigure themselves
    /// when nothing answers. The daemon has no on-screen terminal to answer for it, so the vt session's
    /// replies are written back to the PTY.
    ///
    /// The child turns off echo and canonical input, emits the queries, and then `cat`s whatever it
    /// receives on stdin back to stdout, so a reply that reaches the PTY lands in the transcript where
    /// the test can see it. `min 1 time 0` keeps the non-canonical read blocking, otherwise `cat` would
    /// read zero bytes and exit before any reply arrives.
    ///
    /// Swift Testing and a nonisolated body for the same reasons as
    /// `GhosttyLinuxHeadlessSessionMetadataTests`; `.serialized` because each test mutates the
    /// process-wide SPACES_* environment and owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionQueryResponseTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference back out to the nonisolated test body; the value is only
        /// ever *used* on the engine actor via a later bridge.
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

        private func makeTemporaryPaths() throws -> TerminalSessionPaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            return paths
        }

        /// A configuration whose shell emits `queries` and then echoes everything the terminal sends
        /// back, so the reply bytes reach the transcript.
        private func makeConfiguration(named name: String, queries: String) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: "\(name)-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "query-title",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                command: "stty -echo -icanon min 1 time 0; printf '\(queries)'; cat", createdAt: "2026-07-26T00:00:00Z",
                workspaceID: "workspace-queries", kind: .shell)
        }

        private func startCore(_ configuration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) async throws -> Box<
            GhosttyEmbeddedSessionCore
        > {
            try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                return Box(core)
            }
        }

        /// The transcript holds both the child's own output and everything it echoed back, so a reply
        /// the core wrote to the PTY shows up here.
        private func waitForTranscript(_ path: String, toContain expected: String, timeout: TimeInterval = 30) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            func transcript() -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
            while Date() < deadline {
                if transcript().contains(expected) { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            Issue.record("transcript never carried the expected reply: \(expected.debugDescription)")
        }

        /// A cursor-position report (CSI 6n) is the query a program is most likely to block on, and the
        /// answer has to describe this session's grid: nothing has been printed, so the cursor is at the
        /// home position.
        @Test func cursorPositionQueryIsAnswered() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let core = try await startCore(makeConfiguration(named: "query-dsr", queries: "\\033[6n"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitForTranscript(paths.outputPath, toContain: "\u{1B}[1;1R")
        }

        /// A mode query (DECRQM) must come back as a mode report rather than silence, which is how
        /// programs decide whether to use synchronized output.
        @Test func modeQueryIsAnswered() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let core = try await startCore(makeConfiguration(named: "query-decrqm", queries: "\\033[?2026$p"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitForTranscript(paths.outputPath, toContain: "\u{1B}[?2026;")
            let transcript = try #require(try? String(contentsOfFile: paths.outputPath, encoding: .utf8))
            #expect(transcript.contains("$y"), "a DECRQM query must be answered with a DECRPM report")
        }

        /// Several queries in one write are answered in the order the program asked them, so a program
        /// reading its replies in sequence does not mismatch them.
        @Test func multipleQueriesInOneWriteAreAnsweredInOrder() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let core = try await startCore(makeConfiguration(named: "query-order", queries: "\\033[6n\\033[?2026$p"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitForTranscript(paths.outputPath, toContain: "$y")
            let transcript = try #require(try? String(contentsOfFile: paths.outputPath, encoding: .utf8))
            let cursorReply = try #require(transcript.range(of: "\u{1B}[1;1R"))
            let modeReply = try #require(transcript.range(of: "\u{1B}[?2026;"))
            #expect(cursorReply.lowerBound < modeReply.lowerBound, "replies must reach the program in the order it asked")
        }
    }
#endif
