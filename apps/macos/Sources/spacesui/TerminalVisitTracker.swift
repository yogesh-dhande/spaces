import Foundation
import spacesdevicecore

/// Turns "the user is looking at this terminal" into visit reports for the device that owns it.
///
/// A visit is one terminal's pane being the focused pane of what the key window shows while Spaces is
/// frontmost. After `dwell` seconds of that, anything a visit clears on the device (finished-work
/// alerts, Come Back Later flags) is reported with how long the terminal has been focused, so the device
/// compares against its own clock. A report names exactly the keys whose own dwell completed. Leaving
/// the terminal (another pane, the pane no longer shown, Spaces resigning active) ends the visit and
/// cancels what was pending.
///
/// An alert that arrives while the terminal is watched is reported `dwell` seconds after it first
/// appeared, within the same visit, so `focusedForSeconds` keeps growing from the visit's start. A flag
/// set during the visit is never reported: the device clears flags only on a visit that started after
/// them, so the visit that set one must not clear it. The same holds for a flag that disappears and comes
/// back during the visit: it is a new mark, so the visit stops naming it.
@MainActor final class TerminalVisitTracker {
    /// Seconds a terminal must hold focus before its finished work counts as seen.
    nonisolated static let dwell: TimeInterval = 2

    struct FocusedTerminal: Hashable {
        let deviceID: String
        let sessionID: String
    }

    /// What a visit to a terminal would clear on its device right now.
    struct Clearables: Equatable {
        var alertKeys: Set<String> = []
        var flagKeys: Set<String> = []
    }

    typealias Cancel = @MainActor () -> Void

    private struct Visit {
        let terminal: FocusedTerminal
        let start: Date
        /// When each reportable key was first seen during this visit; keys present at its start are
        /// dated to the start.
        var firstSeen: [String: Date]
        /// Flags the visit may clear: those that existed when it began and have been present since.
        var flagKeysAtStart: Set<String>
        var reportedKeys: Set<String> = []
    }

    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Cancel
    private let clearables: (FocusedTerminal) -> Clearables
    /// The terminal the key window shows right now, nil when Spaces is not frontmost. Read when a
    /// report is due so a visit is never reported from a stale feed.
    private let currentFocus: () -> FocusedTerminal?
    /// Sends the report and answers whether the device took it. A report that was not taken (device
    /// offline, request failed) is retried by the next overview apply, never by a timer.
    private let sendVisit: (FocusedTerminal, TimeInterval, Set<String>) async -> Bool

    private var visit: Visit?
    private var cancelPending: Cancel?
    /// One request per session at a time: a report in flight already covers what a second would say.
    private var sessionsInFlight: Set<String> = []

    init(
        now: @escaping () -> Date, schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Cancel,
        clearables: @escaping (FocusedTerminal) -> Clearables, currentFocus: @escaping () -> FocusedTerminal?,
        sendVisit: @escaping (FocusedTerminal, TimeInterval, Set<String>) async -> Bool
    ) {
        self.now = now
        self.schedule = schedule
        self.clearables = clearables
        self.currentFocus = currentFocus
        self.sendVisit = sendVisit
    }

    /// What a visit to `sessionID` clears on a device, read from its overview: undismissed finished-work
    /// alerts for the session and flags on rows showing it.
    nonisolated static func clearables(overview: SpacesDeviceOverviewPayload, sessionID: String) -> Clearables {
        let dismissed = Set(overview.dismissedAlertKeys)
        var result = Clearables()
        for candidate in overview.alertCandidates() where candidate.sessionID == sessionID {
            if candidate.kind == .comeBackLater {
                result.flagKeys.insert(candidate.key)
            } else if candidate.clearsOnVisit, !dismissed.contains(candidate.key) {
                result.alertKeys.insert(candidate.key)
            }
        }
        return result
    }

    /// Reports the current focus. `focus` is the terminal the key window shows, `isActive` whether
    /// Spaces is frontmost; a visit exists only while both hold.
    func update(focus: FocusedTerminal?, isActive: Bool) {
        let effective = isActive ? focus : nil
        if effective != visit?.terminal {
            cancelPending?()
            cancelPending = nil
            visit = effective.map { terminal in
                let start = now()
                let initial = clearables(terminal)
                return Visit(
                    terminal: terminal, start: start,
                    firstSeen: Dictionary(uniqueKeysWithValues: initial.alertKeys.union(initial.flagKeys).map { ($0, start) }),
                    flagKeysAtStart: initial.flagKeys)
            }
        }
        reconcile()
    }

    /// Re-reads what the visit would clear after an overview changed, scheduling the next report.
    func reconcile() {
        guard var current = visit else { return }
        cancelPending?()
        cancelPending = nil
        let found = clearables(current.terminal)
        current.flagKeysAtStart.formIntersection(found.flagKeys)
        let reportable = found.alertKeys.union(found.flagKeys.intersection(current.flagKeysAtStart))
        current.firstSeen = current.firstSeen.filter { reportable.contains($0.key) }
        for key in reportable where current.firstSeen[key] == nil { current.firstSeen[key] = now() }
        current.reportedKeys.formIntersection(reportable)
        visit = current
        guard !sessionsInFlight.contains(current.terminal.sessionID),
            let earliest = reportable.subtracting(current.reportedKeys).compactMap({ current.firstSeen[$0] }).min()
        else { return }
        let delay = max(0, earliest.addingTimeInterval(Self.dwell).timeIntervalSince(now()))
        cancelPending = schedule(delay) { [weak self] in self?.report() }
    }

    private func report() {
        cancelPending = nil
        guard var current = visit, !sessionsInFlight.contains(current.terminal.sessionID) else { return }
        let focusedNow = currentFocus()
        guard focusedNow == current.terminal else {
            update(focus: focusedNow, isActive: focusedNow != nil)
            return
        }
        let found = clearables(current.terminal)
        current.flagKeysAtStart.formIntersection(found.flagKeys)
        visit = current
        let due = found.alertKeys.union(found.flagKeys.intersection(current.flagKeysAtStart)).subtracting(current.reportedKeys).filter {
            (current.firstSeen[$0] ?? now()).addingTimeInterval(Self.dwell) <= now()
        }
        guard !due.isEmpty else {
            reconcile()
            return
        }
        let terminal = current.terminal
        let start = current.start
        let focusedFor = now().timeIntervalSince(start)
        sessionsInFlight.insert(terminal.sessionID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let taken = await sendVisit(terminal, focusedFor, due)
            sessionsInFlight.remove(terminal.sessionID)
            // The visit may have ended or restarted while the request was out; the keys belong to the one
            // that sent them. A different visit that began meanwhile could not schedule while the slot was
            // held, so it is reconciled now. The same visit retries a report the device did not take only
            // on the next overview, never on a timer.
            if visit?.terminal == terminal, visit?.start == start {
                guard taken else { return }
                visit?.reportedKeys.formUnion(due)
            }
            reconcile()
        }
    }
}
