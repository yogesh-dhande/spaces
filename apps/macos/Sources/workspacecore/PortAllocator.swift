import Foundation

public final class PortAllocator {
    private let store: SQLiteStore

    public init(store: SQLiteStore) { self.store = store }

    public func syncPorts(workspaceID: String, definitions: [ServiceDefinition], range: PortRange) throws -> [Int] {
        let count = definitions.count
        guard count > 0 else {
            try releasePorts(workspaceID: workspaceID)
            return []
        }

        let existingAssignments = try store.workspacePortsAssigned(workspaceID: workspaceID)
        var existingByDefinitionID: [String: Int] = [:]
        for assignment in existingAssignments where !assignment.definitionID.isEmpty {
            existingByDefinitionID[assignment.definitionID] = assignment.port
        }
        let existingNameCounts = Dictionary(existingAssignments.map { ($0.name, 1) }, uniquingKeysWith: +)
        var usedPorts = Set<Int>()
        var allocated = [Int?](repeating: nil, count: count)
        for (index, definition) in definitions.enumerated() {
            if let existingPort = existingByDefinitionID[definition.id], !usedPorts.contains(existingPort) {
                allocated[index] = existingPort
                usedPorts.insert(existingPort)
                continue
            }
            if existingNameCounts[definition.name] == 1,
                let existingPort = existingAssignments.first(where: { $0.name == definition.name && !usedPorts.contains($0.port) })?.port
            {
                allocated[index] = existingPort
                usedPorts.insert(existingPort)
            }
        }
        if allocated.contains(where: { $0 == nil }) {
            var inUse = try allReservedPorts(excludingWorkspaceID: workspaceID)
            for port in allocated.compactMap({ $0 }) { inUse.insert(port) }
            for index in allocated.indices where allocated[index] == nil {
                for port in range.start...range.end {
                    if inUse.contains(port) { continue }
                    allocated[index] = port
                    inUse.insert(port)
                    break
                }
            }
        }

        let resolved = allocated.compactMap { $0 }
        guard resolved.count == count else {
            throw WorkspaceError.invalidArgument(message: "Insufficient free ports in range \(range.start)-\(range.end).")
        }

        try store.setWorkspacePorts(workspaceID: workspaceID, ports: resolved, names: definitions.map(\.name), definitionIDs: definitions.map(\.id))
        return resolved
    }

    public func allocatePorts(workspaceID: String, definitions: [ServiceDefinition], range: PortRange) throws -> [Int] {
        let count = definitions.count
        guard count > 0 else {
            try releasePorts(workspaceID: workspaceID)
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
            throw WorkspaceError.invalidArgument(message: "Insufficient free ports in range \(range.start)-\(range.end).")
        }
        let names = definitions.map(\.name)
        try store.setWorkspacePorts(workspaceID: workspaceID, ports: allocated, names: names, definitionIDs: definitions.map(\.id))
        return allocated
    }

    /// Drops the workspace's port assignments. The placeholder reservation sockets those assignments
    /// justified are held by the daemon and derived from the store, so they are not touched here: the
    /// daemon's `PortReservationReconciler` sees the rows are gone and closes them.
    public func releasePorts(workspaceID: String) throws { try store.releaseWorkspacePorts(workspaceID: workspaceID) }

    private func allReservedPorts(excludingWorkspaceID: String? = nil) throws -> Set<Int> {
        let projects = try store.projects()
        var all: Set<Int> = []
        for project in projects {
            let workspaces = try store.workspaces(projectID: project.id)
            for workspace in workspaces {
                if workspace.id == excludingWorkspaceID { continue }
                let ports = try store.workspacePorts(workspaceID: workspace.id)
                for port in ports { all.insert(port) }
            }
        }
        return all
    }
}
