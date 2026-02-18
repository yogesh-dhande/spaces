import XCTest

@testable import streamctl

final class PortAllocatorTests: XCTestCase {
    // Tests allocate skips reserved ports by arranging representative inputs and asserting the expected result.
    func testAllocateSkipsReservedPorts() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspaceA = makeWorkspaceRecord(projectID: project.id, name: "alpha", dir: projectDir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, name: "beta", dir: projectDir)
        try store.upsert(workspace: workspaceA)
        try store.upsert(workspace: workspaceB)
        try store.setWorkspacePorts(workspaceID: workspaceA.id, ports: [20000, 20001])

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

        let workspaceA = makeWorkspaceRecord(projectID: project.id, name: "alpha", dir: projectDir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, name: "beta", dir: projectDir)
        try store.upsert(workspace: workspaceA)
        try store.upsert(workspace: workspaceB)
        try store.setWorkspacePorts(workspaceID: workspaceA.id, ports: [20000, 20001, 20002])

        let allocator = PortAllocator(store: store)
        let definitions = [PortDefinition(name: "API_PORT"), PortDefinition(name: "WEB_PORT")]

        XCTAssertThrowsError(
            try allocator.allocatePorts(workspaceID: workspaceB.id, definitions: definitions, range: PortRange(start: 20000, end: 20002))
        ) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let stored = try store.workspacePorts(workspaceID: workspaceB.id)
        XCTAssertEqual(stored, [])
    }

    // Tests allocate with empty definitions allocates no ports by arranging representative inputs and asserting the expected result.
    func testAllocateWithEmptyDefinitionsAllocatesNoPorts() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspace = makeWorkspaceRecord(projectID: project.id, name: "alpha", dir: projectDir)
        try store.upsert(workspace: workspace)

        let allocator = PortAllocator(store: store)
        let ports = try allocator.allocatePorts(workspaceID: workspace.id, definitions: [], range: PortRange(start: 20000, end: 20003))

        XCTAssertEqual(ports, [])
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
    }
}
