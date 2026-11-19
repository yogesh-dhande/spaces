import Foundation
import spacesterminalcore

/// One answer to a search: the page and the status clients show beside it.
public struct AgentSessionSearchSnapshot: Sendable, Equatable {
    public let page: AgentSessionSearchPage
    /// Agents with at least one searchable session, in `CodingAgent.allCases` order.
    public let availableAgents: [CodingAgent]
    public let progress: AgentSessionIndexProgress
    /// The first build of the index has not finished, so the page is partial.
    public let isBuilding: Bool

    public init(page: AgentSessionSearchPage, availableAgents: [CodingAgent], progress: AgentSessionIndexProgress, isBuilding: Bool) {
        self.page = page
        self.availableAgents = availableAgents
        self.progress = progress
        self.isBuilding = isBuilding
    }
}

/// The daemon's session search, handed to the Device API server as a closure so the server never holds
/// the index or the service that keeps it current (the shape `AutomationOperations` gives the scheduler).
public struct AgentSessionSearchOperations: Sendable {
    public let search:
        @Sendable (_ query: String, _ page: Int, _ agents: Set<CodingAgent>, _ folders: AgentSessionFolderFilter?) throws ->
            AgentSessionSearchSnapshot

    public init(search: @escaping @Sendable (String, Int, Set<CodingAgent>, AgentSessionFolderFilter?) throws -> AgentSessionSearchSnapshot) {
        self.search = search
    }
}

extension AgentSessionIndex {
    /// Agents that have at least one searchable session.
    public func availableAgents() throws -> [CodingAgent] {
        let sessions = try statistics().sessions
        return CodingAgent.allCases.filter { sessions[$0, default: 0] > 0 }
    }

    /// A page of results with the agent filter's choices and the indexing status, for one response.
    public func snapshot(query: String, page: Int, agents: Set<CodingAgent>, folders: AgentSessionFolderFilter?, isBuilding: Bool) throws
        -> AgentSessionSearchSnapshot
    {
        AgentSessionSearchSnapshot(
            page: try search(query: query, page: page, agents: agents, folders: folders), availableAgents: try availableAgents(), progress: progress,
            isBuilding: isBuilding)
    }
}
