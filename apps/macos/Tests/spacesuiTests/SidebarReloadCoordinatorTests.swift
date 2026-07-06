import Foundation
import Testing

@testable import spacesui

@Suite @MainActor struct SidebarReloadCoordinatorTests {
    @Test func queuedReloadsCoalesceWhileLoadIsRunning() async {
        var continuations: [CheckedContinuation<Result<Int, any Error>, Never>] = []
        var applied: [(snapshot: Int, forceRemoteRefresh: Bool)] = []
        var failures: [String?] = []

        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { await withCheckedContinuation { continuation in continuations.append(continuation) } },
            applySnapshot: { snapshot, forceRemoteRefresh in applied.append((snapshot, forceRemoteRefresh)) },
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
        #expect(failures.isEmpty)
        #expect(coordinator.state == .idle)
    }

    @Test func cancelledReloadCompletionDoesNotStartQueuedRequestForReplacementLoad() async {
        var continuations: [CheckedContinuation<Result<Int, any Error>, Never>] = []
        var applied: [(snapshot: Int, forceRemoteRefresh: Bool)] = []
        var failures: [String?] = []

        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { await withCheckedContinuation { continuation in continuations.append(continuation) } },
            applySnapshot: { snapshot, forceRemoteRefresh in applied.append((snapshot, forceRemoteRefresh)) },
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
        #expect(failures.isEmpty)
    }

    private func eventually(maxYields: Int = 1_000, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
