import Foundation
import spacesdevicecore
import spacesterminalcore

/// One past coding-agent conversation Demo Mode finds on the demo device.
struct DemoAgentSessionSeed: Equatable {
    let agent: CodingAgent
    let sessionKey: String
    let title: String
    let workingDirectory: String
    let ageSeconds: TimeInterval
    let sizeBytes: Int64
    /// What a search matches against, and what a matching hit shows as its excerpt.
    let text: String
    let pinnedName: String?
    /// The demo terminal already running this conversation, which a resume focuses.
    let runningTerminalSessionID: String?
    /// The folder is gone, so an agent that resumes only from it cannot be resumed.
    let folderIsMissing: Bool
}

/// Answers `searchAgentSessions` in Demo Mode from a fixed set of conversations spread over the demo
/// device's agents and projects, so the Search Sessions sheet has content to show. Matching is looser than
/// a real device's index (every query word must start a word of the title or text) but has the same shape:
/// all words, any order, case-insensitive, newest first, 20 to a page.
struct DemoAgentSessionSearch {
    static let pageSize = 20

    let seeds: [DemoAgentSessionSeed]
    let referenceDate: Date

    init(seeds: [DemoAgentSessionSeed] = Self.defaultSeeds, referenceDate: Date = Date()) {
        self.seeds = seeds
        self.referenceDate = referenceDate
    }

    func seed(agent: CodingAgent, sessionKey: String) -> DemoAgentSessionSeed? { seeds.first { $0.agent == agent && $0.sessionKey == sessionKey } }

    /// The workspace a resume of `seed` opens in: the deepest non-home workspace containing its folder,
    /// else the home workspace.
    func workspace(for seed: DemoAgentSessionSeed, in workspaces: [SpacesDeviceWorkspaceSummary]) -> SpacesDeviceWorkspaceSummary? {
        let directory = seed.workingDirectory
        let containing = workspaces.filter { $0.projectKind != .home && (directory == $0.dir || directory.hasPrefix($0.dir + "/")) }
        return containing.max { $0.dir.count < $1.dir.count } ?? workspaces.first { $0.projectKind == .home }
    }

    func result(for request: SpacesDeviceAgentSessionSearchRequest, workspaces: [SpacesDeviceWorkspaceSummary])
        -> SpacesDeviceAgentSessionSearchResult
    {
        let agents = Set(request.agents ?? [])
        let words = request.query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = seeds.filter { seed in
            (agents.isEmpty || agents.contains(seed.agent))
                && (request.projectID == nil || workspace(for: seed, in: workspaces)?.projectID == request.projectID)
                && words.allSatisfy { Self.startsAWord($0, in: seed.title + " " + seed.text) }
        }.sorted { $0.ageSeconds < $1.ageSeconds }
        let start = request.page * Self.pageSize
        let page = matching.dropFirst(start).prefix(Self.pageSize)
        let hits = page.compactMap { seed in workspace(for: seed, in: workspaces).map { hit(for: seed, workspace: $0, isQuery: !words.isEmpty) } }
        return SpacesDeviceAgentSessionSearchResult(
            results: hits, hasMore: matching.count > start + Self.pageSize,
            availableAgents: CodingAgent.allCases.filter { agent in seeds.contains { $0.agent == agent } },
            availableProjects: Self.projects(of: workspaces),
            progress: SpacesDeviceAgentSessionIndexProgress(
                indexedSessions: seeds.count, totalSessions: seeds.count, isBuilding: false, isRefreshing: false))
    }

    private func hit(for seed: DemoAgentSessionSeed, workspace: SpacesDeviceWorkspaceSummary, isQuery: Bool) -> SpacesDeviceAgentSessionHit {
        SpacesDeviceAgentSessionHit(
            agent: seed.agent, sessionKey: seed.sessionKey, title: seed.title, workingDirectory: seed.workingDirectory,
            lastActive: TerminalSessionTimestamp.fractionalString(from: referenceDate.addingTimeInterval(-seed.ageSeconds)),
            sizeBytes: seed.sizeBytes, excerpt: isQuery ? seed.text : nil,
            workspace: SpacesDeviceAgentSessionWorkspace(
                projectID: workspace.projectID, projectName: workspace.projectName, workspaceID: workspace.id, workspaceName: workspace.displayName),
            runningTerminalSessionID: seed.runningTerminalSessionID, pinnedName: seed.pinnedName,
            resumability: seed.folderIsMissing && seed.agent.resumesOnlyFromOriginalFolder ? .folderMissing : .resumable)
    }

    /// The demo device's projects in the order its workspaces list them, with home last like a real device.
    private static func projects(of workspaces: [SpacesDeviceWorkspaceSummary]) -> [SpacesDeviceAgentSessionProject] {
        var seen = Set<String>()
        let projects = workspaces.compactMap { workspace -> SpacesDeviceAgentSessionProject? in
            guard seen.insert(workspace.projectID).inserted else { return nil }
            return SpacesDeviceAgentSessionProject(id: workspace.projectID, name: workspace.projectName, isHome: workspace.projectKind == .home)
        }
        return projects.filter { !$0.isHome } + projects.filter(\.isHome)
    }

    private static func startsAWord(_ prefix: String, in text: String) -> Bool {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { $0.hasPrefix(prefix) }
    }

    static let defaultSeeds: [DemoAgentSessionSeed] = {
        let projects = "/Users/lighthouse/Projects"
        return [
            DemoAgentSessionSeed(
                agent: .claudeCode, sessionKey: "demo-session-checkout", title: "Fix checkout 500 on expired payment session",
                workingDirectory: "\(projects)/harbor-web", ageSeconds: 120, sizeBytes: 1_480_000,
                text: "Checkout returns a 500 when the payment session expires mid-request. Guard the expired session and add a regression test.",
                pinnedName: nil, runningTerminalSessionID: "demo-harbor-agent", folderIsMissing: false),
            DemoAgentSessionSeed(
                agent: .claudeCode, sessionKey: "demo-session-orders", title: "Add pagination to the orders endpoint",
                workingDirectory: "\(projects)/lantern-api", ageSeconds: 3 * 3600, sizeBytes: 860_000,
                text: "Add cursor pagination to the orders endpoint and keep the response shape backwards compatible.", pinnedName: nil,
                runningTerminalSessionID: nil, folderIsMissing: false),
            DemoAgentSessionSeed(
                agent: .codex, sessionKey: "demo-session-docs-search", title: "Migrate the docs site to the new search index",
                workingDirectory: "\(projects)/atlas-docs", ageSeconds: 86_400, sizeBytes: 2_100_000,
                text: "Move the docs site search over to the new index and rebuild the sidebar from the generated manifest.",
                pinnedName: "Docs search migration", runningTerminalSessionID: nil, folderIsMissing: false),
            DemoAgentSessionSeed(
                agent: .codex, sessionKey: "demo-session-build-cache", title: "Why is the build cache invalidating every run",
                workingDirectory: "\(projects)/harbor-web/packages/ui", ageSeconds: 2 * 86_400, sizeBytes: 540_000,
                text: "The build cache key includes a timestamp from the generated icons, so every run misses the cache.", pinnedName: nil,
                runningTerminalSessionID: nil, folderIsMissing: false),
            DemoAgentSessionSeed(
                agent: .opencode, sessionKey: "demo-session-retry", title: "Refactor retry logic into a shared helper",
                workingDirectory: "\(projects)/lantern-api", ageSeconds: 3 * 86_400, sizeBytes: 310_000,
                text: "Pull the retry and backoff logic out of the payment client into a shared helper with jitter.", pinnedName: nil,
                runningTerminalSessionID: nil, folderIsMissing: false),
            DemoAgentSessionSeed(
                agent: .copilot, sessionKey: "demo-session-websocket", title: "Explain the flaky websocket test",
                workingDirectory: "\(projects)/harbor-web", ageSeconds: 4 * 86_400, sizeBytes: 220_000,
                text: "The websocket reconnect test is flaky because it races the server restart; wait for the open event instead.", pinnedName: nil,
                runningTerminalSessionID: nil, folderIsMissing: false),
            DemoAgentSessionSeed(
                agent: .pi, sessionKey: "demo-session-release-notes", title: "Draft the v2 release notes", workingDirectory: "\(projects)/atlas-docs",
                ageSeconds: 6 * 86_400, sizeBytes: 180_000,
                text: "Draft release notes for v2 from the merged pull requests, grouped by feature and fix.", pinnedName: nil,
                runningTerminalSessionID: nil, folderIsMissing: false),
            DemoAgentSessionSeed(
                agent: .amp, sessionKey: "demo-session-billing", title: "Rename the billing module", workingDirectory: "\(projects)/home",
                ageSeconds: 9 * 86_400, sizeBytes: 95_000,
                text: "Rename the billing module to invoicing and update every import across the repository.", pinnedName: nil,
                runningTerminalSessionID: nil, folderIsMissing: false),
            DemoAgentSessionSeed(
                agent: .claudeCode, sessionKey: "demo-session-invoice-pdf", title: "Prototype the invoice PDF export",
                workingDirectory: "\(projects)/retired-app", ageSeconds: 20 * 86_400, sizeBytes: 1_050_000,
                text: "Prototype exporting an invoice as a PDF with the company logo and a line item table.", pinnedName: nil,
                runningTerminalSessionID: nil, folderIsMissing: true),
            DemoAgentSessionSeed(
                agent: .codex, sessionKey: "demo-session-pool", title: "Tune the Postgres connection pool",
                workingDirectory: "\(projects)/lantern-api", ageSeconds: 30 * 86_400, sizeBytes: 1_900_000,
                text: "Tune the Postgres connection pool size for the worker fleet and add a saturation metric.", pinnedName: nil,
                runningTerminalSessionID: nil, folderIsMissing: false),
        ]
    }()
}
