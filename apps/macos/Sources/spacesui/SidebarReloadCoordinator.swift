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
    private(set) var state: State = .idle

    init(
        loadSnapshot: @escaping @MainActor () async -> Result<Snapshot, any Error>,
        applySnapshot: @escaping @MainActor (Snapshot, _ forceRemoteRefresh: Bool, _ bypassesBackoff: Bool) -> Void,
        handleFailure: @escaping @MainActor (any Error, String?) -> Void
    ) {
        self.loadSnapshot = loadSnapshot
        self.applySnapshot = applySnapshot
        self.handleFailure = handleFailure
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
        start(request)
    }

    func cancelCurrentTask() { reloadTask?.cancel() }

    /// Awaits the currently running (or about to run) reload, so a test can observe what a request
    /// applied deterministically instead of polling. A no-op once the coordinator is idle.
    func drainCurrentReloadForTesting() async { await reloadTask?.value }

    func stop() {
        reloadTask?.cancel()
        reloadTask = nil
        activeRunID = nil
        pendingRequest = nil
        state = .idle
    }

    private func start(_ request: ReloadRequest) {
        nextRunID += 1
        let runID = nextRunID
        activeRunID = runID
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
        guard let next = pendingRequest else {
            state = .idle
            return
        }
        pendingRequest = nil
        start(next)
    }

    private func mergedPendingRequest(existing: ReloadRequest?, next: ReloadRequest) -> ReloadRequest {
        ReloadRequest(
            failurePlaceholderMessage: existing?.failurePlaceholderMessage ?? next.failurePlaceholderMessage,
            forceRemoteRefresh: (existing?.forceRemoteRefresh ?? false) || next.forceRemoteRefresh,
            bypassesBackoff: (existing?.bypassesBackoff ?? false) || next.bypassesBackoff)
    }
}
