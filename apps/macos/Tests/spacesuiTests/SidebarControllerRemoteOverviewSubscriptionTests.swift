import Foundation
import Testing

@testable import spacesui

/// A stand-in for the overview stream client. The coordinator never touches the client beyond
/// holding it and handing it back, so identity is all a test needs.
private final class StubOverviewStreamClient {}

private enum StubDisconnectError: Error, Equatable { case dropped }

/// Counts the reconciles the coordinator requests, so a test can prove a retry was armed without
/// re-entering the coordinator.
@MainActor private final class ReconcileRecorder { var count = 0 }

/// Behavior of the sidebar's per-device overview-subscription state machine: which connect results
/// are kept, which disconnects mean the device went offline, how the retry backoff is scheduled, and
/// what a user-initiated Retry does to all of it.
@Suite @MainActor struct RemoteOverviewSubscriptionCoordinatorTests {
    private typealias Coordinator = RemoteOverviewSubscriptionCoordinator<StubOverviewStreamClient>

    private func makeCoordinator() -> (Coordinator, ReconcileRecorder) {
        let recorder = ReconcileRecorder()
        let coordinator = Coordinator(requestReconcile: { recorder.count += 1 })
        // The retry is a real delayed task; shorten the whole backoff curve so the drain seam resolves
        // promptly, and pin the jitter so the armed delays are exact.
        coordinator.retryDelay = .milliseconds(1)
        coordinator.maxRetryDelay = .milliseconds(8)
        coordinator.retryJitterFraction = { 0 }
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

    /// The regression: the stream can drop before the connect that opened it has handed its client
    /// back, because `start()` runs the receive loop before the client is returned. The dead client
    /// must never be cached as the device's live subscription — caching it left the device stuck
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
        case .keep, .discard: Issue.record("the connect result must be discarded with the recorded disconnect so the device is marked offline")
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

        guard case .discard = coordinator.applyConnectResult(deviceID: device, attempt: attempt, client: nil) else {
            Issue.record("a failed connect leaves nothing to retain")
            return
        }
        await coordinator.drainPendingRetryForTesting()
        #expect(recorder.count == 1)
        openAttempt(coordinator, device: device)
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

    /// A remote that stays down must not be reconnected every few seconds for as long as the app runs,
    /// and a remote that comes back must not inherit the delay the previous outage had grown to.
    @Test func retryBackoffGrowsWithConsecutiveFailuresAndResetsOnASuccessfulConnect() async {
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
        #expect(coordinator.armedRetryDelay(deviceID: device) == .milliseconds(1))
        await coordinator.drainPendingRetryForTesting()
    }

    /// Devices that drop together (one network outage) must not retry in lockstep.
    @Test func retryBackoffIsSpreadByTheInjectedJitter() {
        let (coordinator, _) = makeCoordinator()
        coordinator.retryDelay = .milliseconds(4)
        coordinator.retryJitterFraction = { 0.5 }
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
    /// caller to stop — a stream left running would deliver into a device that has reconnected — and
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
}

/// Behavior of the pacing applied to the sidebar's one-shot overview pulls, which are started by every
/// local-event sidebar reload and every reachability watchdog tick.
@Suite @MainActor struct RemoteOverviewPullBackoffTests {
    private func makeBackoff() -> RemoteOverviewPullBackoff {
        let backoff = RemoteOverviewPullBackoff()
        // The hold is a real delayed task; shorten the whole curve so the drain seam resolves promptly,
        // and pin the jitter so the armed delays are exact.
        backoff.retryDelay = .milliseconds(1)
        backoff.maxRetryDelay = .milliseconds(8)
        backoff.retryJitterFraction = { 0 }
        return backoff
    }

    /// The regression: only a pull that returned data stamps the sidebar's freshness window, so nothing
    /// else paces a device whose pulls fail. Against a remote that refuses connections fast, every
    /// sidebar reload and watchdog tick would otherwise dial it again the moment the last attempt failed.
    @Test func aFailedPullIsNotReattemptedUntilItsBackoffElapses() async {
        let backoff = makeBackoff()
        let device = "device-a"
        #expect(backoff.allowsAttempt(deviceID: device))

        #expect(backoff.recordFailure(deviceID: device) == .milliseconds(1))
        #expect(!backoff.allowsAttempt(deviceID: device))

        await backoff.drainPendingHoldsForTesting()
        #expect(backoff.allowsAttempt(deviceID: device))
    }

    /// A remote that stays down must settle into a slow probe, and one that answers again must not
    /// inherit the delay the previous outage had grown to.
    @Test func thePullBackoffGrowsWithConsecutiveFailuresAndResetsOnAPullThatReturnsData() async {
        let backoff = makeBackoff()
        let device = "device-a"

        for expected: Duration in [.milliseconds(1), .milliseconds(2), .milliseconds(4), .milliseconds(8), .milliseconds(8)] {
            #expect(backoff.recordFailure(deviceID: device) == expected)
            await backoff.drainPendingHoldsForTesting()
        }

        backoff.clear(deviceID: device)
        #expect(backoff.recordFailure(deviceID: device) == .milliseconds(1))
        await backoff.drainPendingHoldsForTesting()
    }

    /// Devices that failed together (one network outage) must not be pulled in lockstep.
    @Test func thePullBackoffIsSpreadByTheInjectedJitter() {
        let backoff = makeBackoff()
        backoff.retryDelay = .milliseconds(4)
        backoff.retryJitterFraction = { 0.5 }

        #expect(backoff.recordFailure(deviceID: "device-a") == .milliseconds(6))
    }

    /// The user asking for this device is a stronger signal than the schedule its run of failures grew,
    /// so Retry must not be answered with "wait another minute".
    @Test func aUserRetryReleasesTheDeviceImmediately() async {
        let backoff = makeBackoff()
        let device = "device-a"
        backoff.recordFailure(deviceID: device)
        backoff.recordFailure(deviceID: device)
        #expect(!backoff.allowsAttempt(deviceID: device))

        backoff.clear(deviceID: device)
        #expect(backoff.allowsAttempt(deviceID: device))
        await backoff.drainPendingHoldsForTesting()
    }

    /// One device's outage must not hold back another device's pulls.
    @Test func aHeldBackDeviceDoesNotPaceTheOthers() async {
        let backoff = makeBackoff()
        backoff.recordFailure(deviceID: "device-a")

        #expect(!backoff.allowsAttempt(deviceID: "device-a"))
        #expect(backoff.allowsAttempt(deviceID: "device-b"))
        await backoff.drainPendingHoldsForTesting()
    }
}

/// Behavior of the offline device caption: whose reason repaints, and which offline device is offered a
/// Retry at all.
@Suite struct SidebarDeviceOfflineCaptionTests {
    /// The offline caption's tooltip is read out of the load state when the row's cell is built, so a
    /// reason that changed mid-outage only reaches the user if that row is rebuilt — and an unchanged
    /// failure, which every watchdog probe of a device that stays down produces, must rebuild nothing.
    @Test func aChangedOfflineReasonRepaintsTheRowWhileAnUnchangedFailureTouchesNothing() {
        #expect(SidebarController.offlineSectionUpdate(loadState: .loaded, reason: "Connection refused") == .transition)
        #expect(SidebarController.offlineSectionUpdate(loadState: .loading, reason: "Connection refused") == .transition)
        #expect(SidebarController.offlineSectionUpdate(loadState: .offline("Connection refused"), reason: "Connection refused") == .unchanged)
        #expect(SidebarController.offlineSectionUpdate(loadState: .offline("The connection closed."), reason: "Connection refused") == .repaintReason)
    }

    /// A remote whose auth token or certificate fingerprint is gone reads "Reconnect required" and is
    /// recovered by pairing it again; offering Retry there renders a button that does nothing.
    @Test func aDeviceWithNoCredentialsIsNotOfferedARetry() {
        #expect(!SidebarController.deviceSectionOffersRetry(loadState: .offline("Reconnect required"), isLocal: false, hasCredentials: false))
        #expect(SidebarController.deviceSectionOffersRetry(loadState: .offline("Connection refused"), isLocal: false, hasCredentials: true))
        // The local device has no stored credentials of its own: its retry re-runs the sidebar snapshot.
        #expect(SidebarController.deviceSectionOffersRetry(loadState: .offline("daemon down"), isLocal: true, hasCredentials: false))
        // Retry is an offline device's recovery; a loaded or still-loading section offers none.
        #expect(!SidebarController.deviceSectionOffersRetry(loadState: .loaded, isLocal: false, hasCredentials: true))
        #expect(!SidebarController.deviceSectionOffersRetry(loadState: .loading, isLocal: true, hasCredentials: true))
    }
}
