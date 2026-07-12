import Foundation
import XCTest

@testable import spacesdevicecore
@testable import spacesterminalcore

final class ServiceTunnelProtocolTests: XCTestCase {
    func testOpenServiceTunnelRequestRoundTripsThroughDeviceAPICodec() throws {
        let payload = SpacesDeviceServiceTunnelRequest(workspaceID: "workspace-1", serviceName: "web")
        let request = SpacesDeviceAPIRequest(command: .openServiceTunnel(payload), authToken: "token")

        let decoded = try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request))

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.commandName, "openServiceTunnel")
    }

    func testOpenServiceTunnelHijacksTheConnection() {
        let payload = SpacesDeviceServiceTunnelRequest(workspaceID: "workspace-1", serviceName: "web")
        let command = SpacesDeviceAPICommand.openServiceTunnel(payload)

        XCTAssertTrue(command.isTunnelCommand)
        XCTAssertTrue(command.hijacksConnection)
        XCTAssertFalse(command.isSubscriptionCommand)
    }

    func testServiceNotRunningErrorResponseRoundTripsThroughDeviceAPICodec() throws {
        let response = SpacesDeviceAPIResponse(ok: false, message: "service is not running", errorCode: .serviceNotRunning)

        let decoded = try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(response))

        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.errorCode, .serviceNotRunning)
    }
}
