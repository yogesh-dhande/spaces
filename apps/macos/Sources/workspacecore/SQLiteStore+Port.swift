import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

extension SQLiteStore {
    public func setWorkspacePorts(workspaceID: String, ports: [Int], names: [String] = [], definitionIDs: [String] = []) throws {
        let normalizedNames = try validatedServiceNames(names, expectedCount: ports.count)
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_service_ports WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, port) in ports.enumerated() {
                let name = normalizedNames[index]
                let definitionID = index < definitionIDs.count ? definitionIDs[index] : ""
                try execute(
                    sql: "INSERT INTO workspace_service_ports(workspace_id, service_index, port, service_name, service_id) VALUES (?, ?, ?, ?, ?)",
                    bindings: [workspaceID, String(index), String(port), name, definitionID])
            }
        }
    }

    public func workspacePorts(workspaceID: String) throws -> [Int] {
        let rows = try queryRows(
            sql: "SELECT port FROM workspace_service_ports WHERE workspace_id = ? ORDER BY service_index", bindings: [workspaceID])
        return rows.compactMap { Int($0.first ?? "") }
    }

    public func workspacePortsNamed(workspaceID: String) throws -> [(port: Int, name: String)] {
        let rows = try queryRows(
            sql: "SELECT port, service_name FROM workspace_service_ports WHERE workspace_id = ? ORDER BY service_index", bindings: [workspaceID])
        return rows.compactMap { row in
            guard let port = Int(row[0]) else { return nil }
            return (port: port, name: row[1])
        }
    }

    /// Batched form of `workspacePortsNamed(workspaceID:)`: one full-table SELECT grouped by workspace
    /// in Swift, eliminating the per-workspace query on the overview hot path. The SELECT orders by
    /// `workspace_id` then the same `service_index` key the per-workspace query uses, and the
    /// order-preserving append keeps each group in the same order as `workspacePortsNamed(workspaceID:)`.
    public func workspacePortsNamedByWorkspace() throws -> [String: [(port: Int, name: String)]] {
        let rows = try queryRows(
            sql: "SELECT workspace_id, port, service_name FROM workspace_service_ports ORDER BY workspace_id, service_index")
        var result: [String: [(port: Int, name: String)]] = [:]
        for row in rows {
            guard row.count >= 3, let port = Int(row[1]) else { continue }
            result[row[0], default: []].append((port: port, name: row[2]))
        }
        return result
    }

    public func workspacePortsAssigned(workspaceID: String) throws -> [(definitionID: String, port: Int, name: String)] {
        let rows = try queryRows(
            sql: "SELECT service_id, port, service_name FROM workspace_service_ports WHERE workspace_id = ? ORDER BY service_index",
            bindings: [workspaceID])
        return rows.compactMap { row in
            guard row.count >= 3, let port = Int(row[1]) else { return nil }
            return (definitionID: row[0], port: port, name: row[2])
        }
    }

    public func setWorkspaceServiceDefinitions(workspaceID: String, definitions: [ServiceDefinition]) throws {
        let normalizedDefinitions = try validatedServiceDefinitions(definitions)
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM workspace_services WHERE workspace_id = ?", bindings: [workspaceID])
            for (index, definition) in normalizedDefinitions.enumerated() {
                try execute(
                    sql: "INSERT INTO workspace_services(id, workspace_id, name, order_index) VALUES (?, ?, ?, ?)",
                    bindings: [definition.id, workspaceID, definition.name, String(index)])
            }
        }
    }

    public func workspaceServiceDefinitions(workspaceID: String) throws -> [ServiceDefinition] {
        let rows = try queryRows(sql: "SELECT id, name FROM workspace_services WHERE workspace_id = ? ORDER BY order_index", bindings: [workspaceID])
        return rows.compactMap { row in
            guard row.count >= 2 else { return nil }
            return ServiceDefinition(id: row[0].isEmpty ? UUID().uuidString : row[0], name: row[1])
        }
    }

    public func releaseWorkspacePorts(workspaceID: String) throws {
        try execute(sql: "DELETE FROM workspace_service_ports WHERE workspace_id = ?", bindings: [workspaceID])
    }

    func validatedServiceDefinitions(_ definitions: [ServiceDefinition]) throws -> [ServiceDefinition] {
        let names = try ServiceName.validatedUnique(definitions.map(\.name))
        return zip(definitions, names).map { definition, name in ServiceDefinition(id: definition.id, name: name) }
    }

    func validatedServiceNames(_ names: [String], expectedCount: Int) throws -> [String] {
        guard names.count == expectedCount else {
            throw NSError(
                domain: "spaces.store", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Expected \(expectedCount) service names for \(expectedCount) stored ports, got \(names.count)."
                ])
        }
        return try ServiceName.validatedUnique(names)
    }
}
