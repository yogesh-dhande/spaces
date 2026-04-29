import Foundation

public final class PortAllocator {
    private let store: SQLiteStore

    public init(store: SQLiteStore) { self.store = store }

    public func syncPorts(workspaceID: String, definitions: [PortDefinition], range: PortRange) throws -> [Int] {
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
        var allocated: [Int] = []
        for definition in definitions {
            if let existingPort = existingByDefinitionID[definition.id] {
                allocated.append(existingPort)
                usedPorts.insert(existingPort)
                continue
            }
            if existingNameCounts[definition.name] == 1,
                let existingPort = existingAssignments.first(where: { $0.name == definition.name && !usedPorts.contains($0.port) })?.port
            {
                allocated.append(existingPort)
                usedPorts.insert(existingPort)
            }
        }
        if allocated.count < count {
            var inUse = try allReservedPorts(excludingWorkspaceID: workspaceID)
            for port in allocated { inUse.insert(port) }
            for port in range.start...range.end {
                if inUse.contains(port) { continue }
                allocated.append(port)
                inUse.insert(port)
                if allocated.count == count { break }
            }
        }

        guard allocated.count == count else {
            throw WorkspaceError.invalidArgument(message: "Insufficient free ports in range \(range.start)-\(range.end).")
        }

        try store.setWorkspacePorts(workspaceID: workspaceID, ports: allocated, names: definitions.map(\.name), definitionIDs: definitions.map(\.id))
        PortReserver.shared.reservePorts(workspaceID: workspaceID, ports: allocated)
        return allocated
    }

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
            throw WorkspaceError.invalidArgument(message: "Insufficient free ports in range \(range.start)-\(range.end).")
        }
        let names = definitions.map(\.name)
        try store.setWorkspacePorts(workspaceID: workspaceID, ports: allocated, names: names, definitionIDs: definitions.map(\.id))
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

    private func allReservedPorts(excludingWorkspaceID: String? = nil) throws -> Set<Int> {
        let projects = try store.projects()
        var all: Set<Int> = []
        for project in projects {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
            for workspace in workspaces {
                if workspace.id == excludingWorkspaceID { continue }
                let ports = try store.workspacePorts(workspaceID: workspace.id)
                for port in ports { all.insert(port) }
            }
        }
        return all
    }
}
