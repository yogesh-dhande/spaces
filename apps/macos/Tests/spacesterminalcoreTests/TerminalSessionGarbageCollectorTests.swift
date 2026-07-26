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

    /// A fixed reference instant, close to the seeded session timestamps, so age-sensitive assertions do
    /// not drift with the wall clock. Whole-second ISO8601 matches the format `TerminalSessionTimestamp`
    /// writes for `exitedAt`.
    private static let referenceNow = ISO8601DateFormatter().date(from: "2026-07-19T12:00:00Z")!
    private let now = TerminalSessionGarbageCollectorTests.referenceNow

    /// Renders a whole-second ISO8601 stamp the way the runtime writes `exitedAt`, for age-relative seeds.
    private func iso(_ date: Date) -> String { TerminalSessionTimestamp.string(from: date) }

    /// The persisted final-render payload a seeded session carries. `padding` inflates the encoded JSON so
    /// a test can size the retention budget against the bytes the row actually holds; the test measures the
    /// same value by encoding this payload itself, so the budget never depends on JSON overhead guesses.
    private func remoteStatePayload(id: String, padding: Int) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: id, reason: "final", emittedAt: "2026-07-19T00:00:01Z", sessionStateRevision: nil, sessionStateFlags: nil,
            screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: String(repeating: "x", count: padding),
            workingDirectory: root.path, outputByteCount: 10)
    }

    @discardableResult private func seedSession(
        id: String, state: TerminalSessionState, servicePID: Int32, attachment: Bool = false, remoteState: Bool = false, remoteStatePadding: Int = 1,
        exitedAt: String? = "2026-07-19T00:00:01Z", rootDirectory: String? = nil
    ) throws -> TerminalSessionPaths {
        let paths = try rootDirectory.map { TerminalSessionPaths(rootDirectory: $0) } ?? TerminalSessionPaths.forSession(id: id)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: id, title: "T", workingDirectory: root.path, shell: "/bin/zsh", command: nil, createdAt: "2026-07-19T00:00:00Z",
                workspaceID: "ws", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: id, backend: .ghosttyEmbedded, servicePID: servicePID, childPID: nil, state: state, updatedAt: "2026-07-19T00:00:00Z",
                exitedAt: state.isInteractive ? nil : exitedAt), paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: Data("transcript".utf8))
        if attachment {
            let client = TerminalClient(
                id: "client-\(id)", kind: .localWindow, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-07-19T00:00:00Z")
            let attach = TerminalAttachment(sessionID: id, clientID: client.id, mode: .owner, attachedAt: "2026-07-19T00:00:00Z")
            try TerminalSessionPersistence.writeAttachmentSnapshot(
                TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attach]), paths: paths)
        }
        if remoteState {
            try TerminalSessionPersistence.writeRemoteSessionState(remoteStatePayload(id: id, padding: remoteStatePadding), paths: paths)
        }
        return paths
    }

    /// The tier-1 harness: sessions are either released-then-purged outright (unreferenced, not shown) or
    /// kept. These fixtures are never old enough to age-expire and never large enough to trip the budget, so
    /// any release the injected `releaseExpiredReferences` sees is a tier-1 call; the default is a no-op so
    /// tests that don't care about the release call don't need to stub it. Tests that must assert a release
    /// was (or was not) called, or that a release failure is contained, pass an explicit closure.
    private func collect(
        active: Set<String> = [], referenced: Set<String> = [], fileManager: FileManager = .default,
        release: @escaping (String) throws -> Void = { _ in }, onPurgeFailure: (String, any Error) -> Void = { _, _ in }
    ) throws -> [String] {
        try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: active, isReferencedByProduct: { referenced.contains($0) }, releaseExpiredReferences: release, fileManager: fileManager,
            now: now, onPurgeFailure: onPurgeFailure, onBudgetExceeded: { XCTFail("onBudgetExceeded called unexpectedly with \($0)") })
    }

    /// Stands in for a `removeItem` failure (e.g. a permissions error or a busy file handle) so purge
    /// retryability can be tested without relying on the real filesystem to reject a delete. Everything
    /// else (fileExists, createDirectory, ...) falls back to the real `FileManager` behavior via `super`.
    /// `failingSessionID` narrows the failure to one session's directory (matched by substring on the
    /// runtime-scoped path) so a sweep containing multiple collectable sessions can exercise "only the
    /// targeted purge fails"; `nil` fails every removal, as every prior caller of this class relies on.
    private final class RemoveItemThrowingFileManager: FileManager {
        struct RemovalFailure: Error {}
        private let failingSessionID: String?

        init(failingSessionID: String? = nil) {
            self.failingSessionID = failingSessionID
            super.init()
        }

        override func removeItem(atPath path: String) throws {
            if let failingSessionID, !path.contains(failingSessionID) {
                try super.removeItem(atPath: path)
                return
            }
            throw RemovalFailure()
        }
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

    // (P2, tier 1) A tier-1 purge (ended, not shown, unreferenced) must still retire the session's own
    // subscriber standing before deleting it: a plain shell/process terminal that subscribed to agents has
    // queued inbound notices and outgoing agent_subscriptions/agent_remote_subscriptions watch edges that
    // have no foreign key to terminal_sessions and are not counted by isReferencedByProduct, so tier 1 must
    // not depend on an interactive close having already retired them.
    func testTier1PurgeReleasesReferencesBeforePurging() throws {
        let paths = try seedSession(id: "ended", state: .exited, servicePID: 999_999)
        var released: [String] = []

        let purged = try collect(release: { released.append($0) })

        XCTAssertEqual(released, ["ended"], "Tier 1 must release the session's own subscriber standing even though it has no product reference.")
        XCTAssertEqual(purged, ["ended"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // (P2, tier 1 containment) A releaseExpiredReferences failure for a tier-1 session must not be treated
    // as a purge: it is contained to that session, reported through onPurgeFailure, and left for the next
    // sweep (fail closed), while other unreferenced sessions in the same sweep still collect.
    func testTier1ReleaseFailureIsContainedAndOtherSessionsStillProcessed() throws {
        _ = try seedSession(id: "a-fails", state: .exited, servicePID: 999_999)
        let cleanPaths = try seedSession(id: "b-clean", state: .exited, servicePID: 999_998)
        var failures: [String] = []

        let purged = try collect(
            release: { sessionID in if sessionID == "a-fails" { throw ReleaseFailure() } },
            onPurgeFailure: { sessionID, _ in failures.append(sessionID) })

        XCTAssertEqual(purged, ["b-clean"], "A contained tier-1 release failure must not stop the remaining unreferenced sessions.")
        XCTAssertEqual(failures, ["a-fails"], "The release failure must be reported so the daemon can log it.")
        XCTAssertEqual(
            try TerminalSessionPersistence.listKnownSessions().map(\.sessionID), ["a-fails"],
            "The failed session's row must remain for the next sweep; the purged session's row must be gone.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try TerminalSessionPaths.forSession(id: "a-fails").rootDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanPaths.rootDirectory))
    }

    // (c) A live, interactive session is still shown and must be left untouched.
    func testKeepsLiveInteractiveSession() throws {
        let paths = try seedSession(id: "live", state: .running, servicePID: getpid())

        let purged = try collect()

        XCTAssertTrue(purged.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rootDirectory))
        XCTAssertNoThrow(try TerminalSessionPersistence.readRuntimeState(paths: paths))
    }

    // (c) Tier 1: an ended session carrying only a stale local-window attachment (a crash leftover — the
    // exit path detaches every client, and the ended-pane viewer holds no attachment) is not "shown", so an
    // unreferenced one is collected like any other. A surviving attachment must not pin an ended session.
    func testCollectsEndedSessionWithStaleAttachment() throws {
        let paths = try seedSession(id: "attached", state: .exited, servicePID: 999_999, attachment: true)

        let purged = try collect()

        XCTAssertEqual(purged, ["attached"], "A stale attachment must not keep an ended, unreferenced session from being collected.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rootDirectory))
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

    // (P2) A failed attachment read must fail closed for an interactive session whose service is momentarily
    // dead (the daemon-crash/handoff window): an unreadable attachment snapshot must not be mistaken for "no
    // attachments", or a session a client still holds through a daemon restart could be purged out from under
    // it. The state is interactive (`.running`) with a dead servicePID, so the service is not alive and the
    // decision falls to the attachment read, which throws on the corrupt database.
    func testIsSessionShownFailsClosedWhenAttachmentReadThrows() throws {
        let paths = try seedSession(id: "corrupt-attachments", state: .running, servicePID: 999_999)
        // Corrupt the profile database so the live-attachments query throws instead of returning rows.
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: root.appendingPathComponent("spaces.db").path))
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: "corrupt-attachments", backend: .ghosttyEmbedded, servicePID: 999_999, childPID: nil, state: .running,
            updatedAt: "2026-07-19T00:00:00Z", exitedAt: nil)

        XCTAssertTrue(
            TerminalSessionGarbageCollector.isSessionShown(runtimeState: runtimeState, paths: paths, now: now),
            "An attachment read failure must fail closed and keep an interactive session shown, not be treated as no attachments.")
    }

    // (P2, ended sessions ignore attachments) An ended session never consults attachments: its exit path
    // detached every client, so a surviving attachment row is a crash leftover and must not read as "shown".
    // A corrupt attachment database would fail closed for an interactive session, but for an ended one the
    // read is skipped entirely, so it must read as not shown.
    func testIsSessionShownIgnoresAttachmentsForEndedSession() throws {
        let paths = try seedSession(id: "corrupt-attachments", state: .exited, servicePID: 999_999)
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: root.appendingPathComponent("spaces.db").path))
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: "corrupt-attachments", backend: .ghosttyEmbedded, servicePID: 999_999, childPID: nil, state: .exited,
            updatedAt: "2026-07-19T00:00:00Z", exitedAt: "2026-07-19T00:00:01Z")

        XCTAssertFalse(
            TerminalSessionGarbageCollector.isSessionShown(runtimeState: runtimeState, paths: paths, now: now),
            "An ended session must not consult attachments; a surviving attachment row is a crash leftover, not a live viewer.")
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
    // session from the next sweep, and the next sweep must finish the purge it left behind. The failure is
    // contained (the sweep does not throw) and reported to the caller so it can be logged; per the daemon
    // call site, the collector never performs the logging I/O itself.
    func testCollectRemovedSessionsRetriesPurgeAfterDirectoryRemovalFailure() throws {
        _ = try seedSession(id: "leaky", state: .exited, servicePID: 999_999)
        var failures: [String] = []

        let purged = try collect(fileManager: RemoveItemThrowingFileManager(), onPurgeFailure: { sessionID, _ in failures.append(sessionID) })

        XCTAssertTrue(purged.isEmpty, "A contained purge failure must not be reported as purged.")
        XCTAssertEqual(failures, ["leaky"], "The failure must be reported to the caller so it can be logged.")
        XCTAssertEqual(
            try TerminalSessionPersistence.listKnownSessions().map(\.sessionID), ["leaky"],
            "A removeItem failure must not drop the session's row, or the next sweep can never rediscover it.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try TerminalSessionPaths.forSession(id: "leaky").rootDirectory))

        let retried = try collect()
        XCTAssertEqual(retried, ["leaky"])
        XCTAssertTrue(try TerminalSessionPersistence.listKnownSessions().isEmpty)
    }

    // (P4) A single failing purge must not abort the whole sweep: the collector iterates sessions in a
    // stable order (`created_at`, then `session_id`), reruns every minute, and one permanently-undeletable
    // session (e.g. a permissions error) must not block collection of every session ordered after it
    // forever. "a-leaky" sorts before "b-clean" so it is purged first in sweep order.
    func testCollectContainsOnePurgeFailureAndStillPurgesRemainingSessions() throws {
        _ = try seedSession(id: "a-leaky", state: .exited, servicePID: 999_999)
        let cleanPaths = try seedSession(id: "b-clean", state: .exited, servicePID: 999_998)
        var failures: [String] = []

        let purged = try collect(
            fileManager: RemoveItemThrowingFileManager(failingSessionID: "a-leaky"), onPurgeFailure: { sessionID, _ in failures.append(sessionID) })

        XCTAssertEqual(purged, ["b-clean"], "The sweep must continue past the failed session and purge the rest.")
        XCTAssertEqual(failures, ["a-leaky"])
        XCTAssertEqual(
            try TerminalSessionPersistence.listKnownSessions().map(\.sessionID), ["a-leaky"],
            "The failed session's row must remain for retry; the purged session's row must be gone.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try TerminalSessionPaths.forSession(id: "a-leaky").rootDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanPaths.rootDirectory))

        // The next sweep, with a working FileManager, retries and completes the deferred purge.
        let retried = try collect()
        XCTAssertEqual(retried, ["a-leaky"])
        XCTAssertTrue(try TerminalSessionPersistence.listKnownSessions().isEmpty)
    }

    // A struct error stand-in so a `releaseExpiredReferences` failure can be exercised deterministically.
    private struct ReleaseFailure: Error {}

    // Tier 2 (age): a referenced ended session whose end is exactly at the 7-day boundary expires — its
    // product rows are released and, once that clears the last reference, its footprint is purged. The
    // 7-day clock is the session's own end time (`exitedAt`).
    func testEndedSessionExpiresAtSevenDayBoundary() throws {
        let paths = try seedSession(id: "old", state: .exited, servicePID: 999_999, exitedAt: iso(now.addingTimeInterval(-7 * 86_400)))
        var referenced: Set<String> = ["old"]
        var released: [String] = []

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { referenced.contains($0) },
            releaseExpiredReferences: {
                released.append($0)
                referenced.remove($0)
            }, now: now)

        XCTAssertEqual(released, ["old"], "An ended session at the age limit must have its product rows released.")
        XCTAssertEqual(purged, ["old"], "Once the release clears the last reference the session must be purged.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // Tier 2 (age): a referenced ended session that ended 6d23h ago is inside the retention window, so it
    // must not be released or purged.
    func testEndedSessionYoungerThanMaxAgeDoesNotExpire() throws {
        let paths = try seedSession(id: "young", state: .exited, servicePID: 999_999, exitedAt: iso(now.addingTimeInterval(-(7 * 86_400 - 3_600))))

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { _ in true },
            releaseExpiredReferences: { XCTFail("release called for a session inside the retention window: \($0)") }, now: now)

        XCTAssertTrue(purged.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // Tier 2 (age): when `exitedAt` is absent, the end time falls back to the newest of the directory and
    // `output.log` modification times. The seeded files are stamped ~now, so a sweep dated eight days later
    // sees them as past the age limit and expires the session.
    func testEndedSessionExpiresViaModificationTimeFallbackWhenExitedAtMissing() throws {
        let paths = try seedSession(id: "nostamp", state: .exited, servicePID: 999_999, exitedAt: nil)
        var referenced: Set<String> = ["nostamp"]
        var released: [String] = []

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { referenced.contains($0) },
            releaseExpiredReferences: {
                released.append($0)
                referenced.remove($0)
            }, now: Date().addingTimeInterval(8 * 86_400))

        XCTAssertEqual(released, ["nostamp"], "A missing exitedAt must fall back to file mtime to drive expiry.")
        XCTAssertEqual(purged, ["nostamp"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // Tier 2 (age): a stale local-window attachment left on an ended session by an ungraceful kill of the app
    // or daemon (SIGKILL/crash/power loss) must not exempt it from age expiry. The exit path detaches every
    // client, so an attachment surviving on an ended session is a crash leftover, not a live viewer; a session
    // referenced by a product row and past the age limit is released and purged like any other, regardless of
    // the leftover attachment. (Local-window attachments have no lease, so before the shown gate excluded
    // ended sessions this session read as "shown" forever and was never collected — the retention regression.)
    func testEndedSessionWithStaleAttachmentPastMaxAgeIsPurged() throws {
        let paths = try seedSession(
            id: "stale-attached", state: .exited, servicePID: 999_999, attachment: true, exitedAt: iso(now.addingTimeInterval(-8 * 86_400)))
        var referenced: Set<String> = ["stale-attached"]
        var released: [String] = []

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { referenced.contains($0) },
            releaseExpiredReferences: {
                released.append($0)
                referenced.remove($0)
            }, now: now, onBudgetExceeded: { XCTFail("onBudgetExceeded called unexpectedly with \($0)") })

        XCTAssertEqual(released, ["stale-attached"], "A stale attachment must not keep an expired ended session's product rows from being released.")
        XCTAssertEqual(purged, ["stale-attached"], "An expired ended session with only a crash-leftover attachment must be purged by the age tier.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // Tier 2 (containment): a `releaseExpiredReferences` failure for one expired session must be contained
    // to that session — reported through `onPurgeFailure` — while the remaining expired sessions still
    // release and purge. "a-fails" sorts before "b-clean", so it is processed first.
    func testReleaseFailureIsContainedAndOtherSessionsStillProcessed() throws {
        let expiredAt = iso(now.addingTimeInterval(-8 * 86_400))
        _ = try seedSession(id: "a-fails", state: .exited, servicePID: 999_999, exitedAt: expiredAt)
        let cleanPaths = try seedSession(id: "b-clean", state: .exited, servicePID: 999_998, exitedAt: expiredAt)
        var referenced: Set<String> = ["a-fails", "b-clean"]
        var failures: [String] = []

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { referenced.contains($0) },
            releaseExpiredReferences: { sessionID in
                if sessionID == "a-fails" { throw ReleaseFailure() }
                referenced.remove(sessionID)
            }, now: now, onPurgeFailure: { sessionID, _ in failures.append(sessionID) })

        XCTAssertEqual(purged, ["b-clean"], "A contained release failure must not stop the remaining expired sessions.")
        XCTAssertEqual(failures, ["a-fails"], "The release failure must be reported so the daemon can log it.")
        XCTAssertEqual(
            try TerminalSessionPersistence.listKnownSessions().map(\.sessionID), ["a-fails"],
            "The failed session's row must remain for the next sweep; the purged session's row must be gone.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanPaths.rootDirectory))
    }

    // Tier 2 (fail closed): if the release runs but a reference survives, nothing is purged and no error is
    // raised — the session is left for the next sweep.
    func testReleaseThatDoesNotClearReferenceLeavesSessionForNextSweep() throws {
        let paths = try seedSession(id: "sticky", state: .exited, servicePID: 999_999, exitedAt: iso(now.addingTimeInterval(-8 * 86_400)))
        var released: [String] = []

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { _ in true }, releaseExpiredReferences: { released.append($0) }, now: now)

        XCTAssertEqual(released, ["sticky"], "The release must be attempted for an expired session.")
        XCTAssertTrue(purged.isEmpty, "A reference surviving the release must leave the session intact (fail closed).")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rootDirectory))
    }

    // Tier 3 (budget): three referenced ended sessions younger than the age limit exceed the byte budget.
    // Eviction must proceed oldest-ended-first and stop as soon as the total drops back under budget, so
    // only the oldest is released and purged.
    func testByteBudgetEvictsOldestEndedFirstUntilUnderBudget() throws {
        let policy = TerminalSessionRetentionPolicy(endedSessionMaxAge: 7 * 86_400, endedTranscriptByteBudget: 2_500, orphanGracePeriod: 3_600)
        let oldPaths = try seedSession(id: "old", state: .exited, servicePID: 999_999, exitedAt: iso(now.addingTimeInterval(-3 * 86_400)))
        let midPaths = try seedSession(id: "mid", state: .exited, servicePID: 999_998, exitedAt: iso(now.addingTimeInterval(-2 * 86_400)))
        let newPaths = try seedSession(id: "new", state: .exited, servicePID: 999_997, exitedAt: iso(now.addingTimeInterval(-1 * 86_400)))
        for paths in [oldPaths, midPaths, newPaths] { try Data(repeating: 0, count: 1_000).write(to: URL(fileURLWithPath: paths.outputPath)) }
        var referenced: Set<String> = ["old", "mid", "new"]
        var released: [String] = []

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { referenced.contains($0) },
            releaseExpiredReferences: {
                released.append($0)
                referenced.remove($0)
            }, retentionPolicy: policy, now: now,
            onBudgetExceeded: { XCTFail("total should be back under budget after evicting the oldest, got \($0)") })

        XCTAssertEqual(purged, ["old"], "Only the oldest ended session is evicted once the total drops under budget.")
        XCTAssertEqual(released, ["old"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPaths.rootDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: midPaths.rootDirectory), "Younger sessions must survive once under budget.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPaths.rootDirectory))
    }

    // Tier 3 (budget): a stale local-window attachment left by an ungraceful kill does not protect an ended
    // session from byte-budget eviction. An attachment surviving on an ended session is a crash leftover (the
    // exit path detaches all clients), so these sessions are ordinary eviction candidates and are evicted
    // oldest-ended-first exactly as unattached ended sessions are.
    func testByteBudgetEvictsEndedSessionsWithStaleAttachments() throws {
        let policy = TerminalSessionRetentionPolicy(endedSessionMaxAge: 7 * 86_400, endedTranscriptByteBudget: 2_500, orphanGracePeriod: 3_600)
        let oldPaths = try seedSession(
            id: "old", state: .exited, servicePID: 999_999, attachment: true, exitedAt: iso(now.addingTimeInterval(-3 * 86_400)))
        let midPaths = try seedSession(
            id: "mid", state: .exited, servicePID: 999_998, attachment: true, exitedAt: iso(now.addingTimeInterval(-2 * 86_400)))
        let newPaths = try seedSession(
            id: "new", state: .exited, servicePID: 999_997, attachment: true, exitedAt: iso(now.addingTimeInterval(-1 * 86_400)))
        for paths in [oldPaths, midPaths, newPaths] { try Data(repeating: 0, count: 1_000).write(to: URL(fileURLWithPath: paths.outputPath)) }
        var referenced: Set<String> = ["old", "mid", "new"]
        var released: [String] = []

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { referenced.contains($0) },
            releaseExpiredReferences: {
                released.append($0)
                referenced.remove($0)
            }, retentionPolicy: policy, now: now,
            onBudgetExceeded: { XCTFail("total should be back under budget after evicting the oldest, got \($0)") })

        XCTAssertEqual(purged, ["old"], "A stale local-window attachment must not protect an ended session from budget eviction.")
        XCTAssertEqual(released, ["old"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPaths.rootDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: midPaths.rootDirectory), "Younger sessions must survive once under budget.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPaths.rootDirectory))
    }

    // A session whose row stores a root this profile does not own — a runtime directory that moved, or rows
    // a predecessor daemon left behind — must still be collectable. The sweep reads each session through
    // its stored root, so the phantom `running` row (dead pid, so not shown) and every row keyed to that
    // root are reclaimed on the first sweep instead of being skipped forever.
    func testCollectsSessionWhoseStoredRootIsOutsideTheProfile() throws {
        let foreignRoot = root.appendingPathComponent("foreign-runtime", isDirectory: true).appendingPathComponent("stray", isDirectory: true)
        let paths = try seedSession(
            id: "stray", state: .running, servicePID: 999_999, remoteState: true, exitedAt: nil, rootDirectory: foreignRoot.path)

        let purged = try collect()

        XCTAssertEqual(purged, ["stray"])
        XCTAssertTrue(try TerminalSessionPersistence.listKnownSessions().isEmpty, "terminal_sessions row must be reclaimed.")
        XCTAssertThrowsError(try TerminalSessionPersistence.readRuntimeState(paths: paths), "Runtime row must be reclaimed.")
        XCTAssertThrowsError(try TerminalSessionPersistence.readRemoteSessionState(paths: paths), "Final-render row must be reclaimed.")
    }

    // The stored root is trusted for identity but never for deletion: a row naming a directory outside the
    // profile is reclaimed rows-only, so a garbage-collection sweep can never delete a user directory that
    // a stale or mis-keyed row happens to point at.
    func testPurgingAForeignRootNeverTouchesTheFilesystemOutsideTheProfile() throws {
        let foreignRoot = root.appendingPathComponent("foreign-runtime", isDirectory: true).appendingPathComponent("stray", isDirectory: true)
        _ = try seedSession(id: "stray", state: .exited, servicePID: 999_999, remoteState: true, rootDirectory: foreignRoot.path)
        let sentinel = foreignRoot.appendingPathComponent("keep-me.txt")
        try Data("user data".utf8).write(to: sentinel)

        let purged = try collect()

        XCTAssertEqual(purged, ["stray"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignRoot.path), "A root outside the profile must never be removed.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path), "Nothing under a root outside the profile may be removed.")
        XCTAssertTrue(try TerminalSessionPersistence.listKnownSessions().isEmpty, "The rows must still be reclaimed.")
    }

    // A row naming a root that no longer exists on disk is reclaimed rows-only too: nothing is created to
    // delete, and the sweep must not stall on the missing directory.
    func testCollectsSessionWhoseStoredRootNoLongerExists() throws {
        let vanishedRoot = root.appendingPathComponent("foreign-runtime", isDirectory: true).appendingPathComponent("vanished", isDirectory: true)
        _ = try seedSession(id: "vanished", state: .exited, servicePID: 999_999, remoteState: true, rootDirectory: vanishedRoot.path)
        try FileManager.default.removeItem(at: vanishedRoot)

        let purged = try collect()

        XCTAssertEqual(purged, ["vanished"])
        XCTAssertTrue(try TerminalSessionPersistence.listKnownSessions().isEmpty)
    }

    // Tier 3 (budget): an ended session's footprint accumulates in the profile database, not under its
    // directory — the directory holds a few bytes of transcript once the process is gone while the
    // persisted final-render row holds a full grid snapshot. The budget must weigh those bytes, or it
    // measures a quantity that does not grow and can never fire. The budget here is sized from the exact
    // encoded payload, so only the oldest is evicted before the total drops back under it.
    func testByteBudgetWeighsPersistedFinalRenderPayload() throws {
        let padding = 4_000
        let payloadBytes = try JSONEncoder().encode(remoteStatePayload(id: "old", padding: padding)).count
        let policy = TerminalSessionRetentionPolicy(
            endedSessionMaxAge: 7 * 86_400, endedTranscriptByteBudget: Int64(2 * payloadBytes + 1_000), orphanGracePeriod: 3_600)
        for (id, daysAgo) in [("old", 3), ("mid", 2), ("new", 1)] {
            _ = try seedSession(
                id: id, state: .exited, servicePID: 999_999, remoteState: true, remoteStatePadding: padding,
                exitedAt: iso(now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400)))
        }
        var referenced: Set<String> = ["old", "mid", "new"]
        var released: [String] = []

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { referenced.contains($0) },
            releaseExpiredReferences: {
                released.append($0)
                referenced.remove($0)
            }, retentionPolicy: policy, now: now,
            onBudgetExceeded: { XCTFail("total should be back under budget after evicting the oldest, got \($0)") })

        XCTAssertEqual(purged, ["old"], "The oldest ended session must be evicted once the persisted payload bytes are counted.")
        XCTAssertEqual(released, ["old"])
        XCTAssertEqual(Set(try TerminalSessionPersistence.listKnownSessions().map(\.sessionID)), ["mid", "new"])
    }

    // First sweep after deploy: a whole backlog of expired sessions is released and purged in one pass, with
    // no rate limiting.
    func testBacklogOfExpiredSessionsAllReleasedAndPurgedInOnePass() throws {
        let expiredAt = iso(now.addingTimeInterval(-8 * 86_400))
        let ids = (0..<12).map { "backlog-\(String(format: "%02d", $0))" }
        for id in ids { _ = try seedSession(id: id, state: .exited, servicePID: 999_999, exitedAt: expiredAt) }
        var referenced = Set(ids)
        var released: [String] = []

        let purged = try TerminalSessionGarbageCollector.collectRemovedSessions(
            activeSessionIDs: [], isReferencedByProduct: { referenced.contains($0) },
            releaseExpiredReferences: {
                released.append($0)
                referenced.remove($0)
            }, now: now)

        XCTAssertEqual(Set(purged), Set(ids), "Every expired session must be purged in the same sweep.")
        XCTAssertEqual(Set(released), Set(ids))
        XCTAssertTrue(try TerminalSessionPersistence.listKnownSessions().isEmpty)
    }
}
