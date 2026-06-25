import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
    public func setWorkspacePorts(workspaceID: String, ports: [Int], names: [String] = [], definitionIDs: [String] = []) throws {
        let normalizedNames = try validatedPortNames(names, expectedCount: ports.count)
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, port) in ports.enumerated() {
                let name = normalizedNames[index]
                let definitionID = index < definitionIDs.count ? definitionIDs[index] : ""
                try execute(
                    sql: "INSERT INTO workspace_ports(workspace_id, port_index, port_number, port_name, definition_id) VALUES (?, ?, ?, ?, ?)",
                    bindings: [workspaceID, String(index), String(port), name, definitionID])
            }
        }
    }

    public func workspacePorts(workspaceID: String) throws -> [Int] {
        let rows = try queryRows(sql: "SELECT port_number FROM workspace_ports WHERE workspace_id = ? ORDER BY port_index", bindings: [workspaceID])
        return rows.compactMap { Int($0.first ?? "") }
    }

    public func workspacePortsNamed(workspaceID: String) throws -> [(port: Int, name: String)] {
        let rows = try queryRows(
            sql: "SELECT port_number, port_name FROM workspace_ports WHERE workspace_id = ? ORDER BY port_index", bindings: [workspaceID])
        return rows.compactMap { row in
            guard let port = Int(row[0]) else { return nil }
            return (port: port, name: row[1])
        }
    }

    public func workspacePortsAssigned(workspaceID: String) throws -> [(definitionID: String, port: Int, name: String)] {
        let rows = try queryRows(
            sql: "SELECT definition_id, port_number, port_name FROM workspace_ports WHERE workspace_id = ? ORDER BY port_index",
            bindings: [workspaceID])
        return rows.compactMap { row in
            guard row.count >= 3, let port = Int(row[1]) else { return nil }
            return (definitionID: row[0], port: port, name: row[2])
        }
    }

    public func setWorkspacePortDefinitions(workspaceID: String, definitions: [PortDefinition]) throws {
        let normalizedDefinitions = try validatedPortDefinitions(definitions)
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_port_definitions WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, definition) in normalizedDefinitions.enumerated() {
                try execute(
                    sql: "INSERT INTO workspace_port_definitions(id, workspace_id, name, order_index) VALUES (?, ?, ?, ?)",
                    bindings: [definition.id, workspaceID, definition.name, String(index)])
            }
        }
    }

    public func workspacePortDefinitions(workspaceID: String) throws -> [PortDefinition] {
        let rows = try queryRows(
            sql: "SELECT id, name FROM workspace_port_definitions WHERE workspace_id = ? ORDER BY order_index", bindings: [workspaceID])
        return rows.compactMap { row in
            guard row.count >= 2 else { return nil }
            return PortDefinition(id: row[0].isEmpty ? UUID().uuidString : row[0], name: row[1])
        }
    }

    public func releaseWorkspacePorts(workspaceID: String) throws {
        try execute(sql: "DELETE FROM workspace_ports WHERE workspace_id = ?", bindings: [workspaceID])
    }

    func validatedPortDefinitions(_ definitions: [PortDefinition]) throws -> [PortDefinition] {
        try definitions.map { definition in
            let trimmedName = try validatedPortName(definition.name)
            return PortDefinition(id: definition.id, name: trimmedName)
        }
    }

    func validatedPortNames(_ names: [String], expectedCount: Int) throws -> [String] {
        guard names.count == expectedCount else {
            throw NSError(
                domain: "spaces.store", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected \(expectedCount) port names for \(expectedCount) stored ports, got \(names.count)."])
        }
        return try names.map(validatedPortName)
    }

    func validatedPortName(_ name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(domain: "spaces.store", code: 2, userInfo: [NSLocalizedDescriptionKey: "Port name is required."])
        }
        return trimmedName
    }
}
