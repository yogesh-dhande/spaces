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

        // The refreshes deliberately straddle a real wait, because "nothing is rewritten" is a claim about
        // elapsed time as much as about repetition: a session sitting idle rewrote its row every few
        // seconds forever, and a burst of refreshes inside one of those windows would not show it.
        for _ in 0..<5 {
            await TerminalEngineActor.run {
                hostBox.value.debugPersistRuntimeState(force: false)
                hostBox.value.debugDrainPersistenceQueue()
            }
        }
        try await Task.sleep(nanoseconds: 5_500_000_000)
        for _ in 0..<5 {
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
