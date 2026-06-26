import XCTest

@testable import workspacecore

final class PortAllocatorTests: XCTestCase {
    // Tests allocate skips reserved ports by arranging representative inputs and asserting the expected result.
    func testAllocateSkipsReservedPorts() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspaceA = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspaceA)
        try store.upsert(workspace: workspaceB)
        try store.setWorkspacePorts(workspaceID: workspaceA.id, ports: [20000, 20001], names: ["RESERVED_API", "RESERVED_WEB"])

        let allocator = PortAllocator(store: store)
        let definitions = [PortDefinition(name: "API_PORT"), PortDefinition(name: "WEB_PORT")]
        let ports = try allocator.allocatePorts(workspaceID: workspaceB.id, definitions: definitions, range: PortRange(start: 20000, end: 20003))

        XCTAssertEqual(ports, [20002, 20003])
        let stored = try store.workspacePorts(workspaceID: workspaceB.id)
        XCTAssertEqual(stored, [20002, 20003])
        let named = try store.workspacePortsNamed(workspaceID: workspaceB.id)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(named[0].name, "API_PORT")
        XCTAssertEqual(named[0].port, 20002)
        XCTAssertEqual(named[1].name, "WEB_PORT")
        XCTAssertEqual(named[1].port, 20003)
    }

    // Tests allocate throws when insufficient ports by arranging representative inputs and asserting the expected result.
    func testAllocateThrowsWhenInsufficientPorts() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspaceA = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspaceA)
        try store.upsert(workspace: workspaceB)
        try store.setWorkspacePorts(workspaceID: workspaceA.id, ports: [20000, 20001, 20002], names: ["RESERVED_1", "RESERVED_2", "RESERVED_3"])

        let allocator = PortAllocator(store: store)
        let definitions = [PortDefinition(name: "API_PORT"), PortDefinition(name: "WEB_PORT")]

        XCTAssertThrowsError(
            try allocator.allocatePorts(workspaceID: workspaceB.id, definitions: definitions, range: PortRange(start: 20000, end: 20002))
        ) { error in guard case WorkspaceError.invalidArgument = error else { return XCTFail("Unexpected error: \(error)") } }

        let stored = try store.workspacePorts(workspaceID: workspaceB.id)
        XCTAssertEqual(stored, [])
    }

    // Tests allocate with empty definitions allocates no ports by arranging representative inputs and asserting the expected result.
    func testAllocateWithEmptyDefinitionsAllocatesNoPorts() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)

        let allocator = PortAllocator(store: store)
        let ports = try allocator.allocatePorts(workspaceID: workspace.id, definitions: [], range: PortRange(start: 20000, end: 20003))

        XCTAssertEqual(ports, [])
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
    }

    // Tests reserveExistingPorts with stored ports calls PortReserver (covers the non-empty ports path at line 38).
    func testReserveExistingPortsWithStoredPortsCallsPortReserver() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)

        // Store ports directly so reserveExistingPorts finds a non-empty list.
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [29001, 29002], names: ["API_PORT", "WEB_PORT"])

        let allocator = PortAllocator(store: store)
        // Should not throw and should call PortReserver.shared.reservePorts (non-empty ports path).
        XCTAssertNoThrow(try allocator.reserveExistingPorts(workspaceID: workspace.id))

        // Verify PortReserver tracks the workspace as reserved.
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))

        // Cleanup: release so other tests are not affected.
        PortReserver.shared.releasePorts(workspaceID: workspace.id)
    }

    func testSyncPortsPreservesExistingAssignmentsAndAllocatesAddedPort() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [20010], names: ["API_PORT"])

        let allocator = PortAllocator(store: store)
        let ports = try allocator.syncPorts(
            workspaceID: workspace.id, definitions: [PortDefinition(name: "API_PORT"), PortDefinition(name: "WEB_PORT")],
            range: PortRange(start: 20010, end: 20020))

        XCTAssertEqual(ports, [20010, 20011])
        let named = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.map(\.port), [20010, 20011])
        XCTAssertEqual(named.map(\.name), ["API_PORT", "WEB_PORT"])
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))

        PortReserver.shared.releasePorts(workspaceID: workspace.id)
    }

    func testSyncPortsKeepsInsertedDefinitionsAlignedWithAssignments() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)

        let api = PortDefinition(id: "port-api", name: "API_PORT")
        let web = PortDefinition(id: "port-web", name: "WEB_PORT")
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: [api])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [20010], names: [api.name], definitionIDs: [api.id])

        let allocator = PortAllocator(store: store)
        let ports = try allocator.syncPorts(workspaceID: workspace.id, definitions: [web, api], range: PortRange(start: 20010, end: 20020))

        XCTAssertEqual(ports, [20011, 20010])
        let assigned = try store.workspacePortsAssigned(workspaceID: workspace.id)
        XCTAssertEqual(assigned.map(\.name), [web.name, api.name])
        XCTAssertEqual(assigned.map(\.port), [20011, 20010])
        XCTAssertEqual(assigned.map(\.definitionID), [web.id, api.id])

        PortReserver.shared.releasePorts(workspaceID: workspace.id)
    }

    func testSyncPortsPreservesAssignmentsByDefinitionIDAcrossReorderAndRename() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)

        let api = PortDefinition(id: "port-api", name: "API_PORT")
        let web = PortDefinition(id: "port-web", name: "WEB_PORT")
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: [api, web])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [20000, 20001], names: [api.name, web.name], definitionIDs: [api.id, web.id])

        let allocator = PortAllocator(store: store)
        let ports = try allocator.syncPorts(
            workspaceID: workspace.id, definitions: [PortDefinition(id: web.id, name: "FRONTEND_PORT")], range: PortRange(start: 20000, end: 20020))

        XCTAssertEqual(ports, [20001])
        let named = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.map(\.port), [20001])
        XCTAssertEqual(named.map(\.name), ["FRONTEND_PORT"])
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: workspace.id).map(\.definitionID), [web.id])

        PortReserver.shared.releasePorts(workspaceID: workspace.id)
    }
}
