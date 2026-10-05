import Darwin
import Foundation
import XCTest

@testable import workspacecore

/// The port probe and holder lookup against real sockets opened by the test process.
final class PortProbeTests: XCTestCase {
    private func assertTaken(_ shape: TestSocket.Shape, listening: Bool, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let socket = try XCTUnwrap(openTestSocket(shape, listening: listening), file: file, line: line)
        defer { socket.close() }
        XCTAssertTrue(PortProbe.isInUse(port: socket.port), "\(label) must make its port count as in use.", file: file, line: line)
    }

    func testListenerOnIPv4LoopbackOnlyIsInUse() throws { try assertTaken(.ipv4Loopback, listening: true, "A 127.0.0.1 listener") }

    func testListenerOnIPv6LoopbackOnlyIsInUse() throws { try assertTaken(.ipv6Loopback, listening: true, "A ::1 listener") }

    func testWildcardListenerIsInUse() throws { try assertTaken(.ipv4Any, listening: true, "A wildcard listener") }

    func testReusePortListenerIsInUse() throws { try assertTaken(.reusePortListener, listening: true, "A SO_REUSEPORT listener") }

    func testBoundNotListeningReusePortPlaceholderIsInUse() throws {
        try assertTaken(.placeholder, listening: false, "Another profile's bound-not-listening placeholder")
    }

    func testUnusedPortIsFree() throws {
        let socket = try XCTUnwrap(openTestSocket(.ipv4Any))
        let port = socket.port
        socket.close()
        XCTAssertFalse(PortProbe.isInUse(port: port))
    }

    /// A server that just stopped leaves TIME_WAIT connections on its port. Counting them as in use would
    /// raise a false notice on every quick stop-then-start.
    func testPortWithOnlyTimeWaitLeftoversIsFree() throws {
        let listener = try XCTUnwrap(openTestSocket(.ipv4Loopback, listening: true))
        let port = listener.port
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let accepted = accept(listener.fd, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        // The server side closes first, so the TIME_WAIT entry lands on the listener's port.
        Darwin.close(accepted)
        Darwin.close(client)
        listener.close()

        XCTAssertFalse(PortProbe.isInUse(port: port), "TIME_WAIT leftovers must not count as a holder.")
    }

    func testHolderLookupNamesThisProcessForItsListener() throws {
        let listener = try XCTUnwrap(openTestSocket(.ipv4Any, listening: true))
        defer { listener.close() }

        let holder = try XCTUnwrap(PortHolderLookup.holder(ofPort: listener.port))

        var name = [CChar](repeating: 0, count: 256)
        XCTAssertGreaterThan(proc_name(getpid(), &name, UInt32(name.count)), 0)
        XCTAssertEqual(holder, PortHolder(pid: getpid(), name: String(cString: name)))
    }

    func testHolderLookupFindsNothingForAFreePort() throws {
        let socket = try XCTUnwrap(openTestSocket(.ipv4Any))
        let port = socket.port
        socket.close()
        XCTAssertNil(PortHolderLookup.holder(ofPort: port))
    }
}
