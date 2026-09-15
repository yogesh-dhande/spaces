import Foundation

/// Pure guard logic for `WindowFocusController.refreshCycleModeBrowserState()`: given what the cached
/// Chrome/browser-tracking snapshot and any in-flight round trip cover, decides whether a new request
/// should be dropped, should mark the in-flight round trip for a rerun, or should start a refresh of
/// its own. Kept side-effect free and in its own file so the decision can be unit tested without the
/// AppKit and Chrome-scripting machinery around it.
///
/// Every case is keyed on the *workspace set* a snapshot covers, not just its age: the sidebar can
/// apply the same live workspace several times a second, in which case an unaged, same-set cache
/// should keep answering every one of those applies without a fresh Chrome round trip, but the moment
/// the set changes (a different workspace selected, a device's overview arriving for the first time)
/// the cache no longer answers the question being asked, and a fresh round trip is due immediately
/// regardless of how young the stale-set cache still is. That is what lets the first populated sidebar
/// apply after launch refresh even though the launch-time shortcut reload just stamped an empty
/// snapshot: the set went from empty to populated, so the age guard is bypassed for it.
enum BrowserCycleStateRefreshDecision: Equatable {
    /// The cache already covers the current workspace set within the max age (no refresh in flight),
    /// or a refresh already in flight is covering the current set: nothing to do.
    case skip
    /// No refresh is in flight and the cache does not answer the current request: start one.
    case refresh
    /// A refresh is already in flight and it does not cover the current workspace set: ask it to rerun
    /// once it completes instead of starting a second, overlapping round trip.
    case markPending

    /// - Parameters:
    ///   - inFlight: whether a refresh round trip is currently running.
    ///   - inFlightWorkspaceIDs: the workspace set the in-flight round trip captured at its own start.
    ///     Ignored when `inFlight` is `false`.
    ///   - cachedWorkspaceIDs: the workspace set the last completed refresh cached its result for.
    ///   - cachedAge: how long ago the cached result was taken.
    ///   - currentWorkspaceIDs: the workspace set this request is asking about.
    ///   - maxAge: how stale a same-set cache may get before a request still refreshes.
    static func decide(
        inFlight: Bool, inFlightWorkspaceIDs: Set<String>, cachedWorkspaceIDs: Set<String>, cachedAge: TimeInterval, currentWorkspaceIDs: Set<String>,
        maxAge: TimeInterval
    ) -> BrowserCycleStateRefreshDecision {
        if inFlight { return currentWorkspaceIDs == inFlightWorkspaceIDs ? .skip : .markPending }
        return cachedAge < maxAge && cachedWorkspaceIDs == currentWorkspaceIDs ? .skip : .refresh
    }
}
