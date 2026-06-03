import XCTest
import spacesmobilecore
import spacesterminalcore

final class SpacesMobileBridgeProtocolTests: XCTestCase {
    func testRequestRoundTripsScrollModsThroughCodec() throws {
        let request = SpacesMobileBridgeRequest(
            command: "scroll", authToken: "SECRET", sessionID: "session-1", clientID: "ios-client", ownerEpoch: 3, scrollHorizontal: 1.5,
            scrollVertical: -2.5, scrollMods: 7)

        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeRequest(SpacesMobileBridgeCodec.encodeRequest(request)), request)
    }

    func testLegacyScrollRequestDecodesWithoutScrollMods() throws {
        let payload = #"{"command":"scroll","sessionID":"session-1","clientID":"ios-client","scrollVertical":24}"#.data(using: .utf8)!
        let request = try SpacesMobileBridgeCodec.decodeRequest(payload)

        XCTAssertEqual(request.scrollVertical, 24)
        XCTAssertNil(request.scrollMods)
    }

    func testRequestRoundTripsRenderUpdateProtocolsThroughCodec() throws {
        let request = SpacesMobileBridgeRequest(
            command: "subscribe", authToken: "SECRET", sessionID: "session-1", clientID: "ios-client",
            renderUpdateProtocols: [GhosttyRenderUpdate.binaryEncoding])

        let decoded = try SpacesMobileBridgeCodec.decodeRequest(SpacesMobileBridgeCodec.encodeRequest(request))

        XCTAssertEqual(decoded.renderUpdateProtocols, [GhosttyRenderUpdate.binaryEncoding])
        XCTAssertEqual(decoded, request)
    }

    func testLegacyRequestDecodesWithoutRenderUpdateProtocols() throws {
        let payload = #"{"command":"subscribe","sessionID":"session-1","clientID":"ios-client"}"#.data(using: .utf8)!
        let request = try SpacesMobileBridgeCodec.decodeRequest(payload)

        XCTAssertNil(request.renderUpdateProtocols)
    }
}
