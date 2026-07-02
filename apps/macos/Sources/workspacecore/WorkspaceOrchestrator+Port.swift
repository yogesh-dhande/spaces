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

    @discardableResult public func updateRouterPort(_ port: Int) throws -> AppConfig {
        guard port > 0, port <= 65535 else { throw WorkspaceError.invalidArgument(message: "Router port must be between 1 and 65535.") }
        var config = try store.appConfig()
        config.routerPort = port
        try store.setAppConfig(config)
        return config
    }

    /// Builds the full Caddy route table: one route per service across every non-archived workspace,
    /// mapping `<service>.<workspace-slug>.localhost` to the service's assigned local port. All
    /// non-archived workspaces are routed (not just running ones) so service URLs stay stable; Caddy
    /// returns 502 until the upstream binds. Duplicate hosts (an astronomically unlikely slug+service
    /// collision) are skipped with a warning rather than silently overwriting an earlier route.
    public func caddyRouteTable() throws -> [CaddyRoute] {
        var routes: [CaddyRoute] = []
        var seenHosts = Set<String>()
        for project in try store.projects() {
            for workspace in try store.workspaces(projectID: project.id, includeArchived: false) {
                let assigned = try store.workspacePortsAssigned(workspaceID: workspace.id)
                guard !assigned.isEmpty else { continue }
                let slug = SpacesProfile.workspaceHostSlug(
                    branch: workspace.branch, projectName: project.name, isGitRepo: project.isGitRepo, workspaceID: workspace.id)
                for assignment in assigned {
                    let name = assignment.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { continue }
                    let host = "\(name).\(slug).localhost"
                    guard seenHosts.insert(host).inserted else {
                        Self.writeStandardError("spaces: duplicate Caddy host \(host); skipping workspace \(workspace.id) service \(name)\n")
                        continue
                    }
                    routes.append(CaddyRoute(host: host, upstream: "localhost:\(assignment.port)"))
                }
            }
        }
        return routes
    }

    public func workspacePorts(workspaceID: String) throws -> [Int] { try store.workspacePorts(workspaceID: workspaceID) }

    public func workspacePortsNamed(workspaceID: String) throws -> [(port: Int, name: String)] {
        try store.workspacePortsNamed(workspaceID: workspaceID)
    }

    func normalizeServiceDefinitionIDs(previous: [ServiceDefinition], updated: [ServiceDefinition]) -> [ServiceDefinition] {
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
            return ServiceDefinition(id: match.id, name: definition.name)
        }
    }

    func normalizedServiceDefinitions(_ definitions: [ServiceDefinition]) throws -> [ServiceDefinition] {
        let names = try ServiceName.validatedUnique(definitions.map(\.name))
        return zip(definitions, names).map { definition, name in ServiceDefinition(id: definition.id, name: name) }
    }
}
