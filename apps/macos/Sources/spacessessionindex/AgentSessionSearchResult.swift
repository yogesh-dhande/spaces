import Foundation
import spacesterminalcore

/// One session in a search or listing page.
public struct AgentSessionSearchResult: Sendable, Equatable {
    public let agent: CodingAgent
    /// What `CodingAgent.resumeCommand(launchCommand:sessionKey:)` takes to resume the session.
    public let sessionKey: String
    /// The agent's own title, else the first thing the user typed as one trimmed line.
    public let title: String
    public let workingDirectory: String?
    public let lastActive: Date
    public let sizeBytes: Int64
    /// Plain text around the session's most recent matching message; nil when listing without a query.
    public let excerpt: String?

    public init(
        agent: CodingAgent, sessionKey: String, title: String, workingDirectory: String?, lastActive: Date, sizeBytes: Int64, excerpt: String?
    ) {
        self.agent = agent
        self.sessionKey = sessionKey
        self.title = title
        self.workingDirectory = workingDirectory
        self.lastActive = lastActive
        self.sizeBytes = sizeBytes
        self.excerpt = excerpt
    }
}

public struct AgentSessionSearchPage: Sendable, Equatable {
    public static let pageSize = 20

    public let results: [AgentSessionSearchResult]
    /// True when a further page ("Show more") has at least one more session.
    public let hasMore: Bool

    public init(results: [AgentSessionSearchResult], hasMore: Bool) {
        self.results = results
        self.hasMore = hasMore
    }
}
