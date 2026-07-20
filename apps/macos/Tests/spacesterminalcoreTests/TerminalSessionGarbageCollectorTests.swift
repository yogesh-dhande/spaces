import Foundation
import XCTest

@testable import spacesterminalcore

/// Validates the daemon-owned garbage collector that reclaims sessions the product no longer shows:
/// it must delete an ended, unattached, unreferenced session's directory and every persisted row, and it
/// must never touch a session the product still shows (live, still-attached ended pane, or still
/// referenced by a product row).
final class TerminalSessionGarbageCollectorTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private let now = Date()

    @discardableResult
    private func seedSession(
        id: String, state: TerminalSessionState, servicePID: Int32, attachment: Bool = false, remoteState: Bool = false
    ) throws -> TerminalSessionPaths {
        let paths = try TerminalSessionPaths.forSession(id: id)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: id, title: "T", workingDirectory: root.path, shell: "/bin/zsh", command: nil, createdAt: "2026-07-19T00:00:00Z",
                workspaceID: "ws", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: id, backend: .ghosttyEmbedded, servicePID: servicePID, childPID: nil, state: state, updatedAt: "2026-07-19T00:00:00Z",
                exitedAt: state.isInteractive ? nil : "2026-07-19T00:00:01Z"), paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: Data("transcript".utf8))
        if attachment {
            let client = TerminalClient(id: "client-\(id)", kind: .localWindow, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-07-19T00:00:00Z")
            let attach = TerminalAttachment(sessionID: id, clientID: client.id, mode: .owner, attachedAt: "2026-07-19T00:00:00Z")
            try TerminalSessionPersistence.writeAttachmentSnapshot(
                TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attach]), paths: paths)
        }
        if remoteState {
            let payload = GhosttyRemoteSessionStatePayload(
                sessionID: id, reason: "final", emittedAt: "2026-07-19T00:00:01Z", sessionStateRevision: nil, sessionStateFlags: nil,
                screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: "T", workingDirectory: root.path, outputByteCount: 10)
            try TerminalSessionPersistence.writeRemoteSessionState(payload, paths: paths)
        }
        return paths
    }

    private func collect(active: Set<String> = [], referenced: Set<String> = [], fileManager: FileManager = .default) throws -> [String] {
        try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: active, isReferencedByProduct: { referenced.contains($0) }, fileManager: fileManager, now: now)
    }

    /// Stands in for a `removeItem` failure (e.g. a permissions error or a busy file handle) so purge
    /// retryability can be tested without relying on the real filesystem to reject a delete. Everything
    /// else (fileExists, createDirectory, ...) falls back to the real `FileManager` behavior via `super`.
    private final class RemoveItemThrowingFileManager: FileManager {
        struct RemovalFailure: Error {}
        override func removeItem(atPath path: String) throws { throw RemovalFailure() }
    }

    // (b) Removal deletes the dir and prunes every persisted row, including the final-render state row.
    func testCollectsEndedUnattachedUnreferencedSession() throws {
        let paths = try seedSession(id: "ended", state: .exited, servicePID: 999_999, remoteState: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rootDirectory))

        let purged = try collect()

        XCTAssertEqual(purged, ["ended"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rootDirectory), "Session directory must be removed.")
        XCTAssertThrowsError(try TerminalSessionPersistence.readRuntimeState(paths: paths), "Runtime row must be pruned.")
        XCTAssertThrowsError(try TerminalSessionPersistence.readRemoteSessionState(paths: paths), "Final-render row must be pruned.")
        XCTAssertTrue(try TerminalSessionPersistence.listKnownSessions().isEmpty, "terminal_sessions row must be pruned.")
    }

    // (c) A live, interactive session is still shown and must be left untouched.
    func testKeepsLiveInteractiveSession() throws {
        let paths = try seedSession(id: "live", state: .running, servicePID: getpid())

        let purged = try collect()

        XCTAssertTrue(purged.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rootDirectory))
        XCTAssertNoThrow(try TerminalSessionPersistence.readRuntimeState(paths: paths))
    }

    // (c) An ended session whose pane a client still holds (live attachment) must keep its transcript.
    func testKeepsEndedSessionWithLiveAttachment() throws {
        let paths = try seedSession(id: "attached", state: .exited, servicePID: 999_999, attachment: true)

        let purged = try collect()

        XCTAssertTrue(purged.isEmpty, "A still-attached ended pane must not be collected.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // (c) An ended session still referenced by a product row (exited process/agent) must be kept.
    func testKeepsReferencedEndedSession() throws {
        let paths = try seedSession(id: "referenced", state: .exited, servicePID: 999_999)

        let purged = try collect(referenced: ["referenced"])

        XCTAssertTrue(purged.isEmpty, "A session the product still surfaces must not be collected.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // A session the daemon still owns in memory is never collected, even if it looks ended on disk.
    func testKeepsActiveInMemorySession() throws {
        let paths = try seedSession(id: "inmemory", state: .exited, servicePID: 999_999)

        let purged = try collect(active: ["inmemory"])

        XCTAssertTrue(purged.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // A mixed batch collects only the removed session and leaves the others intact.
    func testCollectsOnlyRemovedSessionsInMixedBatch() throws {
        _ = try seedSession(id: "gone", state: .exited, servicePID: 999_999)
        _ = try seedSession(id: "alive", state: .running, servicePID: getpid())
        _ = try seedSession(id: "kept-ref", state: .failed, servicePID: 999_999)

        let purged = try collect(referenced: ["kept-ref"])

        XCTAssertEqual(purged, ["gone"])
        XCTAssertEqual(Set(try TerminalSessionPersistence.listKnownSessions().map(\.sessionID)), ["alive", "kept-ref"])
    }

    // (P2) A failed attachment read must fail closed: an unreadable attachment snapshot must not be
    // mistaken for "no attachments", or a session an active viewer holds could be purged out from under it.
    func testIsSessionShownFailsClosedWhenAttachmentReadThrows() throws {
        let paths = try seedSession(id: "corrupt-attachments", state: .exited, servicePID: 999_999)
        // Corrupt the profile database so the live-attachments query throws instead of returning rows.
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: root.appendingPathComponent("spaces.db").path))
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: "corrupt-attachments", backend: .ghosttyEmbedded, servicePID: 999_999, childPID: nil, state: .exited,
            updatedAt: "2026-07-19T00:00:00Z", exitedAt: "2026-07-19T00:00:01Z")

        XCTAssertTrue(
            TerminalSessionGarbageCollector.isSessionShown(runtimeState: runtimeState, paths: paths, now: now),
            "An attachment read failure must fail closed and keep the session shown, not be treated as no attachments.")
    }

    // (P3) A `removeItem` failure must leave the DB rows intact so the whole purge is retried on the next
    // sweep, instead of orphaning the directory with no row left to rediscover it.
    func testPurgeSessionKeepsRowsWhenDirectoryRemovalFails() throws {
        let paths = try seedSession(id: "leaky", state: .exited, servicePID: 999_999)

        XCTAssertThrowsError(try TerminalSessionPersistence.purgeSession(paths: paths, fileManager: RemoveItemThrowingFileManager()))

        XCTAssertEqual(try TerminalSessionPersistence.listKnownSessions().map(\.sessionID), ["leaky"], "Rows must survive a failed removeItem.")
        XCTAssertNoThrow(try TerminalSessionPersistence.readRuntimeState(paths: paths), "Runtime row must survive a failed removeItem.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rootDirectory))

        // The next sweep, with a working FileManager, retries and completes the purge.
        try TerminalSessionPersistence.purgeSession(paths: paths, fileManager: .default)
        XCTAssertTrue(try TerminalSessionPersistence.listKnownSessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // (P3) Same guarantee through the collector's own entry point: a removeItem failure must not drop the
    // session from the next sweep, and the next sweep must finish the purge it left behind.
    func testCollectRemovedSessionsRetriesPurgeAfterDirectoryRemovalFailure() throws {
        _ = try seedSession(id: "leaky", state: .exited, servicePID: 999_999)

        XCTAssertThrowsError(try collect(fileManager: RemoveItemThrowingFileManager()))
        XCTAssertEqual(
            try TerminalSessionPersistence.listKnownSessions().map(\.sessionID), ["leaky"],
            "A removeItem failure must not drop the session's row, or the next sweep can never rediscover it.")

        let purged = try collect()
        XCTAssertEqual(purged, ["leaky"])
        XCTAssertTrue(try TerminalSessionPersistence.listKnownSessions().isEmpty)
    }
}
