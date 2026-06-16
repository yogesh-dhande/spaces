import XCTest

@testable import spacesterminalcore

final class TerminalRemoteSessionStatePolicyTests: XCTestCase {
    func testScreenStatePolicyMatchesOwnerBootstrapModel() {
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.initial))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.initial, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.initial, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.attachmentState, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.attachmentState, ownerKind: .remoteViewer))
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.input, ownerKind: .remoteViewer))
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.input, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.inputOutput, ownerKind: .localWindow))
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.inputOutput, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.output, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.output, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.stateChange, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.stateChange, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.resize, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.resize, ownerKind: .localWindow))
        XCTAssertTrue(TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.clearScreen))
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.runtimeState))
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: "unknown", ownerKind: .localWindow))
    }

    func testActiveOwnerHelpersUseLiveOwnerAttachment() {
        let owner = TerminalClient(
            id: "owner", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-15T00:00:00Z")
        let localViewer = TerminalClient(
            id: "viewer", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-15T00:00:01Z")
        let snapshot = TerminalSessionAttachmentSnapshot(
            clients: [localViewer, owner],
            attachments: [
                TerminalAttachment(
                    id: "detached-owner", sessionID: "session", clientID: localViewer.id, mode: .owner, attachedAt: "2026-06-15T00:00:02Z",
                    detachedAt: "2026-06-15T00:00:03Z"),
                TerminalAttachment(id: "owner", sessionID: "session", clientID: owner.id, mode: .owner, attachedAt: "2026-06-15T00:00:04Z"),
            ])

        XCTAssertEqual(TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: snapshot), owner.id)
        XCTAssertEqual(TerminalRemoteSessionStatePolicy.activeOwnerClient(in: snapshot), owner)
        XCTAssertEqual(TerminalRemoteSessionStatePolicy.activeOwnerClientKind(in: snapshot), .remoteViewer)
    }

    func testActiveOwnerHelpersMatchMacOwnerAttachmentSemantics() {
        let owner = TerminalClient(
            id: "owner", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-15T00:00:00Z",
            disconnectedAt: "2026-06-15T00:00:03Z")
        let snapshot = TerminalSessionAttachmentSnapshot(
            clients: [owner],
            attachments: [TerminalAttachment(id: "owner", sessionID: "session", clientID: owner.id, mode: .owner, attachedAt: "2026-06-15T00:00:01Z")]
        )

        XCTAssertEqual(TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: snapshot), owner.id)
        XCTAssertEqual(TerminalRemoteSessionStatePolicy.activeOwnerClient(in: snapshot), owner)
        XCTAssertEqual(TerminalRemoteSessionStatePolicy.activeOwnerClientKind(in: snapshot), .remoteViewer)
    }

    func testOwnerBootstrapRequiresSnapshot() throws {
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: "session", backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .running, updatedAt: "2026-05-27T00:00:00Z")
        let payloadWithoutSnapshot = GhosttyRemoteSessionStatePayload(
            sessionID: "session", reason: TerminalRemoteSessionStateReason.attachmentState, emittedAt: "2026-05-27T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "shell", workingDirectory: "/tmp", outputByteCount: nil)
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.hasUsableOwnerBootstrapState(payloadWithoutSnapshot))

        let snapshot = snapshot(columns: 40, rows: 34)
        let payloadWithSnapshot = GhosttyRemoteSessionStatePayload(
            sessionID: "session", reason: TerminalRemoteSessionStateReason.resize, emittedAt: "2026-05-27T00:00:01Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "shell", workingDirectory: "/tmp", outputByteCount: nil,
            renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(.init(sessionRevision: 1, ownerEpoch: 2, snapshot: snapshot))))
        XCTAssertTrue(TerminalRemoteSessionStatePolicy.hasUsableOwnerBootstrapState(payloadWithSnapshot, viewportColumns: 40, viewportRows: 34))
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.hasUsableOwnerBootstrapState(payloadWithSnapshot, viewportColumns: 122, viewportRows: 34))
    }

    private func snapshot(columns: Int, rows: Int) -> GhosttyTerminalSnapshot {
        GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000,
            cells: Array(
                repeating: GhosttyTerminalSnapshot.Cell(
                    codepoint: UInt32(UnicodeScalar("x").value), foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0), count: columns * rows))
    }
}
