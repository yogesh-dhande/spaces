import Foundation
import Testing

@testable import spacesui

@Suite @MainActor struct SidebarReloadCoordinatorTests {
    @Test func queuedReloadsCoalesceWhileLoadIsRunning() async {
        var continuations: [CheckedContinuation<Result<Int, any Error>, Never>] = []
        var applied: [(snapshot: Int, forceRemoteRefresh: Bool, bypassesBackoff: Bool)] = []
        var failures: [String?] = []

        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { await withCheckedContinuation { continuation in continuations.append(continuation) } },
            applySnapshot: { snapshot, forceRemoteRefresh, bypassesBackoff in applied.append((snapshot, forceRemoteRefresh, bypassesBackoff)) },
            handleFailure: { _, failurePlaceholderMessage in failures.append(failurePlaceholderMessage) })

        coordinator.request()
        while continuations.isEmpty { await Task.yield() }

        coordinator.request(failurePlaceholderMessage: "still loading", forceRemoteRefresh: true)
        #expect(coordinator.state == .queued)

        continuations.removeFirst().resume(returning: .success(1))
        while applied.count < 1 { await Task.yield() }
        while continuations.isEmpty { await Task.yield() }

        continuations.removeFirst().resume(returning: .success(2))
        while applied.count < 2 { await Task.yield() }

        #expect(applied.map(\.snapshot) == [1, 2])
        #expect(applied.map(\.forceRemoteRefresh) == [false, true])
        // Neither request spelled out `bypassesBackoff`, so each keeps the default coupling to its own
        // `forceRemoteRefresh`.
        #expect(applied.map(\.bypassesBackoff) == [false, true])
        #expect(failures.isEmpty)
        #expect(coordinator.state == .idle)
    }

    @Test func cancelledReloadCompletionDoesNotStartQueuedRequestForReplacementLoad() async {
        var continuations: [CheckedContinuation<Result<Int, any Error>, Never>] = []
        var applied: [(snapshot: Int, forceRemoteRefresh: Bool, bypassesBackoff: Bool)] = []
        var failures: [String?] = []

        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { await withCheckedContinuation { continuation in continuations.append(continuation) } },
            applySnapshot: { snapshot, forceRemoteRefresh, bypassesBackoff in applied.append((snapshot, forceRemoteRefresh, bypassesBackoff)) },
            handleFailure: { _, failurePlaceholderMessage in failures.append(failurePlaceholderMessage) })

        coordinator.request()
        #expect(await eventually { continuations.count == 1 })

        coordinator.cancelCurrentTask()
        coordinator.request()
        #expect(await eventually { continuations.count == 2 })

        coordinator.request(failurePlaceholderMessage: "queued", forceRemoteRefresh: true)
        #expect(coordinator.state == .queued)

        continuations[0].resume(returning: .success(1))
        let queuedRequestStartedBeforeReplacementFinished = await eventually { continuations.count >= 3 }

        #expect(!queuedRequestStartedBeforeReplacementFinished)

        continuations[1].resume(returning: .success(2))
        _ = await eventually { continuations.count >= 3 }
        if continuations.count >= 3 { continuations[2].resume(returning: .success(3)) }

        _ = await eventually { coordinator.state == .idle }
        #expect(applied.map(\.snapshot) == [2, 3])
        #expect(applied.map(\.forceRemoteRefresh) == [false, true])
        #expect(applied.map(\.bypassesBackoff) == [false, true])
        #expect(failures.isEmpty)
    }

    /// Every existing forced-refresh caller (the Reload command, a mutation's post-response refresh) asks
    /// only for `forceRemoteRefresh` and relies on it also clearing backoff, the way it always has —
    /// spelling out `bypassesBackoff` at every one of those call sites would be needless churn for no
    /// behavior change. Guards that the default keeps them coupled.
    @Test func bypassesBackoffDefaultsToForceRemoteRefreshWhenNotSpecified() async {
        var applied: [(forceRemoteRefresh: Bool, bypassesBackoff: Bool)] = []
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { .success(1) },
            applySnapshot: { _, forceRemoteRefresh, bypassesBackoff in applied.append((forceRemoteRefresh, bypassesBackoff)) },
            handleFailure: { _, _ in })

        coordinator.request(forceRemoteRefresh: true)
        await coordinator.drainCurrentReloadForTesting()

        #expect(applied.map(\.forceRemoteRefresh) == [true])
        #expect(applied.map(\.bypassesBackoff) == [true])
    }

    /// The regression this type exists to prevent: the remote workspace-setup progress poll needs live
    /// data on every tick (`forceRemoteRefresh: true`) but is not the user asking for any specific
    /// device, so it must be able to force a refresh without clearing any device's failure backoff.
    /// Before `bypassesBackoff` existed, that poll — repeating every 0.75s for the whole duration of a
    /// remote setup — cleared every unrelated offline device's backoff on the same fast cadence.
    @Test func aForcedRefreshCanBypassFreshnessWithoutClearingBackoff() async {
        var applied: [(forceRemoteRefresh: Bool, bypassesBackoff: Bool)] = []
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { .success(1) },
            applySnapshot: { _, forceRemoteRefresh, bypassesBackoff in applied.append((forceRemoteRefresh, bypassesBackoff)) },
            handleFailure: { _, _ in })

        coordinator.request(forceRemoteRefresh: true, bypassesBackoff: false)
        await coordinator.drainCurrentReloadForTesting()

        #expect(applied.map(\.forceRemoteRefresh) == [true])
        #expect(applied.map(\.bypassesBackoff) == [false])
    }

    private func eventually(maxYields: Int = 1_000, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
