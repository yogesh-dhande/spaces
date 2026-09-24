import Foundation
import Testing

@testable import spacesui

@Suite @MainActor struct SidebarReloadCoordinatorTests {
    @Test func terminalOverviewRequestLoadsOnlyThatScope() async {
        var loadedScopes: [SidebarReloadCoordinator<Int>.ReloadScope] = []
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { scope in
                loadedScopes.append(scope)
                return .success(1)
            }, applySnapshot: { _, _, _ in }, handleFailure: { _, _ in })

        coordinator.request(scope: .terminalOverview)
        await coordinator.drainCurrentReloadForTesting()

        #expect(loadedScopes == [.terminalOverview])
    }

    @Test func queuedFullSnapshotDominatesTerminalOverviewRequestsInEitherOrder() async {
        for queuedScopes in [[SidebarReloadCoordinator<Int>.ReloadScope.terminalOverview, .fullSnapshot], [.fullSnapshot, .terminalOverview]] {
            var continuations: [CheckedContinuation<Result<Int, any Error>, Never>] = []
            var loadedScopes: [SidebarReloadCoordinator<Int>.ReloadScope] = []
            let coordinator = SidebarReloadCoordinator<Int>(
                loadSnapshot: { scope in
                    loadedScopes.append(scope)
                    return await withCheckedContinuation { continuation in continuations.append(continuation) }
                }, applySnapshot: { _, _, _ in }, handleFailure: { _, _ in }, minimumStartInterval: .zero)

            coordinator.request(scope: .terminalOverview)
            #expect(await eventually { continuations.count == 1 })
            for scope in queuedScopes { coordinator.request(scope: scope) }

            continuations.removeFirst().resume(returning: .success(1))
            #expect(await eventually { continuations.count == 1 })
            continuations.removeFirst().resume(returning: .success(2))
            await coordinator.drainCurrentReloadForTesting()

            #expect(loadedScopes == [.terminalOverview, .fullSnapshot])
        }
    }

    @Test func queuedReloadsCoalesceWhileLoadIsRunning() async {
        var continuations: [CheckedContinuation<Result<Int, any Error>, Never>] = []
        var applied: [(snapshot: Int, forceRemoteRefresh: Bool, bypassesBackoff: Bool)] = []
        var failures: [String?] = []

        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { _ in await withCheckedContinuation { continuation in continuations.append(continuation) } },
            applySnapshot: { snapshot, forceRemoteRefresh, bypassesBackoff in applied.append((snapshot, forceRemoteRefresh, bypassesBackoff)) },
            handleFailure: { _, failurePlaceholderMessage in failures.append(failurePlaceholderMessage) }, minimumStartInterval: .zero)

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
            loadSnapshot: { _ in await withCheckedContinuation { continuation in continuations.append(continuation) } },
            applySnapshot: { snapshot, forceRemoteRefresh, bypassesBackoff in applied.append((snapshot, forceRemoteRefresh, bypassesBackoff)) },
            handleFailure: { _, failurePlaceholderMessage in failures.append(failurePlaceholderMessage) }, minimumStartInterval: .zero)

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
            loadSnapshot: { _ in .success(1) },
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
            loadSnapshot: { _ in .success(1) },
            applySnapshot: { _, forceRemoteRefresh, bypassesBackoff in applied.append((forceRemoteRefresh, bypassesBackoff)) },
            handleFailure: { _, _ in })

        coordinator.request(forceRemoteRefresh: true, bypassesBackoff: false)
        await coordinator.drainCurrentReloadForTesting()

        #expect(applied.map(\.forceRemoteRefresh) == [true])
        #expect(applied.map(\.bypassesBackoff) == [false])
    }

    /// A streaming terminal raises `databaseDidChange` per output tick, so requests arrive far faster
    /// than a snapshot load can run. Without spacing between starts, each finished reload immediately
    /// starts the queued one and the sidebar reloads back to back for as long as output flows.
    ///
    /// Time comes from a clock the test advances by hand, so "the next reload has not started yet" is a
    /// fact about the coordinator rather than about how loaded the machine running the test is.
    @Test func reloadStartsAreSpacedByTheMinimumIntervalUnderARequestStorm() async {
        var applied: [Int] = []
        var loads = 0

        let clock = ManualClock()
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { _ in
                loads += 1
                return .success(loads)
            }, applySnapshot: { snapshot, _, _ in applied.append(snapshot) }, handleFailure: { _, _ in }, minimumStartInterval: .seconds(60),
            clock: clock)

        coordinator.request()
        for _ in 0..<20 { coordinator.request() }
        #expect(await eventually { applied.count == 1 })

        // The storm collapsed into one run plus one start still waiting on the interval, not a run per
        // request and not a second run started the moment the first finished.
        #expect(loads == 1)
        #expect(coordinator.state == .queued)

        // The held-back start is spaced, not dropped: it runs as soon as the interval elapses.
        clock.advance(by: .seconds(60))
        await coordinator.drainCurrentReloadForTesting()
        #expect(loads == 2)
        #expect(applied == [1, 2])

        coordinator.stop()
    }

    /// The last request must always be applied: it carries state the sidebar has not shown yet, so
    /// spacing may delay the trailing edge but must never drop it.
    @Test func trailingRequestDuringCooldownAlwaysApplies() async {
        var applied: [(snapshot: Int, forceRemoteRefresh: Bool, bypassesBackoff: Bool)] = []
        var loads = 0

        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { _ in
                loads += 1
                return .success(loads)
            }, applySnapshot: { snapshot, forceRemoteRefresh, bypassesBackoff in applied.append((snapshot, forceRemoteRefresh, bypassesBackoff)) },
            handleFailure: { _, _ in }, minimumStartInterval: .milliseconds(60))

        coordinator.request()
        for _ in 0..<5 { coordinator.request() }
        coordinator.request(forceRemoteRefresh: true)
        await coordinator.drainCurrentReloadForTesting()

        #expect(applied.map(\.snapshot) == [1, 2])
        #expect(applied.map(\.forceRemoteRefresh) == [false, true])
        #expect(applied.map(\.bypassesBackoff) == [false, true])
        #expect(coordinator.state == .idle)
    }

    /// Spacing must never delay the first reload of all, whatever the interval is.
    @Test func theFirstRequestStartsImmediately() async {
        var loads = 0
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { _ in
                loads += 1
                return .success(loads)
            }, applySnapshot: { _, _, _ in }, handleFailure: { _, _ in }, minimumStartInterval: .seconds(60))

        coordinator.request()
        #expect(coordinator.state == .loading)

        coordinator.stop()
    }

    /// A user action after a quiet period is the latency-sensitive case, so a request that arrives once
    /// the interval has elapsed starts loading synchronously instead of waiting on a schedule.
    @Test func requestAfterAQuietPeriodStartsImmediately() async {
        let interval = Duration.milliseconds(100)
        var loads = 0
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { _ in
                loads += 1
                return .success(loads)
            }, applySnapshot: { _, _, _ in }, handleFailure: { _, _ in }, minimumStartInterval: interval)

        coordinator.request()
        await coordinator.drainCurrentReloadForTesting()
        #expect(loads == 1)

        // Sleeping past the interval can only overshoot under load, which is the direction that keeps
        // the following request outside the cooldown.
        try? await ContinuousClock().sleep(for: interval + .milliseconds(200))
        coordinator.request()
        #expect(coordinator.state == .loading)
        await coordinator.drainCurrentReloadForTesting()
        #expect(loads == 2)
    }

    /// The manual clock has not reached the scheduled start's deadline, so that start provably still
    /// exists when `stop()` runs, and advancing past the deadline afterwards proves `stop()` cancelled it
    /// rather than merely delaying it.
    @Test func stopCancelsAScheduledStart() async {
        var loads = 0
        let clock = ManualClock()
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { _ in
                loads += 1
                return .success(loads)
            }, applySnapshot: { _, _, _ in }, handleFailure: { _, _ in }, minimumStartInterval: .seconds(60), clock: clock)

        coordinator.request()
        await coordinator.drainCurrentReloadForTesting()
        #expect(loads == 1)

        coordinator.request()
        #expect(coordinator.state == .queued)
        coordinator.stop()
        #expect(coordinator.state == .idle)

        clock.advance(by: .seconds(120))
        let startedAfterStop = await eventually { loads > 1 }
        #expect(!startedAfterStop)
    }

    /// A caller whose lookup missed against the sidebar it can see asks for a snapshot at least as fresh
    /// as its own request. With nothing running, that is a reload started right here.
    @Test func awaitingTheNextRunFromIdleReturnsOnceThatRunHasApplied() async {
        var applied: [Int] = []
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { _ in .success(1) }, applySnapshot: { snapshot, _, _ in applied.append(snapshot) }, handleFailure: { _, _ in },
            minimumStartInterval: .zero)

        await coordinator.requestAndAwaitNextRun()

        #expect(applied == [1])
        #expect(coordinator.state == .idle)
    }

    /// The regression this exists for: a reload already in flight read its data before the caller asked,
    /// so it can be carrying exactly the snapshot the caller already missed against. The wait has to
    /// outlast it and return only once the run that started afterwards has applied.
    @Test func awaitingTheNextRunSkipsTheRunAlreadyInFlight() async {
        var continuations: [CheckedContinuation<Result<Int, any Error>, Never>] = []
        var applied: [Int] = []
        var loadedScopes: [SidebarReloadCoordinator<Int>.ReloadScope] = []
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { scope in
                loadedScopes.append(scope)
                return await withCheckedContinuation { continuation in continuations.append(continuation) }
            }, applySnapshot: { snapshot, _, _ in applied.append(snapshot) }, handleFailure: { _, _ in }, minimumStartInterval: .zero)

        coordinator.request(scope: .terminalOverview)
        #expect(await eventually { continuations.count == 1 })

        let returned = ReturnFlag()
        let waiter = Task { @MainActor in
            await coordinator.requestAndAwaitNextRun()
            returned.value = true
        }
        #expect(await eventually { coordinator.state == .queued })

        continuations.removeFirst().resume(returning: .success(1))
        #expect(await eventually { applied == [1] })
        #expect(!returned.value, "the in-flight run's snapshot predates the request, so it cannot answer it")

        #expect(await eventually { continuations.count == 1 })
        continuations.removeFirst().resume(returning: .success(2))
        #expect(await eventually { returned.value })
        #expect(applied == [1, 2])
        #expect(loadedScopes == [.terminalOverview, .fullSnapshot])
        await waiter.value
    }

    /// A request inside the spacing interval is held back rather than run, and the wait follows it: it
    /// returns when the scheduled start's run applies, not when the request is accepted.
    @Test func awaitingTheNextRunFollowsAStartHeldBackByTheSpacingInterval() async {
        var loads = 0
        var applied: [Int] = []
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { _ in
                loads += 1
                return .success(loads)
            }, applySnapshot: { snapshot, _, _ in applied.append(snapshot) }, handleFailure: { _, _ in }, minimumStartInterval: .milliseconds(60))

        coordinator.request()
        await coordinator.drainCurrentReloadForTesting()
        #expect(loads == 1)

        await coordinator.requestAndAwaitNextRun()

        #expect(loads == 2)
        #expect(applied == [1, 2], "the wait ended on the scheduled run, after it applied")
    }

    /// Teardown leaves nothing that could finish a run, so a waiter is released instead of hanging on a
    /// reload that will never happen.
    @Test func stopReleasesAWaiter() async {
        // The manual clock never reaches the deadline, so the waiter's request is held back by the
        // spacing interval for as long as the test needs, however loaded the machine is.
        let coordinator = SidebarReloadCoordinator<Int>(
            loadSnapshot: { _ in .success(1) }, applySnapshot: { _, _, _ in }, handleFailure: { _, _ in }, minimumStartInterval: .seconds(60),
            clock: ManualClock())

        coordinator.request()
        await coordinator.drainCurrentReloadForTesting()

        let returned = ReturnFlag()
        let waiter = Task { @MainActor in
            await coordinator.requestAndAwaitNextRun()
            returned.value = true
        }
        #expect(await eventually { coordinator.state == .queued })
        #expect(!returned.value)

        coordinator.stop()

        #expect(await eventually { returned.value })
        await waiter.value
    }

    private func eventually(maxYields: Int = 1_000, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

/// A `Task`'s closure is `@Sendable` and cannot capture a mutable local, so a test observes whether the
/// task it spawned has come back through a main-actor box.
@MainActor private final class ReturnFlag { var value = false }

/// A clock the test advances by hand. The spacing assertions ("the next reload has not started yet", "the
/// cancelled start never runs") are otherwise races against real time: the test process only has to be
/// descheduled for longer than the spacing interval, which a loaded CI runner does, for a start the test
/// expects to still be pending to have already fired.
@MainActor private final class ManualClock: SidebarReloadClock {
    private struct Sleeper {
        let id: Int
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var now = ContinuousClock().now
    private var sleepers: [Sleeper] = []
    private var cancelledSleeperIDs: Set<Int> = []
    private var nextSleeperID = 0

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in due { sleeper.continuation.resume() }
    }

    func sleep(until deadline: ContinuousClock.Instant) async {
        guard deadline > now else { return }
        let id = nextSleeperID
        nextSleeperID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation can land before the sleeper is registered, so a cancellation already
                // recorded for this id is answered here instead of leaving the continuation to leak.
                if cancelledSleeperIDs.remove(id) != nil {
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancelSleeper(id) }
        }
    }

    private func cancelSleeper(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            cancelledSleeperIDs.insert(id)
            return
        }
        sleepers.remove(at: index).continuation.resume()
    }
}
