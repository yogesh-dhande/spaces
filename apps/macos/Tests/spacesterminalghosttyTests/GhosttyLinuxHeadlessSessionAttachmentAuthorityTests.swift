#if os(Linux)
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// The Linux headless core answers "who owns this session" from an in-memory attachment snapshot and
    /// mirrors every attachment change to the database off the engine. These drive real attach, takeover, and
    /// detach control requests against a running headless session and check both halves of that contract: the
    /// state payload a subscriber receives reflects the change immediately, and the durable mirror the
    /// out-of-core readers (the session listing, a fresh core after a handoff) read converges on the same
    /// answer once the persistence queue drains.
    ///
    /// The durable convergence also pins the ordering the whole design rests on: the session row is the first
    /// write the core enqueues, so the attachment writes queued behind it always find the session they name.
    ///
    /// Swift Testing (not XCTest) because corelibs-xctest deadlocks async tests on Linux; `.serialized`
    /// because each test mutates the process-wide SPACES_* environment and owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionAttachmentAuthorityTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference (created inside a `TerminalEngineActor.run` block) back out
        /// to the nonisolated test body; the value is only ever *used* on the engine actor via a later bridge.
        private final class Box<Value>: @unchecked Sendable {
            let value: Value
            init(_ value: Value) { self.value = value }
        }

        /// A lock-guarded mutable cell for state written on the engine actor (inside an `onSessionClosed`
        /// callback) and read back from the nonisolated test body once the engine work is known to have
        /// finished. `Box` above is deliberately immutable and cannot serve that purpose.
        private final class MutableBox<Value>: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: Value
            init(_ value: Value) { storage = value }
            var value: Value {
                get {
                    lock.lock()
                    defer { lock.unlock() }
                    return storage
                }
                set {
                    lock.lock()
                    defer { lock.unlock() }
                    storage = newValue
                }
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

        // MARK: - Fixtures

        /// A test-owned PTY plus a live child pid, standing in for the master fd and child that `execv`
        /// preserves across a real handoff. The child is a bare `sleep` (spawned with `posix_spawn` so only
        /// this test reaps it) that keeps `resumeFromHandoff`'s liveness checks satisfied; this test never
        /// injects or reads PTY bytes, it only needs `resumeFromHandoff` to have something real to adopt.
        private struct AdoptablePTY {
            let master: Int32
            let slave: Int32
            let childPID: Int32
        }

        private func makeAdoptablePTY() throws -> AdoptablePTY {
            // Swift's Linux Glibc overlay does not surface posix_openpt/grantpt/unlockpt/ptsname, so
            // allocate the master/slave pair with openpty (which it does expose) instead.
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

        private static let localOwner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-26T00:00:00Z")
        private static let remoteViewer = TerminalClient(
            id: "remote-iphone", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
            connectedAt: "2026-07-26T00:00:01Z")

        private func makeTemporaryPaths() throws -> TerminalSessionPaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            return paths
        }

        /// A session that just blocks on `cat`, so it stays live for the whole test without producing output.
        private func makeConfiguration(named name: String) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: "\(name)-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-07-26T00:00:00Z",
                workspaceID: "workspace-attachment", kind: .shell)
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

        // MARK: - Engine-isolated helpers (call from inside a run/runSynchronously bridge)

        @TerminalEngineActor private static func attach(_ core: GhosttyEmbeddedSessionCore, client: TerminalClient, mode: TerminalAttachmentMode) {
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: mode))
            #expect(response.ok, "attaching a \(mode.rawValue) client must succeed: \(response.message)")
        }

        /// The owner the state payload advertises: what every attached client gates its own input on.
        @TerminalEngineActor private static func broadcastOwnerClientID(of core: GhosttyEmbeddedSessionCore) -> String? {
            let snapshot = core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.attachmentState)?.attachmentSnapshot
            return snapshot?.attachments.first { $0.detachedAt == nil && $0.mode == .owner }?.clientID
        }

        // MARK: - Nonisolated helpers

        private func durableOwnerClientID(paths: TerminalSessionPaths) throws -> String? {
            try TerminalSessionPersistence.readAttachmentSnapshot(paths: paths).attachments.first { $0.detachedAt == nil && $0.mode == .owner }?
                .clientID
        }

        /// Terminates the core and waits for the writes terminate enqueues (exited runtime state,
        /// detach-all, terminated payload) to commit before the deferred cleanup deletes this test's
        /// root or the suite deinit restores SPACES_*. The deferred `terminate()` backstop then no-ops
        /// (terminate is idempotent), so the defers only cover early-throw exits.
        private func shutDownAndDrain(_ core: GhosttyEmbeddedSessionCore) async {
            TerminalEngineActor.runSynchronously { core.terminate() }
            await core.drainPersistenceForShutdown()
        }

        // MARK: - Tests

        /// The first attach of a session's life is also the first attachment write queued behind the session
        /// row the core enqueued at start. The owner is authoritative in memory the moment the attach is
        /// acknowledged, and the mirror lands intact — a mirror that outran the session row would be rejected
        /// as naming an unknown session and leave the durable state with no attachment at all.
        @Test func attachingAnOwnerIsAuthoritativeInMemoryAndConvergesDurably() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let configuration = makeConfiguration(named: "attachment-attach")
            let core = try await startCore(configuration, paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            TerminalEngineActor.runSynchronously { Self.attach(core, client: Self.localOwner, mode: .owner) }
            #expect(
                TerminalEngineActor.runSynchronously { Self.broadcastOwnerClientID(of: core) } == Self.localOwner.id,
                "the attaching owner must own the session in the payload the broadcast carries")

            await core.drainPersistenceForShutdown()
            #expect(try TerminalSessionPersistence.readLaunchConfiguration(paths: paths).sessionID == configuration.sessionID)
            #expect(try durableOwnerClientID(paths: paths) == Self.localOwner.id, "the durable mirror must converge on the attached owner")

            await shutDownAndDrain(core)
        }

        /// A phone taking over a session it is already viewing owns it in memory at once, so its own input is
        /// accepted immediately rather than after the durable transfer commits.
        @Test func takeoverMovesOwnershipInMemoryAndConvergesDurably() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let core = try await startCore(makeConfiguration(named: "attachment-takeover"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            TerminalEngineActor.runSynchronously {
                Self.attach(core, client: Self.localOwner, mode: .owner)
                Self.attach(core, client: Self.remoteViewer, mode: .viewer)
                let takeover = core.handleControlRequest(TerminalControlRequest(command: "takeover", clientID: Self.remoteViewer.id))
                #expect(takeover.ok, "a takeover by an attached viewer must be accepted: \(takeover.message)")
                #expect(Self.broadcastOwnerClientID(of: core) == Self.remoteViewer.id, "the broadcast must advertise the new owner immediately")
            }

            await core.drainPersistenceForShutdown()
            #expect(try durableOwnerClientID(paths: paths) == Self.remoteViewer.id, "the durable mirror must converge on the new owner")

            await shutDownAndDrain(core)
        }

        /// A takeover names a client the session has never seen: rejected from the in-memory snapshot, which
        /// mirrors the precondition the durable transfer enforces, so nothing is enqueued and ownership stands.
        @Test func takeoverByAnUnknownClientIsRejected() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let core = try await startCore(makeConfiguration(named: "attachment-unknown-takeover"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            TerminalEngineActor.runSynchronously {
                Self.attach(core, client: Self.localOwner, mode: .owner)
                let takeover = core.handleControlRequest(TerminalControlRequest(command: "takeover", clientID: "never-attached"))
                #expect(!takeover.ok, "a takeover by a client this session never saw must be rejected")
                #expect(Self.broadcastOwnerClientID(of: core) == Self.localOwner.id, "the rejected takeover must leave ownership where it was")
            }

            await core.drainPersistenceForShutdown()
            #expect(try durableOwnerClientID(paths: paths) == Self.localOwner.id)

            await shutDownAndDrain(core)
        }

        /// Detaching the owner ends its attachment in memory and durably, and a heartbeat from that client is
        /// then answered from memory as no-longer-attached — the answer a client acts on to stop pretending it
        /// still holds the session.
        @Test func detachingTheOwnerEndsItsAttachmentAndItsLease() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let core = try await startCore(makeConfiguration(named: "attachment-detach"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            TerminalEngineActor.runSynchronously {
                Self.attach(core, client: Self.localOwner, mode: .owner)
                let heartbeat = core.handleControlRequest(TerminalControlRequest(command: "heartbeat", clientID: Self.localOwner.id))
                #expect(heartbeat.ok, "an attached client's heartbeat must be accepted: \(heartbeat.message)")

                let detach = core.handleControlRequest(TerminalControlRequest(command: "detach", clientID: Self.localOwner.id))
                #expect(detach.ok, "detaching an attached client must succeed: \(detach.message)")
                #expect(Self.broadcastOwnerClientID(of: core) == nil, "no client owns the session after its only owner detaches")

                let staleHeartbeat = core.handleControlRequest(TerminalControlRequest(command: "heartbeat", clientID: Self.localOwner.id))
                #expect(!staleHeartbeat.ok, "a detached client's heartbeat must be rejected")
                #expect(staleHeartbeat.errorCode == .notFound)
            }

            await core.drainPersistenceForShutdown()
            let snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
            #expect(snapshot.attachments.allSatisfy { $0.detachedAt != nil }, "the durable mirror must hold no active attachment")
            #expect(snapshot.clients.first { $0.id == Self.localOwner.id }?.disconnectedAt != nil, "the detached client must be durably disconnected")

            await shutDownAndDrain(core)
        }

        // MARK: - `hasLiveAttachments`

        /// `hasLiveAttachments()` is what the daemon's `.whileAttached` reaper reads instead of the durable
        /// mirror, because this core's own attachment writes are the only writes to its rows and memory is
        /// therefore always at least as current as a mirror those writes are still queued behind. Checking it
        /// synchronously, on the same engine-actor hop as the attach and before the queue is ever drained,
        /// exercises exactly the window the reaper depends on.
        @Test func hasLiveAttachmentsIsTrueImmediatelyAfterAttach() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let core = try await startCore(makeConfiguration(named: "attachment-has-live-attachments"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            TerminalEngineActor.runSynchronously {
                Self.attach(core, client: Self.localOwner, mode: .owner)
                #expect(
                    core.hasLiveAttachments(),
                    "the in-memory attachment authority must report the attach live on the same hop that applied it")
            }

            await core.drainPersistenceForShutdown()
            #expect(try durableOwnerClientID(paths: paths) == Self.localOwner.id, "the durable mirror must also converge on the attached owner")

            await shutDownAndDrain(core)
        }

        /// A remote client's liveness is lease-gated: once its lease is old enough that
        /// `TerminalSessionAttachmentSnapshot.liveAttachments` would treat it as stale, `hasLiveAttachments`
        /// must stop counting it, the same rule the durable-mirror readers apply.
        @Test func hasLiveAttachmentsIsFalseForALeaseStaleRemoteClient() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let core = try await startCore(makeConfiguration(named: "attachment-has-live-attachments-stale-lease"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            TerminalEngineActor.runSynchronously { Self.attach(core, client: Self.remoteViewer, mode: .owner) }
            await core.drainPersistenceForShutdown()

            #expect(
                TerminalEngineActor.runSynchronously { core.hasLiveAttachments() },
                "a freshly attached remote client's lease has not lapsed, so it is live")

            let wellPastTheLease = Date().addingTimeInterval(TerminalSessionPersistence.remoteClientLeaseInterval * 100)
            #expect(
                !(TerminalEngineActor.runSynchronously { core.hasLiveAttachments(now: wellPastTheLease) }),
                "a remote client whose lease is well past its interval must not count as a live attachment")

            await shutDownAndDrain(core)
        }

        /// The base case for the daemon reaper's `.whileAttached` check: a session with no attachments at all
        /// must not report one.
        @Test func hasLiveAttachmentsIsFalseWithNoAttachments() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let core = try await startCore(makeConfiguration(named: "attachment-has-live-attachments-none"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            #expect(
                !(TerminalEngineActor.runSynchronously { core.hasLiveAttachments() }),
                "a session with no attachments must not report a live attachment")

            await shutDownAndDrain(core)
        }

        // MARK: - `hasLiveOwnerAttachment` / `enqueueAgentSignalAppend`

        /// The close-time ad-hoc stop's owner check reads `hasLiveOwnerAttachment` through the daemon's
        /// prober instead of the durable mirror, because a detach applied to this in-memory snapshot can
        /// still have its mirror write parked behind a contended queue. A detach must flip this to false the
        /// moment it is applied, with the durable mirror still showing the now-stale owner row underneath.
        @Test func detachIsVisibleToOwnerAttachmentProbeBeforeTheDurableMirrorCommits() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let core = try await startCore(makeConfiguration(named: "attachment-owner-probe-before-commit"), paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            TerminalEngineActor.runSynchronously { Self.attach(core, client: Self.localOwner, mode: .owner) }
            await core.drainPersistenceForShutdown()
            #expect(
                TerminalEngineActor.runSynchronously { core.hasLiveOwnerAttachment() },
                "the attached owner must read as a live owner attachment")

            // Park the queue so the detach's durable mirror write is enqueued but cannot commit yet.
            let gate = TerminalEngineActor.runSynchronously { core.debugHoldPersistenceQueue() }
            TerminalEngineActor.runSynchronously {
                let detach = core.handleControlRequest(TerminalControlRequest(command: "detach", clientID: Self.localOwner.id))
                #expect(detach.ok, "detaching the owner must succeed: \(detach.message)")
            }

            #expect(
                !(TerminalEngineActor.runSynchronously { core.hasLiveOwnerAttachment() }),
                "the in-memory attachment authority must report no live owner immediately, before the detach's mirror write commits")
            #expect(
                !(try durableOwnerClientID(paths: paths) == nil),
                "the durable mirror is still parked and must still show the now-stale owner row, proving the read above came from memory")

            gate.signal()
            TerminalEngineActor.runSynchronously { core.debugDrainPersistenceQueue() }

            await shutDownAndDrain(core)
        }

        /// A `SessionStart` hook can fire while a just-spawned session's launch-configuration row is still
        /// queued behind the persistence queue. `enqueueAgentSignalAppend` must land the signal only after
        /// that row exists, which FIFO ordering on the same per-core serial queue guarantees: enqueueing the
        /// signal append while the launch write is still parked must not throw and must commit only once the
        /// queue drains both writes in order.
        @Test func agentSignalEnqueuedDuringPendingLaunchCommitsAfterTheSessionRow() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let configuration = makeConfiguration(named: "attachment-agent-signal-pending-launch")

            let box = await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            defer { TerminalEngineActor.runSynchronously { box.value.terminate() } }

            // Park the queue before starting, so the launch-configuration write is enqueued but cannot commit.
            let gate = TerminalEngineActor.runSynchronously { box.value.debugHoldPersistenceQueue() }
            TerminalEngineActor.runSynchronously { try? box.value.startIfNeeded() }
            #expect(
                TerminalSessionPendingLaunchRegistry.shared.pendingLaunchConfiguration(sessionID: configuration.sessionID) != nil,
                "the launch write must still be pending when the signal is enqueued")

            let signal = TerminalServiceAgentSignalEvent(
                id: "signal-1", sessionID: configuration.sessionID, workspaceID: "workspace-attachment", workspacePath: paths.rootDirectory,
                type: "SessionStart", createdAt: "2026-07-26T00:00:01Z")
            TerminalEngineActor.runSynchronously { box.value.enqueueAgentSignalAppend(signal) }

            #expect(throws: (any Error).self) { try TerminalSessionPersistence.pendingAgentSignals(sessionID: configuration.sessionID, paths: paths) }

            gate.signal()
            TerminalEngineActor.runSynchronously { box.value.debugDrainPersistenceQueue() }

            #expect(
                try TerminalSessionPersistence.pendingAgentSignals(sessionID: configuration.sessionID, paths: paths) == [signal],
                "the signal must commit once the queue drains the launch write ahead of it")

            await shutDownAndDrain(box.value)
        }

        // MARK: - Fix 2: a failed launch-configuration write terminates the core

        /// A prior write against a healthy database is what gives `breakDatabase` below a file to break: the
        /// database a fresh session writes to does not exist until something creates it, and `breakDatabase`
        /// needs an existing file to move aside. The break swaps a garbage file (bytes that fail SQLite's
        /// header check) into the database's place rather than chmod-ing it to 0o000: the Docker Linux lane
        /// runs as root, where a mode change does not bite, and a garbage file makes every open fail with
        /// SQLITE_NOTADB for root too. The `-wal`/`-shm` sidecars move aside with the main file: these tests
        /// run against a per-test fresh database whose entire content sits in the WAL until a checkpoint, so
        /// leaving the WAL behind loses every row whenever the close-time checkpoint was skipped, because
        /// the first open after restore then sees an empty main file, re-runs migrations, and resets the
        /// stranded WAL.
        /// Connections are closed on both sides so the swap actually bites (a long-lived connection would
        /// carry its open file straight through it).
        private static func breakDatabase(at databasePath: String) throws {
            TerminalSessionPersistence.closeDatabaseConnection()
            let garbagePath = databasePath + ".garbage-tmp"
            try Data("spaces test: deliberately not a SQLite database\n".utf8).write(to: URL(fileURLWithPath: garbagePath))
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: databasePath + suffix) {
                try FileManager.default.moveItem(atPath: databasePath + suffix, toPath: databasePath + ".unbroken" + suffix)
            }
            try FileManager.default.moveItem(atPath: databasePath, toPath: databasePath + ".unbroken")
            try FileManager.default.moveItem(atPath: garbagePath, toPath: databasePath)
        }

        /// Sidecars return first (the garbage file still guards the path, so a concurrent open keeps failing),
        /// and then POSIX `rename(2)` replaces the garbage file with the real database in one atomic step:
        /// there is never an instant where the path is absent (an open would create a fresh empty database
        /// there) or where a valid main file is visible without its WAL.
        private static func restoreDatabase(at databasePath: String) throws {
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: databasePath + ".unbroken" + suffix) {
                if FileManager.default.fileExists(atPath: databasePath + suffix) {
                    try FileManager.default.removeItem(atPath: databasePath + suffix)
                }
                try FileManager.default.moveItem(atPath: databasePath + ".unbroken" + suffix, toPath: databasePath + suffix)
            }
            guard rename(databasePath + ".unbroken", databasePath) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            TerminalSessionPersistence.closeDatabaseConnection()
        }

        /// A failed launch-configuration write must terminate the core rather than leave it running with no
        /// `terminal_sessions` row: every later mirror write this core enqueues validates against that row,
        /// so reconciling instead of terminating would just make every later write fail as `unknownSession`
        /// forever.
        @Test func launchConfigurationWriteFailureTerminatesTheCore() async throws {
            let placeholderPaths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: placeholderPaths.rootDirectory) }
            try TerminalSessionPersistence.writeLaunchConfiguration(makeConfiguration(named: "attachment-b2-placeholder"), paths: placeholderPaths)

            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let configuration = makeConfiguration(named: "attachment-b2-terminates-on-launch-write-failure")

            let databasePath = try SpacesProfile.current().databasePath
            try Self.breakDatabase(at: databasePath)

            // Fix 4: `terminate()` alone never calls `onSessionClosed`, only the natural child-exit path does,
            // so a core terminated over a failed launch-configuration write must call it explicitly, or the
            // daemon's session registry keeps the dead core registered forever. Record whether it fired.
            let onSessionClosedFired = MutableBox(false)

            // `startIfNeeded()` enqueues the launch-configuration write as its first act; the write then
            // retries in place against the broken database until its bounded attempts are exhausted. The
            // database must stay broken until that happens — restoring it any earlier lets a later in-place
            // retry succeed and the core (correctly) keep running — so the drain below, which waits until the
            // write has run out of retries, is what gates the restore.
            let box = TerminalEngineActor.runSynchronously { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(
                    launchConfiguration: configuration, paths: paths, onSessionClosed: { _ in onSessionClosedFired.value = true })
                try? core.startIfNeeded()
                return Box(core)
            }
            await box.value.drainPersistenceForShutdown()
            try Self.restoreDatabase(at: databasePath)

            // The failed write's `onFailure` hop into `reconcileAfterFailedLifecycleWrite` (which terminates
            // the core for this label) is a Task spawned from inside the drain above; one more turn on the
            // engine actor's serial executor is ordered after that hop has run.
            await TerminalEngineActor.run {}

            // On regression, terminate the still-running core before asserting, so a leaked PTY child does
            // not outlive this test and destabilize the rest of the `.serialized` suite.
            let stillStarted = TerminalEngineActor.runSynchronously { () -> Bool in box.value.isStarted }
            if stillStarted { TerminalEngineActor.runSynchronously { box.value.terminate() } }
            #expect(
                !stillStarted,
                "a launch-configuration write that exhausts its retries must terminate the core rather than leaving it running with no session row")
            #expect(
                onSessionClosedFired.value,
                "a core terminated over a failed launch-configuration write must call onSessionClosed so the daemon's session registry forgets it")
            #expect(
                TerminalSessionPendingLaunchRegistry.shared.pendingLaunchConfiguration(sessionID: configuration.sessionID) == nil,
                "the final write failure must clear the pending-launch entry along with terminating the core, or a launch-pending probe would keep reporting a launch in flight for a session that no longer exists")

            // The reconcile's own `terminate()` (and the regression branch's, above) enqueued exited-state,
            // detach-all, and terminated-payload writes after the drain that gated the restore; wait for
            // them so the deferred root cleanup cannot race stragglers still writing under this test's root.
            await box.value.drainPersistenceForShutdown()
        }

        // MARK: - Fix 5: a failed attachment-snapshot reseed is retried, not cached as empty

        /// `resumeFromHandoff` reseeds `cachedAttachmentSnapshot` from disk (`seedAttachmentSnapshot`) as
        /// close to the top of resume as possible, since the durable attachment rows it reads there are
        /// exactly what a pre-handoff image committed before this core existed. If a failed read on that
        /// reseed cached an empty snapshot instead of nil, `hasLiveAttachments()` would answer false for a
        /// session the durable rows say is still owned, and the daemon's `.whileAttached` reaper would tear
        /// down a live, attached session on nothing more than a transient disk hiccup, with no read left
        /// that would ever notice the mistake. Fix 5 caches nil on a failed read instead: `hasLiveAttachments`
        /// answers conservatively (live) while the database stays broken, and the next access after it is
        /// restored retries the read and recovers the real, attached answer.
        @Test func resumeFromHandoffRetriesAFailedAttachmentSeedRatherThanCachingItEmpty() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let configuration = makeConfiguration(named: "attachment-b5-failed-seed-retries")

            // Durable state a pre-handoff image would have left behind: a session row and an attached
            // owner, written directly (not through a running core) since this half of the handoff needs no
            // live PTY, only the resumed core adopting one below does.
            try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
            try TerminalSessionPersistence.attachClient(
                sessionID: configuration.sessionID, client: Self.localOwner, mode: .owner, paths: paths, attachedAt: "2026-07-26T00:00:00Z")

            let pty = try makeAdoptablePTY()
            defer { tearDown(pty) }
            let record = DaemonHandoffSessionRecord(
                sessionID: configuration.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: 80, rows: 24, ownerEpoch: 0,
                screenStateRevision: 0, appearance: nil, transcriptOffsetAtQuiesce: nil)

            let databasePath = try SpacesProfile.current().databasePath
            try Self.breakDatabase(at: databasePath)

            let box = await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            let core = box.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            // Resume proceeds even though the database is unreadable: `seedAttachmentSnapshot` swallows the
            // failed read (see its docstring) instead of throwing, and every other read on this path
            // (`readRuntimeState`) is already `try?`-wrapped for the same reason, so nothing here surfaces
            // the broken database as a thrown error. `resumeFromHandoff` also re-enqueues the launch-
            // configuration write, which will independently exhaust its retries against the still-broken
            // database and terminate this core sometime after this call returns (Fix 4); that race is
            // immaterial below, since `hasLiveAttachments()` and the attachment snapshot it and
            // `currentRemoteStatePayload` read from are unaffected by `terminate()`.
            try await core.resumeFromHandoff(record)

            #expect(
                TerminalEngineActor.runSynchronously { core.hasLiveAttachments() },
                "a failed reseed must answer conservatively (live) rather than caching the empty snapshot the broken read could not disprove")

            try Self.restoreDatabase(at: databasePath)

            // The nil cache left by the failed seed above is what makes this retry possible: it is read
            // again, successfully this time, rather than being stuck on the conservative fallback forever.
            let recoveredOwnerClientID = TerminalEngineActor.runSynchronously { Self.broadcastOwnerClientID(of: core) }
            #expect(
                recoveredOwnerClientID == Self.localOwner.id,
                "once the database is restored, the next read must recover the durable owner rather than staying on the conservative fallback")

            await shutDownAndDrain(core)
        }
    }
#endif
