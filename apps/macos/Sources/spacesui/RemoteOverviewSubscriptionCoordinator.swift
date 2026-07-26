import Foundation

/// Per-device bookkeeping for the sidebar's live device-overview subscriptions.
///
/// Opening a subscription connects off the main actor and hands its client back asynchronously,
/// while the stream's disconnect callback can already fire the moment the receive loop starts —
/// that is, before the connect result lands. This type is the single place that decides, per
/// device, what a disconnect means and whether an arriving connect result is still wanted.
///
/// It also owns the retry schedule: every failed connect and every dropped stream arms that device's
/// own bounded exponential backoff, and the device stays tracked while it waits so the caller's
/// unconditional reconciles cannot reopen it early. The two together make "every paired device has a
/// live subscription" a continuously restored invariant that still leaves a genuinely-down remote
/// alone between attempts.
///
/// It performs no I/O: the caller opens connections, stops clients, and paints the sidebar; the
/// coordinator only tracks state and answers those questions, so the decisions are unit-testable
/// by driving transitions directly.
@MainActor final class RemoteOverviewSubscriptionCoordinator<Client: AnyObject> {
    struct ReconcileOutcome {
        /// Live subscriptions whose device is no longer wanted. The caller stops each client; the
        /// coordinator has already dropped it, so the resulting disconnect reads as intentional.
        var removed: [(deviceID: String, client: Client)] = []
        /// Devices with no subscription and no connect in flight, each mapped to the attempt id its
        /// connect and its stream's disconnects must carry back. Marked as opening here, so a second
        /// reconcile before the connect returns does not start a duplicate connection.
        var devicesToOpen: [String: Int] = [:]
    }

    /// What the caller must do with a connect result that just landed.
    enum ConnectOutcome {
        /// Retain the client as the device's live subscription.
        case keep
        /// Stop and drop the client: the device is no longer wanted, or the connect failed.
        case discard
        /// Stop and drop the client and mark the device offline with `error`: the stream dropped
        /// before the connect result landed, so the client handed back is already dead. A retry is
        /// armed.
        case discardDisconnected(error: (any Error)?)
    }

    /// What the caller must do with a disconnect callback.
    enum DisconnectOutcome {
        /// The subscription this disconnect belongs to was already given up on: removed on purpose,
        /// already retrying, or abandoned by a newer attempt on the same device.
        case ignore
        /// The stream dropped while its connect was still in flight. Recorded so the connect result
        /// that lands afterwards is discarded instead of being cached as a live subscription.
        case recordedWhileOpening
        /// The live subscription dropped: stop `client` and mark the device offline. A retry is armed.
        case markOffline(client: Client)
    }

    private enum DeviceState {
        case opening(attempt: Int, disconnect: PendingDisconnect?)
        case live(attempt: Int, client: Client)
        /// Waiting out the backoff delay after a failed connect or a dropped stream. The device stays
        /// tracked while it waits so `reconcile` leaves it alone: reconciles arrive unconditionally
        /// (the sidebar's reachability watchdog ticks on a timer), and reopening on every tick would
        /// reconnect-storm a remote that is genuinely down.
        case waitingToRetry(task: Task<Void, Never>, delay: Duration)
    }

    /// A disconnect observed while the device's connect was still in flight, held until the connect
    /// result lands so its error still reaches the offline caption.
    private struct PendingDisconnect { let error: (any Error)? }

    private let requestReconcile: @MainActor () -> Void
    private var states: [String: DeviceState] = [:]
    /// Source of the attempt ids that tie a connect result and a stream's disconnects to the attempt
    /// that produced them. A device can have an abandoned attempt still winding down — a user retry
    /// stops the live client and connects again immediately, and that stopped stream's disconnect
    /// callback arrives afterwards — so identity, not device alone, decides what a callback means.
    private var lastAttemptID = 0
    /// Consecutive failed connects / dropped streams per device, the exponent behind its retry
    /// backoff. Reset when a connect succeeds and dropped when the device stops being tracked.
    private var consecutiveFailures: [String: Int] = [:]
    private(set) var isEnabled = false
    /// Floor of the per-device retry backoff: the delay before the first retry after a device's
    /// subscription fails. Internal so behavior tests can shorten it instead of waiting out real
    /// seconds.
    var retryDelay: Duration = .seconds(5)
    /// Ceiling of the per-device retry backoff, so a remote that stays down settles into a slow probe
    /// instead of retrying every few seconds for as long as the app runs. Internal so behavior tests
    /// can shorten it.
    var maxRetryDelay: Duration = .seconds(60)
    /// Fraction of the computed backoff added on top as jitter, so several devices that dropped
    /// together (a network outage) don't retry in lockstep. Internal so behavior tests can pin it
    /// instead of depending on a random draw.
    var retryJitterFraction: @MainActor () -> Double = { Double.random(in: 0..<0.25) }

    init(requestReconcile: @escaping @MainActor () -> Void) { self.requestReconcile = requestReconcile }

    func enable() { isEnabled = true }

    /// Stops tracking every device and returns the live clients for the caller to stop. Disconnects
    /// and connect results arriving afterwards find no state and are discarded.
    func disable() -> [Client] {
        isEnabled = false
        var clients: [Client] = []
        for state in states.values {
            switch state {
            case .live(_, let client): clients.append(client)
            case .waitingToRetry(let task, _): task.cancel()
            case .opening: break
            }
        }
        states.removeAll()
        consecutiveFailures.removeAll()
        return clients
    }

    /// Reconciles tracked devices to `desiredIDs`, reporting the subscriptions to tear down and the
    /// devices to connect. A device waiting out its retry backoff is deliberately left alone — its
    /// armed retry is what reopens it — so an unconditional reconcile converges on every device that
    /// has no subscription and no pending attempt, without shortcutting the backoff.
    func reconcile(desiredIDs: Set<String>) -> ReconcileOutcome {
        var outcome = ReconcileOutcome()
        for (deviceID, state) in states where !desiredIDs.contains(deviceID) {
            states[deviceID] = nil
            consecutiveFailures[deviceID] = nil
            switch state {
            case .live(_, let client): outcome.removed.append((deviceID: deviceID, client: client))
            case .waitingToRetry(let task, _): task.cancel()
            case .opening: break
            }
        }
        for deviceID in desiredIDs where states[deviceID] == nil {
            lastAttemptID += 1
            states[deviceID] = .opening(attempt: lastAttemptID, disconnect: nil)
            outcome.devicesToOpen[deviceID] = lastAttemptID
        }
        return outcome
    }

    func applyConnectResult(deviceID: String, attempt: Int, client: Client?) -> ConnectOutcome {
        guard case .opening(let openingAttempt, let pendingDisconnect) = states[deviceID], openingAttempt == attempt else {
            // The device stopped being wanted while the connect was in flight (unpaired, credentials
            // gone, or subscriptions stopped), or a user retry abandoned this attempt and started
            // another, so the result is unwanted and nothing needs retrying.
            return .discard
        }
        guard let client else {
            // The connect attempt failed (remote offline, or still unreachable on a retry). The armed
            // retry's reconcile opens the device again once its backoff elapses.
            armRetry(deviceID: deviceID)
            return .discard
        }
        if let pendingDisconnect {
            // The stream this connect opened already dropped, so the client handed back is dead:
            // retaining it would leave the device with a subscription that can never deliver an
            // overview and can never disconnect again, and every later reconcile would skip the
            // device because it looks subscribed.
            armRetry(deviceID: deviceID)
            return .discardDisconnected(error: pendingDisconnect.error)
        }
        states[deviceID] = .live(attempt: attempt, client: client)
        // A connect that reached the remote clears the backoff, so the next outage retries promptly
        // instead of inheriting the delay a previous outage had grown to.
        consecutiveFailures[deviceID] = nil
        return .keep
    }

    func applyDisconnect(deviceID: String, attempt: Int, error: (any Error)?) -> DisconnectOutcome {
        switch states[deviceID] {
        case .none: return .ignore
        case .opening(let openingAttempt, let recorded):
            // A disconnect from an abandoned attempt says nothing about the one now connecting: a user
            // retry stops the old client, and recording that stop against the new attempt would discard
            // a perfectly good subscription as dead.
            guard openingAttempt == attempt else { return .ignore }
            // Keep the first reason: it is the one that closed the stream, and the offline caption
            // reads better from it than from a follow-on close.
            states[deviceID] = .opening(attempt: attempt, disconnect: recorded ?? PendingDisconnect(error: error))
            return .recordedWhileOpening
        case .waitingToRetry:
            // The subscription this disconnect belongs to was already given up on and its retry armed.
            return .ignore
        case .live(let liveAttempt, let client):
            // A live subscription opened by a later attempt outlives the one this disconnect belongs to.
            guard liveAttempt == attempt else { return .ignore }
            armRetry(deviceID: deviceID)
            return .markOffline(client: client)
        }
    }

    /// Arms this device's delayed reconcile so a persistently unreachable remote reconnects without
    /// spinning, and holds the device in `.waitingToRetry` until it fires so an unconditional
    /// reconcile in the meantime does not reopen it early.
    /// Only reached while subscriptions are enabled: `disable()` drops every tracked device, so a
    /// connect result or disconnect arriving afterwards finds no state and never gets here.
    private func armRetry(deviceID: String) {
        let failures = (consecutiveFailures[deviceID] ?? 0) + 1
        consecutiveFailures[deviceID] = failures
        let delay = RemoteConnectionBackoff.delay(
            consecutiveFailures: failures, floor: retryDelay, cap: maxRetryDelay, jitterFraction: retryJitterFraction())
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            // Stop tracking before the reconcile runs so it sees a device with no subscription and no
            // pending attempt, and reopens it.
            guard case .waitingToRetry = self.states[deviceID] else { return }
            self.states[deviceID] = nil
            self.requestReconcile()
        }
        states[deviceID] = .waitingToRetry(task: task, delay: delay)
    }

    /// Drops everything tracked for `deviceID` — a live subscription, an in-flight connect's claim on
    /// the device, an armed retry — and clears its backoff, so the caller's next reconcile reopens the
    /// device immediately and a fresh failure starts the backoff at its floor again. Returns the live
    /// client, if any, for the caller to stop.
    ///
    /// This is the user asking for this device again, which is a stronger signal than the schedule a run
    /// of failures grew. Everything abandoned here still lands later — an in-flight connect, and the
    /// disconnect the caller's `stop()` triggers on the returned client — carrying the attempt id of the
    /// attempt being abandoned, so neither is mistaken for the state of the attempt that replaces it.
    func resetForUserRetry(deviceID: String) -> Client? {
        let state = states.removeValue(forKey: deviceID)
        consecutiveFailures[deviceID] = nil
        switch state {
        case .live(_, let client): return client
        case .waitingToRetry(let task, _): task.cancel()
        case .opening, .none: break
        }
        return nil
    }

    /// The delay of the retry currently armed for `deviceID`, or `nil` when the device is not waiting on
    /// one. Read by the connection trace to record when a device is next attempted, and by behavior
    /// tests to assert how the backoff grows and resets without waiting out the delays themselves.
    func armedRetryDelay(deviceID: String) -> Duration? {
        guard case .waitingToRetry(_, let delay) = states[deviceID] else { return nil }
        return delay
    }

    /// Awaits every armed retry, including the reconciles they request, so a behavior test can assert
    /// on retry scheduling deterministically instead of polling under a wall-clock ceiling. A no-op
    /// when no retry is armed.
    func drainPendingRetryForTesting() async {
        let tasks = states.values.compactMap { state -> Task<Void, Never>? in
            guard case .waitingToRetry(let task, _) = state else { return nil }
            return task
        }
        for task in tasks { await task.value }
    }
}
