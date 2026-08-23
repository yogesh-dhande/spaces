import Foundation
import XCTest
import spacesterminalcore
import workspacecore

@testable import spacesd

/// The daemon's foreground-agent reconciler holds one database connection for its whole run, so
/// stopping it is what releases that connection and takes its final WAL checkpoint. These cover the
/// stop contract: a stopped reconciler does no more database work and leaves no connection behind,
/// however late the notification that reaches it. That matters because `spacesd` re-execs itself to
/// apply an update, and a connection a stopped reconciler re-opened would still be holding the
/// database when the replacement daemon starts.
final class TerminalForegroundAgentReconcilerTests: XCTestCase {
    private var directory: URL!
    private var databasePath: String!
    private var previousRuntimeDirectory: String?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foreground-agent-reconciler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("spaces.db").path

        // Point the reconciler's live-session lookup at an empty runtime directory so its passes see
        // no terminal sessions from whatever else is running on this machine.
        previousRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        setenv("SPACES_RUNTIME_DIR", directory.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let previousRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", previousRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        previousRuntimeDirectory = nil
        if let directory, FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        directory = nil
        databasePath = nil
    }

    /// Starting runs a pass without waiting for a notification. Sessions that died while the daemon was
    /// down post no runtime-state change on the way back up, so their agent rows are finalized by this
    /// startup pass or not at all.
    @MainActor func testStartRunsAPassWithoutWaitingForANotification() async throws {
        let reconciler = TerminalForegroundAgentReconciler(databasePath: databasePath)
        reconciler.start()
        addTeardownBlock { @MainActor in
            reconciler.beginStop()
            await reconciler.releaseStore()
        }

        try await settle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: databasePath), "Starting must run a pass, which opens the database.")
    }

    /// A runtime-state notification posted just before the stop is delivered after it — removing the
    /// observer does not unqueue a delivery already on its way — and the reconcile it triggers has
    /// certainly not run a pass yet. Nothing it triggers may reach the database: one this reconciler
    /// never touched before stopping must still be untouched afterwards.
    @MainActor func testAReconcileTriggeredAcrossTheStopDoesNoDatabaseWork() async throws {
        let reconciler = TerminalForegroundAgentReconciler(databasePath: databasePath)
        reconciler.start()
        NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil)
        reconciler.beginStop()
        await reconciler.releaseStore()

        try await settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath), "A reconcile triggered across the stop must not run.")
    }

    /// Runtime-state notifications keep arriving while the daemon shuts its services down, and must
    /// not restart the loop.
    @MainActor func testNotificationsAfterStopDoNoDatabaseWork() async throws {
        let reconciler = TerminalForegroundAgentReconciler(databasePath: databasePath)
        reconciler.start()
        reconciler.beginStop()
        await reconciler.releaseStore()

        for _ in 0..<50 { NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil) }
        try await settle()

        XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath), "A notification after stop must not open the database.")
    }

    /// Runtime state changes with terminal output, so a real stop lands mid-burst — one pass running
    /// and another already coalesced behind it. Once that settles, the connection those passes
    /// opened must be released and checkpointed.
    @MainActor func testStopDuringANotificationBurstReleasesTheConnection() async throws {
        let reconciler = TerminalForegroundAgentReconciler(databasePath: databasePath)
        reconciler.start()

        for _ in 0..<200 { NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil) }
        try await Task.sleep(nanoseconds: 20_000_000)
        for _ in 0..<200 { NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil) }
        reconciler.beginStop()
        await reconciler.releaseStore()

        XCTAssertTrue(FileManager.default.fileExists(atPath: databasePath), "The burst should have run passes before the stop.")
        // No settling first: `stop()` awaits the release, so returning from it is what establishes that the
        // connection those passes opened is gone. A poll here would hide a stop that did not wait.
        XCTAssertTrue(databaseIsCheckpointed(), "The connection those passes opened must be released at stop.")
    }

    /// Stopping before any notification arrives is an ordinary daemon shutdown, and stop can be
    /// reached twice (a service teardown and the shutdown sweep). Neither may trap or touch the
    /// database.
    @MainActor func testStopBeforeAnyPassAndRepeatedStopAreSafe() async throws {
        let reconciler = TerminalForegroundAgentReconciler(databasePath: databasePath)
        reconciler.start()
        reconciler.beginStop()
        await reconciler.releaseStore()
        reconciler.beginStop()
        await reconciler.releaseStore()

        try await settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))
    }

    /// SQLite runs a truncating checkpoint when the last connection to a database closes, so an
    /// empty `-wal` sidecar beside a database that passes did write through is the observable form
    /// of "the connection was released and its final checkpoint happened".
    private func databaseIsCheckpointed() -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: databasePath + "-wal")[.size] as? Int else { return true }
        return size == 0
    }
}

/// Lets everything a stop can leave in flight — a queued notification delivery, a committed
/// reconcile task, an in-flight pass, and the store's own close — run to completion before the
/// assertions look.
private func settle() async throws { try await Task.sleep(nanoseconds: 300_000_000) }
