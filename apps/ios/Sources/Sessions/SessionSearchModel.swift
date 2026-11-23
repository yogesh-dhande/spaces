import Foundation
import spacesdevicecore
import spacesterminalcore

struct SessionSearchDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

enum SessionSearchResumeOutcome {
    case opened(SpacesDeviceTerminalSessionSummary)
    case failed(String)
}

/// How the sheet model reaches the app: the paired devices, their reachability, and the two device calls.
/// The app model supplies closures over its private per-device connections; tests supply fakes.
struct SessionSearchEnvironment {
    var devices: () -> [SessionSearchDevice]
    var activeDeviceID: () -> String?
    var isOffline: (String) -> Bool
    var search: (_ deviceID: String, _ request: SpacesDeviceAgentSessionSearchRequest) async throws -> SpacesDeviceAgentSessionSearchResult
    var resume: (_ deviceID: String, _ hit: SpacesDeviceAgentSessionHit) async -> SessionSearchResumeOutcome
}

/// The hits shown so far and how many pages of them were fetched.
struct SessionSearchResults: Equatable {
    private(set) var hits: [SpacesDeviceAgentSessionHit] = []
    private(set) var hasMore = false
    private(set) var loadedPages = 0

    mutating func reset() { self = SessionSearchResults() }

    /// Page 0 replaces the list; the next page appends, skipping conversations a shifted page repeats.
    /// Any other page is a response that no longer fits the list and is ignored.
    mutating func apply(page: Int, hits newHits: [SpacesDeviceAgentSessionHit], hasMore: Bool) {
        if page == 0 {
            hits = newHits
            loadedPages = 1
        } else if page == loadedPages {
            let known = Set(hits.map(\.listID))
            hits += newHits.filter { !known.contains($0.listID) }
            loadedPages += 1
        } else {
            return
        }
        self.hasMore = hasMore
    }
}

extension SpacesDeviceAgentSessionHit {
    /// A session key is unique per agent, not across agents.
    var listID: String { "\(agent.rawValue):\(sessionKey)" }
}

/// State behind the Search Sessions sheet: which device, agents and project are searched, the debounced query, the
/// pages of results, the indexing status the device reports, and the resume action.
///
/// Every request carries the generation it was issued in; a response from an older generation (the query,
/// agents, project, or device moved on) is dropped so a slow answer never overwrites a newer one.
@MainActor @Observable final class SessionSearchModel {
    static let pollInterval: Duration = .seconds(2)

    struct ResumeFailure: Equatable {
        let hitID: String
        let message: String
    }

    private(set) var devices: [SessionSearchDevice] = []
    private(set) var deviceID: String?
    var query = ""
    private(set) var selectedAgents: Set<CodingAgent>
    /// The agents the device reported conversations for in its last response; the agent filter's choices.
    private(set) var availableAgents: [CodingAgent] = []
    private(set) var selectedProjectID: String?
    /// The device's projects from its last response, home last; the project filter's choices.
    private(set) var availableProjects: [SpacesDeviceAgentSessionProject] = []
    private(set) var results = SessionSearchResults()
    private(set) var progress: SpacesDeviceAgentSessionIndexProgress?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isResuming = false
    private(set) var searchError: String?
    private(set) var resumeFailure: ResumeFailure?

    @ObservationIgnored private let environment: SessionSearchEnvironment
    @ObservationIgnored private let preferences: SessionSearchPreferences
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var resultsIdentity: SearchIdentity?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(
        environment: SessionSearchEnvironment, preferences: SessionSearchPreferences = SessionSearchPreferences(),
        debounce: Duration = .milliseconds(250)
    ) {
        self.environment = environment
        self.preferences = preferences
        self.debounce = debounce
        let paired = environment.devices()
        let initial = SessionSearchPreferences.initialDeviceID(
            lastSearched: preferences.lastDeviceID, activeDeviceID: environment.activeDeviceID(), pairedDeviceIDs: paired.map(\.id))
        devices = paired
        deviceID = initial
        selectedAgents = initial.map { preferences.agents(forDeviceID: $0) } ?? []
        selectedProjectID = initial.flatMap { preferences.projectID(forDeviceID: $0) }
    }

    var deviceName: String? { devices.first { $0.id == deviceID }?.name }
    var isDeviceOffline: Bool { deviceID.map(environment.isOffline) ?? false }
    var hits: [SpacesDeviceAgentSessionHit] { results.hits }

    /// The remembered agents that the device still has conversations for. Until the device has answered, the
    /// remembered choice is trusted as is.
    var effectiveAgents: Set<CodingAgent> { availableAgents.isEmpty ? selectedAgents : selectedAgents.intersection(availableAgents) }

    /// The remembered project while the device still lists it; trusted as is until the device has answered.
    var effectiveProjectID: String? {
        guard let selectedProjectID else { return nil }
        return availableProjects.isEmpty || availableProjects.contains { $0.id == selectedProjectID } ? selectedProjectID : nil
    }

    var effectiveProject: SpacesDeviceAgentSessionProject? { effectiveProjectID.flatMap { id in availableProjects.first { $0.id == id } } }

    var isIndexBuilding: Bool { progress?.isBuilding == true }

    /// The index is changing under the list, so the current query is asked again every `pollInterval`.
    var needsPolling: Bool { (progress?.isBuilding == true || progress?.isRefreshing == true) && !isDeviceOffline }

    // MARK: - Choosing what to search

    func refreshDevices() { devices = environment.devices() }

    func selectDevice(_ id: String) async {
        guard id != deviceID else { return }
        deviceID = id
        preferences.lastDeviceID = id
        selectedAgents = preferences.agents(forDeviceID: id)
        selectedProjectID = preferences.projectID(forDeviceID: id)
        availableAgents = []
        availableProjects = []
        results.reset()
        resultsIdentity = nil
        progress = nil
        searchError = nil
        resumeFailure = nil
        await reload()
    }

    func toggleAgent(_ agent: CodingAgent) async {
        var agents = effectiveAgents
        if agents.contains(agent) { agents.remove(agent) } else { agents.insert(agent) }
        await setAgents(agents)
    }

    func clearAgents() async { await setAgents([]) }

    private func setAgents(_ agents: Set<CodingAgent>) async {
        guard let deviceID else { return }
        selectedAgents = agents
        preferences.setAgents(agents, forDeviceID: deviceID)
        await reload()
    }

    /// Nil searches every project.
    func selectProject(_ projectID: String?) async {
        guard let deviceID else { return }
        selectedProjectID = projectID
        preferences.setProjectID(projectID, forDeviceID: deviceID)
        await reload()
    }

    // MARK: - Searching

    /// What the shown results were fetched for.
    private struct SearchIdentity: Equatable {
        let deviceID: String
        let query: String
        let agents: Set<CodingAgent>
        let projectID: String?
    }

    private func currentIdentity(deviceID: String) -> SearchIdentity {
        SearchIdentity(
            deviceID: deviceID, query: query.trimmingCharacters(in: .whitespacesAndNewlines), agents: effectiveAgents, projectID: effectiveProjectID)
    }

    /// Called as the query text changes: asks the device once typing pauses.
    func queryChanged() {
        debounceTask?.cancel()
        invalidateRequests()
        let wait = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            // `reload` cancels a pending debounce; the handle is dropped first so it cannot cancel this
            // task, which is the search it is about to run.
            self?.debounceTask = nil
            await self?.reload()
        }
    }

    /// Drops every request still on its way, including a next page being loaded: its response will be
    /// ignored, so nothing would ever clear its loading state.
    private func invalidateRequests() {
        generation += 1
        isLoadingMore = false
    }

    /// Runs the current query from the first page.
    func reload() async {
        debounceTask?.cancel()
        invalidateRequests()
        resumeFailure = nil
        guard let deviceID else { return }
        // Remembered on every search, not only on a picker change: the fallback (the active device) can
        // change between openings, and the sheet should reopen on the device last searched.
        preferences.lastDeviceID = deviceID
        guard !environment.isOffline(deviceID) else {
            results.reset()
            progress = nil
            searchError = nil
            isLoading = false
            return
        }
        // Pages belong to one search; a new query, agent filter or device starts over even if its request fails.
        if resultsIdentity != currentIdentity(deviceID: deviceID) {
            results.reset()
            resultsIdentity = nil
        }
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }
        await fetch(page: 0, deviceID: deviceID, token: token, updatesResults: true)
    }

    /// The poll while the index is building or refreshing: asks the first page again. With later pages
    /// already shown the list is left alone, so a page the user is reading does not collapse, but the
    /// indexing status still updates. A poll's first page replaces the list only if no page is loading now
    /// and none was loaded by the time it answers: the answer would collapse pages the user just got.
    func poll() async {
        guard let deviceID, !environment.isOffline(deviceID) else { return }
        let loadedPages = results.loadedPages
        await fetch(
            page: 0, deviceID: deviceID, token: generation, updatesResults: loadedPages <= 1 && !isLoadingMore, requiredLoadedPages: loadedPages)
    }

    func showMore() async {
        // After an edit to the query and before its search starts, the list still belongs to the old query.
        guard let deviceID, results.hasMore, !isLoadingMore, !isLoading, resultsIdentity == currentIdentity(deviceID: deviceID) else { return }
        let token = generation
        isLoadingMore = true
        defer { if token == generation { isLoadingMore = false } }
        await fetch(page: results.loadedPages, deviceID: deviceID, token: token, updatesResults: true)
    }

    /// `isRetry` marks the one repeat of a search whose agent or project filter the device's answer changed.
    private func fetch(page: Int, deviceID: String, token: Int, updatesResults: Bool, requiredLoadedPages: Int? = nil, isRetry: Bool = false) async {
        let identity = currentIdentity(deviceID: deviceID)
        let request = SpacesDeviceAgentSessionSearchRequest(
            query: identity.query, page: page, agents: identity.agents.isEmpty ? nil : identity.agents.sorted { $0.rawValue < $1.rawValue },
            projectID: identity.projectID)
        do {
            let result = try await environment.search(deviceID, request)
            guard token == generation, deviceID == self.deviceID else { return }
            availableAgents = result.availableAgents
            availableProjects = result.availableProjects
            progress = result.progress
            searchError = nil
            // The answer can narrow the remembered filters (it names agents the device has no conversations for,
            // or a project it does not have). The filters shown must be the ones the shown results were fetched
            // with, so search again with them.
            if !isRetry, effectiveAgents != identity.agents || effectiveProjectID != identity.projectID {
                results.reset()
                resultsIdentity = nil
                await fetch(page: 0, deviceID: deviceID, token: token, updatesResults: true, isRetry: true)
                return
            }
            if updatesResults, requiredLoadedPages.map({ $0 == results.loadedPages }) ?? true {
                results.apply(page: page, hits: result.results, hasMore: result.hasMore)
                resultsIdentity = identity
            }
        } catch {
            guard token == generation, deviceID == self.deviceID, !(error is CancellationError) else { return }
            searchError = Self.message(for: error)
        }
    }

    // MARK: - Resuming

    /// Resumes (or focuses) the hit's conversation; the session to open, or nil with `resumeFailure` set.
    /// A conversation whose folder is gone is not sent: the row already explains why.
    func resume(_ hit: SpacesDeviceAgentSessionHit) async -> (deviceID: String, session: SpacesDeviceTerminalSessionSummary)? {
        guard let deviceID, hit.resumability == .resumable, !isResuming else { return nil }
        isResuming = true
        resumeFailure = nil
        defer { isResuming = false }
        switch await environment.resume(deviceID, hit) {
        case .opened(let session): return (deviceID, session)
        case .failed(let message):
            resumeFailure = ResumeFailure(hitID: hit.listID, message: message)
            return nil
        }
    }

    static func message(for error: Error) -> String {
        if case SpacesDeviceAPIClientError.requestFailed(let message, _) = error { return message }
        return error.localizedDescription
    }
}

/// The text of a result row, built apart from the view so the wording is testable.
enum SessionSearchRowText {
    static func location(of hit: SpacesDeviceAgentSessionHit) -> String {
        let workspace = hit.workspace
        return workspace.workspaceName == workspace.projectName ? workspace.projectName : "\(workspace.projectName) / \(workspace.workspaceName)"
    }

    static func meta(of hit: SpacesDeviceAgentSessionHit, relativeTo now: Date) -> String {
        var parts = [location(of: hit)]
        if let date = TerminalSessionTimestamp.date(from: hit.lastActive) {
            parts.append(AlertsAgeFormatting.abbreviatedAge(of: date, relativeTo: now))
        }
        parts.append(ByteCountFormatter.string(fromByteCount: hit.sizeBytes, countStyle: .file))
        if hit.runningTerminalSessionID != nil { parts.append("Running") }
        return parts.joined(separator: " · ")
    }

    static func folderMissing(sessionKey: String) -> String { "Folder no longer exists, can't resume · id \(sessionKey)" }

    /// How the project filter names the device's home project.
    static let homeProjectName = "~ (home)"

    static func projectName(_ project: SpacesDeviceAgentSessionProject) -> String { project.isHome ? homeProjectName : project.name }

    static func projectSummary(_ project: SpacesDeviceAgentSessionProject?) -> String { project.map(projectName) ?? "All projects" }

    /// The status line's count of the sessions loaded so far; a "+" says more pages are available.
    static func countSummary(loaded: Int, hasMore: Bool) -> String {
        "\(loaded)\(hasMore ? "+" : "") \(loaded == 1 && !hasMore ? "session" : "sessions")"
    }

    static func agentsSummary(_ agents: Set<CodingAgent>) -> String {
        agents.isEmpty ? "All agents" : CodingAgent.allCases.filter(agents.contains).map(\.displayName).joined(separator: ", ")
    }
}
