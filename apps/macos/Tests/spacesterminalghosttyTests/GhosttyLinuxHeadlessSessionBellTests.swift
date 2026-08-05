#if os(Linux)
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Verifies the Linux headless core records when a running program rang the terminal bell, which is
    /// the only thing a client needs to raise that session's bell alert. The daemon has no on-screen
    /// terminal to ring, so the bell becomes a timestamp on the runtime state, and because that
    /// timestamp is also the alert's dismissal identity it must advance only for a bell the user has not
    /// been told about yet — repeats inside the coalescing window leave it exactly where it was.
    ///
    /// These drive a real BEL through a real PTY child, so they exercise the whole path: PTY output ->
    /// vt session -> shim bell event -> coalescer -> runtime state.
    ///
    /// Swift Testing and a nonisolated body for the same reasons as
    /// `GhosttyLinuxHeadlessSessionMetadataTests`; `.serialized` because each test mutates the
    /// process-wide SPACES_* environment and owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionBellTests {
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

        // MARK: - Nonisolated helpers

        private func makeTemporaryPaths() throws -> TerminalSessionPaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            return paths
        }

        /// A configuration whose shell emits `script` and then blocks on `cat`, so the session stays live
        /// while the test polls. Terminal echo is off so only the bytes the script prints reach the vt
        /// session.
        private func makeConfiguration(named name: String, script: String) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: "\(name)-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "bell-title",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "stty -echo; \(script); cat",
                createdAt: "2026-07-26T00:00:00Z", workspaceID: "workspace-bell", kind: .shell)
        }

        /// `quietWindow` is set before the child can produce any output, so a test that needs the window
        /// to reopen does not have to sleep through the real 30 seconds.
        private func startCore(_ configuration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths, quietWindow: TimeInterval? = nil)
            async throws -> Box<GhosttyEmbeddedSessionCore>
        {
            try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                if let quietWindow { core.bellCoalescer.quietWindow = quietWindow }
                try core.startIfNeeded()
                return Box(core)
            }
        }

        /// Nonisolated poller so its `Task.sleep` suspensions don't hold the engine's queue while the
        /// engine runs the queued `handleOutput` tasks the condition is waiting on.
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

        /// Waits for output the core has definitely consumed, so an assertion about what the core did
        /// (or deliberately did not do) with those bytes cannot pass simply because nothing arrived yet.
        /// The transcript append and the bell fold happen in the same `handleOutput` turn.
        private func waitForSettledTranscript(_ path: String, timeout: TimeInterval = 30) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            func transcript() -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
            while Date() < deadline {
                if transcript().contains("SETTLED") { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            Issue.record("the child never produced its settle marker")
        }

        // MARK: - Engine-isolated helpers (call from inside a run/runSynchronously bridge)

        @TerminalEngineActor private static func bellAt(of core: GhosttyEmbeddedSessionCore) -> String? {
            core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.stateChange)?.runtimeState?.bellAt
        }

        // MARK: - Tests

        /// A bell reaches both surfaces a client can read it from: the state payload a subscriber
        /// receives and the durable runtime-state row the device overview builds its alerts from.
        @Test func bellReachesThePayloadAndTheDurableRuntimeState() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let core = try await startCore(makeConfiguration(named: "bell-rings", script: "printf '\\007'"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitAsync { Self.bellAt(of: core) != nil }
            try await waitAsync { (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.bellAt != nil }
        }

        /// A session that never rings reports no bell, so a client derives no alert for it. Asserted
        /// against output the core has already consumed, not against an empty session.
        @Test func aSessionThatNeverRingsReportsNoBell() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let core = try await startCore(makeConfiguration(named: "bell-silent", script: "printf 'SETTLED\\n'"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitForSettledTranscript(paths.outputPath)
            #expect(TerminalEngineActor.runSynchronously { Self.bellAt(of: core) } == nil)
        }

        /// The product behavior the coalescing window exists for: a program that rings repeatedly is one
        /// thing the user needs to know about. The timestamp IS the alert's identity, so it must not move
        /// for the repeats — a moving value would re-raise an alert the user had already dismissed.
        @Test func repeatedBellsInsideTheWindowLeaveTheTimestampAlone() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            // Separate output turns on purpose: bells inside one write would collapse into a single ring
            // regardless of the window, which would prove nothing about the coalescer.
            let core = try await startCore(
                makeConfiguration(
                    named: "bell-burst", script: "printf '\\007'; sleep 1; printf '\\007'; sleep 1; printf '\\007'; sleep 1; printf 'SETTLED\\n'"),
                paths: paths
            ).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitAsync { Self.bellAt(of: core) != nil }
            let firstBellAt = try #require(TerminalEngineActor.runSynchronously { Self.bellAt(of: core) })
            try await waitForSettledTranscript(paths.outputPath)
            #expect(TerminalEngineActor.runSynchronously { Self.bellAt(of: core) } == firstBellAt)
        }

        /// Once the window has passed, a genuinely new bell is a new thing to know about, so the
        /// timestamp advances and the alert returns even for a session whose earlier bell was dismissed.
        @Test func aBellAfterTheWindowAdvancesTheTimestamp() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let core = try await startCore(
                makeConfiguration(named: "bell-reopen", script: "printf '\\007'; sleep 1; printf '\\007'"), paths: paths, quietWindow: 0.2
            ).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            try await waitAsync { Self.bellAt(of: core) != nil }
            let firstBellAt = try #require(TerminalEngineActor.runSynchronously { Self.bellAt(of: core) })
            try await waitAsync { Self.bellAt(of: core) != firstBellAt }
        }

        // MARK: - Handoff

        /// A daemon update rebuilds the session around a fresh core and a fresh coalescer while the
        /// clients keep showing the alert the pre-exec image raised. The resumed session republishes that
        /// exact timestamp, and a bell arriving inside the window it was raised in is absorbed into it —
        /// a second identity here would be a second, undismissable alert for the same bell.
        @Test func aBellSoonAfterAHandoffIsAbsorbedIntoTheAlertTheUserAlreadyHas() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let configuration = makeConfiguration(named: "bell-handoff-absorb", script: "printf '\\007'")
            let core = try await startCore(configuration, paths: paths).value
            try await waitAsync { (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.bellAt != nil }
            let bellAt = try #require((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.bellAt)

            guard let record = try await core.quiesceForHandoff() else {
                Issue.record("quiesce produced no handoff record for a live session")
                return
            }
            TerminalEngineActor.runSynchronously { core.terminate() }

            let pty = try makeAdoptablePTY()
            let resumedCore = await makeResumedCore(configuration, paths: paths).value
            defer {
                // Close the slave FIRST so the adopted master's blocked read hits EOF, then terminate:
                // closing a PTY master out from under a still-blocked read hangs.
                tearDown(pty)
                TerminalEngineActor.runSynchronously { resumedCore.terminate() }
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))

            #expect(TerminalEngineActor.runSynchronously { Self.bellAt(of: resumedCore) } == bellAt)

            inject("\u{07}SETTLED\n", into: pty)
            try await waitForSettledTranscript(paths.outputPath)
            #expect(TerminalEngineActor.runSynchronously { Self.bellAt(of: resumedCore) } == bellAt)
            #expect((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.bellAt == bellAt)
        }

        /// The restored window still expires: a bell the user has not been told about is a new alert even
        /// when it is the first one after a handoff.
        @Test func aBellAfterTheRestoredWindowAdvancesTheTimestamp() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let configuration = makeConfiguration(named: "bell-handoff-reopen", script: "printf '\\007'")
            let core = try await startCore(configuration, paths: paths).value
            try await waitAsync { (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.bellAt != nil }
            let bellAt = try #require((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.bellAt)

            guard let record = try await core.quiesceForHandoff() else {
                Issue.record("quiesce produced no handoff record for a live session")
                return
            }
            TerminalEngineActor.runSynchronously { core.terminate() }

            let pty = try makeAdoptablePTY()
            let resumedCore = await makeResumedCore(configuration, paths: paths, quietWindow: 0.2).value
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { resumedCore.terminate() }
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))

            try await Task.sleep(for: .milliseconds(250))
            inject("\u{07}", into: pty)
            try await waitAsync { Self.bellAt(of: resumedCore) != bellAt }
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

        private func handoffRecord(from record: DaemonHandoffSessionRecord, adopting pty: AdoptablePTY) -> DaemonHandoffSessionRecord {
            DaemonHandoffSessionRecord(
                sessionID: record.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: record.columns, rows: record.rows,
                ownerEpoch: record.ownerEpoch, screenStateRevision: record.screenStateRevision, appearance: record.appearance,
                transcriptOffsetAtQuiesce: record.transcriptOffsetAtQuiesce)
        }

        /// The staged image's core: built but not started, so `quietWindow` can be shortened before the
        /// resume seeds the window and any live byte arrives.
        private func makeResumedCore(
            _ configuration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths, quietWindow: TimeInterval? = nil
        ) async -> Box<GhosttyEmbeddedSessionCore> {
            await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                if let quietWindow { core.bellCoalescer.quietWindow = quietWindow }
                return Box(core)
            }
        }

        /// Injects live output on the resumed session's adopted PTY (written to the slave, read by the
        /// core from the master).
        private func inject(_ text: String, into pty: AdoptablePTY) {
            let bytes = Array(text.utf8)
            #expect(bytes.withUnsafeBufferPointer { write(pty.slave, $0.baseAddress, $0.count) } == bytes.count)
        }
    }
#endif
