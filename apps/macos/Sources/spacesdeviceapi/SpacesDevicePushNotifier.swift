import Foundation
import spacesdevicecore

/// Turns committed device overviews into push-relay reports for every phone that registered on this daemon.
///
/// Per registered phone it keeps three things apart:
/// - a seen set of visible alert keys, so only a key that is new since the previous overview can buzz;
/// - the recheck wait: a new blocked or finished agent buzzes only if its key is still visible
///   `recheckDelay` later, so an agent the user answers or dismisses at once never buzzes;
/// - the relay report: counts with `notify: false` after a `debounceDelay` of quiet, or `notify: true` the
///   moment a recheck confirms a buzz.
///
/// Requests for one phone are serial, and a report always carries the latest counts, so a slow or failed
/// call is replaced by the newest state instead of replayed. The relay pushes only when the delivered
/// badge differs, which makes sending an unchanged state harmless and lets a restart simply resync.
///
/// Thread-safety: all state is guarded by `lock`. Relay calls, store writes, and scheduler callbacks run
/// outside it, because a test double may complete a call synchronously.
final class SpacesDevicePushNotifier: @unchecked Sendable {
    static let recheckDelay: TimeInterval = 10
    static let debounceDelay: TimeInterval = 1
    /// Waits before each retry of a transiently failed report. After the last one the daemon gives up on
    /// those counts until they change.
    static let retryDelays: [TimeInterval] = [5, 30, 120]

    private struct PendingTimer {
        let id: Int
        let fireAt: Date
        let work: any SpacesDevicePushScheduledWork
    }

    private struct Flight {
        let capability: String
        let counts: SpacesDeviceAlertCounts
        let notifyKeys: Set<String>
    }

    /// One registered phone. Reference type so a relay completion can find the state it was sent for even
    /// after the phone was re-registered or dropped; `isRetired` tells it to stand down. Every field is read
    /// and written only under the notifier's `lock`, which is what makes `@unchecked Sendable` honest.
    private final class Phone: @unchecked Sendable {
        let installationID: String
        var registration: SpacesDevicePushRegistration
        var seenKeys: Set<String>?
        var latest: SpacesDevicePushAlertSnapshot?
        var recheckQueue: [String: (due: Date, kind: SpacesDeviceAlertKind)] = [:]
        var notifyKeys: Set<String> = []
        var recheckTimer: PendingTimer?
        var debounceTimer: PendingTimer?
        var retryTimer: PendingTimer?
        var flight: Flight?
        /// What the relay last accepted from this daemon for this phone. Nil forces a resync report.
        var lastSent: SpacesDeviceAlertCounts?
        /// Counts the daemon stopped retrying; they are not sent again until the counts change.
        var abandoned: SpacesDeviceAlertCounts?
        var attempt = 0
        var isRetired = false
        /// Set when the phone unregisters while a report is in flight: the unregister waits for it, so the
        /// relay never sees the two out of order.
        var unregisterCapability: String?

        init(installationID: String, registration: SpacesDevicePushRegistration) {
            self.installationID = installationID
            self.registration = registration
        }
    }

    /// Work decided under the lock and performed after it.
    private enum Effect {
        case send(Phone, SpacesDevicePushRelayRequest)
        case sendUnregister(SpacesDevicePushRelayRequest, installationID: String)
        case clearRegistration(installationID: String, capability: String)
    }

    private let relay: any SpacesDevicePushRelayClient
    private let scheduler: any SpacesDevicePushScheduler
    private let relayDeviceID: String
    private let loadRegistrations: @Sendable () throws -> [String: SpacesDevicePushRegistration]
    private let clearRegistration: @Sendable (_ installationID: String, _ capability: String) -> Void

    private let lock = NSLock()
    private var isRunning = false
    private var snapshot: SpacesDevicePushAlertSnapshot?
    private var phones: [String: Phone] = [:]
    private var nextTimerID = 0
    /// Unregister calls not yet settled, by installation. A replacement registration for the same installation
    /// reports nothing until its count reaches zero, because the relay deletes a device's counts when it
    /// processes an unregister, and a late one would erase the replacement's live counts.
    private var pendingUnregisters: [String: Int] = [:]
    /// Bumped by every registration change (`registrationsChanged`, `unregister`). A caller that loaded the stored
    /// registrations applies them only if the generation it saw before loading is still current.
    private var registrationGeneration = 0

    init(
        relay: any SpacesDevicePushRelayClient, scheduler: any SpacesDevicePushScheduler, relayDeviceID: String,
        loadRegistrations: @escaping @Sendable () throws -> [String: SpacesDevicePushRegistration],
        clearRegistration: @escaping @Sendable (_ installationID: String, _ capability: String) -> Void
    ) {
        self.relay = relay
        self.scheduler = scheduler
        self.relayDeviceID = relayDeviceID
        self.loadRegistrations = loadRegistrations
        self.clearRegistration = clearRegistration
    }

    func start() {
        lock.lock()
        isRunning = true
        lock.unlock()
    }

    /// Cancels every timer and forgets every phone, so the next start seeds from its first overview.
    func stop() {
        lock.lock()
        isRunning = false
        snapshot = nil
        for phone in phones.values { retire(phone) }
        phones = [:]
        lock.unlock()
    }

    /// Feeds one committed overview. Called for every committed overview, whether or not any client streams.
    func overviewCommitted(_ overview: SpacesDeviceOverviewPayload) {
        let captured = currentRegistrationGeneration()
        let registrations = try? loadRegistrations()
        let next = SpacesDevicePushAlertSnapshot(overview: overview)
        var effects: [Effect] = []
        lock.lock()
        if isRunning {
            snapshot = next
            // A registration change since the load makes the loaded set stale: applying it could recreate a phone
            // that just unregistered. The change reconciles on its own, and the next overview reconciles again.
            if let registrations, registrationGeneration == captured { reconcile(registrations, effects: &effects) }
        }
        lock.unlock()
        perform(effects)
    }

    /// Re-reads the stored registrations after one was added, changed, or removed.
    func registrationsChanged() {
        lock.lock()
        registrationGeneration += 1
        let captured = registrationGeneration
        lock.unlock()
        guard let registrations = try? loadRegistrations() else { return }
        var effects: [Effect] = []
        lock.lock()
        if isRunning, snapshot != nil, registrationGeneration == captured { reconcile(registrations, effects: &effects) }
        lock.unlock()
        perform(effects)
    }

    private func currentRegistrationGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return registrationGeneration
    }

    /// Stops reporting for a phone whose registration was removed (it unregistered, or its pairing was revoked
    /// or reset) and tells the relay once, best effort, so this device's counts leave the phone's badge. The
    /// relay call waits for a report already in flight for that phone.
    func unregister(installationID: String, capability: String) {
        var effects: [Effect] = []
        let request = SpacesDevicePushRelayRequest.unregister(capability: capability, deviceID: relayDeviceID)
        lock.lock()
        registrationGeneration += 1
        pendingUnregisters[installationID, default: 0] += 1
        if let phone = phones.removeValue(forKey: installationID) {
            retire(phone)
            if phone.flight != nil {
                phone.unregisterCapability = capability
            } else {
                effects.append(.sendUnregister(request, installationID: installationID))
            }
        } else {
            effects.append(.sendUnregister(request, installationID: installationID))
        }
        lock.unlock()
        perform(effects)
    }

    // MARK: - State changes (lock held)

    private func reconcile(_ registrations: [String: SpacesDevicePushRegistration], effects: inout [Effect]) {
        guard let snapshot else { return }
        for (installationID, phone) in phones where registrations[installationID] == nil {
            retire(phone)
            phones.removeValue(forKey: installationID)
        }
        let now = scheduler.now
        for (installationID, registration) in registrations {
            let phone: Phone
            if let existing = phones[installationID] {
                phone = existing
                if existing.registration.capability != registration.capability {
                    // The new capability names a fresh relay registration that has never heard from this daemon.
                    cancel(&existing.retryTimer)
                    existing.lastSent = nil
                    existing.abandoned = nil
                    existing.attempt = 0
                }
                existing.registration = registration
            } else {
                phone = Phone(installationID: installationID, registration: registration)
                phones[installationID] = phone
            }
            observe(snapshot, on: phone, now: now, effects: &effects)
        }
    }

    private func observe(_ snapshot: SpacesDevicePushAlertSnapshot, on phone: Phone, now: Date, effects: inout [Effect]) {
        let evaluation = SpacesDevicePushAlertEvaluation.evaluate(seenKeys: phone.seenKeys, snapshot: snapshot, registration: phone.registration)
        phone.seenKeys = evaluation.seenKeys
        phone.latest = snapshot
        for (key, kind) in evaluation.recheckKeys where phone.recheckQueue[key] == nil {
            phone.recheckQueue[key] = (now.addingTimeInterval(Self.recheckDelay), kind)
        }
        phone.recheckQueue = phone.recheckQueue.filter { snapshot.kindsByKey[$0.key] != nil }
        armRecheck(phone)
        if !phone.notifyKeys.isEmpty { flush(phone, effects: &effects) } else { armDebounce(phone) }
    }

    private func armRecheck(_ phone: Phone) {
        guard let earliest = phone.recheckQueue.values.map(\.due).min() else {
            cancel(&phone.recheckTimer)
            return
        }
        if let timer = phone.recheckTimer, timer.fireAt <= earliest { return }
        cancel(&phone.recheckTimer)
        let id = takeTimerID()
        let work = scheduler.schedule(after: max(earliest.timeIntervalSince(scheduler.now), 0)) { [weak self, weak phone] in
            guard let self, let phone else { return }
            self.recheckFired(phone, timerID: id)
        }
        phone.recheckTimer = PendingTimer(id: id, fireAt: earliest, work: work)
    }

    private func armDebounce(_ phone: Phone) {
        guard phone.debounceTimer == nil, phone.retryTimer == nil, phone.flight == nil, !awaitsUnregister(phone), needsReport(phone) else { return }
        let id = takeTimerID()
        let work = scheduler.schedule(after: Self.debounceDelay) { [weak self, weak phone] in
            guard let self, let phone else { return }
            self.debounceFired(phone, timerID: id)
        }
        phone.debounceTimer = PendingTimer(id: id, fireAt: scheduler.now.addingTimeInterval(Self.debounceDelay), work: work)
    }

    private func awaitsUnregister(_ phone: Phone) -> Bool { pendingUnregisters[phone.installationID] != nil }

    /// Whether the relay's picture of this daemon differs from the latest counts and the daemon has not
    /// already given up on them.
    private func needsReport(_ phone: Phone) -> Bool {
        guard let counts = phone.latest?.counts else { return false }
        return counts != phone.lastSent && counts != phone.abandoned
    }

    /// Sends the latest state now unless a call is in flight or a retry is pending (either of which sends the
    /// latest state when it settles).
    private func flush(_ phone: Phone, effects: inout [Effect]) {
        guard !phone.isRetired, phone.flight == nil, phone.retryTimer == nil, !awaitsUnregister(phone), let latest = phone.latest else { return }
        cancel(&phone.debounceTimer)
        // Queued keys can wait behind an in-flight call or a backoff, so both the alert and the toggle for its kind
        // are checked now, not when the key was queued.
        let confirmed = phone.notifyKeys.filter { key in
            guard let kind = latest.kindsByKey[key] else { return false }
            return SpacesDevicePushAlertEvaluation.buzzes(kind, for: phone.registration)
        }
        phone.notifyKeys = []
        guard !confirmed.isEmpty || needsReport(phone) else { return }
        let capability = phone.registration.capability
        phone.flight = Flight(capability: capability, counts: latest.counts, notifyKeys: confirmed)
        effects.append(.send(phone, .report(capability: capability, deviceID: relayDeviceID, counts: latest.counts, notify: !confirmed.isEmpty)))
    }

    private func retire(_ phone: Phone) {
        phone.isRetired = true
        cancel(&phone.recheckTimer)
        cancel(&phone.debounceTimer)
        cancel(&phone.retryTimer)
    }

    private func cancel(_ timer: inout PendingTimer?) {
        timer?.work.cancel()
        timer = nil
    }

    private func takeTimerID() -> Int {
        nextTimerID += 1
        return nextTimerID
    }

    // MARK: - Timer and relay callbacks

    private func recheckFired(_ phone: Phone, timerID: Int) {
        var effects: [Effect] = []
        lock.lock()
        if isRunning, !phone.isRetired, phone.recheckTimer?.id == timerID {
            phone.recheckTimer = nil
            let now = scheduler.now
            let due = phone.recheckQueue.filter { $0.value.due <= now }
            for key in due.keys { phone.recheckQueue.removeValue(forKey: key) }
            // A toggle turned off during the wait also cancels the buzz.
            let confirmed = due.filter {
                phone.latest?.kindsByKey[$0.key] != nil && SpacesDevicePushAlertEvaluation.buzzes($0.value.kind, for: phone.registration)
            }
            phone.notifyKeys.formUnion(confirmed.keys)
            armRecheck(phone)
            if !phone.notifyKeys.isEmpty { flush(phone, effects: &effects) }
        }
        lock.unlock()
        perform(effects)
    }

    private func debounceFired(_ phone: Phone, timerID: Int) {
        var effects: [Effect] = []
        lock.lock()
        if isRunning, !phone.isRetired, phone.debounceTimer?.id == timerID {
            phone.debounceTimer = nil
            flush(phone, effects: &effects)
        }
        lock.unlock()
        perform(effects)
    }

    private func retryFired(_ phone: Phone, timerID: Int) {
        var effects: [Effect] = []
        lock.lock()
        if isRunning, !phone.isRetired, phone.retryTimer?.id == timerID {
            phone.retryTimer = nil
            flush(phone, effects: &effects)
        }
        lock.unlock()
        perform(effects)
    }

    private func reportCompleted(_ phone: Phone, outcome: SpacesDevicePushRelayOutcome) {
        var effects: [Effect] = []
        lock.lock()
        let flight = phone.flight
        phone.flight = nil
        if let capability = phone.unregisterCapability {
            phone.unregisterCapability = nil
            effects.append(.sendUnregister(.unregister(capability: capability, deviceID: relayDeviceID), installationID: phone.installationID))
        } else if isRunning, !phone.isRetired, let flight {
            settle(phone, flight: flight, outcome: outcome, effects: &effects)
        }
        lock.unlock()
        perform(effects)
    }

    private func settle(_ phone: Phone, flight: Flight, outcome: SpacesDevicePushRelayOutcome, effects: inout [Effect]) {
        // The phone re-registered under a new capability while this call was out: its answer says nothing
        // about the new registration.
        guard flight.capability == phone.registration.capability else {
            flush(phone, effects: &effects)
            return
        }
        switch outcome {
        case .delivered:
            phone.lastSent = flight.counts
            phone.abandoned = nil
            phone.attempt = 0
            if !phone.notifyKeys.isEmpty { flush(phone, effects: &effects) } else { armDebounce(phone) }
        case .registrationDead:
            retire(phone)
            if phones[phone.installationID] === phone { phones.removeValue(forKey: phone.installationID) }
            effects.append(.clearRegistration(installationID: phone.installationID, capability: flight.capability))
        case .transientFailure:
            // A 5xx can follow a relay write: it may already hold these counts. What it holds is unknown, so the
            // next flush must send the latest counts even if they equal the last accepted ones.
            phone.lastSent = nil
            if phone.attempt < Self.retryDelays.count {
                phone.notifyKeys.formUnion(flight.notifyKeys)
                let delay = Self.retryDelays[phone.attempt]
                phone.attempt += 1
                let id = takeTimerID()
                let work = scheduler.schedule(after: delay) { [weak self, weak phone] in
                    guard let self, let phone else { return }
                    self.retryFired(phone, timerID: id)
                }
                phone.retryTimer = PendingTimer(id: id, fireAt: scheduler.now.addingTimeInterval(delay), work: work)
            } else {
                giveUp(phone, on: flight)
            }
        case .rejected: giveUp(phone, on: flight)
        }
    }

    /// Stops retrying the counts `flight` carried. Counts that changed while it was out were never sent, so
    /// they still report; a later change of counts, or a new buzz, sends again.
    private func giveUp(_ phone: Phone, on flight: Flight) {
        phone.attempt = 0
        phone.abandoned = flight.counts
        phone.notifyKeys = []
        armDebounce(phone)
    }

    private func unregisterSettled(_ installationID: String) {
        var effects: [Effect] = []
        lock.lock()
        let remaining = (pendingUnregisters[installationID] ?? 1) - 1
        if remaining > 0 { pendingUnregisters[installationID] = remaining } else { pendingUnregisters.removeValue(forKey: installationID) }
        if remaining <= 0, isRunning, let phone = phones[installationID] {
            if !phone.notifyKeys.isEmpty { flush(phone, effects: &effects) } else { armDebounce(phone) }
        }
        lock.unlock()
        perform(effects)
    }

    private func perform(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case .send(let phone, let request): relay.send(request) { [weak self] outcome in self?.reportCompleted(phone, outcome: outcome) }
            case .sendUnregister(let request, let installationID):
                // Best effort: success or failure, the lane moves on, so a replacement registration is never stuck.
                relay.send(request) { [weak self] _ in self?.unregisterSettled(installationID) }
            case .clearRegistration(let installationID, let capability): clearRegistration(installationID, capability)
            }
        }
    }
}
