import SwiftUI

/// What sits on top of the list that owns an `OverviewPollingModifier`.
enum OverviewPollingRoute: Equatable {
    /// A terminal or browser detail: it has no poller of its own, so the list keeps polling at the slow
    /// cadence to keep the detail's runtime-row menu roughly current.
    case detail(String)
    /// A pushed screen that installs its own `overviewPolling` (an automation's detail, the recent-runs
    /// list): the list stops so exactly one poller runs.
    case nestedList(String)
}

/// The overview refresh feeds two consumers: the list rows on each tab, and the runtime-row toolbar
/// menu on a terminal detail screen (`TerminalDetailView`'s `trailingChrome`). The list needs to
/// feel live, so it polls every two seconds. The detail screen's menu only needs to stay roughly
/// current, and every refresh pulls the whole overview payload (tens of KB, 12 to 17 KB/s at the
/// list cadence per issue #673), so a detail screen polls fifteen times slower. The detail screen
/// has no poller of its own; this policy is the single source of the cadence.
///
/// A pushed screen that is itself a live list (an automation's detail, the recent-runs list) installs
/// its own `overviewPolling` modifier, so the list underneath it must stop rather than also polling:
/// otherwise two pollers would run for the same overview at once. `OverviewPollingRoute` distinguishes
/// these two cases for the modifier above the pushed screen.
enum OverviewPollingPolicy {
    static let listInterval: Duration = .seconds(2)
    static let detailInterval: Duration = .seconds(30)

    static func shouldPoll(scenePhase: ScenePhase, isSelectedTab: Bool, isPaired: Bool, route: OverviewPollingRoute?) -> Bool {
        if case .nestedList = route { return false }
        return scenePhase == .active && isSelectedTab && isPaired
    }

    /// A failing refresh always retries at the list cadence, whatever the route: the connection-error
    /// alert is gated on refreshes having failed for about five seconds, and a thirty-second sleep after
    /// the first failure would push that report to the next slow poll.
    static func interval(route: OverviewPollingRoute?, refreshFailing: Bool) -> Duration {
        if refreshFailing { return listInterval }
        switch route {
        case .detail: return detailInterval
        case .nestedList, nil: return listInterval
        }
    }
}
