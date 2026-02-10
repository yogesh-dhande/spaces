import XCTest

@testable import streamctl

final class PortAllocatorTests: XCTestCase {
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
        let ports = try allocator.allocatePorts(
            workspaceID: workspaceB.id,
            count: 2,
            range: PortRange(start: 20000, end: 20003)
        )

        XCTAssertEqual(ports, [20002, 20003])
        let stored = try store.workspacePorts(workspaceID: workspaceB.id)
        XCTAssertEqual(stored, [20002, 20003])
    }

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

        XCTAssertThrowsError(
            try allocator.allocatePorts(
                workspaceID: workspaceB.id,
                count: 2,
                range: PortRange(start: 20000, end: 20002)
            )
        ) { error in
            guard case AgentmuxError.invalidArgument = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let stored = try store.workspacePorts(workspaceID: workspaceB.id)
        XCTAssertEqual(stored, [])
    }
}
