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
        syncReservationState(workspaceID: workspaceID, ports: resolved)
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
        syncReservationState(workspaceID: workspaceID, ports: allocated)
        return allocated
    }

    public func releasePorts(workspaceID: String) throws {
        try store.releaseWorkspacePorts(workspaceID: workspaceID)
        PortReserver.shared.releasePorts(workspaceID: workspaceID)
    }

    public func reserveExistingPorts(workspaceID: String) throws {
        let ports = try store.workspacePorts(workspaceID: workspaceID)
        syncReservationState(workspaceID: workspaceID, ports: ports)
    }

    /// Keeps placeholder reservation sockets aligned with the workspace lifecycle.
    ///
    /// Stopped workspaces hold their assigned service ports so unrelated processes do not claim them
    /// before the next launch. Running workspaces never hold placeholder sockets: Spaces cannot know
    /// which configured or ad-hoc process will bind which port, and re-reserving a briefly-free port can
    /// make the intended server fail with EADDRINUSE.
    private func syncReservationState(workspaceID: String, ports: [Int]) {
        guard !ports.isEmpty, !isWorkspaceRunning(workspaceID) else {
            PortReserver.shared.releasePorts(workspaceID: workspaceID)
            return
        }
        PortReserver.shared.reservePorts(workspaceID: workspaceID, ports: ports)
    }

    private func isWorkspaceRunning(_ workspaceID: String) -> Bool {
        guard let workspace = try? store.workspace(id: workspaceID) else { return false }
        return workspace.isRunning
    }

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
