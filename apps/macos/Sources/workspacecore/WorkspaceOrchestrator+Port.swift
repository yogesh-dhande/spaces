import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    @discardableResult public func updatePortRange(_ range: PortRange) throws -> AppConfig {
        var config = try store.appConfig()
        config.portRange = range
        try store.setAppConfig(config)
        return config
    }

    public func workspacePorts(workspaceID: String) throws -> [Int] { try store.workspacePorts(workspaceID: workspaceID) }

    public func workspacePortsNamed(workspaceID: String) throws -> [(port: Int, name: String)] {
        try store.workspacePortsNamed(workspaceID: workspaceID)
    }

    func normalizePortDefinitionIDs(previous: [PortDefinition], updated: [PortDefinition]) -> [PortDefinition] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let previousNameCounts = Dictionary(previous.map { ($0.name, 1) }, uniquingKeysWith: +)
        var usedIDs = Set<String>()

        return updated.map { definition in
            if previousByID[definition.id] != nil {
                usedIDs.insert(definition.id)
                return definition
            }
            guard previousNameCounts[definition.name] == 1,
                let match = previous.first(where: { $0.name == definition.name && !usedIDs.contains($0.id) })
            else { return definition }
            usedIDs.insert(match.id)
            return PortDefinition(id: match.id, name: definition.name)
        }
    }

    func normalizedPortDefinitions(_ definitions: [PortDefinition]) throws -> [PortDefinition] {
        try definitions.map { definition in
            let trimmedName = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Port name is required.") }
            return PortDefinition(id: definition.id, name: trimmedName)
        }
    }
}
