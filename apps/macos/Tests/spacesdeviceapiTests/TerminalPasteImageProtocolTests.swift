import Foundation
import XCTest

@testable import spacesdevicecore
@testable import spacesterminalcore

final class TerminalPasteImageProtocolTests: XCTestCase {
    func testTerminalPasteImageRequestRoundTripsThroughDeviceAPICodec() throws {
        let payload = SpacesDeviceTerminalPasteImageRequest(
            sessionID: "session-1", clientID: "client-1", ownerEpoch: 42, fileExtension: "png", imageData: Data([0x89, 0x50, 0x4E, 0x47]))
        let request = SpacesDeviceAPIRequest(command: .terminalPasteImage(payload), authToken: "token")

        let decoded = try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request))

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.commandName, "terminalPasteImage")
        XCTAssertEqual(decoded.sessionID, "session-1")
        XCTAssertEqual(decoded.clientID, "client-1")
    }

    func testTerminalPasteImageIsNotReplaySafeAfterConnectionFailure() {
        let payload = SpacesDeviceTerminalPasteImageRequest(
            sessionID: "session-1", clientID: "client-1", ownerEpoch: 42, fileExtension: "png", imageData: Data([1, 2, 3]))
        let request = SpacesDeviceAPIRequest(command: .terminalPasteImage(payload))

        XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure)
    }

    // terminalPasteImage entered the wire contract at version 3; later bumps must never regress
    // below it. An exact pin would break on every unrelated bump, so assert the floor.
    func testWireProtocolVersionIncludesTerminalPasteImageCommand() { XCTAssertGreaterThanOrEqual(SpacesWireProtocol.version, 3) }
}
