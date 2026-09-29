import Foundation
import Testing

@testable import spacesdevicecore

/// A stand-in for the overview stream client. The coordinator never touches the client beyond
/// holding it and handing it back, so identity is all a test needs.
private final class StubOverviewStreamClient {}

private enum StubDisconnectError: Error, Equatable { case dropped }

/// Counts the reconciles the coordinator requests, so a test can prove a retry was armed without
/// re-entering the coordinator.
@MainActor private final class ReconcileRecorder { var count = 0 }

/// Behavior of the per-device overview-subscription state machine shared by the Mac sidebar and the iOS
/// app model: which connect results are kept, which disconnects mean the device went offline, how the
/// retry backoff is scheduled, and what a user-initiated Retry does to all of it.
@Suite @MainActor struct RemoteOverviewSubscriptionCoordinatorTests {
    private typealias Coordinator = RemoteOverviewSubscriptionCoordinator<StubOverviewStreamClient>

    private func makeCoordinator() -> (Coordinator, ReconcileRecorder) {
        let recorder = ReconcileRecorder()
        let coordinator = Coordinator(requestReconcile: { recorder.count += 1 })
        // The retry is a real delayed task; shorten the whole backoff curve so the drain seam resolves
        // promptly, and pin the jitter so the armed delays are exact.
        coordinator.retryDelayPolicy = { _, failures in
            RemoteConnectionBackoff.delay(consecutiveFailures: failures, floor: .milliseconds(1), cap: .milliseconds(8), jitterFraction: 0)
        }
        coordinator.enable()
        return (coordinator, recorder)
    }

    /// Reconciles `device` in and returns the attempt id the reconcile assigned to the connect it asked
    /// for, so the test can hand that attempt's connect result and disconnects back the way the sidebar
    /// does. Also asserts the device was opened at all.
    @discardableResult private func openAttempt(_ coordinator: Coordinator, device: String) -> Int {
        guard let attempt = coordinator.reconcile(desiredIDs: [device]).devicesToOpen[device] else {
            Issue.record("the reconcile must open a device that has no subscription and no attempt pending")
            return -1
        }
        return attempt
    }

    /// Drives one failed connect for `attempt` on a coordinator that is already tracking it, and
    /// returns the delay of the retry that failure armed.
    private func armedDelayAfterFailedConnect(_ coordinator: Coordinator, device: String, attempt: Int) -> Duration? {
        _ = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: nil)
        return coordinator.armedRetryDelay(deviceID: device)
    }

    /// Drives a connect that reaches the remote (`.keep`) and then drops before delivering anything,
    /// the shape of a daemon that accepts the transport and rejects the subscribe request: the
    /// regression this file guards against. Returns the delay of the retry that disconnect armed.
    private func armedDelayAfterLiveDisconnect(_ coordinator: Coordinator, device: String, attempt: Int) -> Duration? {
        _ = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: StubOverviewStreamClient())
        _ = coordinator.applyDisconnect(deviceID: device, attempt: attempt, error: StubDisconnectError.dropped)
        return coordinator.armedRetryDelay(deviceID: device)
    }

    /// The regression: the stream can drop before the connect that opened it has handed its client
    /// back, because `start()` runs the receive loop before the client is returned. The dead client
    /// must never be cached as the device's live subscription: caching it left the device stuck
    /// showing stale state with no reconnect until the user hit Reload.
    @Test func disconnectBeforeTheConnectResultDiscardsTheClientAndReopensTheDevice() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)

        guard case .recordedWhileOpening = coordinator.applyDisconnect(deviceID: device, attempt: attempt, error: StubDisconnectError.dropped) else {
            Issue.record("a disconnect while the connect is in flight must be recorded, not ignored as an intentional removal")
            return
        }

        let client = StubOverviewStreamClient()
        switch coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: client) {
        case .discardDisconnected(let error): #expect(error as? StubDisconnectError == .dropped)
        case .keep, .discard, .connectFailed:
            Issue.record("the connect result must be discarded with the recorded disconnect so the device is marked offline")
        }

        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 1)
        // Nothing was retained for the device, so the reconcile opens it again instead of skipping it.
        openAttempt(coordinator, device: device)
    }

    @Test func liveSubscriptionDisconnectHandsBackTheClientAndArmsARetry() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)
        let client = StubOverviewStreamClient()
        guard case .keep = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: client) else {
            Issue.record("an uneventful connect result must be kept as the live subscription")
            return
        }

        switch coordinator.applyDisconnect(deviceID: device, attempt: attempt, error: StubDisconnectError.dropped) {
        case .markOffline(let disconnectedClient): #expect(disconnectedClient === client)
        case .ignore, .recordedWhileOpening: Issue.record("a live subscription dropping must mark the device offline")
        }

        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 1)
        openAttempt(coordinator, device: device)
    }

    @Test func disconnectAfterAnIntentionalRemovalIsIgnored() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)
        let client = StubOverviewStreamClient()
        _ = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: client)

        let removal = coordinator.reconcile(desiredIDs: [])
        #expect(removal.removed.count == 1)
        #expect(removal.removed.first?.client === client)

        guard case .ignore = coordinator.applyDisconnect(deviceID: device, attempt: attempt, error: nil) else {
            Issue.record("stopping a subscription on purpose must not mark the device offline")
            return
        }
        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 0)
    }

    @Test func failedConnectArmsARetryThatReopensTheDevice() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)

        guard case .connectFailed = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: nil) else {
            Issue.record("the current attempt's own failed connect must report connectFailed, not a bare discard, so the caller reports it")
            return
        }
        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 1)
        openAttempt(coordinator, device: device)
    }

    /// A stale attempt's connect result (superseded by a user retry that already started a new attempt
    /// on the same device) must read as an unwanted discard, never as a failure the caller should
    /// report: reporting it would raise a failure for a device whose replacement attempt may already be
    /// live.
    @Test func staleAttemptsFailedConnectDiscardsWithoutArmingARetry() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let staleAttempt = openAttempt(coordinator, device: device)
        _ = coordinator.resetForUserRetry(deviceID: device)
        openAttempt(coordinator, device: device)

        guard case .discard = coordinator.applyConnectResult(deviceID: device, attempt: staleAttempt, client: nil) else {
            Issue.record("a stale attempt's result must discard, not report connectFailed for the attempt that replaced it")
            return
        }
        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 0)
    }

    @Test func stoppingSubscriptionsDiscardsAnInFlightConnectWithoutRetrying() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)

        #expect(coordinator.disable().isEmpty)
        guard case .discard = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: StubOverviewStreamClient()) else {
            Issue.record("a connect that lands after subscriptions stop must be discarded")
            return
        }
        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 0)
    }

    @Test func stoppingSubscriptionsCancelsAnArmedRetry() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)
        #expect(armedDelayAfterFailedConnect(coordinator, device: device, attempt: attempt) != nil)

        #expect(coordinator.disable().isEmpty)
        // A retry surviving teardown would reconnect to a device the app has stopped tracking.
        #expect(coordinator.armedRetryDelay(deviceID: device) == nil)
        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 0)
    }

    /// A remote that stays down must not be reconnected every few seconds for as long as the app runs.
    /// A connect reaching the remote is not by itself evidence the subscription works (the daemon can
    /// still reject the subscribe request after the connect returns, e.g. a revoked token), so a bare
    /// connect must not undo the growth a run of failures already produced.
    @Test func retryBackoffGrowsWithConsecutiveFailuresAndIsNotResetByABareConnect() async {
        let (coordinator, _) = makeCoordinator()
        let device = "device-a"

        for expected: Duration in [.milliseconds(1), .milliseconds(2), .milliseconds(4), .milliseconds(8), .milliseconds(8)] {
            let attempt = openAttempt(coordinator, device: device)
            #expect(armedDelayAfterFailedConnect(coordinator, device: device, attempt: attempt) == expected)
            await coordinator.drainPendingRetryForTesting()
        }

        let attempt = openAttempt(coordinator, device: device)
        guard case .keep = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: StubOverviewStreamClient()) else {
            Issue.record("an uneventful connect result must be kept as the live subscription")
            return
        }
        guard case .markOffline = coordinator.applyDisconnect(deviceID: device, attempt: attempt, error: StubDisconnectError.dropped) else {
            Issue.record("a live subscription dropping must mark the device offline")
            return
        }
        // Still capped, not reset to the floor: the connect above never delivered an overview.
        #expect(coordinator.armedRetryDelay(deviceID: device) == .milliseconds(8))
        await coordinator.drainPendingRetryForTesting()
    }

    /// The regression this file guards against: a daemon that accepts the transport and rejects the
    /// subscribe request (a revoked token, for one) looks identical to a healthy connect until the
    /// rejection arrives as a disconnect. Every cycle here reaches `.keep` and then drops without ever
    /// calling `noteOverviewDelivered`, so the backoff must keep growing exactly as it would for a
    /// connect that failed outright. Fails without the fix: a connect resetting the count on its own
    /// pins every one of these cycles back at the floor.
    @Test func retryBackoffGrowsAcrossRepeatedConnectsThatNeverDeliverAnOverview() async {
        let (coordinator, _) = makeCoordinator()
        let device = "device-a"

        for expected: Duration in [.milliseconds(1), .milliseconds(2), .milliseconds(4), .milliseconds(8), .milliseconds(8)] {
            let attempt = openAttempt(coordinator, device: device)
            #expect(armedDelayAfterLiveDisconnect(coordinator, device: device, attempt: attempt) == expected)
            await coordinator.drainPendingRetryForTesting()
        }
    }

    /// Only a delivered overview proves the subscription itself works, so only it may reset the count a
    /// run of rejected connects grew.
    @Test func aDeliveredOverviewForTheCurrentAttemptResetsTheBackoff() async {
        let (coordinator, _) = makeCoordinator()
        let device = "device-a"

        for expected: Duration in [.milliseconds(1), .milliseconds(2)] {
            let attempt = openAttempt(coordinator, device: device)
            #expect(armedDelayAfterLiveDisconnect(coordinator, device: device, attempt: attempt) == expected)
            await coordinator.drainPendingRetryForTesting()
        }

        let attempt = openAttempt(coordinator, device: device)
        _ = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: StubOverviewStreamClient())
        coordinator.noteOverviewDelivered(deviceID: device, attempt: attempt)
        _ = coordinator.applyDisconnect(deviceID: device, attempt: attempt, error: StubDisconnectError.dropped)
        #expect(coordinator.armedRetryDelay(deviceID: device) == .milliseconds(1))
        await coordinator.drainPendingRetryForTesting()
    }

    /// A payload from an attempt a replacement has already superseded can still arrive after the
    /// replacement itself is open (the same receive-loop race `isCurrentAttempt`'s own doc comment
    /// describes), and must not be trusted to prove anything about the device's current subscription.
    @Test func aDeliveredOverviewForAStaleAttemptDoesNotResetTheBackoff() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"

        let staleAttempt = openAttempt(coordinator, device: device)
        #expect(armedDelayAfterLiveDisconnect(coordinator, device: device, attempt: staleAttempt) == .milliseconds(1))
        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 1)

        let currentAttempt = openAttempt(coordinator, device: device)
        #expect(currentAttempt != staleAttempt)

        coordinator.noteOverviewDelivered(deviceID: device, attempt: staleAttempt)

        #expect(armedDelayAfterLiveDisconnect(coordinator, device: device, attempt: currentAttempt) == .milliseconds(2))
        await coordinator.drainPendingRetryForTesting()
    }

    /// Devices that drop together (one network outage) must not retry in lockstep.
    @Test func retryBackoffIsSpreadByTheInjectedJitter() {
        let (coordinator, _) = makeCoordinator()
        coordinator.retryDelayPolicy = { _, failures in
            RemoteConnectionBackoff.delay(consecutiveFailures: failures, floor: .milliseconds(4), cap: .seconds(60), jitterFraction: 0.5)
        }
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)

        #expect(armedDelayAfterFailedConnect(coordinator, device: device, attempt: attempt) == .milliseconds(6))
    }

    /// The sidebar's reachability watchdog reconciles unconditionally, so the backoff only holds if
    /// the coordinator itself refuses to reopen a device that is still waiting one out.
    @Test func aDeviceWaitingOutItsBackoffIsNotReopenedByAReconcile() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)
        #expect(armedDelayAfterFailedConnect(coordinator, device: device, attempt: attempt) != nil)

        #expect(coordinator.reconcile(desiredIDs: [device]).devicesToOpen.isEmpty)
        #expect(coordinator.reconcile(desiredIDs: [device]).devicesToOpen.isEmpty)

        // Once the backoff elapses the device is reopened, so nothing is lost by holding it back.
        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 1)
        openAttempt(coordinator, device: device)
    }

    /// The sidebar's per-device Retry: the user asking again must not be answered with the schedule a
    /// run of failures grew, and must not leave the device waiting on the retry it was already holding.
    @Test func userRetryClearsTheArmedRetryAndResetsTheBackoff() async {
        let (coordinator, _) = makeCoordinator()
        let device = "device-a"
        // Fail three times, so the user intervenes while the device is waiting out a grown backoff.
        for expected: Duration in [.milliseconds(1), .milliseconds(2), .milliseconds(4)] {
            let attempt = openAttempt(coordinator, device: device)
            #expect(armedDelayAfterFailedConnect(coordinator, device: device, attempt: attempt) == expected)
            if expected != .milliseconds(4) { await coordinator.drainPendingRetryForTesting() }
        }

        #expect(coordinator.resetForUserRetry(deviceID: device) == nil)
        // The armed retry is cancelled and the device untracked, so the caller's reconcile reopens it
        // immediately instead of waiting the backoff out.
        #expect(coordinator.armedRetryDelay(deviceID: device) == nil)
        let attempt = openAttempt(coordinator, device: device)
        // The failure count went with it: the next failure starts the curve at its floor again.
        #expect(armedDelayAfterFailedConnect(coordinator, device: device, attempt: attempt) == .milliseconds(1))
        await coordinator.drainPendingRetryForTesting()
    }

    /// A retry on a device that still holds a live subscription must hand that client back for the
    /// caller to stop (a stream left running would deliver into a device that has reconnected), and
    /// the disconnect that stopping it triggers must not be charged to the retry's own attempt.
    @Test func userRetryHandsBackTheLiveClientAndIgnoresItsTrailingDisconnect() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let stoppedAttempt = openAttempt(coordinator, device: device)
        let client = StubOverviewStreamClient()
        _ = coordinator.applyConnectResult(deviceID: device, attempt: stoppedAttempt, client: client)

        #expect(coordinator.resetForUserRetry(deviceID: device) === client)
        let retryAttempt = openAttempt(coordinator, device: device)
        #expect(retryAttempt != stoppedAttempt)

        // Stopping a client fires its disconnect asynchronously, so it lands while the retry's connect
        // is still in flight. Charging it to that connect would discard a healthy new subscription as
        // dead and park the device offline behind another backoff.
        guard case .ignore = coordinator.applyDisconnect(deviceID: device, attempt: stoppedAttempt, error: StubDisconnectError.dropped) else {
            Issue.record("a disconnect from the attempt the retry abandoned must not touch the attempt that replaced it")
            return
        }
        guard case .keep = coordinator.applyConnectResult(deviceID: device, attempt: retryAttempt, client: StubOverviewStreamClient()) else {
            Issue.record("the retry's connect must be kept as the device's live subscription")
            return
        }
        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 0)
    }

    /// The watchdog's tick is a plain reconcile, so it is the reconcile that has to restore the
    /// invariant: every wanted device that has no subscription and no attempt pending gets opened.
    @Test func aReconcileOpensEveryDeviceWithoutALiveSubscription() {
        let (coordinator, _) = makeCoordinator()
        let attempt = openAttempt(coordinator, device: "device-a")
        _ = coordinator.applyConnectResult(deviceID: "device-a", attempt: attempt, client: StubOverviewStreamClient())

        #expect(Array(coordinator.reconcile(desiredIDs: ["device-a", "device-b"]).devicesToOpen.keys) == ["device-b"])
    }

    /// Parking a device that turned out to be wire-incompatible is expressed purely by dropping it from
    /// the desired set, so the live stream it still holds has to be torn down by the removal path: a
    /// stream left running would keep dropping and re-arming for as long as the daemon stays behind.
    @Test func droppingADeviceFromTheDesiredSetStopsItsLiveSubscription() {
        let (coordinator, _) = makeCoordinator()
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)
        let client = StubOverviewStreamClient()
        _ = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: client)

        let outcome = coordinator.reconcile(desiredIDs: [])
        #expect(outcome.removed.map(\.deviceID) == [device])
        #expect(outcome.removed.first?.client === client)
        #expect(outcome.devicesToOpen.isEmpty)
    }

    /// A device that becomes unwanted while it is waiting out a retry must let that retry expire without
    /// leaving anything armed behind it: the retry clears the device and asks for a reconcile, and the
    /// reconcile that answers no longer wants it. Recovering the device later is just as plain: it
    /// re-enters the desired set and the next reconcile opens it.
    @Test func anArmedRetryForAnUnwantedDeviceExpiresWithoutReopeningIt() async {
        let (coordinator, recorder) = makeCoordinator()
        let device = "device-a"
        let attempt = openAttempt(coordinator, device: device)
        #expect(armedDelayAfterFailedConnect(coordinator, device: device, attempt: attempt) != nil)

        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 1)
        #expect(coordinator.reconcile(desiredIDs: []).devicesToOpen.isEmpty)
        #expect(coordinator.armedRetryDelay(deviceID: device) == nil)

        openAttempt(coordinator, device: device)
    }

    /// `isCurrentAttempt` is what lets a data delivery (which carries no attempt id of its own until a
    /// caller threads one through) be checked the same way a connect result or a disconnect already is.
    /// True while opening or live under the matching attempt id, false for a mismatched attempt, false
    /// once the device is waiting out a retry, and false for a device never tracked at all.
    @Test func isCurrentAttemptTracksOpeningAndLiveButNotWaitingToRetryOrUntracked() async {
        let (coordinator, _) = makeCoordinator()
        let device = "device-a"

        #expect(!coordinator.isCurrentAttempt(deviceID: device, attempt: 1), "untracked: no attempt is current")

        let attempt = openAttempt(coordinator, device: device)
        #expect(coordinator.isCurrentAttempt(deviceID: device, attempt: attempt), "opening under its own attempt id")
        #expect(!coordinator.isCurrentAttempt(deviceID: device, attempt: attempt + 1), "a mismatched attempt id is never current")

        _ = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: StubOverviewStreamClient())
        #expect(coordinator.isCurrentAttempt(deviceID: device, attempt: attempt), "live under the same attempt id that opened it")

        _ = coordinator.applyDisconnect(deviceID: device, attempt: attempt, error: StubDisconnectError.dropped)
        #expect(!coordinator.isCurrentAttempt(deviceID: device, attempt: attempt), "waiting out an armed retry: nothing is current")

        await coordinator.drainPendingRetryForTesting()
    }

    /// `isLive` answers a different question than `isCurrentAttempt`: not "is this attempt id still the
    /// one that matters" but "is anything open right now that would itself notice a drop". False while
    /// opening (the connect has not resolved yet), true only once `.live`, and false again the instant a
    /// disconnect arms a retry.
    @Test func isLiveTracksOnlyTheLiveStateNotOpeningOrWaitingToRetry() async {
        let (coordinator, _) = makeCoordinator()
        let device = "device-a"

        #expect(!coordinator.isLive(deviceID: device), "untracked: nothing is live")

        let attempt = openAttempt(coordinator, device: device)
        #expect(!coordinator.isLive(deviceID: device), "opening: the connect has not resolved yet")

        _ = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: StubOverviewStreamClient())
        #expect(coordinator.isLive(deviceID: device), "a kept connect result is live")

        _ = coordinator.applyDisconnect(deviceID: device, attempt: attempt, error: StubDisconnectError.dropped)
        #expect(!coordinator.isLive(deviceID: device), "waiting out an armed retry: not live")

        await coordinator.drainPendingRetryForTesting()
    }
}
