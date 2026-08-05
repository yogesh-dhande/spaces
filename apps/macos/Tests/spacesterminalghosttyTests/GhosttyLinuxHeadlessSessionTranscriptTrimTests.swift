#if os(Linux)
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Guards the split error domains of the Linux headless core's `appendTranscript`: a durable write that
    /// succeeds must report success no matter what happens to the follow-on head-truncation. The trim runs
    /// off the engine actor and never touches `output.log` until its atomic swap
    /// (`TerminalTranscriptTrimCoordinator`), so a trim that cannot run leaves the just-appended bytes
    /// durable and the append handle valid. `clearScreen` keys the live-renderer application (and its
    /// ok/failure response) off the append's return value, so conflating the two would durably persist the
    /// clear bytes while skipping the live clear, diverging live state from a future replay.
    ///
    /// The trim only fires once the transcript exceeds `liveTranscriptTrimTriggerBytes`, so these tests
    /// pre-fill `output.log` past that trigger and resume the core through the real handoff path (which
    /// preserves the existing bytes and seeds the byte count from the file size). The trim is then made to
    /// fail without disturbing the append by pre-creating a DIRECTORY at the sibling `output.log.trim` temp
    /// path: the staging stage opens that path for writing to hold preamble+tail, which fails with `EISDIR`
    /// (a directory can never be opened for writing, even by root — so this is robust in the root-owned
    /// Linux CI container, unlike a permission-bit block that `DAC_OVERRIDE` bypasses), while the
    /// already-open `output.log` append fd is untouched.
    ///
    /// The headless core runs on `TerminalEngineActor`, so the test body stays nonisolated and hops onto
    /// the engine for every core call: the core is created inside a `TerminalEngineActor.run` block,
    /// carried back out through a `Box`, and used only via `runSynchronously`/`run` bridges (or a direct
    /// `await` for the core's async handoff methods).
    ///
    /// Swift Testing (not XCTest) on purpose: the swift-testing runner executes tests from an async main,
    /// so async tests actually make progress on Linux. Under corelibs-xctest an async test deadlocks
    /// before its first line regardless of isolation — the test job is queued to run while XCTest's
    /// blocked main thread polls in a loop that never drains it. The test body stays nonisolated (not
    /// `@MainActor`) because the headless core is isolated to `TerminalEngineActor`, a distinct global
    /// actor from `MainActor`: a nonisolated body can legally bridge onto the engine with the synchronous
    /// `TerminalEngineActor.runSynchronously`, whereas the one-way rule forbids calling that bridge from
    /// the main actor. `.serialized` because each test mutates the process-wide SPACES_* environment and
    /// owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionTranscriptTrimTests {
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

        // MARK: - Fixtures

        /// A test-owned PTY plus a live child pid, standing in for the master fd and child that survive
        /// `execv` for the resuming core to adopt. The child is a bare `sleep` (spawned with `posix_spawn` so
        /// only the session driver ever reaps it) that keeps the resumed session's liveness checks satisfied.
        private struct AdoptablePTY {
            let master: Int32
            let slave: Int32
            let childPID: Int32
        }

        private func makeTemporaryPaths() throws -> TerminalSessionPaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            return paths
        }

        private func makeConfiguration(sessionID: String, command: String?) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "trim", workingDirectory: FileManager.default.temporaryDirectory.path,
                shell: "/bin/sh", command: command, createdAt: "2026-07-20T00:00:00Z", workspaceID: "workspace-trim", kind: .shell)
        }

        private func makeAdoptablePTY() throws -> AdoptablePTY {
            var master: Int32 = 0
            var slave: Int32 = 0
            #expect(openpty(&master, &slave, nil, nil, nil) == 0, "openpty failed")
            #expect(master >= 0)
            #expect(slave >= 0)

            // Spawn `/bin/sleep` itself rather than `sh -c "sleep 120"`: `tearDown` kills exactly the pid
            // reported here, and a shell layer would fork the real `sleep` (dash does not exec it), leaving
            // that grandchild running after the shell is killed. Redirect the child's stdio to /dev/null so
            // it never inherits the test runner's stdout/stderr: a surviving child holding SwiftPM's output
            // pipe blocks `swift test` on pipe EOF long after the test binary itself has exited.
            var childPID: pid_t = 0
            let path = "/bin/sleep"
            let arguments = ["sleep", "120"]
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { for argument in argv where argument != nil { free(argument) } }
            var fileActions = posix_spawn_file_actions_t()
            #expect(posix_spawn_file_actions_init(&fileActions) == 0, "posix_spawn_file_actions_init failed")
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            #expect(posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0) == 0, "redirecting child stdin failed")
            #expect(posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0) == 0, "redirecting child stdout failed")
            #expect(posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0) == 0, "redirecting child stderr failed")
            #expect(posix_spawn(&childPID, path, &fileActions, nil, &argv, environ) == 0, "posix_spawn of the liveness child failed")

            return AdoptablePTY(master: master, slave: slave, childPID: childPID)
        }

        private func tearDown(_ pty: AdoptablePTY) {
            close(pty.slave)
            kill(pty.childPID, SIGKILL)
            var status: Int32 = 0
            waitpid(pty.childPID, &status, WNOHANG)
        }

        // MARK: - Nonisolated helpers

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

        // MARK: - Engine-isolated helpers (call from inside a run/runSynchronously bridge)

        /// Attaches a remote-viewer owner so the core includes screen state in exported payloads (the state
        /// policy gates screen frames on an attached local/remote owner).
        @TerminalEngineActor private static func attachRemoteOwner(to core: GhosttyEmbeddedSessionCore, id: String) {
            let client = TerminalClient(
                id: id, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
                connectedAt: "2026-07-20T00:00:00Z")
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            #expect(response.ok, "attaching a remote owner must succeed: \(response.message)")
        }

        /// Reconstructs the visible screen text from a self-contained full-frame export.
        @TerminalEngineActor private static func renderedScreenText(of core: GhosttyEmbeddedSessionCore) -> String? {
            guard let snapshot = core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot else { return nil }
            return screenText(of: snapshot)
        }

        private static func screenText(of snapshot: GhosttyTerminalSnapshot) -> String {
            guard snapshot.columns > 0, snapshot.rows > 0 else { return "" }
            var lines: [String] = []
            for row in 0..<snapshot.rows {
                var line = ""
                for column in 0..<snapshot.columns {
                    let index = row * snapshot.columns + column
                    let codepoint = index < snapshot.cells.count ? snapshot.cells[index].codepoint : 0
                    if codepoint == 0 {
                        line.append(" ")
                    } else if let scalar = Unicode.Scalar(codepoint) {
                        line.append(Character(scalar))
                    } else {
                        line.append(" ")
                    }
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }

        // MARK: - Tests

        /// A trim that cannot run must not fail the clear-mutation append that triggered it: `clearScreen`
        /// must still report success, apply the clear to the live renderer, and leave the durable mutation
        /// bytes at the tail of `output.log`. Pre-fix (one conflated do/catch around the inline trim) the
        /// trim throw returned false, so `clearScreen` returned ok:false and never touched the live renderer
        /// even though the clear bytes were already durable — diverging live state from a future replay.
        @Test func clearScreenSucceedsWhenTrimFailsAfterDurableWrite() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            // Pre-fill output.log past the trim trigger so the next append triggers a trim, ending with a
            // visible marker line the resume replay renders onto the live screen.
            let marker = "TRANSCRIPT_TRIM_MARKER_ZZZ"
            var transcript = Data(repeating: UInt8(ascii: "A"), count: TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes + 1)
            transcript.append(contentsOf: "\n\(marker)\n".utf8)
            try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

            // Resume through the real handoff path so the existing bytes are preserved and the byte count is
            // seeded from the file size (a fresh start would truncate output.log).
            let configuration = makeConfiguration(sessionID: "trim-clear-\(UUID().uuidString)", command: "cat")
            let pty = try makeAdoptablePTY()
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            let core = coreBox.value
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { core.terminate() }
            }
            let record = DaemonHandoffSessionRecord(
                sessionID: configuration.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: 80, rows: 24, ownerEpoch: 0,
                screenStateRevision: 0, appearance: ThemeAppearance.dark.rawValue, transcriptOffsetAtQuiesce: nil)
            try await core.resumeFromHandoff(record)
            try await TerminalEngineActor.run { Self.attachRemoteOwner(to: core, id: "remote-owner") }

            // The replayed transcript renders the marker onto the live screen before the clear.
            try await waitAsync(transcriptPath: paths.outputPath) { Self.renderedScreenText(of: core)?.contains(marker) == true }

            // Make the trim fail without disturbing the append: pre-create a directory at the sibling
            // output.log.trim temp path so the trim's open-for-writing throws EISDIR (unblockable even by
            // root), while the already-open output.log append fd keeps writing.
            let trimBlockerPath = paths.outputPath + ".trim"
            try FileManager.default.createDirectory(atPath: trimBlockerPath, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: trimBlockerPath) }

            let response = TerminalEngineActor.runSynchronously { core.handleControlRequest(TerminalControlRequest(command: "clearScreen")) }

            // The append succeeded (bytes durable) even though the trim could not stage, so clearScreen
            // reports success and applied the clear to the live renderer.
            #expect(response.ok, "clearScreen must report success when only the post-write trim failed: \(response.message)")
            let screen = try #require(TerminalEngineActor.runSynchronously { Self.renderedScreenText(of: core) })
            #expect(!screen.contains(marker), "the live renderer must apply the clear, dropping the marker from the visible screen")

            // The clear mutation bytes are durably persisted at the tail of output.log — the trim never
            // rewrites the file, so the durable write is intact.
            let persisted = try Data(contentsOf: URL(fileURLWithPath: paths.outputPath))
            let mutation = GhosttyTerminalTranscriptMutation.clearScreenAndScrollback
            #expect(persisted.suffix(mutation.count) == mutation, "the clear mutation bytes must be durably appended to output.log")
        }
    }
#endif
