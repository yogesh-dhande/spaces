import Foundation
import Testing

@testable import spacesterminalcore

/// A broadcast attachment snapshot conveys who is attached now, never the session's attach history.
@Suite struct TerminalSessionAttachmentSnapshotWireProjectionTests {
    private let sessionID = "SESSION"

    private func client(_ id: String, kind: TerminalClientKind = .remoteViewer, disconnectedAt: String? = nil, leaseRefreshedAt: String? = nil)
        -> TerminalClient
    {
        TerminalClient(
            id: id, kind: kind, identity: TerminalClientIdentity(label: id), connectedAt: "2026-08-22T10:00:00Z", disconnectedAt: disconnectedAt,
            leaseRefreshedAt: leaseRefreshedAt)
    }

    private func attachment(_ clientID: String, mode: TerminalAttachmentMode = .viewer, detachedAt: String? = nil) -> TerminalAttachment {
        TerminalAttachment(
            id: "attachment-\(clientID)-\(detachedAt ?? "live")", sessionID: sessionID, clientID: clientID, mode: mode,
            attachedAt: "2026-08-22T10:00:00Z", detachedAt: detachedAt)
    }

    @Test func dropsDetachedAttachmentsAndTheClientsOnlyTheyReferenced() {
        let snapshot = TerminalSessionAttachmentSnapshot(
            clients: [client("owner", kind: .localWindow), client("gone-phone", disconnectedAt: "2026-08-22T10:05:00Z")],
            attachments: [
                attachment("owner", mode: .owner), attachment("gone-phone", detachedAt: "2026-08-22T10:05:00Z"),
                attachment("owner", mode: .viewer, detachedAt: "2026-08-22T09:00:00Z"),
            ])

        let projected = snapshot.liveWireProjection()

        #expect(projected.attachments.map { $0.clientID } == ["owner"])
        #expect(projected.attachments.allSatisfy { $0.detachedAt == nil })
        #expect(projected.clients.map { $0.id } == ["owner"])
    }

    @Test func keepsADisconnectedClientThatStillHoldsAnUndetachedAttachment() {
        // Liveness is `liveAttachments`' call, and it must still see the row to make it.
        let snapshot = TerminalSessionAttachmentSnapshot(
            clients: [client("stale-phone", disconnectedAt: "2026-08-22T10:05:00Z")], attachments: [attachment("stale-phone")])

        let projected = snapshot.liveWireProjection()

        #expect(projected.clients.map { $0.id } == ["stale-phone"])
        #expect(projected.attachments.count == 1)
    }

    @Test func preservesTheLivenessVerdictOfEveryAttachment() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = GhosttyRemoteSessionStateTimestamp.string(from: now.addingTimeInterval(-5))
        let expired = GhosttyRemoteSessionStateTimestamp.string(from: now.addingTimeInterval(-600))
        let snapshot = TerminalSessionAttachmentSnapshot(
            clients: [
                client("owner", kind: .localWindow), client("fresh-viewer", leaseRefreshedAt: fresh),
                client("expired-viewer", leaseRefreshedAt: expired), client("detached-viewer", leaseRefreshedAt: fresh),
            ],
            attachments: [
                attachment("owner", mode: .owner), attachment("fresh-viewer"), attachment("expired-viewer"),
                attachment("detached-viewer", detachedAt: "2026-08-22T10:05:00Z"),
            ])

        let before = Set(snapshot.liveAttachments(now: now).map { $0.id })
        let after = Set(snapshot.liveWireProjection().liveAttachments(now: now).map { $0.id })

        #expect(before == after)
        #expect(before == ["attachment-owner-live", "attachment-fresh-viewer-live"])
    }

    @Test func preservesTheActiveOwnerAndItsClient() {
        let snapshot = TerminalSessionAttachmentSnapshot(
            clients: [client("owner", kind: .localWindow), client("old-owner", disconnectedAt: "2026-08-22T09:30:00Z")],
            attachments: [attachment("old-owner", mode: .owner, detachedAt: "2026-08-22T09:30:00Z"), attachment("owner", mode: .owner)])

        let projected = snapshot.liveWireProjection()

        #expect(TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: projected) == "owner")
        #expect(TerminalRemoteSessionStatePolicy.activeOwnerClient(in: projected)?.identity.label == "owner")
    }

    @Test func isIdempotent() {
        let snapshot = TerminalSessionAttachmentSnapshot(
            clients: [client("owner", kind: .localWindow), client("gone", disconnectedAt: "2026-08-22T10:05:00Z")],
            attachments: [attachment("owner", mode: .owner), attachment("gone", detachedAt: "2026-08-22T10:05:00Z")])

        #expect(snapshot.liveWireProjection() == snapshot.liveWireProjection().liveWireProjection())
    }
}
