#if os(Linux)
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Guards the split error domains of the Linux headless core's `appendTranscript`: a durable write
    /// that succeeds must report success even when the follow-on head-truncation (`TerminalTranscriptTrim`)
    /// throws. The trim is failure-safe with no post-commit failure path — on any throw the just-appended
    /// bytes are already durable in `output.log` and the append handle is untouched — so a trim failure
    /// must not be surfaced as an append failure. `clearScreen` keys the live-renderer application (and its
    /// ok/failure response) off the append's return value, so a conflated failure would durably persist the
    /// clear bytes while skipping the live clear, diverging live state from a future replay.
    ///
    /// The trim only fires once the transcript exceeds `liveTranscriptTrimTriggerBytes`, so these tests
    /// pre-fill `output.log` past that trigger and resume the core through the real handoff path (which
    /// preserves the existing bytes and seeds the byte count from the file size). The trim is then made to
    /// fail without disturbing the append by pre-creating a DIRECTORY at the sibling `output.log.trim` temp
    /// path: `TerminalTranscriptTrim` opens that path for writing to stage preamble+tail, which fails with
    /// `EISDIR` (a directory can never be opened for writing, even by root — so this is robust in the
    /// root-owned Linux CI container, unlike a permission-bit block that `DAC_OVERRIDE` bypasses), while the
    /// already-open `output.log` append fd is untouched.
    ///
    /// Swift Testing (not XCTest) on purpose: the swift-testing runner executes tests from an async main, so
    /// `@MainActor` async tests make progress on Linux, where an async `@MainActor` XCTest deadlocks before
    /// its first line. `.serialized` because each test mutates the process-wide SPACES_* environment and owns
    /// a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionTranscriptTrimTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

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

            var childPID: pid_t = 0
            let path = "/bin/sh"
            let arguments = [path, "-c", "sleep 120"]
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { for argument in argv where argument != nil { free(argument) } }
            #expect(posix_spawn(&childPID, path, nil, nil, &argv, environ) == 0, "posix_spawn of the liveness child failed")

            return AdoptablePTY(master: master, slave: slave, childPID: childPID)
        }

        private func tearDown(_ pty: AdoptablePTY) {
            close(pty.slave)
            kill(pty.childPID, SIGKILL)
            var status: Int32 = 0
            waitpid(pty.childPID, &status, WNOHANG)
        }

        // MARK: - Helpers

        @MainActor private func waitUntil(
            timeout: TimeInterval = 30, _ comment: Comment, condition: @MainActor () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            #expect(condition(), comment)
        }

        /// Attaches a remote-viewer owner so the core includes screen state in exported payloads (the state
        /// policy gates screen frames on an attached local/remote owner).
        @MainActor private func attachRemoteOwner(to core: GhosttyEmbeddedSessionCore, id: String) throws {
            let client = TerminalClient(
                id: id, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
                connectedAt: "2026-07-20T00:00:00Z")
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            #expect(response.ok, "attaching a remote owner must succeed: \(response.message)")
        }

        /// Reconstructs the visible screen text from a self-contained full-frame export.
        @MainActor private func renderedScreenText(of core: GhosttyEmbeddedSessionCore) -> String? {
            guard let snapshot = core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot else { return nil }
            return Self.screenText(of: snapshot)
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

        /// A trim failure AFTER a successful clear-mutation write must not fail the append: `clearScreen`
        /// must still report success, apply the clear to the live renderer, and leave the durable mutation
        /// bytes at the tail of `output.log`. Pre-fix (one conflated do/catch) the trim throw returned false,
        /// so `clearScreen` returned ok:false and never touched the live renderer even though the clear bytes
        /// were already durable — diverging live state from a future replay.
        @Test @MainActor func clearScreenSucceedsWhenTrimFailsAfterDurableWrite() async throws {
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
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            defer {
                tearDown(pty)
                core.terminate()
            }
            let record = DaemonHandoffSessionRecord(
                sessionID: configuration.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: 80, rows: 24, ownerEpoch: 0,
                screenStateRevision: 0, appearance: ThemeAppearance.dark.rawValue)
            try await core.resumeFromHandoff(record)
            try attachRemoteOwner(to: core, id: "remote-owner")

            // The replayed transcript renders the marker onto the live screen before the clear.
            try await waitUntil("the pre-filled marker must render before the clear") { self.renderedScreenText(of: core)?.contains(marker) == true }

            // Make the trim fail without disturbing the append: pre-create a directory at the sibling
            // output.log.trim temp path so the trim's open-for-writing throws EISDIR (unblockable even by
            // root), while the already-open output.log append fd keeps writing.
            let trimBlockerPath = paths.outputPath + ".trim"
            try FileManager.default.createDirectory(atPath: trimBlockerPath, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: trimBlockerPath) }

            let response = core.handleControlRequest(TerminalControlRequest(command: "clearScreen"))

            // The append succeeded (bytes durable) even though the trim threw, so clearScreen reports success
            // and applied the clear to the live renderer.
            #expect(response.ok, "clearScreen must report success when only the post-write trim failed: \(response.message)")
            let screen = try #require(renderedScreenText(of: core))
            #expect(!screen.contains(marker), "the live renderer must apply the clear, dropping the marker from the visible screen")

            // The clear mutation bytes are durably persisted at the tail of output.log — the trim never
            // rewrites the file, so the durable write is intact.
            let persisted = try Data(contentsOf: URL(fileURLWithPath: paths.outputPath))
            let mutation = GhosttyTerminalTranscriptMutation.clearScreenAndScrollback
            #expect(persisted.suffix(mutation.count) == mutation, "the clear mutation bytes must be durably appended to output.log")
        }
    }
#endif
