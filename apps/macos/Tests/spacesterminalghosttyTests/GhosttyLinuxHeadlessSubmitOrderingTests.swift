#if os(Linux)
    import Foundation
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Linux mirror of `GhosttyEmbeddedSubmitOrderingTests`: two submit-style sends enqueued
    /// back-to-back must reach the child as two separately submitted lines, never as one merged line
    /// with a stray Enter (the daemon's notification flush delivers queued lines like this). Each
    /// submit is a paste-encoded text write followed by its carriage return — immediate when the
    /// receiver enabled bracketed paste, separated when (as with `cat` here) it did not, in which
    /// case the text also reaches the PTY verbatim.
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
            timeout: TimeInterval = 30, transcriptPath: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
            _ condition: @escaping @TerminalEngineActor () -> Bool
        ) async throws {
            let started = Date()
            let deadline = started.addingTimeInterval(timeout)
            while Date() < deadline {
                if TerminalEngineActor.runSynchronously({ condition() }) { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            await GhosttyLinuxHeadlessHangDiagnostics.report(
                wait: "waitAsync at \(sourceLocation)", elapsed: Date().timeIntervalSince(started), timeout: timeout, transcriptPath: transcriptPath)
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
            try await waitAsync(transcriptPath: outputPath) {
                ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY")
            }

            let firstMarker = "SUBMIT_ORDER_FIRST"
            let secondMarker = "SUBMIT_ORDER_SECOND"
            // Handled from here, off the engine: a send waits for its writes to reach the PTY, and that
            // wait must not be held on the engine those writes run on.
            let firstResponse = core.handleControlRequest(TerminalControlRequest(command: "send", text: firstMarker, appendNewline: true))
            #expect(firstResponse.ok, "\(firstResponse.message)")
            let secondResponse = core.handleControlRequest(TerminalControlRequest(command: "send", text: secondMarker, appendNewline: true))
            #expect(secondResponse.ok, "\(secondResponse.message)")

            // Each marker appears once as the PTY echo of the typed line and once as `cat`'s output of the
            // submitted line, so two occurrences of the second marker means both Enters landed.
            try await waitAsync(transcriptPath: outputPath) {
                Self.occurrences(of: secondMarker, in: (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "") >= 2
            }

            let output = transcript()
            #expect(
                !output.contains(firstMarker + secondMarker),
                "the second submit's text was written before the first submit's carriage return, merging both commands: \(output)")
            #expect(Self.occurrences(of: firstMarker, in: output) >= 2, "the first submit must be echoed and submitted on its own line")
        }

        private func startSubmitCore(command: String, paths: TerminalSessionPaths) async throws -> GhosttyEmbeddedSessionCore {
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(
                    launchConfiguration: TerminalSessionLaunchConfiguration(
                        sessionID: "submit-framing-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                        workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command,
                        createdAt: "2026-07-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
                try core.startIfNeeded()
                return Box(core)
            }
            return coreBox.value
        }

        /// Linux mirror of the embedded unframed-receiver test: `cat` never enables bracketed paste, so
        /// the submit's CR must be temporally separated from its unframed text (issue #187) — in canonical
        /// mode the line discipline delivers the line to `cat` only when the CR lands, so "cat produced
        /// the line" is exactly "the CR arrived".
        @Test func submitToUnframedReceiverSeparatesItsCarriageReturn() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = TerminalSessionPaths(rootDirectory: root.path)

            let core = try await startSubmitCore(command: "echo SUBMIT_READY; cat", paths: paths)
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            let outputPath = paths.outputPath
            try await waitAsync { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

            let marker = "SUBMIT_UNFRAMED_MARKER"
            let sentAt = ContinuousClock.now
            let response = core.handleControlRequest(TerminalControlRequest(command: "send", text: marker, appendNewline: true))
            #expect(response.ok, "\(response.message)")
            // The send answers only once its bytes reached the PTY, so the round trip itself measures the
            // separation: an immediate CR would return in milliseconds.
            #expect(
                sentAt.duration(to: .now) >= .milliseconds(450),
                "an unframed submit's CR landed immediately instead of waiting out the separation")

            try await waitAsync { Self.occurrences(of: marker, in: (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "") >= 2 }
        }

        /// Linux mirror of the embedded framed-receiver test: the child enables DECSET 2004 before
        /// signaling readiness, so the submit goes out framed and its CR follows immediately with no
        /// pacing cost (issue #389). The frame's open marker in the transcript proves the framed
        /// encoding; the line completing well inside the 500ms separation proves the CR was not delayed.
        @Test func submitToBracketedPasteReceiverSubmitsImmediately() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = TerminalSessionPaths(rootDirectory: root.path)

            let core = try await startSubmitCore(command: "printf '\\033[?2004h'; echo SUBMIT_READY; cat", paths: paths)
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            let outputPath = paths.outputPath
            try await waitAsync { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

            let marker = "SUBMIT_FRAMED_MARKER"
            let sentAt = ContinuousClock.now
            let response = core.handleControlRequest(TerminalControlRequest(command: "send", text: marker, appendNewline: true))
            #expect(response.ok, "\(response.message)")

            try await waitAsync { Self.occurrences(of: marker, in: (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "") >= 2 }
            let elapsed = sentAt.duration(to: .now)
            #expect(elapsed < .milliseconds(400), "a framed submit's CR must follow immediately, not after the unframed separation")
            #expect(
                ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("\u{1b}[200~"),
                "the receiver enabled bracketed paste, so the submit's text must have gone out framed")
        }

        /// Linux mirror of the embedded teardown test: a send answers for its bytes, not for its enqueue,
        /// so a session torn down while the submit still had a write outstanding must report failure. This
        /// is what keeps an automation from recording a seed prompt as delivered that no agent received.
        /// `cat` leaves bracketed paste off, so the CR is still waiting out its separation when the session
        /// goes away.
        @Test func submitWhoseSessionIsTornDownBeforeItsCarriageReturnReportsFailure() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = TerminalSessionPaths(rootDirectory: root.path)

            let core = try await startSubmitCore(command: "echo SUBMIT_READY; cat", paths: paths)
            let coreBox = Box(core)
            defer { TerminalEngineActor.runSynchronously { coreBox.value.terminate() } }
            let outputPath = paths.outputPath
            try await waitAsync { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

            let teardown = Task.detached {
                try? await Task.sleep(for: .milliseconds(150))
                TerminalEngineActor.runSynchronously { coreBox.value.terminate() }
            }
            let response = core.handleControlRequest(TerminalControlRequest(command: "send", text: "SUBMIT_TORN_DOWN", appendNewline: true))
            await teardown.value

            #expect(!response.ok, "a submit whose carriage return never reached the PTY must not report success")
            #expect(response.errorCode == .sessionNotRunning)
        }

        /// A bare Enter is a submit too, written as one write rather than the text-then-CR split, so it is
        /// the path that can most easily answer for its enqueue instead of its bytes. Sent into a session
        /// that is already torn down, its write has nowhere to go: the send must fail rather than report a
        /// keystroke that landed nowhere.
        @Test func bareEnterWhoseWriteNeverReachesThePTYReportsFailure() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = TerminalSessionPaths(rootDirectory: root.path)

            let core = try await startSubmitCore(command: "printf '\\033[?2004h'; echo SUBMIT_READY; sleep 30", paths: paths)
            let coreBox = Box(core)
            defer { TerminalEngineActor.runSynchronously { coreBox.value.terminate() } }
            let outputPath = paths.outputPath
            try await waitAsync { ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains("SUBMIT_READY") }

            TerminalEngineActor.runSynchronously { coreBox.value.terminate() }
            let response = await Task.detached {
                coreBox.value.handleControlRequest(TerminalControlRequest(command: "send", text: "", appendNewline: true))
            }.value

            #expect(!response.ok, "a bare Enter whose bytes never reached the PTY must not report success")
            #expect(response.errorCode == .sessionNotRunning)
            // The message pins the failure to the send's own write acknowledgement rather than to any
            // earlier guard that also reports a session as not running.
            #expect(response.message == "Terminal session stopped accepting input before the send reached it.")
        }
    }
#endif
