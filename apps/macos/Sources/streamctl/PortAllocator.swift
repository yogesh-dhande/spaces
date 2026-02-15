import Foundation

public final class PortAllocator {
    private let store: SQLiteStore

    public init(store: SQLiteStore) { self.store = store }

    public func allocatePorts(workspaceID: String, definitions: [PortDefinition], range: PortRange) throws -> [Int] {
        let count = definitions.count
        guard count > 0 else {
            try store.setWorkspacePorts(workspaceID: workspaceID, ports: [], names: [])
            return []
        }
        let inUse = try allReservedPorts()
        var allocated: [Int] = []
        for port in range.start...range.end {
            if inUse.contains(port) { continue }
            allocated.append(port)
            if allocated.count == count { break }
        }
        guard allocated.count == count else {
            throw SpaceshipError.invalidArgument(message: "Insufficient free ports in range \(range.start)-\(range.end).")
        }
        let names = definitions.map(\.name)
        try store.setWorkspacePorts(workspaceID: workspaceID, ports: allocated, names: names)
        PortReserver.shared.reservePorts(workspaceID: workspaceID, ports: allocated)
        return allocated
    }

    public func releasePorts(workspaceID: String) throws {
        try store.releaseWorkspacePorts(workspaceID: workspaceID)
        PortReserver.shared.releasePorts(workspaceID: workspaceID)
    }

    public func reserveExistingPorts(workspaceID: String) throws {
        let ports = try store.workspacePorts(workspaceID: workspaceID)
        guard !ports.isEmpty else { return }
        PortReserver.shared.reservePorts(workspaceID: workspaceID, ports: ports)
    }

    private func allReservedPorts() throws -> Set<Int> {
        let projects = try store.projects()
        var all: Set<Int> = []
        for project in projects {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
            for workspace in workspaces {
                let ports = try store.workspacePorts(workspaceID: workspace.id)
                for port in ports { all.insert(port) }
            }
        }
        return all
    }
}
