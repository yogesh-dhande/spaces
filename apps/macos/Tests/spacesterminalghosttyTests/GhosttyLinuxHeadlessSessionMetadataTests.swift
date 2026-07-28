#if os(Linux)
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Verifies the Linux headless core tracks the LIVE terminal metadata a running program reports —
    /// the title from OSC 0/2 and the working directory from OSC 7 — instead of echoing the
    /// launch-time values for the life of the session. The values must reach both the exported state
    /// payload (what subscribers receive) and the durable runtime-state row (what the overview reads),
    /// and they must survive the vt-session rebuild a daemon handoff performs.
    ///
    /// These drive real escape sequences through a real PTY child, so they exercise the whole path:
    /// PTY output -> vt session -> shim getters -> OSC 7 decode -> runtime state.
    ///
    /// The headless core runs on `TerminalEngineActor`, so the test body stays nonisolated and hops
    /// onto the engine for every core call: cores are created inside a `TerminalEngineActor.run`
    /// block, carried back out through a `Box`, and used only via `runSynchronously`/`run` bridges.
    ///
    /// Swift Testing (not XCTest) on purpose: the swift-testing runner executes tests from an async
    /// main, so async tests actually make progress on Linux. Under corelibs-xctest an async test
    /// deadlocks before its first line regardless of isolation — the test job is queued to run while
    /// XCTest's blocked main thread polls in a loop that never drains it. Test bodies stay nonisolated
    /// (not `@MainActor`) because the headless core is isolated to `TerminalEngineActor`, a distinct
    /// global actor from `MainActor`: a nonisolated body can legally bridge onto the engine with the
    /// synchronous `TerminalEngineActor.runSynchronously`, whereas the one-way rule forbids calling
    /// that bridge from the main actor. `.serialized` because each test mutates the process-wide
    /// SPACES_* environment and owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionMetadataTests {
        private static let launchTitle = "launch-title"

        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference (created inside a `TerminalEngineActor.run` block) back out
        /// to the nonisolated test body; the value is only ever *used* on the engine actor via a later bridge.
        private final class Box<Value>: @unchecked Sendable {
            let value: Value
            init(_ value: Value) { self.value = value }
        }

        /// Counts one session's postings of a terminal notification. The core posts from the engine
        /// actor's thread while the test body reads from its own, so the count is lock-guarded.
        private final class NotificationCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var observed = 0
            private var token: (any NSObjectProtocol)?

            init(_ name: Notification.Name, sessionID: String) {
                token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                    guard TerminalSessionNotification.sessionID(from: notification) == sessionID, let self else { return }
                    self.lock.lock()
                    self.observed += 1
                    self.lock.unlock()
                }
            }

            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return observed
            }

            func stop() {
                guard let token else { return }
                NotificationCenter.default.removeObserver(token)
                self.token = nil
            }
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

        // MARK: - Nonisolated helpers

        private func makeTemporaryPaths() throws -> TerminalSessionPaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            return paths
        }

        private func makeConfiguration(sessionID: String, command: String) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: Self.launchTitle,
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command, createdAt: "2026-07-26T00:00:00Z",
                workspaceID: "workspace-metadata", kind: .shell)
        }

        /// A configuration whose shell emits `script` and then blocks on `cat`, so the session stays
        /// live while the test polls. Terminal echo is off so only the escape sequences the script
        /// prints reach the vt session.
        private func makeConfiguration(named name: String, script: String) -> TerminalSessionLaunchConfiguration {
            makeConfiguration(sessionID: "\(name)-\(UUID().uuidString)", command: "stty -echo; \(script); cat")
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

        /// Nonisolated poller so its `Task.sleep` suspensions don't hold the engine's queue while the
        /// engine runs the queued `handleOutput` tasks the condition is waiting on. Each poll hops onto
        /// the engine synchronously to evaluate the (engine-isolated) condition.
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

        // MARK: - Engine-isolated helpers (call from inside a run/runSynchronously bridge)

        /// The state payload a subscriber receives, built by the same `makeStatePayload` the broadcast
        /// path uses.
        @TerminalEngineActor private static func payload(of core: GhosttyEmbeddedSessionCore) -> GhosttyRemoteSessionStatePayload? {
            core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.stateChange)
        }

        // MARK: - Tests

        /// A program that sets its window title with OSC 2 replaces the launch-time title everywhere a
        /// session's identity is read: the payload, the payload's embedded runtime state, and the
        /// durable runtime-state row. The change is also announced as a session-metadata change, which
        /// is what makes it a *displayed* title — the output-shaped broadcast reasons deliberately do
        /// not re-derive pane and tab titles on a mirroring client.
        @Test func titleFromOSC2ReachesThePayloadAndTheDurableRuntimeState() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let configuration = makeConfiguration(named: "metadata-title", script: "printf '\\033]2;live title\\007'")
            let metadataChanges = NotificationCounter(.spacesTerminalSessionMetadataDidChange, sessionID: configuration.sessionID)
            defer { metadataChanges.stop() }

            let core = try await startCore(configuration, paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitAsync { Self.payload(of: core)?.title == "live title" }
            let payload = try #require(TerminalEngineActor.runSynchronously { Self.payload(of: core) })
            #expect(payload.runtimeState?.title == "live title")
            try await waitAsync { (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.title == "live title" }
            #expect(metadataChanges.count >= 1, "a live title change must be announced as a session-metadata change")
        }

        /// OSC 7 carries a URI, and libghostty-vt stores it unparsed, so the reported working directory
        /// must be the decoded absolute path — not the raw `file://…` payload.
        @Test func workingDirectoryFromOSC7DecodesToAnAbsolutePath() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            // `%%` is the printf escape for a literal `%`, so the shell emits the percent-encoded space
            // the decode has to unescape.
            let coreBox = try await startCore(
                makeConfiguration(named: "metadata-cwd", script: "printf '\\033]7;file://localhost/srv/work/my%%20repo\\007'"), paths: paths)
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitAsync { Self.payload(of: core)?.workingDirectory == "/srv/work/my repo" }
            let payload = try #require(TerminalEngineActor.runSynchronously { Self.payload(of: core) })
            #expect(payload.runtimeState?.workingDirectory == "/srv/work/my repo")
        }

        /// Clearing the title returns the session to its launch-configuration title rather than
        /// leaving the stale one in place. Both clear spellings are pinned because they surface
        /// differently at the VT layer: a whitespace-only payload reads back as a present title that
        /// normalizes to blank, while an empty payload reads back as absent (the same reading a
        /// never-set title produces, which is why clearing on absence requires the vt session to have
        /// reported the title first). The macOS host treats both as cleared.
        @Test func clearedTitleFallsBackToTheLaunchConfiguration() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let coreBox = try await startCore(
                makeConfiguration(
                    named: "metadata-cleared",
                    script: "printf '\\033]2;temporary\\007'; sleep 1; printf '\\033]2;   \\007'; sleep 1;"
                        + " printf '\\033]2;again\\007'; sleep 1; printf '\\033]2;\\007'"), paths: paths)
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitAsync { Self.payload(of: core)?.title == "temporary" }
            try await waitAsync { Self.payload(of: core)?.title == Self.launchTitle }
            try await waitAsync { Self.payload(of: core)?.title == "again" }
            try await waitAsync { Self.payload(of: core)?.title == Self.launchTitle }
        }

        /// OSC 7 can be sent by anything on the far end of an SSH session, so a payload naming another
        /// host — or one that is not a URI at all — is ignored and the launch-configuration working
        /// directory stands.
        @Test func unusableOSC7PayloadsAreIgnored() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let configuration = makeConfiguration(
                named: "metadata-hostile",
                script: "printf '\\033]7;file://elsewhere.example.com/srv/elsewhere\\007'; printf '\\033]7;not-a-uri\\007'; printf 'SETTLED\\n'")
            let metadataChanges = NotificationCounter(.spacesTerminalSessionMetadataDidChange, sessionID: configuration.sessionID)
            defer { metadataChanges.stop() }
            let core = try await startCore(configuration, paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            // Wait for output the core has definitely consumed before asserting the absence of a change,
            // so the assertion cannot pass simply because nothing has arrived yet. The transcript append
            // and the metadata refresh happen in the same `handleOutput` turn, and this poll evaluates on
            // the engine, so a visible transcript means the refresh for those bytes has already run.
            try await waitAsync { (try? String(contentsOfFile: paths.outputPath, encoding: .utf8))?.contains("SETTLED") == true }
            let payload = try #require(TerminalEngineActor.runSynchronously { Self.payload(of: core) })
            #expect(payload.workingDirectory == configuration.workingDirectory)
            #expect(payload.runtimeState?.workingDirectory == configuration.workingDirectory)
            #expect(metadataChanges.count == 0, "an ignored OSC 7 payload must not announce a metadata change")
        }

        /// A rejected OSC 7 must not disturb a directory an earlier valid OSC 7 established. This is
        /// the everyday SSH shape: the local shell reports a valid directory, then the remote shell on
        /// the far end emits OSC 7 naming its own host — the VT layer overwrites its stored payload
        /// with the foreign one, so the core has to keep the last accepted decode rather than re-derive
        /// from the (now unusable) stored value.
        @Test func rejectedOSC7PreservesThePreviouslyReportedDirectory() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            // The sleep separates the two reports into distinct output turns, so the valid one is
            // observed (and cached) before the foreign one replaces it in the vt session.
            let coreBox = try await startCore(
                makeConfiguration(
                    named: "metadata-ssh",
                    script: "printf '\\033]7;file://localhost/srv/local\\007'; sleep 1; printf '\\033]7;file://far-end.example.com/srv/remote\\007'; printf 'SETTLED\\n'"
                ), paths: paths)
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitAsync { Self.payload(of: core)?.workingDirectory == "/srv/local" }
            try await waitAsync { (try? String(contentsOfFile: paths.outputPath, encoding: .utf8))?.contains("SETTLED") == true }
            let payload = try #require(TerminalEngineActor.runSynchronously { Self.payload(of: core) })
            #expect(payload.workingDirectory == "/srv/local")
            #expect(payload.runtimeState?.workingDirectory == "/srv/local")
        }

        /// A daemon handoff builds a fresh core and a fresh vt session, and a trimmed transcript's state
        /// preamble deliberately restores no title — so the resumed session must recover the title from
        /// the runtime-state row the pre-exec image wrote, not fall back to the launch title.
        @Test func titleSurvivesHandoffWhenTheTranscriptNoLongerCarriesTheEscapeSequence() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let configuration = makeConfiguration(named: "metadata-handoff", script: "printf '\\033]2;handed off\\007'")
            let core = try await startCore(configuration, paths: paths).value
            try await waitAsync { (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.title == "handed off" }

            guard let record = try await core.quiesceForHandoff() else {
                Issue.record("quiesce produced no handoff record for a live session")
                return
            }
            TerminalEngineActor.runSynchronously { core.terminate() }

            // Stand in for a trimmed transcript: the bytes that survive the trim no longer contain the
            // OSC 2 sequence, so replay alone cannot recover the title.
            try Data("TRIMMED\r\n".utf8).write(to: URL(fileURLWithPath: paths.outputPath))

            let pty = try makeAdoptablePTY()
            let resumedCoreBox = await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            let resumedCore = resumedCoreBox.value
            defer {
                // Close the slave FIRST so the adopted master's blocked read hits EOF, then terminate:
                // closing a PTY master out from under a still-blocked read hangs.
                tearDown(pty)
                TerminalEngineActor.runSynchronously { resumedCore.terminate() }
            }
            try await resumedCore.resumeFromHandoff(
                DaemonHandoffSessionRecord(
                    sessionID: record.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: record.columns, rows: record.rows,
                    ownerEpoch: record.ownerEpoch, screenStateRevision: record.screenStateRevision, appearance: record.appearance))

            let payload = try #require(TerminalEngineActor.runSynchronously { Self.payload(of: resumedCore) })
            #expect(payload.title == "handed off")
            #expect(payload.runtimeState?.title == "handed off")

            // The rebuilt vt session never saw the OSC 2 sequence, so it reports the title as absent.
            // New live output must not read that absence as "the program cleared the title" and erase
            // the recovered value — clearing requires a present→absent transition the vt session
            // actually observed.
            let liveBytes = Array("fresh output after handoff\r\n".utf8)
            #expect(liveBytes.withUnsafeBufferPointer { write(pty.slave, $0.baseAddress, $0.count) } == liveBytes.count)
            try await waitAsync {
                (try? String(contentsOfFile: paths.outputPath, encoding: .utf8))?.contains("fresh output after handoff") == true
            }
            let refreshed = try #require(TerminalEngineActor.runSynchronously { Self.payload(of: resumedCore) })
            #expect(refreshed.title == "handed off")
            #expect(refreshed.runtimeState?.title == "handed off")
        }

        // MARK: - Handoff fixtures

        /// A test-owned PTY plus a live child pid, standing in for the master fd and child that survive
        /// `execv` for the resuming core to adopt. The child is a bare `sleep` (spawned with
        /// `posix_spawn` so only the session driver ever reaps it) that keeps the resumed session's
        /// liveness checks satisfied.
        private struct AdoptablePTY {
            let master: Int32
            let slave: Int32
            let childPID: Int32
        }

        private func makeAdoptablePTY() throws -> AdoptablePTY {
            var master: Int32 = 0
            var slave: Int32 = 0
            #expect(openpty(&master, &slave, nil, nil, nil) == 0, "openpty failed")

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
    }
#endif
