import Foundation
import XCTest
import spacesterminalcore

final class GhosttyRemoteSessionStateTests: XCTestCase {
    func testMergedPayloadCarriesOutputPositionWithoutRawBytes() throws {
        let initial = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha", outputByteCount: nil,
            renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))

        let outputUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "output", emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha", outputByteCount: 2,
            outputEndByteOffset: 42)

        let merged = initial.merged(with: outputUpdate)
        XCTAssertEqual(merged.renderText, "alpha")
        XCTAssertEqual(merged.renderSnapshot?.columns, initial.renderSnapshot?.columns)
        XCTAssertEqual(merged.renderOwnerEpoch, 4)
        XCTAssertEqual(merged.outputByteCount, 2)
        XCTAssertEqual(merged.outputEndByteOffset, 42)
        let decodedOutputUpdate = try GhosttyRemoteSessionStateCodec.decodeLine(try GhosttyRemoteSessionStateCodec.encodeLine(outputUpdate))
        XCTAssertEqual(decodedOutputUpdate.outputEndByteOffset, 42)

        let metadataUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "attachment_state", emittedAt: "2026-05-20T00:00:02Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "alpha",
            workingDirectory: "/tmp/alpha", outputByteCount: nil)

        let metadataMerged = merged.merged(with: metadataUpdate)
        XCTAssertNil(metadataMerged.outputEndByteOffset)
        XCTAssertEqual(metadataMerged.renderText, "alpha")
    }

    func testMergedPayloadClearsScreenStateWhenOwnerChangesWithoutFreshSnapshot() throws {
        let initial = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: attachmentSnapshot(ownerID: "mac-window"), title: "alpha",
            workingDirectory: "/tmp/alpha", outputByteCount: nil,
            renderUpdate: try renderUpdateData(text: "stale suggestion", sessionRevision: 1, ownerEpoch: 9))

        let ownerUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "attachment_state", emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: attachmentSnapshot(ownerID: "ios-viewer"), title: "alpha",
            workingDirectory: "/tmp/alpha", outputByteCount: nil)

        let merged = initial.merged(with: ownerUpdate)
        XCTAssertNil(merged.renderSnapshot)
        XCTAssertNil(merged.renderText)
    }

    func testReducerDoesNotApplyPreservedFrameForMetadataOnlyUpdate() throws {
        var reducer = TerminalRemoteStateReducer()
        let initial = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha", outputByteCount: nil,
            renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))

        let initialReduction = reducer.reduce(incomingPayload: initial, previousPayload: nil)
        XCTAssertEqual(initialReduction.frameToApply?.snapshot, initial.renderSnapshot)

        let inputAck = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.input, emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: 5)

        let inputReduction = reducer.reduce(incomingPayload: inputAck, previousPayload: initialReduction.storedPayload)

        XCTAssertNil(inputReduction.frameToApply)
        XCTAssertEqual(inputReduction.storedPayload.renderText, "alpha")
        XCTAssertEqual(inputReduction.storedPayload.outputByteCount, 5)
    }

    func testReducerYieldsFullFrameWithoutDrop() throws {
        var reducer = TerminalRemoteStateReducer()
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))

        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil)

        XCTAssertEqual(reduction.frameToApply?.snapshot, snapshot(text: "alpha"))
        XCTAssertEqual(reduction.frameToApply?.ownerEpoch, 4)
        XCTAssertNil(reduction.dropReason)
        XCTAssertFalse(reduction.didRequestResync)
        XCTAssertEqual(reduction.storedPayload.renderText, "alpha")
        XCTAssertEqual(reduction.storedPayload.renderOwnerEpoch, 4)
    }

    func testReducerAppliesDeltaOntoEstablishedBaseline() throws {
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha"))
        let secondFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "bravo"))
        let delta = GhosttyRenderUpdateFactory.makeUpdate(target: secondFrame, baseline: GhosttyRenderUpdateBaseline(frame: firstFrame))
        XCTAssertEqual(delta.kind, .delta)

        var reducer = TerminalRemoteStateReducer()
        let full = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(firstFrame)))
        _ = reducer.reduce(incomingPayload: full, previousPayload: nil)

        let deltaPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(delta))
        let reduction = reducer.reduce(incomingPayload: deltaPayload, previousPayload: full)

        XCTAssertEqual(reduction.frameToApply?.snapshot, snapshot(text: "bravo"))
        XCTAssertNil(reduction.dropReason)
        XCTAssertFalse(reduction.didRequestResync)
        XCTAssertEqual(reduction.storedPayload.renderText, "bravo")
    }

    func testReducerDropsFrameRejectedByShouldUseFrame() throws {
        var reducer = TerminalRemoteStateReducer()
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.resize, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))

        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil, shouldUseFrame: { _, _ in false })

        XCTAssertNil(reduction.frameToApply)
        XCTAssertEqual(reduction.dropReason, "stale_resize_grid")
        XCTAssertNil(reduction.storedPayload.renderSnapshot)
    }

    func testReducerReportsDecodeFailureForCorruptRenderUpdate() {
        var reducer = TerminalRemoteStateReducer()
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: Data([0x00, 0x01, 0x02, 0x03]))

        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil, requestResyncOnApplyFailure: true)

        XCTAssertNil(reduction.frameToApply)
        XCTAssertEqual(reduction.dropReason, "render_update_decode_failed")
        XCTAssertTrue(reduction.didRequestResync)
        XCTAssertNil(reduction.storedPayload.renderSnapshot)
    }

    func testDecodedRenderUpdateReturnsEqualValueAcrossRepeatedAndSeededAccess() throws {
        let data = try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4)
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: data)

        XCTAssertEqual(payload.decodedRenderUpdate, payload.decodedRenderUpdate)
        XCTAssertEqual(payload.decodedRenderUpdate?.fullFrame?.snapshot, snapshot(text: "alpha"))

        // A materialized full frame stored back into a payload resolves to the seeded value.
        var reducer = TerminalRemoteStateReducer()
        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil)
        let stored = reduction.storedPayload
        XCTAssertEqual(stored.decodedRenderUpdate, stored.decodedRenderUpdate)
        XCTAssertEqual(stored.decodedRenderUpdate?.fullFrame?.snapshot, snapshot(text: "alpha"))
    }

    func testReducerRequestsResyncForDeltaWithoutBaseline() throws {
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha"))
        let secondFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "bravo"))
        let delta = GhosttyRenderUpdateFactory.makeUpdate(target: secondFrame, baseline: GhosttyRenderUpdateBaseline(frame: firstFrame))
        XCTAssertEqual(delta.kind, .delta)
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(delta))
        var reducer = TerminalRemoteStateReducer()

        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil, requestResyncOnApplyFailure: true)

        XCTAssertNil(reduction.frameToApply)
        XCTAssertNil(reduction.storedPayload.renderSnapshot)
        XCTAssertEqual(reduction.dropReason, "missing_baseline")
        XCTAssertTrue(reduction.didRequestResync)
    }

    func testRenderFrameRoundTripsOwnerEpochAndGrid() throws {
        let snapshot = snapshot(text: "frame")
        let data = try GhosttyRenderFrame.encode(.init(sessionRevision: 12, ownerEpoch: 34, snapshot: snapshot))
        let decoded = try GhosttyRenderFrame.decode(data)

        XCTAssertEqual(decoded.version, GhosttyRenderFrame.currentVersion)
        XCTAssertEqual(decoded.sessionRevision, 12)
        XCTAssertEqual(decoded.ownerEpoch, 34)
        XCTAssertEqual(decoded.columns, snapshot.columns)
        XCTAssertEqual(decoded.rows, snapshot.rows)
        XCTAssertEqual(decoded.snapshot, snapshot)
    }

    func testRenderFrameMetricAttributesIncludePayloadAndGridFields() throws {
        let snapshot = snapshot(text: "frame")
        let frame = GhosttyRenderFrame(sessionRevision: 12, ownerEpoch: 34, snapshot: snapshot)
        let attributes = GhosttyRenderFrameMetrics.attributes(
            reason: "output", frame: frame, frameByteCount: 256, frameEncodeMS: 3, payloadByteCount: 384, payloadEncodeMS: 4, decodeMS: 5,
            outputByteCount: 6, screenStateRevision: 7, dropped: false, renderMode: "ghostty-mirror")

        XCTAssertEqual(attributes["reason"], "output")
        XCTAssertEqual(attributes["render_frame"], "1")
        XCTAssertEqual(attributes["frame_bytes"], "256")
        XCTAssertEqual(attributes["frame_encode_ms"], "3")
        XCTAssertEqual(attributes["payload_bytes"], "384")
        XCTAssertEqual(attributes["payload_encode_ms"], "4")
        XCTAssertEqual(attributes["decode_ms"], "5")
        XCTAssertEqual(attributes["output_bytes"], "6")
        XCTAssertEqual(attributes["screen_revision"], "7")
        XCTAssertEqual(attributes["frame_kind"], "full")
        XCTAssertEqual(attributes["base_revision"], "nil")
        XCTAssertEqual(attributes["target_revision"], "7")
        XCTAssertEqual(attributes["applied_revision"], "nil")
        XCTAssertEqual(attributes["frame_columns"], String(snapshot.columns))
        XCTAssertEqual(attributes["frame_rows"], String(snapshot.rows))
        XCTAssertEqual(attributes["owner_epoch"], "34")
        XCTAssertEqual(attributes["session_revision"], "12")
        XCTAssertEqual(attributes["dropped"], "0")
        XCTAssertEqual(attributes["drop_reason"], "none")
        XCTAssertEqual(attributes["render_mode"], "ghostty-mirror")
        XCTAssertTrue(GhosttyRenderFrameMetrics.detailString(attributes).contains("frame_bytes=256"))
    }

    func testRenderFrameMetricAttributesMarkMissingRenderUpdateAsNone() {
        let attributes = GhosttyRenderFrameMetrics.attributes(reason: "input", frame: nil, frameByteCount: nil, screenStateRevision: 7)

        XCTAssertEqual(attributes["render_frame"], "0")
        XCTAssertEqual(attributes["frame_kind"], "none")
        XCTAssertEqual(attributes["frame_bytes"], "0")
        XCTAssertEqual(attributes["screen_revision"], "7")
    }

    private func renderUpdateData(text: String, sessionRevision: UInt64, ownerEpoch: UInt64) throws -> Data {
        let frame = GhosttyRenderFrame(sessionRevision: sessionRevision, ownerEpoch: ownerEpoch, snapshot: snapshot(text: text))
        return try GhosttyRenderUpdateBinaryCodec.encode(.full(frame))
    }

    private func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = rows.map(\.count).max() ?? 0
        let paddedRows = rows.map { row in row.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedRows.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: paddedRows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000, cells: cells)
    }

    private func attachmentSnapshot(ownerID: String) -> TerminalSessionAttachmentSnapshot {
        let client = TerminalClient(
            id: ownerID, kind: ownerID.hasPrefix("mac") ? .localWindow : .remoteViewer, identity: .init(label: ownerID),
            connectedAt: "2026-05-20T00:00:00Z")
        return TerminalSessionAttachmentSnapshot(
            clients: [client],
            attachments: [TerminalAttachment(sessionID: "session-1", clientID: ownerID, mode: .owner, attachedAt: "2026-05-20T00:00:00Z")])
    }
}
