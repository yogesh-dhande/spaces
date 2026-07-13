import XCTest

@testable import spacesdeviceapi

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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

    func testShutdownWantWriteKeepsThePendingOperationAsShutdown() {
        let pending = SpacesDeviceServiceTunnelSSLPendingOperation.shutdown(waitingFor: .write)

        XCTAssertEqual(pending.operation, .shutdown)
        XCTAssertFalse(pending.waitsForRead)
        XCTAssertTrue(pending.waitsForWrite)
        XCTAssertTrue(pending.isReady(clientReadable: false, clientWritable: true))
        XCTAssertFalse(pending.isReady(clientReadable: true, clientWritable: false))
    }

    func testClientHangupOrErrorCountsAsWriteReadyForPendingSSLRetry() {
        let pending = SpacesDeviceServiceTunnelSSLPendingOperation.read(waitingFor: .write)

        for event in [POLLHUP, POLLERR] {
            let readiness = spacesDeviceServiceTunnelClientSocketReadiness(revents: Int16(event))
            XCTAssertTrue(readiness.readable)
            XCTAssertTrue(readiness.writable)
            XCTAssertTrue(pending.isReady(clientReadable: readiness.readable, clientWritable: readiness.writable))
        }
    }
}
