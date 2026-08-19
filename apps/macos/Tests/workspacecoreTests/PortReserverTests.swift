import Darwin
import XCTest

@testable import workspacecore

/// Placeholder bookkeeping, keyed by port. Ports come from `freeEphemeralPort()` so a real daemon's
/// reservations on this machine are never involved.
final class PortReserverTests: XCTestCase {
    private var portsToRelease: Set<Int> = []

    override func tearDown() {
        clearPortReservationsForTest(portsToRelease)
        portsToRelease.removeAll()
        super.tearDown()
    }

    func testSyncBindsDesiredPortsAndClosesTheRest() throws {
        let kept = try freeEphemeralPort()
        let dropped = try distinctFreeEphemeralPort(from: [kept])
        portsToRelease.formUnion([kept, dropped])

        PortReserver.shared.sync(desiredPorts: PortReserver.shared.reservedPorts().union([kept, dropped]))
        XCTAssertEqual(bindPlainSocket(to: kept), -1)
        XCTAssertEqual(bindPlainSocket(to: dropped), -1)

        PortReserver.shared.sync(desiredPorts: PortReserver.shared.reservedPorts().subtracting([dropped]))

        XCTAssertEqual(bindPlainSocket(to: kept), -1, "A port still wanted keeps its placeholder.")
        let fd = bindPlainSocket(to: dropped)
        XCTAssertGreaterThanOrEqual(fd, 0, "A port no longer wanted must be released.")
        if fd >= 0 { Darwin.close(fd) }
    }

    func testRuntimeStartHoldFreesOnlyTheNamedPorts() throws {
        let launching = try freeEphemeralPort()
        let untouched = try distinctFreeEphemeralPort(from: [launching])
        portsToRelease.formUnion([launching, untouched])
        PortReserver.shared.sync(desiredPorts: PortReserver.shared.reservedPorts().union([launching, untouched]))

        PortReserver.shared.beginRuntimeStartHold(ports: [launching])

        let fd = bindPlainSocket(to: launching)
        XCTAssertGreaterThanOrEqual(fd, 0, "A launching workspace's server must be able to bind its assigned port.")
        if fd >= 0 { Darwin.close(fd) }
        XCTAssertEqual(bindPlainSocket(to: untouched), -1)
        XCTAssertFalse(PortReserver.shared.reservedPorts().contains(launching))
        XCTAssertTrue(PortReserver.shared.reservedPorts().contains(untouched))
    }

    // The mid-launch race: the launch's own database writes make a reconcile pass run while the
    // workspace record still says stopped, so the pass still wants this port. The hold is what keeps it
    // from rebinding the placeholder under a server that can take seconds to come up.
    func testSyncDoesNotRebindAPortUnderARuntimeStartHold() throws {
        let launching = try freeEphemeralPort()
        portsToRelease.insert(launching)
        PortReserver.shared.sync(desiredPorts: PortReserver.shared.reservedPorts().union([launching]))
        XCTAssertEqual(bindPlainSocket(to: launching), -1)

        PortReserver.shared.beginRuntimeStartHold(ports: [launching])
        PortReserver.shared.sync(desiredPorts: PortReserver.shared.reservedPorts().union([launching]))

        let fd = bindPlainSocket(to: launching)
        XCTAssertGreaterThanOrEqual(fd, 0, "A reconcile pass mid-launch must not rebind a held port.")
        if fd >= 0 { Darwin.close(fd) }
        XCTAssertFalse(PortReserver.shared.reservedPorts().contains(launching))
    }

    // The failed-launch restore: nothing took the port, the workspace is still stopped, so the
    // placeholder comes straight back instead of waiting for the next reconcile pass.
    func testEndRuntimeStartHoldRebindsThePlaceholder() throws {
        let launching = try freeEphemeralPort()
        portsToRelease.insert(launching)
        PortReserver.shared.beginRuntimeStartHold(ports: [launching])

        PortReserver.shared.endRuntimeStartHold(ports: [launching])

        XCTAssertEqual(bindPlainSocket(to: launching), -1, "A failed launch must leave the stopped workspace's port held.")
        XCTAssertTrue(PortReserver.shared.reservedPorts().contains(launching))
    }

    // The failed-launch path for a workspace that was already running: its ports stay unreserved while
    // it runs, but the hold has to go, or it outlives the workspace stopping and blocks the pass that
    // holds its pinned ports again.
    func testClearRuntimeStartHoldDropsTheHoldWithoutBinding() throws {
        let launching = try freeEphemeralPort()
        portsToRelease.insert(launching)
        PortReserver.shared.beginRuntimeStartHold(ports: [launching])

        PortReserver.shared.clearRuntimeStartHold(ports: [launching])

        let fd = bindPlainSocket(to: launching)
        XCTAssertGreaterThanOrEqual(fd, 0, "Clearing a hold must not bind a placeholder over the workspace's running servers.")
        if fd >= 0 { Darwin.close(fd) }
        XCTAssertFalse(PortReserver.shared.reservedPorts().contains(launching))

        // The workspace stops: the first pass that wants the port again must be able to hold it.
        PortReserver.shared.sync(desiredPorts: PortReserver.shared.reservedPorts().union([launching]))

        XCTAssertEqual(bindPlainSocket(to: launching), -1, "A stopped workspace's port must be held again once the failed launch's hold is cleared.")
        XCTAssertTrue(PortReserver.shared.reservedPorts().contains(launching))
    }

    // A hold is self-healing: the port leaving the desired set means the launch marked the workspace
    // running (or the record went away), so a later stopped-state pass must be free to rebind.
    func testSyncClearsAHoldOnceThePortLeavesTheDesiredSet() throws {
        let launching = try freeEphemeralPort()
        portsToRelease.insert(launching)
        PortReserver.shared.beginRuntimeStartHold(ports: [launching])

        // The workspace is marked running: its port is no longer wanted as a placeholder.
        PortReserver.shared.sync(desiredPorts: PortReserver.shared.reservedPorts().subtracting([launching]))
        // It stops again: the placeholder must come back.
        PortReserver.shared.sync(desiredPorts: PortReserver.shared.reservedPorts().union([launching]))

        XCTAssertEqual(bindPlainSocket(to: launching), -1, "A stopped workspace's port must be held again once its hold has served its purpose.")
        XCTAssertTrue(PortReserver.shared.reservedPorts().contains(launching))
    }

    private func distinctFreeEphemeralPort(from used: Set<Int>) throws -> Int {
        for _ in 0..<20 {
            let port = try freeEphemeralPort()
            if !used.contains(port) { return port }
        }
        throw XCTSkip("Could not allocate a distinct ephemeral port.")
    }

    private func freeEphemeralPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("Failed to allocate socket.") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bindResult, 0)
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        XCTAssertEqual(nameResult, 0)
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func bindPlainSocket(to port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            Darwin.close(fd)
            return -1
        }
        return fd
    }
}
