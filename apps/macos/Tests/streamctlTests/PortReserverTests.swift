import XCTest

@testable import streamctl

final class PortReserverTests: XCTestCase {
    // Unique prefix per test run to avoid collisions with other tests running in parallel.
    private let prefix = "portreserver-test-\(ProcessInfo.processInfo.processIdentifier)"

    override func tearDown() {
        // Release any workspaces this test class may have reserved.
        for id in PortReserver.shared.reservedWorkspaceIDs() where id.hasPrefix(prefix) {
            PortReserver.shared.releasePorts(workspaceID: id)
        }
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
}
