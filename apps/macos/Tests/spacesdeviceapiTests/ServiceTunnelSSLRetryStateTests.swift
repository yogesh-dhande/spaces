import XCTest

@testable import spacesdeviceapi

final class ServiceTunnelSSLRetryStateTests: XCTestCase {
    func testReadWantWriteKeepsThePendingOperationAsRead() {
        let pending = SpacesDeviceServiceTunnelSSLPendingOperation.read(waitingFor: .write)

        XCTAssertEqual(pending.operation, .read)
        XCTAssertFalse(pending.waitsForRead)
        XCTAssertTrue(pending.waitsForWrite)
        XCTAssertTrue(pending.isReady(clientReadable: false, clientWritable: true))
        XCTAssertFalse(pending.isReady(clientReadable: true, clientWritable: false))
    }

    func testWriteWantReadKeepsThePendingOperationAsWrite() {
        let pending = SpacesDeviceServiceTunnelSSLPendingOperation.write(waitingFor: .read)

        XCTAssertEqual(pending.operation, .write)
        XCTAssertTrue(pending.waitsForRead)
        XCTAssertFalse(pending.waitsForWrite)
        XCTAssertTrue(pending.isReady(clientReadable: true, clientWritable: false))
        XCTAssertFalse(pending.isReady(clientReadable: false, clientWritable: true))
    }
}
