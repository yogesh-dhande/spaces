#if os(Linux)
    import Foundation
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Linux mirror of `GhosttyEmbeddedSubmitOrderingTests`: two submit-style sends enqueued
    /// back-to-back must reach the child as two separately submitted lines, never as one merged line
    /// with a stray Enter (the daemon's notification flush delivers queued lines like this). Each
    /// submit is a paste-encoded text write followed immediately by its carriage return, and the
    /// child leaves bracketed paste off, so the text reaches the PTY verbatim.
    ///
    /// The headless core runs on `TerminalEngineActor`, so the test body stays nonisolated and hops
    /// onto the engine for every core call: the core is created inside a `TerminalEngineActor.run`
    /// block, carried back out through a `Box`, and used only via `runSynchronously`/`run` bridges.
    ///
    /// Swift Testing (not XCTest) on purpose: the swift-testing runner executes tests from an async
    /// main, so async tests actually make progress on Linux. Under corelibs-xctest an async test
    /// deadlocks before its first line regardless of isolation — the test job is queued to run while
    /// XCTest's blocked main thread polls in a loop that never drains it. The test body stays
    /// nonisolated (not `@MainActor`) because the headless core is isolated to `TerminalEngineActor`,
    /// a distinct global actor from `MainActor`: a nonisolated body can legally bridge onto the engine
    /// with the synchronous `TerminalEngineActor.runSynchronously`, whereas the one-way rule forbids
    /// calling that bridge from the main actor. `.serialized` because the test mutates the
    /// process-wide SPACES_* environment and owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSubmitOrderingTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference (created inside a `TerminalEngineActor.run` block) back out
        /// to the nonisolated test body; the value is only ever *used* on the engine actor via a later bridge.
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

        /// Nonisolated poller so its `Task.sleep` suspensions don't hold the engine's queue while the
        /// engine runs the queued `handleOutput` tasks the condition is waiting on. Each poll hops onto
        /// the engine synchronously to evaluate the (engine-isolated) condition. libghostty-vt writes are
        /// synchronous, so unlike the macOS harness no renderer tick is needed here.
        private func waitAsync(
            timeout: TimeInterval = 30, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @escaping @TerminalEngineActor () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if TerminalEngineActor.runSynchronously({ condition() }) { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            #expect(TerminalEngineActor.runSynchronously { condition() }, "waitAsync timed out", sourceLocation: sourceLocation)
        }

        private static func occurrences(of needle: String, in haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }

        @Test func rapidSubmitSendsReachChildAsSeparateSubmissions() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = TerminalSessionPaths(rootDirectory: root.path)

            // `cat` echoes each submitted line back, so the transcript shows exactly how the input was
            // grouped into lines by the PTY line discipline.
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(
                    launchConfiguration: TerminalSessionLaunchConfiguration(
                        sessionID: "submit-ordering-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                        workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "echo SUBMIT_READY; cat",
                        createdAt: "2026-07-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
                try core.startIfNeeded()
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            let outputPath = paths.outputPath
            let transcript = { (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "" }
            try await waitAsync { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

            let firstMarker = "SUBMIT_ORDER_FIRST"
            let secondMarker = "SUBMIT_ORDER_SECOND"
            let firstResponse = TerminalEngineActor.runSynchronously {
                core.handleControlRequest(TerminalControlRequest(command: "send", text: firstMarker, appendNewline: true))
            }
            #expect(firstResponse.ok, "\(firstResponse.message)")
            let secondResponse = TerminalEngineActor.runSynchronously {
                core.handleControlRequest(TerminalControlRequest(command: "send", text: secondMarker, appendNewline: true))
            }
            #expect(secondResponse.ok, "\(secondResponse.message)")

            // Each marker appears once as the PTY echo of the typed line and once as `cat`'s output of the
            // submitted line, so two occurrences of the second marker means both Enters landed.
            try await waitAsync { Self.occurrences(of: secondMarker, in: (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "") >= 2 }

            let output = transcript()
            #expect(
                !output.contains(firstMarker + secondMarker),
                "the second submit's text was written before the first submit's carriage return, merging both commands: \(output)")
            #expect(
                Self.occurrences(of: firstMarker, in: output) >= 2, "the first submit must be echoed and submitted on its own line")
        }
    }
#endif
