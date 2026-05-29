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
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.input, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.resize, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.resize, ownerKind: .localWindow))
    }

    func testCachedSnapshotPolicyOnlyAppliesToRemoteOwnerBootstrap() {
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldUseCachedSessionSnapshot(reason: TerminalRemoteSessionStateReason.initial, ownerKind: .localWindow)
        )
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldUseCachedSessionSnapshot(
                reason: TerminalRemoteSessionStateReason.initial, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldUseCachedSessionSnapshot(
                reason: TerminalRemoteSessionStateReason.attachmentState, ownerKind: .remoteViewer))
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldUseCachedSessionSnapshot(reason: TerminalRemoteSessionStateReason.input, ownerKind: .remoteViewer))
    }

    func testOwnerBootstrapRequiresSnapshot() {
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: "session", backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .running, updatedAt: "2026-05-27T00:00:00Z")
        let payloadWithoutSnapshot = GhosttyRemoteSessionStatePayload(
            sessionID: "session", reason: TerminalRemoteSessionStateReason.attachmentState, emittedAt: "2026-05-27T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "shell", workingDirectory: "/tmp", snapshot: nil, snapshotText: "shell",
            transcriptTail: nil, outputByteCount: nil)
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.hasUsableOwnerBootstrapState(payloadWithoutSnapshot))

        let payloadWithSnapshot = GhosttyRemoteSessionStatePayload(
            sessionID: "session", reason: TerminalRemoteSessionStateReason.resize, emittedAt: "2026-05-27T00:00:01Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "shell", workingDirectory: "/tmp", snapshot: snapshot(columns: 40, rows: 34), snapshotText: nil, transcriptTail: nil,
            outputByteCount: nil)
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
