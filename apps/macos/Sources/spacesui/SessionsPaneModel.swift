import Foundation
import spacesdevicecore
import spacesterminalcore

/// What the Sessions pane holds, apart from any view: the chosen device, the query, each device's agent
/// and project filters, the pages loaded so far, and the state of the request in flight.
///
/// Every request is stamped with a token and any later request, device change, or clear moves the token on,
/// so a response that arrives for an earlier one is dropped instead of overwriting newer results. The
/// controller runs the requests this model hands out and feeds their outcome back.
struct SessionsPaneModel: Equatable {
    enum RequestKind: Equatable {
        /// A new query, device, or filter: the results are replaced by page 0.
        case search
        /// The same query again, covering the pages already loaded, so the visible results stay put.
        case refresh
        /// The next page, appended.
        case more
    }

    struct Request: Equatable {
        let token: Int
        let kind: RequestKind
        let deviceID: String
        let query: String
        let agents: [CodingAgent]?
        let projectID: String?
        let firstPage: Int
        let pageCount: Int
    }

    /// The pages of one request, merged.
    struct Response: Equatable {
        let hits: [SpacesDeviceAgentSessionHit]
        let hasMore: Bool
        let availableAgents: [CodingAgent]
        let availableProjects: [SpacesDeviceAgentSessionProject]
        let progress: SpacesDeviceAgentSessionIndexProgress
        let pagesFetched: Int
    }

    /// One result row, ready to draw.
    struct Row: Equatable {
        let key: String
        /// "project / workspace", or "~" for a conversation that opens in home.
        let placeText: String
        let agentName: String
        /// The pin's name when the conversation is pinned, otherwise the agent's own title.
        let title: String
        let isPinned: Bool
        let isRunning: Bool
        let excerpt: String?
        let ageText: String
        let sizeText: String
        /// Set when the conversation cannot be resumed: its folder is gone. The row then shows why and the id.
        let cannotResumeID: String?
    }

    struct ResumeError: Equatable {
        let key: String
        let message: String
    }

    static let allProjectsTitle = "All projects"
    static let homeProjectTitle = "~ (home)"

    private(set) var deviceID: String
    /// Editing the query drops the selection and every response still on its way, and withdraws Show more,
    /// until results for the new query arrive. Typing and pressing Return before they do cannot open a
    /// conversation that matched the previous query, a late answer cannot bring it back, and the next page
    /// is never fetched for the new query and appended to the old list.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            token += 1
            inFlight = nil
            selectedKey = nil
            hasMore = false
        }
    }
    private(set) var agentsByDevice: [String: [CodingAgent]]
    private(set) var projectByDevice: [String: String]
    private(set) var hits: [SpacesDeviceAgentSessionHit] = []
    private(set) var loadedPages = 0
    private(set) var hasMore = false
    private(set) var availableAgents: [CodingAgent] = []
    private(set) var availableProjects: [SpacesDeviceAgentSessionProject] = []
    /// Nil until the device has answered for the current device and filter.
    private(set) var progress: SpacesDeviceAgentSessionIndexProgress?
    private(set) var errorMessage: String?
    private(set) var selectedKey: String?
    private(set) var resumingKey: String?
    private(set) var resumeError: ResumeError?
    private(set) var inFlight: Request?
    private var token = 0

    init(deviceID: String, agentsByDevice: [String: [CodingAgent]] = [:], projectByDevice: [String: String] = [:]) {
        self.deviceID = deviceID
        self.agentsByDevice = agentsByDevice
        self.projectByDevice = projectByDevice
    }

    // MARK: - Device, agents and project

    /// The device Sessions opens on: the last one searched while it is still paired, otherwise this Mac.
    static func initialDeviceID(lastSearched: String?, pairedDeviceIDs: [String], localDeviceID: String) -> String {
        if let lastSearched, pairedDeviceIDs.contains(lastSearched) { return lastSearched }
        return localDeviceID
    }

    mutating func selectDevice(_ id: String) {
        guard id != deviceID else { return }
        deviceID = id
        clearResults()
    }

    /// The ticked agents of the current device, in the registry's order. Empty means every agent.
    var selectedAgents: [CodingAgent] { agentsByDevice[deviceID] ?? [] }

    var agentsTitle: String { selectedAgents.isEmpty ? "All agents" : selectedAgents.map(\.displayName).joined(separator: ", ") }

    var requestAgents: [CodingAgent]? { selectedAgents.isEmpty ? nil : selectedAgents }

    mutating func toggleAgent(_ agent: CodingAgent) {
        var selected = Set(selectedAgents)
        if selected.contains(agent) { selected.remove(agent) } else { selected.insert(agent) }
        setAgents(selected)
    }

    mutating func clearAgents() { setAgents([]) }

    private mutating func setAgents(_ agents: Set<CodingAgent>) {
        let ordered = CodingAgent.allCases.filter(agents.contains)
        agentsByDevice[deviceID] = ordered.isEmpty ? nil : ordered
    }

    /// Agent selections are stored as JSON keyed by device id. An agent this build does not know is dropped.
    static func decodeAgentSelections(_ json: String?) -> [String: [CodingAgent]] {
        guard let json, let data = json.data(using: .utf8), let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return raw.compactMapValues { names in
            let agents = names.compactMap(CodingAgent.init(rawValue:))
            return agents.isEmpty ? nil : agents
        }
    }

    static func encodeAgentSelections(_ selections: [String: [CodingAgent]]) -> String? {
        let raw = selections.mapValues { $0.map(\.rawValue) }
        return (try? JSONEncoder().encode(raw)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The current device's project filter; nil means every project.
    var selectedProjectID: String? { projectByDevice[deviceID] }

    static func title(of project: SpacesDeviceAgentSessionProject) -> String { project.isHome ? homeProjectTitle : project.name }

    /// Choosing a project replaces the results, like any other filter change, so the selection and the
    /// responses still on their way for the old filter go.
    mutating func selectProject(_ id: String?) {
        guard id != selectedProjectID else { return }
        projectByDevice[deviceID] = id
        token += 1
        inFlight = nil
        selectedKey = nil
        hasMore = false
    }

    /// Project selections are stored as JSON keyed by device id.
    static func decodeProjectSelections(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8), let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw
    }

    static func encodeProjectSelections(_ selections: [String: String]) -> String? {
        (try? JSONEncoder().encode(selections)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Requests

    /// Whether the device has not been asked yet for the current device and filter, and nothing is pending.
    var needsSearch: Bool { progress == nil && inFlight == nil && errorMessage == nil }

    /// Forgets the results and drops whatever response is still on its way.
    mutating func clearResults() {
        token += 1
        inFlight = nil
        hits = []
        loadedPages = 0
        hasMore = false
        availableAgents = []
        availableProjects = []
        progress = nil
        errorMessage = nil
        selectedKey = nil
        resumingKey = nil
        resumeError = nil
    }

    mutating func beginSearch() -> Request { begin(.search, firstPage: 0, pageCount: 1) }

    mutating func beginRefresh() -> Request { begin(.refresh, firstPage: 0, pageCount: max(loadedPages, 1)) }

    /// The next page, or nil when there is none or the results are being replaced.
    mutating func beginShowMore() -> Request? {
        guard canShowMore else { return nil }
        return begin(.more, firstPage: loadedPages, pageCount: 1)
    }

    var canShowMore: Bool { hasMore && loadedPages > 0 && inFlight?.kind != .search }

    var isLoadingMore: Bool { inFlight?.kind == .more }

    private mutating func begin(_ kind: RequestKind, firstPage: Int, pageCount: Int) -> Request {
        token += 1
        let request = Request(
            token: token, kind: kind, deviceID: deviceID, query: query, agents: requestAgents, projectID: selectedProjectID, firstPage: firstPage,
            pageCount: pageCount)
        inFlight = request
        return request
    }

    /// Takes a response in. Returns false, changing nothing, when a later request has made it stale.
    ///
    /// A remembered project the device does not list (deleted or unpaired since) matches nothing there, so
    /// it is dropped and the results cleared, which leaves `needsSearch` true for the caller to search again
    /// without it.
    mutating func apply(_ response: Response, to request: Request) -> Bool {
        guard request.token == token else { return false }
        if let projectID = request.projectID, !response.availableProjects.contains(where: { $0.id == projectID }) {
            projectByDevice[request.deviceID] = nil
            clearResults()
            return true
        }
        inFlight = nil
        errorMessage = nil
        switch request.kind {
        case .search, .refresh:
            hits = response.hits
            loadedPages = response.pagesFetched
        case .more:
            // The index can move between pages while it builds, so a conversation may appear in two of them.
            let known = Set(hits.map(\.rowKey))
            hits += response.hits.filter { !known.contains($0.rowKey) }
            loadedPages += response.pagesFetched
        }
        hasMore = response.hasMore
        availableAgents = response.availableAgents
        availableProjects = response.availableProjects
        progress = response.progress
        reconcileSelection()
        return true
    }

    /// Takes a failure in. A failed search leaves nothing to show for the query; a failed refresh or page
    /// keeps the results already there. Returns false when a later request has made it stale.
    mutating func fail(_ message: String, for request: Request) -> Bool {
        guard request.token == token else { return false }
        inFlight = nil
        errorMessage = message
        if request.kind == .search {
            hits = []
            loadedPages = 0
            hasMore = false
            selectedKey = nil
        }
        return true
    }

    /// While the device is building its index or scanning for changes the results are still moving, so the
    /// pane asks again.
    var shouldPoll: Bool { Self.shouldPoll(progress: progress) }

    static func shouldPoll(progress: SpacesDeviceAgentSessionIndexProgress?) -> Bool {
        guard let progress else { return false }
        return progress.isBuilding || progress.isRefreshing
    }

    // MARK: - Presentation

    var progressText: String? {
        guard let progress, progress.isBuilding else { return nil }
        return "Indexing \(progress.indexedSessions) of \(progress.totalSessions) sessions"
    }

    /// "N sessions", or "N+ sessions" while the device has more pages. Nil before the first answer.
    var countText: String? {
        guard progress != nil else { return nil }
        return Self.sessionCountText(hits.count, hasMore: hasMore)
    }

    private static func sessionCountText(_ count: Int, hasMore: Bool) -> String {
        "\(count)\(hasMore ? "+" : "") \(count == 1 && !hasMore ? "session" : "sessions")"
    }

    func hit(forKey key: String) -> SpacesDeviceAgentSessionHit? { hits.first { $0.rowKey == key } }

    /// The rows in the order the device returned them: newest matching message first.
    func rows(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [Row] {
        hits.map { Self.row(for: $0, now: now, calendar: calendar, locale: locale) }
    }

    static func row(for hit: SpacesDeviceAgentSessionHit, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> Row {
        Row(
            key: hit.rowKey,
            placeText: hit.workspace.projectName == ProjectKind.homeProjectName
                ? "~" : "\(hit.workspace.projectName) / \(hit.workspace.workspaceName)", agentName: hit.agent.displayName,
            title: hit.pinnedName ?? hit.title, isPinned: hit.pinnedName != nil, isRunning: hit.runningTerminalSessionID != nil,
            excerpt: hit.excerpt.map(SessionQueryHighlight.displayExcerpt).flatMap { $0.isEmpty ? nil : $0 },
            ageText: SessionRowFormatting.ageText(lastActive: hit.lastActive, now: now, calendar: calendar, locale: locale),
            sizeText: SessionRowFormatting.sizeText(bytes: hit.sizeBytes), cannotResumeID: hit.resumability == .folderMissing ? hit.sessionKey : nil)
    }

    // MARK: - Selection

    /// Row keys in display order, which is the order arrow keys walk.
    var orderedKeys: [String] { hits.map(\.rowKey) }

    mutating func select(_ key: String?) { selectedKey = key }

    mutating func moveSelection(by delta: Int) {
        let keys = orderedKeys
        guard !keys.isEmpty else { return }
        let current = selectedKey.flatMap(keys.firstIndex(of:))
        selectedKey = keys[min(max((current ?? (delta > 0 ? -1 : keys.count)) + delta, 0), keys.count - 1)]
    }

    /// Keeps the selection on its row when results change, and otherwise on the first row.
    private mutating func reconcileSelection() {
        let keys = orderedKeys
        if let selectedKey, keys.contains(selectedKey) { return }
        selectedKey = keys.first
    }

    // MARK: - Resuming

    /// False when another resume is still running.
    mutating func beginResume(key: String) -> Bool {
        guard resumingKey == nil else { return false }
        resumingKey = key
        resumeError = nil
        return true
    }

    mutating func finishResume(key: String, errorMessage: String?) {
        guard resumingKey == key else { return }
        resumingKey = nil
        resumeError = errorMessage.map { ResumeError(key: key, message: $0) }
    }
}

extension SpacesDeviceAgentSessionHit {
    /// A conversation id is unique only within its agent.
    var rowKey: String { "\(agent.rawValue):\(sessionKey)" }
}
