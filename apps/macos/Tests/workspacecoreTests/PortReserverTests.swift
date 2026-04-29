import Darwin
import XCTest

@testable import workspacecore

final class PortReserverTests: XCTestCase {
    // Unique prefix per test run to avoid collisions with other tests running in parallel.
    private let prefix = "portreserver-test-\(ProcessInfo.processInfo.processIdentifier)"

    override func tearDown() {
        // Release any workspaces this test class may have reserved.
        for id in PortReserver.shared.reservedWorkspaceIDs() where id.hasPrefix(prefix) { PortReserver.shared.releasePorts(workspaceID: id) }
        super.tearDown()
    }

    // Tests reservePorts tracks the workspace ID by arranging representative inputs and asserting the expected result.
    func testReservePortsTracksWorkspaceID() {
        let wsID = "\(prefix)-alpha"
        PortReserver.shared.reservePorts(workspaceID: wsID, ports: [])
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(wsID))
    }

    // Tests reservePorts with valid port creates socket binding by arranging representative inputs and asserting the expected result.
    func testReservePortsWithHighPortSucceeds() {
        let wsID = "\(prefix)-beta"
        // Port 0 lets the OS assign an ephemeral port — bind always succeeds.
        PortReserver.shared.reservePorts(workspaceID: wsID, ports: [0])
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(wsID))
    }

    // Tests releasePorts removes the workspace from tracked IDs by arranging representative inputs and asserting the expected result.
    func testReleasePortsRemovesWorkspaceID() {
        let wsID = "\(prefix)-gamma"
        PortReserver.shared.reservePorts(workspaceID: wsID, ports: [])
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(wsID))

        PortReserver.shared.releasePorts(workspaceID: wsID)
        XCTAssertFalse(PortReserver.shared.reservedWorkspaceIDs().contains(wsID))
    }

    // Tests releasePorts on unknown workspace is a no-op by arranging representative inputs and asserting the expected result.
    func testReleasePortsUnknownWorkspaceIsNoOp() {
        let wsID = "\(prefix)-nonexistent"
        // Should not crash or throw when releasing a workspace that was never reserved.
        PortReserver.shared.releasePorts(workspaceID: wsID)
        XCTAssertFalse(PortReserver.shared.reservedWorkspaceIDs().contains(wsID))
    }

    // Tests reservePorts overwrites previous reservation for the same workspace by arranging representative inputs and asserting the expected result.
    func testReservePortsOverwritesPreviousReservation() {
        let wsID = "\(prefix)-delta"
        PortReserver.shared.reservePorts(workspaceID: wsID, ports: [0])
        PortReserver.shared.reservePorts(workspaceID: wsID, ports: [0])
        // After overwrite, workspace should still be tracked.
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(wsID))
        // And releasing should remove it cleanly.
        PortReserver.shared.releasePorts(workspaceID: wsID)
        XCTAssertFalse(PortReserver.shared.reservedWorkspaceIDs().contains(wsID))
    }

    // Tests reservedWorkspaceIDs returns all tracked IDs by arranging representative inputs and asserting the expected result.
    func testReservedWorkspaceIDsReturnsAllIDs() {
        let id1 = "\(prefix)-1"
        let id2 = "\(prefix)-2"
        let id3 = "\(prefix)-3"
        PortReserver.shared.reservePorts(workspaceID: id1, ports: [])
        PortReserver.shared.reservePorts(workspaceID: id2, ports: [])
        PortReserver.shared.reservePorts(workspaceID: id3, ports: [])
        let ids = PortReserver.shared.reservedWorkspaceIDs()
        XCTAssertTrue(ids.contains(id1))
        XCTAssertTrue(ids.contains(id2))
        XCTAssertTrue(ids.contains(id3))
    }

    // Tests reservePorts with a privileged port (1) which requires root — bind fails gracefully,
    // covering the Darwin.close(fd); return nil path in bindSocket.
    func testReservePortsWithPrivilegedPortHandlesBindFailure() {
        let wsID = "\(prefix)-privileged"
        // Port 1 is privileged; bind will fail without root. This exercises the bind-failure path.
        PortReserver.shared.reservePorts(workspaceID: wsID, ports: [1])
        // Even when bind fails, the workspace is still tracked (with an empty fd list).
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(wsID))
        PortReserver.shared.releasePorts(workspaceID: wsID)
    }

    func testReleasePortsLetsAnotherSocketBindPreviouslyReservedPort() throws {
        let wsID = "\(prefix)-handoff"
        let port = try temporaryBoundPort()
        PortReserver.shared.reservePorts(workspaceID: wsID, ports: [port])

        XCTAssertEqual(bindSocket(to: port), -1)

        PortReserver.shared.releasePorts(workspaceID: wsID)

        let fd = bindSocket(to: port)
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 { Darwin.close(fd) }
    }

    private func temporaryBoundPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { throw XCTSkip("Failed to allocate socket.") }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in getsockname(fd, sockaddrPtr, &length) }
        }
        XCTAssertEqual(nameResult, 0)
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func bindSocket(to port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            Darwin.close(fd)
            return -1
        }
        return fd
    }
}
