import Foundation
import XCTest

@testable import spacesterminalcore

/// Covers the catalog's contract: it reports exactly the sessions whose interactive service is still
/// running, whatever else the device has accumulated, and the cost of asking is set by how many of
/// those there are rather than by how many sessions have ever existed.
final class TerminalSessionCatalogTests: XCTestCase {
    private var originalRuntimeDirectory: String?
    private var originalDatabasePath: String?
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db", isDirectory: false).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// A pid that is guaranteed not to name a running process, so "the service died" is a fact rather
    /// than a race: pid 0 is never a process `kill(2)` reports as alive for a single target.
    private let deadServicePID: Int32 = 0

    private enum SessionShape {
        /// A session whose service process is this test process, i.e. demonstrably alive.
        case live
        /// The rows an ordinary ended session leaves behind.
        case ended
        /// The rows a session whose daemon died without finalizing it leaves behind: still marked
        /// running, but its recorded service process is gone.
        case runningWithDeadService
        /// A session row with no runtime-state row at all.
        case withoutRuntimeState
    }

    @discardableResult private func seedSession(id: String, shape: SessionShape, createdAt: String = "2026-01-01T00:00:00Z") throws
        -> TerminalSessionPaths
    {
        let paths = try TerminalSessionPaths.forSession(id: id)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: id, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: createdAt,
                workspaceID: "workspace-1", kind: .shell), paths: paths)
        guard shape != .withoutRuntimeState else { return paths }
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: id, servicePID: shape == .live ? getpid() : deadServicePID, childPID: nil, state: shape == .ended ? .exited : .running,
                updatedAt: "2026-01-01T00:00:05Z", exitedAt: shape == .ended ? "2026-01-01T00:00:05Z" : nil), paths: paths)
        return paths
    }

    func testReportsOnlySessionsWhoseServiceIsStillRunning() throws {
        try seedSession(id: "alive-one", shape: .live, createdAt: "2026-01-01T00:00:01Z")
        try seedSession(id: "ended", shape: .ended, createdAt: "2026-01-01T00:00:02Z")
        try seedSession(id: "running-dead-service", shape: .runningWithDeadService, createdAt: "2026-01-01T00:00:03Z")
        try seedSession(id: "no-runtime-state", shape: .withoutRuntimeState, createdAt: "2026-01-01T00:00:04Z")
        try seedSession(id: "alive-two", shape: .live, createdAt: "2026-01-01T00:00:05Z")

        XCTAssertEqual(try TerminalSessionCatalog.listLiveSessions().map(\.sessionID), ["alive-one", "alive-two"])
    }

    /// The reported set must not depend on how much dead history sits alongside it — that history is
    /// what accumulates on a long-lived install.
    func testReportedSessionsAreUnaffectedByTheVolumeOfDeadRows() throws {
        try seedSession(id: "alive", shape: .live, createdAt: "2026-01-01T00:00:00Z")
        let expected = try TerminalSessionCatalog.listLiveSessions()
        XCTAssertEqual(expected.map(\.sessionID), ["alive"])

        for index in 0..<150 {
            try seedSession(id: "ended-\(index)", shape: .ended, createdAt: "2026-01-02T00:00:00Z")
            try seedSession(id: "orphaned-\(index)", shape: .runningWithDeadService, createdAt: "2026-01-03T00:00:00Z")
        }

        XCTAssertEqual(try TerminalSessionCatalog.listLiveSessions(), expected)
    }

    func testReportedEntryCarriesTheSessionsOwnStoredStateAndAttachments() throws {
        let paths = try seedSession(id: "alive", shape: .live)
        try seedSession(id: "ended", shape: .ended)
        let client = TerminalClient(
            id: "viewer", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-01-01T00:00:06Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: "alive", client: client, mode: .owner, paths: paths, attachedAt: "2026-01-01T00:00:06Z")

        let entry = try XCTUnwrap(try TerminalSessionCatalog.listLiveSessions().first)
        XCTAssertEqual(entry.sessionID, "alive")
        XCTAssertEqual(entry.paths.rootDirectory, paths.rootDirectory)
        XCTAssertEqual(entry.runtimeState.servicePID, getpid())
        XCTAssertEqual(entry.runtimeState.updatedAt, "2026-01-01T00:00:05Z")
        XCTAssertEqual(entry.launchConfiguration.workspaceID, "workspace-1")
        XCTAssertEqual(entry.attachmentSnapshot.attachments.map(\.clientID), ["viewer"])
    }

    /// The cost of listing sessions is a product guarantee, not an implementation detail: the device-API
    /// overview rebuilds this several times a second while someone is using a terminal, and the CLI's
    /// `terminal list` runs it on the daemon's main actor. Growing with the number of sessions the device
    /// has ever created rather than with the live ones is what made it cost tens of milliseconds of daemon
    /// CPU per call on an ordinary install.
    ///
    /// It is asserted with a counter rather than with timing because the guarantee is about how much
    /// database work is done, and a timing assertion could only observe that indirectly and unreliably on
    /// a loaded machine. No assertion about the returned sessions can distinguish the two shapes — that is
    /// exactly why the regression was invisible to the rest of this suite.
    ///
    /// The bound is absolute rather than a ratio so it states the guarantee directly: listing one live
    /// session costs a fixed handful of database round trips no matter how much history is stored. It is
    /// generous enough that a stray unit of work from elsewhere in the process cannot trip it, and far
    /// below the one-read-per-stored-session shape it exists to rule out.
    func testDatabaseWorkDoesNotGrowWithTheNumberOfStoredSessions() throws {
        try seedSession(id: "alive", shape: .live)
        for index in 0..<300 { try seedSession(id: "ended-\(index)", shape: .ended) }
        _ = try TerminalSessionCatalog.listLiveSessions()

        let baseline = TerminalDatabaseConnection.shared.workUnitCount
        XCTAssertEqual(try TerminalSessionCatalog.listLiveSessions().count, 1)
        XCTAssertLessThan(TerminalDatabaseConnection.shared.workUnitCount - baseline, 10)
    }
}
