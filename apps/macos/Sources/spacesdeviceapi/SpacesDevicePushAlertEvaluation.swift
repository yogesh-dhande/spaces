import Foundation
import spacesdevicecore

/// A device overview reduced to what push notifications read: the visible alert candidates by key, and the
/// counts the relay is told. Both come from `visibleAlertCandidates()`, the one definition of what a phone's
/// Alerts tab lists.
struct SpacesDevicePushAlertSnapshot: Equatable, Sendable {
    let counts: SpacesDeviceAlertCounts
    let kindsByKey: [String: SpacesDeviceAlertKind]
    /// Every candidate key, hidden and dismissed included. The seen set follows this rather than the visible
    /// keys, so an alert that becomes visible again (a hidden workspace shown) is not mistaken for a new one.
    let candidateKeys: Set<String>

    init(overview: SpacesDeviceOverviewPayload) {
        counts = overview.visibleAlertCounts()
        kindsByKey = Dictionary(overview.visibleAlertCandidates().map { ($0.key, $0.kind) }, uniquingKeysWith: { first, _ in first })
        candidateKeys = Set(overview.alertCandidates().map(\.key))
    }
}

/// What a new overview means for one phone's notifications.
struct SpacesDevicePushAlertEvaluation: Equatable, Sendable {
    /// The keys that appeared since `seenKeys`, are of a kind the phone's toggles allow to buzz, and so start
    /// the recheck wait.
    let recheckKeys: [String: SpacesDeviceAlertKind]
    let counts: SpacesDeviceAlertCounts
    /// Every candidate key now, visible or not. Replaces the seen set, so only a key that was never a
    /// candidate in the previous overview can buzz.
    let seenKeys: Set<String>

    /// `seenKeys` is nil before this phone has seen any overview: the first one only seeds the set, so a
    /// daemon restart (or a phone that just registered) never buzzes for alerts that already existed.
    static func evaluate(seenKeys: Set<String>?, snapshot: SpacesDevicePushAlertSnapshot, registration: SpacesDevicePushRegistration) -> Self {
        let current = snapshot.candidateKeys
        guard let seenKeys else { return Self(recheckKeys: [:], counts: snapshot.counts, seenKeys: current) }
        let fresh = snapshot.kindsByKey.filter { key, kind in !seenKeys.contains(key) && buzzes(kind, for: registration) }
        return Self(recheckKeys: fresh, counts: snapshot.counts, seenKeys: current)
    }

    /// Only a blocked or a finished agent can buzz, each behind its own toggle; every other kind moves the
    /// badge and stays silent.
    static func buzzes(_ kind: SpacesDeviceAlertKind, for registration: SpacesDevicePushRegistration) -> Bool {
        switch kind {
        case .agentWaiting: registration.notifyBlocked
        case .agentDone: registration.notifyFinished
        case .processExited, .terminalExited, .terminalFailed, .bell, .automationRunFailed, .automationRunTimedOut, .comeBackLater: false
        }
    }
}
