import Darwin
import XCTest

@testable import workspacecore

/// Reproduces the launch-window port-reservation race.
///
/// When a workspace launches, `Orchestrator.launchWorkspaceUnlocked` releases its placeholder
/// reservation sockets so the real server can bind the port, then marks the workspace running. A dev
/// server such as `next dev --turbopack` can take several seconds to actually `bind()` (turbopack cold
/// start), leaving the port free the whole time. If any reserve path (a settings `syncPorts`, a stray
/// `reserveExistingPorts`) fires during that window it used to re-grab the freed port; because the
/// reservation socket uses `SO_REUSEPORT` while the dev server does not, the reserver's re-grab then
/// blocks the real server and it dies with EADDRINUSE — the workspace ends up `running=true` with the
/// reserver holding the port and no real listener.
///
/// The contract: placeholder reservations exist only while the workspace is stopped. These tests pin
/// that behavior and confirm stopped workspaces are still reserved.
final class PortReservationRaceTests: XCTestCase {
    private var reservedWorkspaceIDs: [String] = []

    override func tearDown() {
        for id in reservedWorkspaceIDs { PortReserver.shared.releasePorts(workspaceID: id) }
        reservedWorkspaceIDs.removeAll()
        super.tearDown()
    }

    // A stray reserveExistingPorts during the launch window must not re-grab a running workspace's
    // port, so its dev server (which does not set SO_REUSEPORT) can still bind it.
    func testReserveExistingPortsSkipsRunningWorkspaceSoServerCanBind() throws {
        let (store, workspace) = try makeWorkspace()
        let port = try freeEphemeralPort()
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [port], names: ["web"])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-07-01T00:00:00Z")

        try PortAllocator(store: store).reserveExistingPorts(workspaceID: workspace.id)

        XCTAssertFalse(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id), "A running workspace's ports must not be reserved.")
        let serverFD = bindPlainSocket(to: port)
        XCTAssertGreaterThanOrEqual(serverFD, 0, "Running workspace's server must be able to bind its port without hitting EADDRINUSE.")
        if serverFD >= 0 { Darwin.close(serverFD) }
    }

    // A settings edit that re-syncs ports while the workspace runs must still persist assignments but
    // must not bind the reservation sockets.
    func testSyncPortsPersistsButDoesNotReserveRunningWorkspace() throws {
        let (store, workspace) = try makeWorkspace()
        let port = try freeEphemeralPort()
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [port], names: ["web"])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-07-01T00:00:00Z")

        let resolved = try PortAllocator(store: store).syncPorts(
            workspaceID: workspace.id, definitions: [ServiceDefinition(name: "web")], range: PortRange(start: port, end: port))

        XCTAssertEqual(resolved, [port])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [port], "Assignments must still be persisted.")
        XCTAssertFalse(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))
        let serverFD = bindPlainSocket(to: port)
        XCTAssertGreaterThanOrEqual(serverFD, 0)
        if serverFD >= 0 { Darwin.close(serverFD) }
    }

    // A running workspace must not keep stale placeholder reservations, even if it was marked running
    // by an ad-hoc terminal path before the placeholders were released.
    func testSyncPortsReleasesExistingReservationsForRunningTerminalOnlyWorkspace() throws {
        let (store, workspace) = try makeWorkspace()
        let oldService = ServiceDefinition(id: "old-service", name: "api")
        let newService = ServiceDefinition(id: "new-service", name: "web")
        let oldPort = try freeEphemeralPort()
        var newPort = try freeEphemeralPort()
        for _ in 0..<20 where newPort == oldPort { newPort = try freeEphemeralPort() }
        guard newPort != oldPort else { throw XCTSkip("Could not allocate two distinct ephemeral ports.") }
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [oldPort], names: [oldService.name], definitionIDs: [oldService.id])
        reservedWorkspaceIDs.append(workspace.id)
        PortReserver.shared.reservePorts(workspaceID: workspace.id, ports: [oldPort])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-07-01T00:00:00Z")

        let resolved = try PortAllocator(store: store).syncPorts(
            workspaceID: workspace.id, definitions: [newService], range: PortRange(start: newPort, end: newPort))

        XCTAssertEqual(resolved, [newPort])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [newPort])
        XCTAssertFalse(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))
        let oldPortFD = bindPlainSocket(to: oldPort)
        XCTAssertGreaterThanOrEqual(oldPortFD, 0, "Removed service port should be released from the placeholder reservation.")
        if oldPortFD >= 0 { Darwin.close(oldPortFD) }
        let newPortFD = bindPlainSocket(to: newPort)
        XCTAssertGreaterThanOrEqual(newPortFD, 0, "Running workspace service ports are not placeholder-reserved.")
        if newPortFD >= 0 { Darwin.close(newPortFD) }
    }

    // Control: a stopped workspace's ports are still reserved, so nothing else claims them before the
    // next launch. This confirms the running-workspace rule did not disable reservation altogether.
    func testReserveExistingPortsStillReservesStoppedWorkspace() throws {
        let (store, workspace) = try makeWorkspace()
        let port = try freeEphemeralPort()
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [port], names: ["web"])
        reservedWorkspaceIDs.append(workspace.id)

        try PortAllocator(store: store).reserveExistingPorts(workspaceID: workspace.id)

        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))
        XCTAssertEqual(bindPlainSocket(to: port), -1, "A stopped workspace's reserved port must be held against other binders.")
    }

    private func makeWorkspace() throws -> (SQLiteStore, WorkspaceRecord) {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)
        return (store, workspace)
    }

    // Binds an ephemeral port, reads the assigned number, then frees it — yielding a port number that
    // is free at return time for the test to drive through the reserver and a stand-in server.
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

    // A plain server bind (no SO_REUSEPORT), mirroring how dev servers bind. Returns the fd on
    // success, or -1 if the port is already held (EADDRINUSE).
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
