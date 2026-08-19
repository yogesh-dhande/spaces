import Darwin
import XCTest

@testable import workspacecore

/// Placeholder port reservations are derived from the store, so what these assert is the observable
/// product contract: whether a would-be server (a plain bind, as dev servers do it) can take the port.
///
/// Every port here comes from `freeEphemeralPort()`, never from the configured workspace range, so a
/// real daemon's reservations on this machine are untouched.
final class PortReservationReconcilerTests: XCTestCase {
    private var portsToRelease: Set<Int> = []

    override func tearDown() {
        clearPortReservationsForTest(portsToRelease)
        portsToRelease.removeAll()
        super.tearDown()
    }

    // The leak: a workspace deleted by another process leaves this process holding its placeholder, and
    // nothing in the delete path can close it. The next reconcile pass has to.
    func testReconcileReleasesPlaceholderForAWorkspaceDeletedElsewhere() throws {
        let (store, workspace) = try makeStoppedWorkspace()
        let port = try freeEphemeralPort()
        portsToRelease.insert(port)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [port], names: ["web"])
        let reconciler = PortReservationReconciler(store: store)

        try reconciler.reconcile()
        XCTAssertEqual(bindPlainSocket(to: port), -1, "A stopped workspace's assigned port must be held.")

        // Another process deletes the workspace: the rows go away, no release call reaches this process.
        try store.deleteWorkspace(id: workspace.id)
        try reconciler.reconcile()

        let fd = bindPlainSocket(to: port)
        XCTAssertGreaterThanOrEqual(fd, 0, "A port no longer assigned to any stopped workspace must not stay held.")
        if fd >= 0 { Darwin.close(fd) }
    }

    // The pre-launch hold is keyed by port, not by whatever workspace the placeholder was bound for,
    // so a workspace that inherits a port another record used to own still frees it before launching.
    func testRuntimeStartHoldFreesAPlaceholderBoundForAnEarlierWorkspace() throws {
        let (store, firstWorkspace) = try makeStoppedWorkspace()
        let port = try freeEphemeralPort()
        portsToRelease.insert(port)
        try store.setWorkspacePorts(workspaceID: firstWorkspace.id, ports: [port], names: ["web"])
        try PortReservationReconciler(store: store).reconcile()
        XCTAssertEqual(bindPlainSocket(to: port), -1)

        // The port is re-assigned to a different workspace while the placeholder still says "first".
        let secondWorkspace = makeWorkspaceRecord(projectID: firstWorkspace.projectID, dir: firstWorkspace.dir)
        try store.upsert(workspace: secondWorkspace)
        try store.releaseWorkspacePorts(workspaceID: firstWorkspace.id)
        try store.setWorkspacePorts(workspaceID: secondWorkspace.id, ports: [port], names: ["web"])

        PortReserver.shared.beginRuntimeStartHold(ports: try store.workspacePorts(workspaceID: secondWorkspace.id))

        let fd = bindPlainSocket(to: port)
        XCTAssertGreaterThanOrEqual(fd, 0, "A launching workspace must free its assigned port whatever reservation held it.")
        if fd >= 0 { Darwin.close(fd) }
    }

    // A launch writes terminal-session and running-process rows before the workspace is marked running,
    // and every write raises `databaseDidChange`, so a reconcile pass runs mid-launch against a record
    // that still says stopped. The runtime-start hold is what keeps that pass from rebinding a
    // placeholder on the port the workspace's own server is still coming up on.
    func testReconcileLeavesAPortHeldForAStartingRuntimeUnbound() throws {
        let (store, workspace) = try makeStoppedWorkspace()
        let port = try freeEphemeralPort()
        portsToRelease.insert(port)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [port], names: ["web"])
        let reconciler = PortReservationReconciler(store: store)
        try reconciler.reconcile()
        XCTAssertEqual(bindPlainSocket(to: port), -1)

        PortReserver.shared.beginRuntimeStartHold(ports: [port])
        // The launch's own writes drive a pass while the workspace record still says stopped.
        try reconciler.reconcile()

        let fd = bindPlainSocket(to: port)
        XCTAssertGreaterThanOrEqual(fd, 0, "A reconcile pass during a launch must not rebind the launching workspace's port.")
        if fd >= 0 { Darwin.close(fd) }
    }

    // A running workspace's ports belong to its own servers, which bind without SO_REUSEPORT and would
    // fail with EADDRINUSE against a placeholder.
    func testReconcileReleasesPlaceholdersWhenTheWorkspaceStartsRunning() throws {
        let (store, workspace) = try makeStoppedWorkspace()
        let port = try freeEphemeralPort()
        portsToRelease.insert(port)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [port], names: ["web"])
        let reconciler = PortReservationReconciler(store: store)
        try reconciler.reconcile()
        XCTAssertEqual(bindPlainSocket(to: port), -1)

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-07-01T00:00:00Z")
        try reconciler.reconcile()

        let fd = bindPlainSocket(to: port)
        XCTAssertGreaterThanOrEqual(fd, 0, "A running workspace's server must be able to bind its assigned port.")
        if fd >= 0 { Darwin.close(fd) }

        // And the placeholder comes back once the workspace stops, so nothing else claims the port.
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: "2026-07-01T00:00:00Z")
        try reconciler.reconcile()
        XCTAssertEqual(bindPlainSocket(to: port), -1, "A stopped workspace holds its pinned ports again.")
    }

    private func makeStoppedWorkspace() throws -> (SQLiteStore, WorkspaceRecord) {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)
        return (store, workspace)
    }

    // Binds an ephemeral port, reads the assigned number, then frees it — yielding a port number that is
    // free at return time and outside any workspace port range a real daemon reserves.
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

    // A plain server bind (no SO_REUSEPORT), mirroring how dev servers bind. Returns the fd on success,
    // or -1 if a placeholder still holds the port (EADDRINUSE).
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
