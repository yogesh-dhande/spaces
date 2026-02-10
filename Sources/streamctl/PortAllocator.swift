import Foundation

public final class PortAllocator {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func allocatePorts(workspaceID: String, count: Int, range: PortRange) throws -> [Int] {
        let inUse = try allReservedPorts()
        var allocated: [Int] = []
        for port in range.start...range.end {
            if inUse.contains(port) { continue }
            allocated.append(port)
            if allocated.count == count { break }
        }
        guard allocated.count == count else {
            throw AgentmuxError.invalidArgument(
                message: "Insufficient free ports in range \(range.start)-\(range.end).")
        }
        try store.setWorkspacePorts(workspaceID: workspaceID, ports: allocated)
        return allocated
    }

    public func releasePorts(workspaceID: String) throws {
        try store.releaseWorkspacePorts(workspaceID: workspaceID)
    }

    private func allReservedPorts() throws -> Set<Int> {
        let projects = try store.projects()
        var all: Set<Int> = []
        for project in projects {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
            for workspace in workspaces {
                let ports = try store.workspacePorts(workspaceID: workspace.id)
                for port in ports {
                    all.insert(port)
                }
            }
        }
        return all
    }
}
