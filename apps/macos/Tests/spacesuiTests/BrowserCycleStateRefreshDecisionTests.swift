import Foundation
import Testing

@testable import spacesui

/// Covers `BrowserCycleStateRefreshDecision.decide`, the pure guard `WindowFocusController.refreshCycleModeBrowserState()`
/// uses to skip, start, or queue a Chrome/browser-tracking round trip. Workspace ids are opaque here;
/// only set equality drives the decision.
@Suite struct BrowserCycleStateRefreshDecisionTests {
    private static let maxAge: TimeInterval = 2

    @Test func sameWorkspaceSetWithinAgeSkips() {
        let decision = BrowserCycleStateRefreshDecision.decide(
            inFlight: false, inFlightWorkspaceIDs: [], cachedWorkspaceIDs: ["w1"], cachedAge: 0.5, currentWorkspaceIDs: ["w1"], maxAge: Self.maxAge)
        #expect(decision == .skip)
    }

    @Test func changedWorkspaceSetWithinAgeRefreshesAnyway() {
        // A changed set answers a different question than the cache holds, so the age guard is
        // bypassed even though the cache is nowhere near stale: this is what lets the first populated
        // sidebar apply after launch refresh even though the launch-time shortcut reload just stamped
        // an empty snapshot.
        let decision = BrowserCycleStateRefreshDecision.decide(
            inFlight: false, inFlightWorkspaceIDs: [], cachedWorkspaceIDs: [], cachedAge: 0.1, currentWorkspaceIDs: ["w1"], maxAge: Self.maxAge)
        #expect(decision == .refresh)
    }

    @Test func agedCacheWithSameSetStillRefreshes() {
        let decision = BrowserCycleStateRefreshDecision.decide(
            inFlight: false, inFlightWorkspaceIDs: [], cachedWorkspaceIDs: ["w1"], cachedAge: 5, currentWorkspaceIDs: ["w1"], maxAge: Self.maxAge)
        #expect(decision == .refresh)
    }

    @Test func inFlightWithSameSetSkipsRatherThanQueuing() {
        let decision = BrowserCycleStateRefreshDecision.decide(
            inFlight: true, inFlightWorkspaceIDs: ["w1"], cachedWorkspaceIDs: [], cachedAge: 100, currentWorkspaceIDs: ["w1"], maxAge: Self.maxAge)
        #expect(decision == .skip)
    }

    @Test func inFlightWithChangedSetMarksPending() {
        let decision = BrowserCycleStateRefreshDecision.decide(
            inFlight: true, inFlightWorkspaceIDs: ["w1"], cachedWorkspaceIDs: [], cachedAge: 100, currentWorkspaceIDs: ["w1", "w2"],
            maxAge: Self.maxAge)
        #expect(decision == .markPending)
    }

    @Test func inFlightIgnoresCacheEntirely() {
        // Cache age and cache set are irrelevant while a round trip is running: only the in-flight
        // capture decides.
        let decision = BrowserCycleStateRefreshDecision.decide(
            inFlight: true, inFlightWorkspaceIDs: [], cachedWorkspaceIDs: [], cachedAge: 0, currentWorkspaceIDs: [], maxAge: Self.maxAge)
        #expect(decision == .skip)
    }
}
