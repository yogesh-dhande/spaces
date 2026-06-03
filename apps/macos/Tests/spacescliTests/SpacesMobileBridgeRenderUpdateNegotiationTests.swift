import XCTest
import spacesterminalcore

@testable import spacesmobilebridge

final class SpacesMobileBridgeRenderUpdateNegotiationTests: XCTestCase {
    func testLegacyStreamPayloadReceivesV1FrameWithoutV2Update() throws {
        let line = try GhosttyRemoteSessionStateCodec.encodeLine(renderStatePayload())

        let decoded = try GhosttyRemoteSessionStateCodec.decodeLine(
            SpacesMobileBridgeServer.stateStreamDataForClient(line, supportsRenderUpdateV2: false))

        XCTAssertNotNil(decoded.renderFrame)
        XCTAssertNil(decoded.renderUpdate)
        XCTAssertNil(decoded.renderUpdateEncoding)
    }

    func testV2StreamPayloadReceivesRenderUpdateWithoutV1Frame() throws {
        let line = try GhosttyRemoteSessionStateCodec.encodeLine(renderStatePayload())

        let decoded = try GhosttyRemoteSessionStateCodec.decodeLine(
            SpacesMobileBridgeServer.stateStreamDataForClient(line, supportsRenderUpdateV2: true))

        XCTAssertNil(decoded.renderFrame)
        XCTAssertNotNil(decoded.renderUpdate)
        XCTAssertEqual(decoded.renderUpdateEncoding, GhosttyRenderUpdate.binaryEncoding)
    }

    private func renderStatePayload() throws -> GhosttyRemoteSessionStatePayload {
        let frame = GhosttyRenderFrame(sessionRevision: 7, ownerEpoch: 3, snapshot: snapshot())
        return GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "output", emittedAt: "2026-06-03T12:00:00Z", sessionStateRevision: 7, sessionStateFlags: nil,
            screenStateRevision: 7, runtimeState: nil, attachmentSnapshot: nil, title: "Terminal", workingDirectory: "/tmp",
            renderFrame: try GhosttyRenderFrame.encode(frame), outputByteCount: 1,
            renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)), renderUpdateEncoding: GhosttyRenderUpdate.binaryEncoding)
    }

    private func snapshot() -> GhosttyTerminalSnapshot {
        GhosttyTerminalSnapshot(
            columns: 1, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0x00ff_ffff, defaultBackgroundRGB: 0,
            cells: [GhosttyTerminalSnapshot.Cell(codepoint: 65, foregroundRGB: 0x00ff_ffff, backgroundRGB: 0, flags: 0)])
    }
}
