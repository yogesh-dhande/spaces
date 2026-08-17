import Foundation
import Testing

@testable import spacesterminalcore

/// The in-memory attachment snapshot is what a session core enforces ownership from and broadcasts; the
/// database is a mirror it enqueues off the engine. That only holds while the two agree, so every mutation
/// here applies the SQL statement to a real profile database AND the matching in-memory transcription to the
/// snapshot read before it, then requires the two results to describe the same clients and attachments. A
/// transcription that drifts from its statement would let a session enforce ownership no reader can see.
///
/// Swift Testing (not XCTest) so the suite runs in the Linux daemon lane, where the headless core relies on
/// the same transcriptions. Every persistence call passes this suite's own throwaway database path explicitly,
/// so the suite never touches the process-wide SPACES_* environment and is safe to run in parallel with
/// sibling suites.
@Suite final class TerminalSessionAttachmentSnapshotMutationsTests {
    private let databaseRoot: URL
    private let databasePath: String

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        databasePath = root.appendingPathComponent("spaces.db").path
    }

    deinit {
        try? FileManager.default.removeItem(at: databaseRoot)
    }

    // MARK: - Fixtures

    private static let localOwner = TerminalClient(
        id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-07-21T00:00:00Z")
    private static let remoteViewer = TerminalClient(
        id: "remote-iphone", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-07-21T00:00:01Z")

    /// A session with the local window attached as owner and the remote viewer attached as viewer — the
    /// shape every ownership mutation below starts from.
    private func makeAttachedSession() throws -> (paths: TerminalSessionPaths, sessionID: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "snapshot-mutations-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
            shell: "/bin/sh", command: "cat", createdAt: "2026-07-21T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths, databasePath: databasePath)
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: Self.localOwner, mode: .owner, paths: paths, attachedAt: "2026-07-21T00:00:00Z",
            databasePath: databasePath)
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: Self.remoteViewer, mode: .viewer, paths: paths, attachedAt: "2026-07-21T00:00:01Z",
            databasePath: databasePath)
        return (paths, launchConfiguration.sessionID)
    }

    /// Compares the two snapshots by what the product reads out of them. Attachment row ids are excluded:
    /// an inserted attachment gets a fresh UUID on each side by design, and no product decision reads it.
    private func describe(_ snapshot: TerminalSessionAttachmentSnapshot) -> (clients: [String], attachments: [String]) {
        let clients = snapshot.clients.map { client in
            "\(client.id)|\(client.kind.rawValue)|\(client.identity.label)|\(client.connectedAt)|\(client.disconnectedAt ?? "-")|\(client.leaseRefreshedAt)"
        }.sorted()
        let attachments = snapshot.attachments.map { attachment in
            "\(attachment.sessionID)|\(attachment.clientID)|\(attachment.mode.rawValue)|\(attachment.attachedAt)|\(attachment.detachedAt ?? "-")"
        }.sorted()
        return (clients, attachments)
    }

    private func expectMirrors(_ inMemory: TerminalSessionAttachmentSnapshot, _ durable: TerminalSessionAttachmentSnapshot, _ what: Comment) {
        let memory = describe(inMemory)
        let disk = describe(durable)
        #expect(memory.clients == disk.clients, what)
        #expect(memory.attachments == disk.attachments, what)
    }

    // MARK: - Tests

    @Test func attachingANewOwnerMirrorsTheAttachStatement() throws {
        let session = try makeAttachedSession()
        let before = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let attachedAt = "2026-07-21T00:00:02Z"
        try TerminalSessionPersistence.attachClient(
            sessionID: session.sessionID, client: Self.remoteViewer, mode: .owner, paths: session.paths, attachedAt: attachedAt,
            databasePath: databasePath)
        let durable = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let inMemory = before.applyingAttach(client: Self.remoteViewer, mode: .owner, sessionID: session.sessionID, attachedAt: attachedAt)
        expectMirrors(inMemory, durable, "attaching a viewer as owner must detach the previous owner and re-mode the viewer's attachment")
        #expect(
            inMemory.attachments.filter { $0.detachedAt == nil && $0.mode == .owner }.map(\.clientID) == [Self.remoteViewer.id],
            "exactly one client owns the session after the attach")
    }

    @Test func attachingAFreshClientMirrorsTheAttachStatement() throws {
        let session = try makeAttachedSession()
        let before = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let newViewer = TerminalClient(
            id: "remote-ipad", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-07-21T00:00:03Z")
        let attachedAt = "2026-07-21T00:00:03Z"
        try TerminalSessionPersistence.attachClient(
            sessionID: session.sessionID, client: newViewer, mode: .viewer, paths: session.paths, attachedAt: attachedAt,
            databasePath: databasePath)
        let durable = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let inMemory = before.applyingAttach(client: newViewer, mode: .viewer, sessionID: session.sessionID, attachedAt: attachedAt)
        expectMirrors(inMemory, durable, "a first-time attach must insert both the client and its attachment")
    }

    @Test func detachingAClientMirrorsTheDetachStatement() throws {
        let session = try makeAttachedSession()
        let before = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let detachedAt = "2026-07-21T00:00:04Z"
        try TerminalSessionPersistence.detachClient(id: Self.localOwner.id, paths: session.paths, detachedAt: detachedAt, databasePath: databasePath)
        let durable = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let inMemory = before.applyingDetach(clientID: Self.localOwner.id, detachedAt: detachedAt)
        expectMirrors(inMemory, durable, "detaching must disconnect the client and end every attachment it holds")
        #expect(
            inMemory.attachments.filter { $0.detachedAt == nil }.map(\.clientID) == [Self.remoteViewer.id],
            "only the still-attached viewer remains active after the owner detaches")
    }

    @Test func transferringOwnershipMirrorsTheTransferStatement() throws {
        let session = try makeAttachedSession()
        let before = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let transferredAt = "2026-07-21T00:00:05Z"
        try TerminalSessionPersistence.transferOwnership(
            sessionID: session.sessionID, newOwnerClientID: Self.remoteViewer.id, paths: session.paths, transferredAt: transferredAt,
            databasePath: databasePath)
        let durable = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let inMemory = before.applyingOwnershipTransfer(to: Self.remoteViewer.id, sessionID: session.sessionID, transferredAt: transferredAt)
        expectMirrors(inMemory, durable, "a takeover must demote the previous owner to viewer and promote the new owner in place")
    }

    @Test func touchingALeaseMirrorsTheTouchStatement() throws {
        let session = try makeAttachedSession()
        let before = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let touchedAt = "2026-07-21T00:01:00Z"
        #expect(
            try TerminalSessionPersistence.touchClient(
                id: Self.remoteViewer.id, paths: session.paths, touchedAt: touchedAt, databasePath: databasePath))
        let durable = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let inMemory = before.applyingClientLeaseTouch(clientID: Self.remoteViewer.id, leaseRefreshedAt: touchedAt)
        expectMirrors(inMemory, durable, "a heartbeat must refresh only the heartbeating client's lease")
    }

    @Test func touchingADisconnectedClientLeavesItsLeaseAloneOnBothSides() throws {
        let session = try makeAttachedSession()
        try TerminalSessionPersistence.detachClient(
            id: Self.remoteViewer.id, paths: session.paths, detachedAt: "2026-07-21T00:00:06Z", databasePath: databasePath)
        let before = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let touchedAt = "2026-07-21T00:02:00Z"
        #expect(
            try TerminalSessionPersistence.touchClient(
                id: Self.remoteViewer.id, paths: session.paths, touchedAt: touchedAt, databasePath: databasePath) == false,
            "a disconnected client's lease touch must report that it changed nothing")
        let durable = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let inMemory = before.applyingClientLeaseTouch(clientID: Self.remoteViewer.id, leaseRefreshedAt: touchedAt)
        expectMirrors(inMemory, durable, "a stray heartbeat must never resurrect a client the session already let go of")
    }

    @Test func upsertingAClientMirrorsTheUpsertStatement() throws {
        let session = try makeAttachedSession()
        let before = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        // The identity a client reports can change between connections (a renamed device), and the upsert is
        // what carries the newest one; the lease follows the client's connection instant, as the SQL does.
        let renamed = TerminalClient(
            id: Self.remoteViewer.id, kind: .remoteViewer, identity: .init(label: "iPhone 17", deviceName: "iPhone 17"),
            connectedAt: "2026-07-21T00:03:00Z")
        try TerminalSessionPersistence.upsertClient(renamed, paths: session.paths, databasePath: databasePath)
        let durable = try TerminalSessionPersistence.readAttachmentSnapshot(paths: session.paths, databasePath: databasePath)

        let inMemory = before.applyingClientUpsert(renamed, leaseRefreshedAt: renamed.connectedAt)
        expectMirrors(inMemory, durable, "an upsert must replace the client's row wholesale without touching its attachments")
    }
}
