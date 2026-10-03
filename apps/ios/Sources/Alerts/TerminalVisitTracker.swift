import Foundation
import spacesdevicecore

/// What the visit tracker needs from the app model, kept behind a protocol so the tracker's timing
/// rules are testable without a model or a device.
@MainActor
protocol SpacesMobileTerminalVisitHost: AnyObject {
    /// Alert keys a visit to `sessionID` would clear on its device right now: undismissed alerts that
    /// clear on a visit, plus Come Back Later flags on rows showing the session. Empty when nothing can
    /// be sent (the device is offline, or Demo Mode), so a visit is never marked reported when it was not
    /// sent.
    func visitClearableKeys(forSessionID sessionID: String) -> Set<String>
    /// `keys` are the alerts and flags whose own dwell completed; the device acts on no other.
    func sendVisit(sessionID: String, focusedForSeconds: Double, keys: Set<String>) async
}

/// Decides when the open terminal viewer has been looked at long enough to tell its device about the
/// visit (see "Visiting a terminal" in `docs/spec.md`), so the device can clear what a visit clears.
///
/// A visit runs while the viewer is open, the app is in the foreground, and the terminal's content has
/// shown. Leaving (closing, switching sessions, backgrounding) ends it and cancels anything pending;
/// returning to the foreground starts a new one. The device never sees client clocks: it is told how
/// long the visit has lasted and derives the start itself.
@MainActor
final class SpacesMobileTerminalVisitTracker {
    /// How long a terminal must be looked at, or an alert must have been on it, before the visit is sent.
    static let dwell: TimeInterval = 2

    /// Runs `action` after `delay` seconds; the returned closure cancels it.
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    static let sleepingSchedule: Schedule = { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    private struct Visit {
        let start: Date
        /// Keys already sent to the device, or flags set during this visit, which the device will not
        /// clear. Neither is sent (again) for the rest of the visit, so a flag the device keeps cannot
        /// make every response trigger another request.
        var accountedKeys: Set<String> = []
        /// Keys still to send, with when each first appeared.
        var appearedAt: [String: Date] = [:]
    }

    private let now: () -> Date
    private let schedule: Schedule
    private weak var host: SpacesMobileTerminalVisitHost?
    private var sessionID: String?
    private var isForeground = true
    private var contentShown = false
    private var visit: Visit?
    private var cancelTimer: (() -> Void)?
    /// One request at a time, across visits: leaving and returning while a request is out waits for it.
    private var isRequestInFlight = false
    /// Distinguishes the visit a request belongs to, so a response arriving after the user left does not
    /// mark the next visit's keys as sent.
    private var visitGeneration = 0

    init(now: @escaping () -> Date, schedule: @escaping Schedule = SpacesMobileTerminalVisitTracker.sleepingSchedule) {
        self.now = now
        self.schedule = schedule
    }

    var hasActiveVisit: Bool { visit != nil }

    func openSession(_ sessionID: String, host: SpacesMobileTerminalVisitHost) {
        closeSession()
        self.sessionID = sessionID
        self.host = host
        contentShown = false
    }

    func closeSession() {
        endVisit()
        sessionID = nil
        contentShown = false
    }

    func setForeground(_ isForeground: Bool) {
        guard isForeground != self.isForeground else { return }
        self.isForeground = isForeground
        if isForeground { startVisitIfReady() } else { endVisit() }
    }

    /// The open session's content has been painted. Stays true for the rest of the open: the surface is
    /// not re-created when the app returns to the foreground.
    func contentDidShow(sessionID: String) {
        guard sessionID == self.sessionID else { return }
        contentShown = true
        startVisitIfReady()
    }

    /// The device delivered an overview; an alert that arrived on the watched terminal starts its own
    /// dwell.
    func overviewChanged() {
        guard visit != nil else { return }
        evaluate(isVisitStart: false)
    }

    private func startVisitIfReady() {
        guard sessionID != nil, isForeground, contentShown, visit == nil else { return }
        visit = Visit(start: now())
        evaluate(isVisitStart: true)
    }

    private func endVisit() {
        cancelTimer?()
        cancelTimer = nil
        visit = nil
        visitGeneration += 1
    }

    private func evaluate(isVisitStart: Bool) {
        guard var current = visit, let sessionID, let host else { return }
        cancelTimer?()
        cancelTimer = nil
        let pending = host.visitClearableKeys(forSessionID: sessionID)
        for key in pending where !current.accountedKeys.contains(key) && current.appearedAt[key] == nil {
            // A flag first seen mid-visit was set during it, and the device keeps flags set after the visit
            // began; only flags present at the start are worth reporting.
            if !isVisitStart && key.hasPrefix(SpacesDeviceComeBackLaterFlag.alertKeyPrefix) {
                current.accountedKeys.insert(key)
            } else {
                current.appearedAt[key] = now()
            }
        }
        current.appearedAt = current.appearedAt.filter { pending.contains($0.key) }
        current.accountedKeys.formIntersection(pending)
        visit = current

        guard let earliest = current.appearedAt.values.min() else { return }
        let wait = earliest.addingTimeInterval(Self.dwell).timeIntervalSince(now())
        guard wait <= 0 else {
            cancelTimer = schedule(wait) { [weak self] in self?.evaluate(isVisitStart: false) }
            return
        }
        guard !isRequestInFlight else { return }
        isRequestInFlight = true
        // Only keys whose own dwell elapsed: one that appeared later waits for its own report, which also
        // keeps a request's latency from clearing a mark that appeared during it.
        let keys = Set(current.appearedAt.filter { $0.value.addingTimeInterval(Self.dwell) <= now() }.keys)
        let focusedForSeconds = now().timeIntervalSince(current.start)
        let generation = visitGeneration
        Task { @MainActor [weak self, weak host] in
            await host?.sendVisit(sessionID: sessionID, focusedForSeconds: focusedForSeconds, keys: keys)
            self?.requestFinished(keys: keys, generation: generation)
        }
    }

    /// A failed request is not retried within the visit: the next visit reports again.
    private func requestFinished(keys: Set<String>, generation: Int) {
        isRequestInFlight = false
        if generation == visitGeneration, var current = visit {
            current.accountedKeys.formUnion(keys)
            for key in keys { current.appearedAt.removeValue(forKey: key) }
            visit = current
        }
        // Also for a later visit that was waiting on this request.
        if visit != nil { evaluate(isVisitStart: false) }
    }
}
