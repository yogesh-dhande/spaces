import Foundation
import spacessessionindex
import spacesterminalcore

/// Keeps this device's index of its coding agents' session stores current, and answers searches from it.
///
/// Every device runs this, headless Linux daemons included: each indexes the stores under its own home
/// directory. One dedicated thread at background priority builds the index when the daemon starts and
/// then runs an incremental pass every `refreshInterval`; a search also asks for a pass, without waiting
/// for it, so a session an agent just wrote is found by the next search.
///
/// The service holds no daemon-wide resource: its thread is not a session core, so it never counts as
/// activity that keeps an idle daemon alive, and it is cancelled between sessions the moment the daemon
/// stops, hands off, or shuts down (a pass that finds `isSuspended` true does nothing). A stopped service
/// is finished for good; a daemon that resumes after a failed exec handoff builds a new one.
final class AgentSessionIndexService: @unchecked Sendable {
    static let refreshInterval: TimeInterval = 60
    /// The shortest gap between passes that searches ask for. Clients re-query while a pass runs, so
    /// without it each answer's own request for a pass would keep the next one running.
    static let minimumSearchRefreshSpacing: TimeInterval = 5

    private let indexURL: URL
    private let locations: AgentSessionStoreLocations
    private let refreshInterval: TimeInterval
    private let minimumSearchRefreshSpacing: TimeInterval
    private let isSuspended: @Sendable () -> Bool
    private let onError: @Sendable (String) -> Void

    /// Guards the state below and wakes the thread between passes.
    private let condition = NSCondition()
    private var started = false
    private var stopped = false
    private var workerIsRunning = false
    private var refreshRequested = false
    private var passIsRunning = false
    private var lastPassStartedAt: Date?
    private var index: AgentSessionIndex?
    private var firstPassFinished = false

    init(
        indexURL: URL, locations: AgentSessionStoreLocations, refreshInterval: TimeInterval = AgentSessionIndexService.refreshInterval,
        minimumSearchRefreshSpacing: TimeInterval = AgentSessionIndexService.minimumSearchRefreshSpacing, isSuspended: @escaping @Sendable () -> Bool,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.indexURL = indexURL
        self.locations = locations
        self.refreshInterval = refreshInterval
        self.minimumSearchRefreshSpacing = minimumSearchRefreshSpacing
        self.isSuspended = isSuspended
        self.onError = onError
    }

    func start() {
        condition.lock()
        defer { condition.unlock() }
        guard !started, !stopped else { return }
        started = true
        workerIsRunning = true
        let thread = Thread { [self] in
            run()
            condition.lock()
            workerIsRunning = false
            condition.broadcast()
            condition.unlock()
        }
        thread.name = "spaces.daemon.agent-session-index"
        thread.stackSize = 4 << 20
        thread.start()
    }

    /// Returns only once the worker thread has exited, so no read or commit is in flight afterwards: the
    /// daemon stops this before an exec handoff or shutdown and must not leave a writer mid-commit, and a
    /// caller may delete the index file right after. The thread abandons a running pass between sessions, so
    /// the wait is bounded by one session's read and its commit. The index is released here so its
    /// connections close once that pass lets go of it.
    func stop() {
        condition.lock()
        stopped = true
        index = nil
        condition.broadcast()
        while workerIsRunning { condition.wait() }
        condition.unlock()
    }

    /// One page of results, with the agent filter's choices and the indexing status. Before the index
    /// has opened it answers an empty page, which is also what a device with no sessions yet answers.
    func search(query: String, page: Int, agents: Set<CodingAgent>, folders: AgentSessionFolderFilter?) throws -> AgentSessionSearchSnapshot {
        requestRefresh()
        condition.lock()
        let index = self.index
        let isBuilding = !firstPassFinished
        // A refresh is pending from the moment it is requested until its pass has committed. The index only
        // reports a pass once it is discovering, so without this an answer that beats the pass says
        // nothing is refreshing and the client stops polling before the new results exist. Read before the
        // page, so a pass that commits in between at worst costs one more poll.
        let refreshIsPending = refreshRequested || passIsRunning
        condition.unlock()
        guard let index else {
            return AgentSessionSearchSnapshot(
                page: AgentSessionSearchPage(results: [], hasMore: false), availableAgents: [], progress: AgentSessionIndexProgress(),
                isBuilding: isBuilding)
        }
        let snapshot = try index.snapshot(query: query, page: page, agents: agents, folders: folders, isBuilding: isBuilding)
        guard refreshIsPending, !snapshot.progress.isRefreshing else { return snapshot }
        var progress = snapshot.progress
        progress.isRefreshing = true
        return AgentSessionSearchSnapshot(
            page: snapshot.page, availableAgents: snapshot.availableAgents, progress: progress, isBuilding: snapshot.isBuilding)
    }

    private var isCancelled: Bool {
        condition.lock()
        let stopped = self.stopped
        condition.unlock()
        return stopped || isSuspended()
    }

    private func requestRefresh() {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, !passIsRunning else { return }
        if let lastPassStartedAt, Date().timeIntervalSince(lastPassStartedAt) < minimumSearchRefreshSpacing { return }
        refreshRequested = true
        condition.signal()
    }

    private func run() {
        BackgroundPriority.lowerCurrentThread()
        while true {
            runPass()
            condition.lock()
            defer { condition.unlock() }
            refreshRequested = false
            let deadline = Date().addingTimeInterval(refreshInterval)
            while !stopped, !refreshRequested, Date() < deadline { _ = condition.wait(until: deadline) }
            if stopped { return }
        }
    }

    /// A pass that is cancelled keeps what it committed and does not count as the first build finishing.
    /// One that fails does: the error is reported, and clients are better served by what is indexed than
    /// by an "Indexing" status that would never end.
    private func runPass() {
        guard !isCancelled else { return }
        condition.lock()
        passIsRunning = true
        lastPassStartedAt = Date()
        condition.unlock()
        var finished = true
        do {
            let index = try openIndex()
            finished = !(try index.refresh(isCancelled: { [self] in isCancelled }).wasCancelled)
        } catch { onError("\(error)") }
        condition.lock()
        passIsRunning = false
        if finished { firstPassFinished = true }
        condition.unlock()
    }

    private func openIndex() throws -> AgentSessionIndex {
        condition.lock()
        let existing = index
        condition.unlock()
        if let existing { return existing }
        let opened = try AgentSessionIndex(indexURL: indexURL, locations: locations)
        condition.lock()
        defer { condition.unlock() }
        // A stop that landed while the file was opening must not leave the service holding it.
        if !stopped { index = opened }
        return opened
    }
}
