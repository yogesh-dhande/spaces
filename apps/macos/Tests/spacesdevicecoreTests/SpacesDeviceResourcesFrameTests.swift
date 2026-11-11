import Foundation
import XCTest

@testable import spacesdevicecore

final class SpacesDeviceResourcesFrameTests: XCTestCase {
    func testStreamLineRoundTripsAFrame() throws {
        let frame = SpacesDeviceResourcesFrame(
            sampledAt: Date(timeIntervalSince1970: 1_700_000_000), processorCount: 10, physicalMemoryBytes: 32 << 30,
            daemon: SpacesDeviceResourceUsage(cpuPercent: 3.5, memoryBytes: 120 << 20),
            terminals: [
                SpacesDeviceTerminalResourceUsage(
                    sessionID: "session-1", usage: SpacesDeviceResourceUsage(cpuPercent: 250, memoryBytes: 1 << 30), processCount: 4)
            ])
        let line = try SpacesDeviceResourcesStreamCodec.encodeLine(frame)
        XCTAssertEqual(line.last, 0x0A, "frames are newline-terminated")
        XCTAssertEqual(try SpacesDeviceResourcesStreamCodec.decodeLine(line.dropLast()), frame)
    }

    func testSubscribeDeviceResourcesRequestRoundTrips() throws {
        let request = SpacesDeviceAPIRequest(command: .subscribeDeviceResources, authToken: "token", clientApp: nil)
        let decoded = try SpacesDeviceAPICodec.decodeRequest(try SpacesDeviceAPICodec.encodeRequest(request))
        XCTAssertTrue(decoded.command.isDeviceResourcesSubscription)
        XCTAssertTrue(decoded.command.isSubscriptionCommand)
        XCTAssertFalse(decoded.command.isSafeToReplayAfterConnectionFailure)
    }
}
