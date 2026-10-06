import XCTest

@testable import workspacecore

final class PortAllocatorTests: XCTestCase {
    func testAllocateSkipsReservedPorts() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspaceA = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspaceA)
        try store.upsert(workspace: workspaceB)
        // New assignments probe the machine, so the range is one this process has just found free.
        let range = try probeBindablePortRange(count: 4)
        try store.setWorkspacePorts(workspaceID: workspaceA.id, ports: [range.start, range.start + 1], names: ["reserved-api", "reserved-web"])

        let allocator = PortAllocator(store: store)
        let definitions = [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")]
        let ports = try allocator.allocatePorts(workspaceID: workspaceB.id, definitions: definitions, range: range)

        XCTAssertEqual(ports, [range.start + 2, range.start + 3])
        let stored = try store.workspacePorts(workspaceID: workspaceB.id)
        XCTAssertEqual(stored, [range.start + 2, range.start + 3])
        let named = try store.workspacePortsNamed(workspaceID: workspaceB.id)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(named[0].name, "api")
        XCTAssertEqual(named[0].port, range.start + 2)
        XCTAssertEqual(named[1].name, "web")
        XCTAssertEqual(named[1].port, range.start + 3)
    }

    func testAllocateThrowsWhenInsufficientPorts() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspaceA = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        let workspaceB = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspaceA)
        try store.upsert(workspace: workspaceB)
        try store.setWorkspacePorts(workspaceID: workspaceA.id, ports: [20000, 20001, 20002], names: ["reserved-1", "reserved-2", "reserved-3"])

        let allocator = PortAllocator(store: store)
        let definitions = [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")]

        XCTAssertThrowsError(
            try allocator.allocatePorts(workspaceID: workspaceB.id, definitions: definitions, range: PortRange(start: 20000, end: 20002))
        ) { error in guard case WorkspaceError.invalidArgument = error else { return XCTFail("Unexpected error: \(error)") } }

        let stored = try store.workspacePorts(workspaceID: workspaceB.id)
        XCTAssertEqual(stored, [])
    }

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

    func testSyncPortsPreservesExistingAssignmentsAndAllocatesAddedPort() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)
        let range = try probeBindablePortRange(count: 4)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [range.start], names: ["api"])

        let allocator = PortAllocator(store: store)
        let ports = try allocator.syncPorts(
            workspaceID: workspace.id, definitions: [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")], range: range)

        XCTAssertEqual(ports, [range.start, range.start + 1])
        let named = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.map(\.port), [range.start, range.start + 1])
        XCTAssertEqual(named.map(\.name), ["api", "web"])
    }

    func testSyncPortsKeepsInsertedDefinitionsAlignedWithAssignments() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)

        let api = ServiceDefinition(id: "port-api", name: "api")
        let web = ServiceDefinition(id: "port-web", name: "web")
        try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: [api])
        let range = try probeBindablePortRange(count: 4)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [range.start], names: [api.name], definitionIDs: [api.id])

        let allocator = PortAllocator(store: store)
        let ports = try allocator.syncPorts(workspaceID: workspace.id, definitions: [web, api], range: range)

        XCTAssertEqual(ports, [range.start + 1, range.start])
        let assigned = try store.workspacePortsAssigned(workspaceID: workspace.id)
        XCTAssertEqual(assigned.map(\.name), [web.name, api.name])
        XCTAssertEqual(assigned.map(\.port), [range.start + 1, range.start])
        XCTAssertEqual(assigned.map(\.definitionID), [web.id, api.id])
    }

    func testSyncPortsPreservesAssignmentsByDefinitionIDAcrossReorderAndRename() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)

        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)

        let api = ServiceDefinition(id: "port-api", name: "api")
        let web = ServiceDefinition(id: "port-web", name: "web")
        try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: [api, web])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [20000, 20001], names: [api.name, web.name], definitionIDs: [api.id, web.id])

        let allocator = PortAllocator(store: store)
        let ports = try allocator.syncPorts(
            workspaceID: workspace.id, definitions: [ServiceDefinition(id: web.id, name: "frontend")], range: PortRange(start: 20000, end: 20020))

        XCTAssertEqual(ports, [20001])
        let named = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.map(\.port), [20001])
        XCTAssertEqual(named.map(\.name), ["frontend"])
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: workspace.id).map(\.definitionID), [web.id])
    }

    func testAllocateSkipsPortsSomethingIsListeningOn() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)
        let holder = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: holder)
        try store.upsert(workspace: workspace)
        let range = try probeBindablePortRange(count: 5)

        // The lowest port has a foreign listener and the next is assigned to another workspace.
        let listener = try XCTUnwrap(openTestSocket(.ipv4Any, port: range.start, listening: true))
        addTeardownBlock { listener.close() }
        try store.setWorkspacePorts(workspaceID: holder.id, ports: [range.start + 1], names: ["held"])

        let ports = try PortAllocator(store: store).allocatePorts(
            workspaceID: workspace.id, definitions: [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")], range: range)

        XCTAssertEqual(ports, [range.start + 2, range.start + 3])
    }

    func testSyncPortsSkipsPortsSomethingIsListeningOnButKeepsExistingAssignments() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(workspace: workspace)
        let range = try probeBindablePortRange(count: 5)

        // The existing assignment is held by a foreign listener and still stays with the workspace.
        let listener = try XCTUnwrap(openTestSocket(.ipv4Loopback, port: range.start, listening: true))
        let nextListener = try XCTUnwrap(openTestSocket(.ipv4Any, port: range.start + 1, listening: true))
        addTeardownBlock {
            listener.close()
            nextListener.close()
        }
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [range.start], names: ["api"])

        let ports = try PortAllocator(store: store).syncPorts(
            workspaceID: workspace.id, definitions: [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")], range: range)

        XCTAssertEqual(ports, [range.start, range.start + 2])
    }
}
