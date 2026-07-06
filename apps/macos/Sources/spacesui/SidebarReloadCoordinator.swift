import Foundation

@MainActor final class SidebarReloadCoordinator<Snapshot> {
    struct ReloadRequest: Equatable {
        let failurePlaceholderMessage: String?
        let forceRemoteRefresh: Bool
    }

    enum State: Equatable {
        case idle
        case loading
        case queued
    }

    private let loadSnapshot: @MainActor () async -> Result<Snapshot, any Error>
    private let applySnapshot: @MainActor (Snapshot, Bool) -> Void
    private let handleFailure: @MainActor (any Error, String?) -> Void
    private var reloadTask: Task<Void, Never>?
    private var nextRunID = 0
    private var activeRunID: Int?
    private var pendingRequest: ReloadRequest?
    private(set) var state: State = .idle

    init(
        loadSnapshot: @escaping @MainActor () async -> Result<Snapshot, any Error>, applySnapshot: @escaping @MainActor (Snapshot, Bool) -> Void,
        handleFailure: @escaping @MainActor (any Error, String?) -> Void
    ) {
        self.loadSnapshot = loadSnapshot
        self.applySnapshot = applySnapshot
        self.handleFailure = handleFailure
    }

    func request(failurePlaceholderMessage: String? = nil, forceRemoteRefresh: Bool = false) {
        let request = ReloadRequest(failurePlaceholderMessage: failurePlaceholderMessage, forceRemoteRefresh: forceRemoteRefresh)
        guard reloadTask?.isCancelled != false else {
            pendingRequest = mergedPendingRequest(existing: pendingRequest, next: request)
            state = .queued
            return
        }
        start(request)
    }

    func cancelCurrentTask() { reloadTask?.cancel() }

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
        case .success(let snapshot): applySnapshot(snapshot, request.forceRemoteRefresh)
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
            forceRemoteRefresh: (existing?.forceRemoteRefresh ?? false) || next.forceRemoteRefresh)
    }
}
