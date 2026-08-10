/// Where in a session's frame order a client's armed resync retry must be answered.
///
/// A client that could not apply a render update asks the daemon for a full frame and arms one delayed
/// retry behind the request, because the read it just sent may answer with no render update at all (see
/// the trailing-resync machinery in `RemoteGhosttySessionHost` and the iOS `TerminalViewerModel`).
/// Retiring that retry the moment ANY frame lands is not sound: a `.state` read issued *before* the
/// failure was owed can answer with a frame the daemon captured before it, and that frame still applies
/// — it is newer than the baseline the failure broke — so it would cancel a retry armed for a gap it
/// does not cover. The client is then parked on the older revision while the session sits at a newer
/// one, and a session that goes quiet leaves the pane stale until some unrelated later event.
///
/// So an arming failure records what would prove the owed read was answered, and only a frame meeting
/// that closes it. A read issued *after* the failure always does, since the daemon's capture then
/// postdates the export that failed. The ordering is the reducer's own
/// (`TerminalRemoteStateReducer.retainedFrameOrdering`): owner epoch dominates, because epochs only
/// advance and a newer one is a session generation past the failure, then session revision, which the
/// daemon advances monotonically per session.
public enum TerminalResyncOwedOrdering: Sendable, Equatable {
    /// Owed for a gap with no ordering of its own — an attach that found no frame at all rather than a
    /// specific update that failed. Any frame closes it.
    case anyFrame
    /// Owed for a render update that failed to apply, whose target is known. Only a frame at or past
    /// that target closes it.
    case throughFrame(ownerEpoch: UInt64, sessionRevision: UInt64)
    /// Owed for a failure whose target could not be read: the update's bytes never decoded, or it
    /// carried no target revision. Nothing about a landing frame can prove it covers such a failure, so
    /// only the retry itself closes it — one read is the correct price for not knowing.
    case unknown

    /// The ordering owed by a render update that failed to apply. A nil update is the decode failure:
    /// the bytes never became an update, so the failure names no target.
    public static func forFailedUpdate(_ update: GhosttyRenderUpdate?) -> Self {
        guard let update, let targetRevision = update.targetRevision else { return .unknown }
        return .throughFrame(ownerEpoch: update.ownerEpoch, sessionRevision: targetRevision)
    }

    /// Whether a frame that just landed proves the owed read was answered.
    ///
    /// A frame carrying no session revision cannot be ordered against a known target, so it proves
    /// nothing and leaves the retry armed.
    public func isSatisfied(byFrameOwnerEpoch ownerEpoch: UInt64, sessionRevision: UInt64?) -> Bool {
        switch self {
        case .anyFrame: return true
        case .unknown: return false
        case .throughFrame(let owedEpoch, let owedRevision):
            if ownerEpoch != owedEpoch { return ownerEpoch > owedEpoch }
            guard let sessionRevision else { return false }
            return sessionRevision >= owedRevision
        }
    }

    /// The stricter of two owed orderings, for the retry a second failure re-arms while the first is
    /// still pending: one read has to answer both, so it must answer the later one. `unknown` dominates
    /// everything, since no frame retires it.
    public func merged(with other: Self) -> Self {
        switch (self, other) {
        case (.unknown, _), (_, .unknown): return .unknown
        case (.anyFrame, _): return other
        case (_, .anyFrame): return self
        case (.throughFrame(let epoch, let revision), .throughFrame(let otherEpoch, let otherRevision)):
            if epoch != otherEpoch { return epoch > otherEpoch ? self : other }
            return revision >= otherRevision ? self : other
        }
    }
}
