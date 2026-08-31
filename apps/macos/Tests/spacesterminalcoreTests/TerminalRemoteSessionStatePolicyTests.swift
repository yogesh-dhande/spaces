import XCTest

@testable import spacesterminalcore

final class TerminalRemoteSessionStatePolicyTests: XCTestCase {
    /// Migrated from the retired `TerminalRemoteSessionStateNotificationRoutingTests`: which
    /// notifications each reason maps to is product behavior the `TerminalRemoteSessionStateReason`
    /// enum's exhaustive switches do not pin down on their own (a switch being exhaustive only proves
    /// every case is handled, not that it is mapped correctly), so this stays a behavioral assertion.
    /// The consistency check between `notifications(forReason:)` and `isOutputShaped(reason:)` that
    /// file also carried is not migrated: `isOutputShaped(reason:)` now reads the same
    /// `TerminalRemoteSessionStateReason.isOutputShaped` primitive `notifications(forReason:)` defers
    /// to for its screen-content branch, so the two cannot disagree by construction, not merely by
    /// the exhaustiveness of separately-maintained switches.
    func testNotificationRoutingMapsEachReasonToItsNotifications() {
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.initial.rawValue),
            [.spacesTerminalRuntimeStateDidChange])
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.runtimeState.rawValue),
            [.spacesTerminalRuntimeStateDidChange])
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.terminated.rawValue),
            [.spacesTerminalRuntimeStateDidChange])
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.attachmentState.rawValue),
            [.spacesTerminalAttachmentStateDidChange, .spacesTerminalRuntimeStateDidChange])
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.sessionMetadata.rawValue),
            [.spacesTerminalSessionMetadataDidChange])
        let screenContentReasons: [TerminalRemoteSessionStateReason] = [
            .output, .input, .inputOutput, .stateChange, .scroll, .clearScreen, .selection, .resize,
        ]
        for reason in screenContentReasons {
            XCTAssertEqual(
                TerminalRemoteSessionStateNotificationRouting.notifications(forReason: reason.rawValue), [.spacesTerminalOutputDidChange],
                "reason \(reason) must route to the output notification")
        }
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.clipboardWrite.rawValue), [])
        XCTAssertEqual(TerminalRemoteSessionStateNotificationRouting.notifications(forReason: "not_a_reason"), [])
        XCTAssertEqual(TerminalRemoteSessionStateNotificationRouting.notifications(forReason: ""), [])
    }

    func testScreenStatePolicyMatchesOwnerBootstrapModel() {
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.initial.rawValue))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.initial.rawValue, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.initial.rawValue, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, ownerKind: .remoteViewer))
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.input.rawValue, ownerKind: .remoteViewer))
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.input.rawValue, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.inputOutput.rawValue, ownerKind: .localWindow))
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.inputOutput.rawValue, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.output.rawValue, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.output.rawValue, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.stateChange.rawValue, ownerKind: .localWindow))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.stateChange.rawValue, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.resize.rawValue, ownerKind: .remoteViewer))
        XCTAssertTrue(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.resize.rawValue, ownerKind: .localWindow))
        XCTAssertTrue(TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.clearScreen.rawValue))
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: TerminalRemoteSessionStateReason.runtimeState.rawValue))
        // A clipboard write rides its own broadcast after the output turn that already carried the
        // frame; re-exporting one here would put a second frame on the delta chain for nothing.
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.clipboardWrite.rawValue, ownerKind: .localWindow))
        XCTAssertFalse(
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(
                reason: TerminalRemoteSessionStateReason.clipboardWrite.rawValue, ownerKind: .remoteViewer))
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
            sessionID: "session", reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, emittedAt: "2026-05-27T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "shell", workingDirectory: "/tmp", outputByteCount: nil)
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.hasUsableOwnerBootstrapState(payloadWithoutSnapshot))

        let snapshot = snapshot(columns: 40, rows: 34)
        let payloadWithSnapshot = GhosttyRemoteSessionStatePayload(
            sessionID: "session", reason: TerminalRemoteSessionStateReason.resize.rawValue, emittedAt: "2026-05-27T00:00:01Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "shell", workingDirectory: "/tmp", outputByteCount: nil,
            renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(.init(sessionRevision: 1, ownerEpoch: 2, snapshot: snapshot))))
        XCTAssertTrue(TerminalRemoteSessionStatePolicy.hasUsableOwnerBootstrapState(payloadWithSnapshot, viewportColumns: 40, viewportRows: 34))
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.hasUsableOwnerBootstrapState(payloadWithSnapshot, viewportColumns: 122, viewportRows: 34))
    }

    /// A selection-only frame (no text, no non-default background, no cursor) must still count as
    /// visible screen content: `resolveRemoteScreenState` drops a frame this policy calls invisible,
    /// and a selection set or shown on an otherwise blank screen would never reach a viewer.
    func testHasVisibleScreenContentTreatsSelectionOnBlankGridAsVisible() {
        let selection = GhosttyTerminalSelectionRange(
            startColumn: 0, startRow: 0, endColumn: 5, endRow: 0, isRectangle: false, extendsAbove: false, extendsBelow: false)
        let blankSnapshotWithSelection = blankSnapshot(columns: 10, rows: 4, selection: selection)
        XCTAssertTrue(TerminalRemoteSessionStatePolicy.hasVisibleScreenContent(snapshot: blankSnapshotWithSelection, snapshotText: nil))

        let blankSnapshotWithoutSelection = blankSnapshot(columns: 10, rows: 4)
        XCTAssertFalse(TerminalRemoteSessionStatePolicy.hasVisibleScreenContent(snapshot: blankSnapshotWithoutSelection, snapshotText: nil))
    }

    private func snapshot(columns: Int, rows: Int) -> GhosttyTerminalSnapshot {
        GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000,
            cells: Array(
                repeating: GhosttyTerminalSnapshot.Cell(
                    codepoint: UInt32(UnicodeScalar("x").value), foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0), count: columns * rows))
    }

    /// An entirely blank grid: default backgrounds, no visible cursor, whitespace-only cells (codepoint
    /// 0 resolves to a space via the default foreground/background).
    private func blankSnapshot(columns: Int, rows: Int, selection: GhosttyTerminalSelectionRange? = nil) -> GhosttyTerminalSnapshot {
        GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000,
            cells: Array(
                repeating: GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0),
                count: columns * rows), selection: selection)
    }
}
