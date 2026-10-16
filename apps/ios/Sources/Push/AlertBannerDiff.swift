import Foundation

/// Decides which new alert, if any, raises the in-app banner. Pure state over successive attention-event
/// lists, so the rules are testable without a stream.
///
/// Each device is diffed on its own, only when that device itself delivered a fresh overview. A device's
/// first fresh overview after its stream (re)opens only seeds the seen set: launching or reconnecting
/// must never banner alerts that already existed, which the system notification already covered. A
/// device's cached overview is not a delivery, so it never seeds: it would mark the device seeded before
/// its fresh overview arrives, and an alert raised while the app was away would then banner. After
/// that, an event shows a banner only when it is new, of a kind whose toggle is on, and not on the terminal
/// the user is looking at. Every event is recorded as seen whether or not it banners, so turning a toggle on
/// later does not surface old alerts.
struct AlertBannerDiff {
    private var seenEventIDs: Set<String> = []
    private var seededDeviceIDs: Set<String> = []

    /// - Parameters:
    ///   - deviceID: the device that just delivered a fresh overview. A device with no events still seeds,
    ///     so an alert that is its first counts as new.
    ///   - events: that device's listed (visible) attention events, the only ones eligible to banner.
    ///   - candidateIDs: the ids of every alert the device holds, hidden workspaces and dismissed alerts
    ///     included. All of them are recorded as seen, so an alert that existed while its workspace was
    ///     hidden does not read as new when the workspace is shown again (the daemon's push rule is the
    ///     same). It must contain every id in `events`.
    ///   - watchedSessionID: the terminal on screen; alerts about it never banner.
    /// - Returns: the newest qualifying event, since a newer event replaces the one shown.
    mutating func nextBanner(
        deviceID: String, events: [SpacesMobileAttentionEvent], candidateIDs: Set<String>, notifyBlocked: Bool, notifyFinished: Bool,
        watchedSessionID: String?
    ) -> SpacesMobileAttentionEvent? {
        let isSeeding = seededDeviceIDs.insert(deviceID).inserted
        var banner: SpacesMobileAttentionEvent?
        defer { seenEventIDs.formUnion(candidateIDs) }
        for event in events where !seenEventIDs.contains(event.id) {
            guard !isSeeding else { continue }
            guard Self.isEnabled(event.kind, notifyBlocked: notifyBlocked, notifyFinished: notifyFinished) else { continue }
            if let watchedSessionID, event.sessionID == watchedSessionID { continue }
            if banner == nil || event.date > banner!.date { banner = event }
        }
        return banner
    }

    /// Re-seeds `deviceID` on its next overview, for a device that went offline.
    mutating func forget(deviceID: String) { seededDeviceIDs.remove(deviceID) }

    /// Re-seeds every device on its next overview, for streams that closed with the app backgrounded.
    mutating func forgetAll() { seededDeviceIDs.removeAll() }

    private static func isEnabled(_ kind: SpacesMobileAttentionEvent.Kind, notifyBlocked: Bool, notifyFinished: Bool) -> Bool {
        switch kind {
        case .waitingForInput: notifyBlocked
        case .finished: notifyFinished
        case .exited, .failed, .bell, .comeBackLater: false
        }
    }
}

extension SpacesMobileAttentionEvent {
    /// "<agent> needs input" or "<agent> finished": the banner's headline. Only those two kinds banner.
    var bannerTitle: String { kind == .finished ? "\(title) finished" : "\(title) needs input" }
}
