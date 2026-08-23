import Foundation

@MainActor final class SidebarReloadCoordinator<Snapshot> {
    struct ReloadRequest: Equatable {
        let failurePlaceholderMessage: String?
        let forceRemoteRefresh: Bool
        // Whether this request clears a device's failure backoff, distinct from `forceRemoteRefresh`
        // (which only bypasses the freshness window): see `SidebarController.startRemoteOverviewPull`.
        // Defaults to `forceRemoteRefresh` at the call site so every existing caller keeps its current,
        // coupled behavior; only a caller that explicitly wants freshness without clearing backoff (the
        // remote workspace-setup progress poll) passes them independently.
        let bypassesBackoff: Bool
    }

    enum State: Equatable {
        case idle
        case loading
        case queued
    }

    private let loadSnapshot: @MainActor () async -> Result<Snapshot, any Error>
    private let applySnapshot: @MainActor (Snapshot, _ forceRemoteRefresh: Bool, _ bypassesBackoff: Bool) -> Void
    private let handleFailure: @MainActor (any Error, String?) -> Void
    private var reloadTask: Task<Void, Never>?
    private var nextRunID = 0
    private var activeRunID: Int?
    private var pendingRequest: ReloadRequest?
    /// Minimum spacing between reload *starts*. Requests are driven by database writes, so a streaming
    /// terminal raises them far faster than a snapshot load can run; coalescing alone only keeps one
    /// load in flight, which under a storm means reloads run back to back forever. Spacing the starts
    /// rather than debouncing to the trailing edge keeps the latency-sensitive case free: a request
    /// after a quiet period runs at once, and only requests inside the interval wait.
    private let minimumStartInterval: Duration
    private let clock = ContinuousClock()
    private var lastStartInstant: ContinuousClock.Instant?
    private var scheduledStartTask: Task<Void, Never>?
    /// Callers suspended in `requestAndAwaitNextRun`, each tagged with the run it is waiting for.
    private var nextRunWaiters: [(targetRunID: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var state: State = .idle

    init(
        loadSnapshot: @escaping @MainActor () async -> Result<Snapshot, any Error>,
        applySnapshot: @escaping @MainActor (Snapshot, _ forceRemoteRefresh: Bool, _ bypassesBackoff: Bool) -> Void,
        handleFailure: @escaping @MainActor (any Error, String?) -> Void, minimumStartInterval: Duration = .milliseconds(250)
    ) {
        self.loadSnapshot = loadSnapshot
        self.applySnapshot = applySnapshot
        self.handleFailure = handleFailure
        self.minimumStartInterval = minimumStartInterval
    }

    /// `bypassesBackoff` defaults to `forceRemoteRefresh` (nil means "same as forceRemoteRefresh") so a
    /// caller that only wants the existing coupled behavior does not have to spell it out. Pass `false`
    /// explicitly to force-refresh without clearing any device's backoff — see `ReloadRequest`.
    func request(failurePlaceholderMessage: String? = nil, forceRemoteRefresh: Bool = false, bypassesBackoff: Bool? = nil) {
        let request = ReloadRequest(
            failurePlaceholderMessage: failurePlaceholderMessage, forceRemoteRefresh: forceRemoteRefresh,
            bypassesBackoff: bypassesBackoff ?? forceRemoteRefresh)
        guard reloadTask?.isCancelled != false else {
            pendingRequest = mergedPendingRequest(existing: pendingRequest, next: request)
            state = .queued
            return
        }
        startOrSchedule(request)
    }

    /// Requests a reload and suspends until a run that starts *after* this call has finished: applied its
    /// snapshot, or failed. The caller is asking because its own lookup missed, so a run already in flight
    /// cannot answer it: that run's data was read before the write the caller is chasing. The run to wait
    /// for is therefore always the next one to start, `nextRunID + 1`, which every branch of `request`
    /// either starts immediately or queues the pending request that the next start carries.
    func requestAndAwaitNextRun() async {
        let targetRunID = nextRunID + 1
        request()
        // `withCheckedContinuation` inherits this method's main-actor isolation, so no run can finish
        // between reading `nextRunID` above and the waiter being registered here.
        await withCheckedContinuation { continuation in nextRunWaiters.append((targetRunID, continuation)) }
    }

    /// Cancels the in-flight load only. A start already scheduled behind the spacing interval keeps its
    /// schedule, matching the one call site (`applicationWillTerminate`), which drops the load it no
    /// longer needs rather than shutting the coordinator down; `stop()` is the full teardown.
    func cancelCurrentTask() { reloadTask?.cancel() }

    /// Awaits the currently running reload plus any start still waiting on the spacing interval, so a
    /// test can observe what a request applied deterministically instead of polling. A no-op once the
    /// coordinator is idle.
    func drainCurrentReloadForTesting() async {
        while scheduledStartTask != nil || reloadTask != nil {
            if let scheduledStartTask { await scheduledStartTask.value }
            if let reloadTask { await reloadTask.value }
        }
    }

    func stop() {
        reloadTask?.cancel()
        reloadTask = nil
        scheduledStartTask?.cancel()
        scheduledStartTask = nil
        activeRunID = nil
        pendingRequest = nil
        state = .idle
        // Nothing is left that could finish a run, so every waiter would hang otherwise. They get the
        // same answer a finished run gives: go look at whatever the sidebar holds.
        let waiters = nextRunWaiters
        nextRunWaiters = []
        for waiter in waiters { waiter.continuation.resume() }
    }

    /// Starts immediately when the spacing interval has already elapsed, otherwise holds the request as
    /// pending and schedules the one start that will run it. At most one start is ever scheduled; every
    /// further request merges into the pending one that start will carry.
    private func startOrSchedule(_ request: ReloadRequest) {
        guard scheduledStartTask == nil else {
            pendingRequest = mergedPendingRequest(existing: pendingRequest, next: request)
            state = .queued
            return
        }
        guard let earliestStart = lastStartInstant?.advanced(by: minimumStartInterval), earliestStart > clock.now else {
            start(request)
            return
        }
        pendingRequest = mergedPendingRequest(existing: pendingRequest, next: request)
        state = .queued
        scheduleStart(at: earliestStart)
    }

    private func scheduleStart(at deadline: ContinuousClock.Instant) {
        let clock = clock
        scheduledStartTask = Task { @MainActor [weak self] in
            try? await clock.sleep(until: deadline, tolerance: nil)
            guard !Task.isCancelled, let self else { return }
            self.scheduledStartTask = nil
            // The trailing request carries state the sidebar has not shown yet, so spacing may delay it
            // but must never drop it.
            guard let next = self.pendingRequest else {
                self.state = .idle
                return
            }
            self.pendingRequest = nil
            self.start(next)
        }
    }

    private func start(_ request: ReloadRequest) {
        nextRunID += 1
        let runID = nextRunID
        activeRunID = runID
        lastStartInstant = clock.now
        state = .loading
        reloadTask = Task { @MainActor [weak self] in await self?.run(request, runID: runID) }
    }

    private func run(_ request: ReloadRequest, runID: Int) async {
        let result = await loadSnapshot()
        guard !Task.isCancelled else {
            finishCurrentRun(runID: runID)
            return
        }
        switch result {
        case .success(let snapshot): applySnapshot(snapshot, request.forceRemoteRefresh, request.bypassesBackoff)
        case .failure(let error): handleFailure(error, request.failurePlaceholderMessage)
        }
        finishCurrentRun(runID: runID)
    }

    private func finishCurrentRun(runID: Int) {
        guard activeRunID == runID else { return }
        reloadTask = nil
        activeRunID = nil
        // A waiter is owed a run no older than the one it asked for, so this run answers every waiter
        // whose target it has reached; later targets keep waiting for their own run.
        let satisfied = nextRunWaiters.filter { $0.targetRunID <= runID }
        nextRunWaiters.removeAll { $0.targetRunID <= runID }
        for waiter in satisfied { waiter.continuation.resume() }
        guard let next = pendingRequest else {
            state = .idle
            return
        }
        pendingRequest = nil
        startOrSchedule(next)
    }

    private func mergedPendingRequest(existing: ReloadRequest?, next: ReloadRequest) -> ReloadRequest {
        ReloadRequest(
            failurePlaceholderMessage: existing?.failurePlaceholderMessage ?? next.failurePlaceholderMessage,
            forceRemoteRefresh: (existing?.forceRemoteRefresh ?? false) || next.forceRemoteRefresh,
            bypassesBackoff: (existing?.bypassesBackoff ?? false) || next.bypassesBackoff)
    }
}
