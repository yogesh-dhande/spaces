import Foundation
import spacesterminalcore

/// Searches the coding-agent conversations in the agents' own stores on one device. A blank `query` lists
/// the device's conversations by last activity instead.
public struct SpacesDeviceAgentSessionSearchRequest: Codable, Sendable, Equatable {
    public let query: String
    /// Zero-based; the device decides how many conversations a page holds.
    public let page: Int
    /// Restricts the search to these agents; nil or empty searches all of them.
    public let agents: [CodingAgent]?
    /// Restricts the search to the conversations that open in this project (the project each hit's
    /// `workspace` names); nil searches every project.
    public let projectID: String?

    public init(query: String, page: Int, agents: [CodingAgent]? = nil, projectID: String? = nil) {
        self.query = query
        self.page = page
        self.agents = agents
        self.projectID = projectID
    }

    /// Agents this build does not know are dropped (see `SkippingUnreadableList`), like every other
    /// request that carries agent kinds.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(String.self, forKey: .query)
        page = try container.decode(Int.self, forKey: .page)
        agents = container.contains(.agents) ? try container.decodeSkippingUnreadable(CodingAgent.self, forKey: .agents) : nil
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
    }
}

/// One page of conversations, with what a client needs to show the agent filter and the indexing status.
public struct SpacesDeviceAgentSessionSearchResult: Codable, Sendable, Equatable {
    public let results: [SpacesDeviceAgentSessionHit]
    public let hasMore: Bool
    /// The agents with at least one searchable conversation on this device: the choices of the agent filter.
    public let availableAgents: [CodingAgent]
    /// The device's projects, home included, in the device's order: the choices of the project filter.
    public let availableProjects: [SpacesDeviceAgentSessionProject]
    public let progress: SpacesDeviceAgentSessionIndexProgress

    public init(
        results: [SpacesDeviceAgentSessionHit], hasMore: Bool, availableAgents: [CodingAgent], availableProjects: [SpacesDeviceAgentSessionProject],
        progress: SpacesDeviceAgentSessionIndexProgress
    ) {
        self.results = results
        self.hasMore = hasMore
        self.availableAgents = availableAgents
        self.availableProjects = availableProjects
        self.progress = progress
    }

    /// Hits and agents this build does not know are dropped (see `SkippingUnreadableList`), so a newer
    /// daemon's page still shows the conversations this client can open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decodeSkippingUnreadable(SpacesDeviceAgentSessionHit.self, forKey: .results)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        availableAgents = try container.decodeSkippingUnreadable(CodingAgent.self, forKey: .availableAgents)
        availableProjects = try container.decode([SpacesDeviceAgentSessionProject].self, forKey: .availableProjects)
        progress = try container.decode(SpacesDeviceAgentSessionIndexProgress.self, forKey: .progress)
    }
}

/// How far the device's index of its agents' stores has got. Clients poll while `isBuilding` or
/// `isRefreshing` and show "Indexing `indexedSessions` of `totalSessions` sessions" while the first build
/// runs.
public struct SpacesDeviceAgentSessionIndexProgress: Codable, Sendable, Equatable {
    public let indexedSessions: Int
    public let totalSessions: Int
    /// The first build of the index has not finished, so results are partial.
    public let isBuilding: Bool
    /// A pass over the stores is running now.
    public let isRefreshing: Bool

    public init(indexedSessions: Int, totalSessions: Int, isBuilding: Bool, isRefreshing: Bool) {
        self.indexedSessions = indexedSessions
        self.totalSessions = totalSessions
        self.isBuilding = isBuilding
        self.isRefreshing = isRefreshing
    }
}

public struct SpacesDeviceAgentSessionHit: Codable, Sendable, Equatable {
    public let agent: CodingAgent
    /// The conversation id `resumeAgentSession` takes, which a user can also cite in a new session.
    public let sessionKey: String
    public let title: String
    public let workingDirectory: String?
    /// A fixed-width UTC timestamp (`TerminalSessionTimestamp.fractionalString`).
    public let lastActive: String
    /// The conversation's size on disk.
    public let sizeBytes: Int64
    /// Text around the most recent matching message; nil when listing without a query.
    public let excerpt: String?
    /// The workspace a resume opens in.
    public let workspace: SpacesDeviceAgentSessionWorkspace
    /// The terminal already running this conversation, which a resume focuses instead of launching again.
    public let runningTerminalSessionID: String?
    /// The pinned thread's name when the conversation is pinned in any workspace.
    public let pinnedName: String?
    public let resumability: SpacesDeviceAgentSessionResumability

    public init(
        agent: CodingAgent, sessionKey: String, title: String, workingDirectory: String?, lastActive: String, sizeBytes: Int64, excerpt: String?,
        workspace: SpacesDeviceAgentSessionWorkspace, runningTerminalSessionID: String?, pinnedName: String?,
        resumability: SpacesDeviceAgentSessionResumability
    ) {
        self.agent = agent
        self.sessionKey = sessionKey
        self.title = title
        self.workingDirectory = workingDirectory
        self.lastActive = lastActive
        self.sizeBytes = sizeBytes
        self.excerpt = excerpt
        self.workspace = workspace
        self.runningTerminalSessionID = runningTerminalSessionID
        self.pinnedName = pinnedName
        self.resumability = resumability
    }
}

/// A choice of the project filter.
public struct SpacesDeviceAgentSessionProject: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// The device's home project, where conversations from folders outside every project open.
    public let isHome: Bool

    public init(id: String, name: String, isHome: Bool) {
        self.id = id
        self.name = name
        self.isHome = isHome
    }
}

public struct SpacesDeviceAgentSessionWorkspace: Codable, Sendable, Equatable {
    public let projectID: String
    public let projectName: String
    public let workspaceID: String
    public let workspaceName: String

    public init(projectID: String, projectName: String, workspaceID: String, workspaceName: String) {
        self.projectID = projectID
        self.projectName = projectName
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
    }
}

public enum SpacesDeviceAgentSessionResumability: String, Codable, Sendable, Equatable {
    case resumable
    /// The conversation's folder is gone and its agent resumes only from that folder.
    case folderMissing
}

/// Resumes a conversation found by `searchAgentSessions`: focuses the terminal already running it, else
/// launches the agent's resume in the workspace the hit named.
public struct SpacesDeviceResumeAgentSessionRequest: Codable, Sendable, Equatable {
    public let agent: CodingAgent
    public let sessionKey: String
    public let workingDirectory: String?

    public init(agent: CodingAgent, sessionKey: String, workingDirectory: String?) {
        self.agent = agent
        self.sessionKey = sessionKey
        self.workingDirectory = workingDirectory
    }
}
