import Foundation
import XCTest
import spacesterminalcore

final class GhosttyRemoteSessionStateTests: XCTestCase {
    func testMergedPayloadCarriesOutputPositionWithoutRawBytes() throws {
        let initial = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            renderFrame: try renderFrameData(text: "alpha", sessionRevision: 1, ownerEpoch: 4), outputByteCount: nil)

        let outputUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "output", emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha", renderFrame: nil,
            outputByteCount: 2, outputEndByteOffset: 42)

        let merged = initial.merged(with: outputUpdate)
        XCTAssertEqual(merged.renderFrameText, "alpha")
        XCTAssertEqual(merged.renderFrameSnapshot?.columns, initial.renderFrameSnapshot?.columns)
        XCTAssertEqual(merged.renderFrameOwnerEpoch, 4)
        XCTAssertEqual(merged.outputByteCount, 2)
        XCTAssertEqual(merged.outputEndByteOffset, 42)
        let decodedOutputUpdate = try GhosttyRemoteSessionStateCodec.decodeLine(try GhosttyRemoteSessionStateCodec.encodeLine(outputUpdate))
        XCTAssertEqual(decodedOutputUpdate.outputEndByteOffset, 42)

        let metadataUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "attachment_state", emittedAt: "2026-05-20T00:00:02Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "alpha",
            workingDirectory: "/tmp/alpha", renderFrame: nil, outputByteCount: nil)

        let metadataMerged = merged.merged(with: metadataUpdate)
        XCTAssertNil(metadataMerged.outputEndByteOffset)
        XCTAssertEqual(metadataMerged.renderFrameText, "alpha")
    }

    func testMergedPayloadClearsScreenStateWhenOwnerChangesWithoutFreshSnapshot() throws {
        let initial = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: attachmentSnapshot(ownerID: "mac-window"), title: "alpha",
            workingDirectory: "/tmp/alpha", renderFrame: try renderFrameData(text: "stale suggestion", sessionRevision: 1, ownerEpoch: 9),
            outputByteCount: nil)

        let ownerUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "attachment_state", emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: attachmentSnapshot(ownerID: "ios-viewer"), title: "alpha",
            workingDirectory: "/tmp/alpha", renderFrame: nil, outputByteCount: nil)

        let merged = initial.merged(with: ownerUpdate)
        XCTAssertNil(merged.renderFrameSnapshot)
        XCTAssertNil(merged.renderFrameText)
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
        XCTAssertEqual(attributes["frame_columns"], String(snapshot.columns))
        XCTAssertEqual(attributes["frame_rows"], String(snapshot.rows))
        XCTAssertEqual(attributes["owner_epoch"], "34")
        XCTAssertEqual(attributes["session_revision"], "12")
        XCTAssertEqual(attributes["dropped"], "0")
        XCTAssertEqual(attributes["render_mode"], "ghostty-mirror")
        XCTAssertTrue(GhosttyRenderFrameMetrics.detailString(attributes).contains("frame_bytes=256"))
    }

    private func renderFrameData(text: String, sessionRevision: UInt64, ownerEpoch: UInt64) throws -> Data {
        try GhosttyRenderFrame.encode(.init(sessionRevision: sessionRevision, ownerEpoch: ownerEpoch, snapshot: snapshot(text: text)))
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
