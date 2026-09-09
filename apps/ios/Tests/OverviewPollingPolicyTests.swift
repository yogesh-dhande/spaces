#if canImport(UIKit)
    import SwiftUI
    import XCTest
    @testable import SpacesMobile

    /// Pins the two cadences `OverviewPollingModifier` polls at (see issue #673), the three gates
    /// that stop polling outright (an inactive scene, an unselected tab, an unpaired device), and the
    /// route distinction that separates a slowed poller from a stopped one. A `.detail` route (a
    /// terminal or browser session, which has no poller of its own) slows polling instead of stopping
    /// it; a `.nestedList` route (a pushed screen that installs its own `overviewPolling`, such as an
    /// automation's detail or the recent-runs list) stops this poller outright so exactly one runs.
    final class OverviewPollingPolicyTests: XCTestCase {
        func testListIntervalIsTwoSeconds() { XCTAssertEqual(OverviewPollingPolicy.listInterval, .seconds(2)) }

        func testDetailIntervalIsThirtySeconds() { XCTAssertEqual(OverviewPollingPolicy.detailInterval, .seconds(30)) }

        func testIntervalUsesListCadenceWithNoRoute() {
            XCTAssertEqual(OverviewPollingPolicy.interval(route: nil, refreshFailing: false), OverviewPollingPolicy.listInterval)
        }

        func testIntervalUsesDetailCadenceForDetailRoute() {
            XCTAssertEqual(OverviewPollingPolicy.interval(route: .detail("session-1"), refreshFailing: false), OverviewPollingPolicy.detailInterval)
        }

        func testFailingRefreshRetriesAtListCadenceBehindADetailRoute() {
            XCTAssertEqual(OverviewPollingPolicy.interval(route: .detail("session-1"), refreshFailing: true), OverviewPollingPolicy.listInterval)
            XCTAssertEqual(OverviewPollingPolicy.interval(route: nil, refreshFailing: true), OverviewPollingPolicy.listInterval)
        }

        func testPollsWhenActiveSelectedAndPairedWithNoRoute() {
            XCTAssertTrue(OverviewPollingPolicy.shouldPoll(scenePhase: .active, isSelectedTab: true, isPaired: true, route: nil))
        }

        func testStillPollsWhenDetailRouteIsActive() {
            XCTAssertTrue(OverviewPollingPolicy.shouldPoll(scenePhase: .active, isSelectedTab: true, isPaired: true, route: .detail("session-1")))
        }

        func testStopsWhenNestedListRouteIsActiveEvenIfActiveSelectedAndPaired() {
            XCTAssertFalse(
                OverviewPollingPolicy.shouldPoll(scenePhase: .active, isSelectedTab: true, isPaired: true, route: .nestedList("automation-1")))
        }

        func testStopsWhenSceneIsNotActive() {
            XCTAssertFalse(OverviewPollingPolicy.shouldPoll(scenePhase: .background, isSelectedTab: true, isPaired: true, route: nil))
            XCTAssertFalse(OverviewPollingPolicy.shouldPoll(scenePhase: .inactive, isSelectedTab: true, isPaired: true, route: nil))
        }

        func testStopsWhenTabIsNotSelected() {
            XCTAssertFalse(OverviewPollingPolicy.shouldPoll(scenePhase: .active, isSelectedTab: false, isPaired: true, route: nil))
        }

        func testStopsWhenDeviceIsNotPaired() {
            XCTAssertFalse(OverviewPollingPolicy.shouldPoll(scenePhase: .active, isSelectedTab: true, isPaired: false, route: nil))
        }
    }
#endif
