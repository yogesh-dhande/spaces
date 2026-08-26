import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// Covers what a live session costs while nothing is happening to it. The per-session refresh runs once
/// a second for the session's whole life, on the serial engine queue that also carries keystrokes, so
/// "an idle session does no durable work" is part of the session's contract rather than a tuning
/// detail — and it has to hold without weakening what a session that IS changing still writes, or what
/// the stale-client sweep still expires.
final class GhosttyEmbeddedSessionIdleCostTests: XCTestCase {
    /// Carries an engine-isolated session across the `await`s between ticks. Those awaits are what the
    /// test needs: the durable persist marker advances in a task hopped back onto the engine after a write
    /// commits, exactly as it does between two real one-second ticks, so a test that never left the engine
    /// would see every refresh decided against a marker that had not caught up yet.
    private final class Box<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// A timestamp nothing else would produce, stamped onto the stored row so a later write is visible
    /// however coarse the clock is. The core decides what to persist from its own in-memory marker rather
    /// than from the row, so stamping it cannot influence the decision it is used to observe.
    private static let sentinelTimestamp = "1999-01-01T00:00:00Z"

    private static func makeLaunchConfiguration(sessionID: String) -> TerminalSessionLaunchConfiguration {
        TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
    }

    /// A session whose observable state does not move: a fixed child pid and a fixed foreground process.
    @TerminalEngineActor private static func makeSteadySession(_ launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths)
        throws -> GhosttyEmbeddedSessionHost
    {
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        host.debugSetLastKnownChildPID(4242)
        host.debugSetForegroundPIDForTesting(4243)
        host.debugSetForegroundProcessResolverForTesting { pid in
            TerminalForegroundProcessSnapshot(pid: pid, executablePath: "/bin/zsh", executableName: "zsh", argv: ["zsh"])
        }
        return host
    }

    private static func stampStoredRuntimeStateWithSentinel(paths: TerminalSessionPaths) throws {
        let stored = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: stored.sessionID, backend: stored.backend, servicePID: stored.servicePID, childPID: stored.childPID, state: stored.state,
                updatedAt: sentinelTimestamp, exitedAt: stored.exitedAt, title: stored.title, workingDirectory: stored.workingDirectory,
                columns: stored.columns, rows: stored.rows, foregroundPID: stored.foregroundPID,
                foregroundExecutablePath: stored.foregroundExecutablePath, foregroundExecutableName: stored.foregroundExecutableName,
                foregroundArgv: stored.foregroundArgv, foregroundDetectedAgentKind: stored.foregroundDetectedAgentKind,
                foregroundDisplayLabel: stored.foregroundDisplayLabel, foregroundDisplayCommand: stored.foregroundDisplayCommand), paths: paths)
    }

    private static func makeSessionRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Repeated idle refreshes must not rewrite the stored runtime state: `shouldPersistRuntimeState` finds
    /// nothing about the row that changed, so `updated_at` stays at the sentinel stamped below no matter
    /// how many refresh ticks run.
    ///
    /// This covers repetition only, not elapsed real time. The regression this guards against — a session
    /// sitting idle rewrote its row every few seconds forever — was originally reproduced by running ticks
    /// across a real 5.5-second sleep; that made this one test the slowest thing in the suite for a claim
    /// repetition alone already exercises (each tick decides fresh from the same unchanged in-memory state
    /// regardless of how much time passed since the last one). The sleep was cut and deliberately not
    /// replaced with a clock injection: a reintroduced periodic rewrite timed at real wall-clock intervals
    /// would NOT be caught by this test as it stands today.
    func testIdleRefreshesLeaveTheStoredRuntimeStateAlone() async throws {
        try useIsolatedSpacesProfile()
        let root = try Self.makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = Self.makeLaunchConfiguration(sessionID: "idle-refresh-session")

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = try Self.makeSteadySession(launchConfiguration, paths: paths)
            host.debugPersistRuntimeState()
            host.debugDrainPersistenceQueue()
            return Box(host)
        }
        try await TerminalEngineActor.run { try Self.stampStoredRuntimeStateWithSentinel(paths: paths) }

        for _ in 0..<10 {
            await TerminalEngineActor.run {
                hostBox.value.debugPersistRuntimeState(force: false)
                hostBox.value.debugDrainPersistenceQueue()
            }
        }

        try await TerminalEngineActor.run {
            XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).updatedAt, Self.sentinelTimestamp)
        }
    }

    func testRefreshWritesAsSoonAsTheForegroundProcessChanges() async throws {
        try useIsolatedSpacesProfile()
        let root = try Self.makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = Self.makeLaunchConfiguration(sessionID: "changing-foreground-session")

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = try Self.makeSteadySession(launchConfiguration, paths: paths)
            host.debugPersistRuntimeState()
            host.debugDrainPersistenceQueue()
            return Box(host)
        }
        try await TerminalEngineActor.run { try Self.stampStoredRuntimeStateWithSentinel(paths: paths) }

        try await TerminalEngineActor.run {
            let host = hostBox.value
            host.debugSetForegroundProcessResolverForTesting { pid in
                TerminalForegroundProcessSnapshot(
                    pid: pid, executablePath: "/opt/homebrew/bin/codex", executableName: "codex", argv: ["codex", "--model", "gpt-5"])
            }
            host.debugPersistRuntimeState(force: false)
            host.debugDrainPersistenceQueue()

            let stored = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertNotEqual(stored.updatedAt, Self.sentinelTimestamp)
            XCTAssertEqual(stored.foregroundExecutableName, "codex")
            XCTAssertEqual(stored.foregroundDetectedAgentKind, .codex)
        }
    }

    /// An agent TUI animates a spinner in its terminal title, setting a new one several times a second for
    /// as long as it runs. Each set used to force a durable write, so a spinning agent committed a SQLite
    /// transaction per animation frame; on a machine running a few agents that was megabytes per second of
    /// WAL. The title is served to clients from the core's in-memory state, so the stored row does not have
    /// to track it.
    func testSpinnerTitleFramesDoNotRewriteTheStoredRuntimeState() async throws {
        try useIsolatedSpacesProfile()
        let root = try Self.makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = Self.makeLaunchConfiguration(sessionID: "spinner-title-session")

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = try Self.makeSteadySession(launchConfiguration, paths: paths)
            host.debugPersistRuntimeState()
            host.debugDrainPersistenceQueue()
            return Box(host)
        }
        try await TerminalEngineActor.run { try Self.stampStoredRuntimeStateWithSentinel(paths: paths) }

        for frame in ["\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}"] {
            await TerminalEngineActor.run {
                hostBox.value.debugApplyTitleActionEvent("\(frame) spider")
                hostBox.value.debugDrainPersistenceQueue()
            }
        }

        try await TerminalEngineActor.run {
            let host = hostBox.value
            XCTAssertEqual(host.debugCurrentTitle, "\u{2827} spider", "the core still tracks the latest reported title in memory")
            XCTAssertEqual(
                try TerminalSessionPersistence.readRuntimeState(paths: paths).updatedAt, Self.sentinelTimestamp,
                "no spinner frame may reach the durable row")
        }
    }

    /// Overview pushes used to ride the durable runtime-state write, so dropping `title` from the persist
    /// signature would have left the sidebar showing a stale title indefinitely. The signal is owed on every
    /// title change but coalesced onto the 1 Hz tick, so a spinning agent costs one overview rebuild per
    /// second rather than one per animation frame.
    func testTitleFramesOweExactlyOneCoalescedOverviewSignal() async throws {
        try useIsolatedSpacesProfile()
        let root = try Self.makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = Self.makeLaunchConfiguration(sessionID: "overview-signal-session")

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = try Self.makeSteadySession(launchConfiguration, paths: paths)
            host.debugPersistRuntimeState()
            host.debugDrainPersistenceQueue()
            return Box(host)
        }

        // Let the setup write's `onPersisted` hop land first. It posts a runtime-state overview signal of
        // its own, which would otherwise be counted below as if a title frame had produced it.
        await TerminalEngineActor.run {}
        await TerminalEngineActor.run {}

        let counter = SignalCounter()
        let token = NotificationCenter.default.addObserver(forName: TerminalOverviewSignal.name, object: nil, queue: nil) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(token) }

        for frame in ["\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}"] {
            await TerminalEngineActor.run {
                hostBox.value.debugApplyTitleActionEvent("\(frame) spider")
                hostBox.value.debugDrainPersistenceQueue()
            }
        }
        // The owed flag is the deterministic half of this assertion: the notification count can only show
        // that nothing was posted, while the flag shows the burst was recorded rather than dropped.
        await TerminalEngineActor.run { XCTAssertTrue(hostBox.value.debugOwesOverviewSignalForMetadata, "the burst leaves exactly one signal owed") }
        XCTAssertEqual(counter.value, 0, "no title frame posts an overview signal on its own")

        await TerminalEngineActor.run { hostBox.value.debugFlushPendingOverviewSignalForMetadata() }
        XCTAssertEqual(counter.value, 1, "the tick posts exactly one signal for the whole burst")

        // Nothing further is owed, so a tick with no title change since is silent.
        await TerminalEngineActor.run {
            XCTAssertFalse(hostBox.value.debugOwesOverviewSignalForMetadata)
            hostBox.value.debugFlushPendingOverviewSignalForMetadata()
        }
        XCTAssertEqual(counter.value, 1, "an idle tick posts nothing")
    }

    /// Counts overview signals across the engine hops the test makes.
    private final class SignalCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// The title still has to reach the row when something else about the session moves, so a row written
    /// for any other reason carries the current title rather than a stale one.
    func testAWriteTriggeredByAnotherFieldCarriesTheCurrentTitle() async throws {
        try useIsolatedSpacesProfile()
        let root = try Self.makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = Self.makeLaunchConfiguration(sessionID: "title-ride-along-session")

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = try Self.makeSteadySession(launchConfiguration, paths: paths)
            host.debugPersistRuntimeState()
            host.debugDrainPersistenceQueue()
            return Box(host)
        }
        try await TerminalEngineActor.run { try Self.stampStoredRuntimeStateWithSentinel(paths: paths) }

        try await TerminalEngineActor.run {
            let host = hostBox.value
            host.debugApplyTitleActionEvent("claude - editing")
            host.debugDrainPersistenceQueue()
            XCTAssertEqual(
                try TerminalSessionPersistence.readRuntimeState(paths: paths).updatedAt, Self.sentinelTimestamp,
                "the title alone still does not write")

            // The foreground process changing is in the signature, so this write happens for that reason.
            host.debugSetForegroundProcessResolverForTesting { pid in
                TerminalForegroundProcessSnapshot(pid: pid, executablePath: "/opt/homebrew/bin/claude", executableName: "claude", argv: ["claude"])
            }
            host.debugPersistRuntimeState(force: false)
            host.debugDrainPersistenceQueue()

            let stored = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertNotEqual(stored.updatedAt, Self.sentinelTimestamp)
            XCTAssertEqual(stored.title, "claude - editing", "the write carries the title the core currently holds")
        }
    }

    /// The sweep skips a session with nothing a lease could expire. A viewer that attaches afterwards has
    /// to be expired on the first sweep after its lease lapses all the same — the ticks before it arrived
    /// must not leave the sweep believing the session is still empty.
    func testSweepExpiresAViewerThatAttachesAfterIdleTicks() async throws {
        try useIsolatedSpacesProfile()
        let root = try Self.makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = Self.makeLaunchConfiguration(sessionID: "late-viewer-session")

        try await TerminalEngineActor.run {
            let host = try Self.makeSteadySession(launchConfiguration, paths: paths)
            let idleNow = Date()
            for _ in 0..<5 { XCTAssertEqual(host.expireStaleRemoteClientsIfNeeded(now: idleNow), []) }

            let viewer = TerminalClient(
                id: "late-viewer", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"),
                connectedAt: TerminalSessionTimestamp.string(from: idleNow))
            XCTAssertTrue(host.handleControlRequest(.init(command: "attach", client: viewer, attachmentMode: .viewer)).ok)
            host.debugDrainPersistenceQueue()

            let lapsed = Date().addingTimeInterval(TerminalSessionPersistence.remoteClientLeaseInterval + 5)
            XCTAssertEqual(host.expireStaleRemoteClientsIfNeeded(now: lapsed), [viewer.id])
            host.debugDrainPersistenceQueue()
            XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty)
        }
    }

    /// A local window client never expires however long the sweep runs: its liveness is not the lease's to
    /// decide, and the window it belongs to is what keeps the session open.
    func testSweepNeverExpiresAnAttachedLocalWindow() async throws {
        try useIsolatedSpacesProfile()
        let root = try Self.makeSessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = Self.makeLaunchConfiguration(sessionID: "local-window-session")

        try await TerminalEngineActor.run {
            let host = try Self.makeSteadySession(launchConfiguration, paths: paths)
            let window = TerminalClient(
                id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"),
                connectedAt: TerminalSessionTimestamp.string(from: Date()))
            XCTAssertTrue(host.handleControlRequest(.init(command: "attach", client: window, attachmentMode: .owner)).ok)
            host.debugDrainPersistenceQueue()

            let farFuture = Date().addingTimeInterval(TerminalSessionPersistence.remoteClientLeaseInterval * 100)
            for _ in 0..<5 { XCTAssertEqual(host.expireStaleRemoteClientsIfNeeded(now: farFuture), []) }

            host.debugDrainPersistenceQueue()
            XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).map(\.clientID), [window.id])
        }
    }
}
