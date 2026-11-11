#if canImport(UIKit)
    import XCTest
    @testable import SpacesMobile

    final class AlertBannerDiffTests: XCTestCase {
        private func event(
            _ key: String, kind: SpacesMobileAttentionEvent.Kind = .waitingForInput, device: String = "device-a", session: String? = nil,
            at seconds: TimeInterval = 0
        ) -> SpacesMobileAttentionEvent {
            SpacesMobileAttentionEvent(
                key: key, sourceID: "agent:\(key)", kind: kind, date: Date(timeIntervalSince1970: seconds), title: "claude", rowType: .codingAgents,
                sessionID: session ?? "session-\(key)", workspaceID: "workspace", deviceID: device, projectName: "n6-basecode",
                workspaceDisplayName: "main", deviceText: "MacBook Pro", isDeviceOffline: false)
        }

        private func next(
            _ diff: inout AlertBannerDiff, _ events: [SpacesMobileAttentionEvent], device: String = "device-a", blocked: Bool = true,
            finished: Bool = false, watching: String? = nil, hiddenIDs: Set<String> = []
        ) -> SpacesMobileAttentionEvent? {
            let deviceEvents = events.filter { $0.deviceID == device }
            return diff.nextBanner(
                deviceID: device, events: deviceEvents, candidateIDs: Set(deviceEvents.map(\.id)).union(hiddenIDs), notifyBlocked: blocked,
                notifyFinished: finished, watchedSessionID: watching)
        }

        func testAnAlertHeldHiddenWhileSeedingNeverBannersWhenItBecomesVisible() {
            var diff = AlertBannerDiff()
            let hidden = event("hid", at: 5)
            XCTAssertNil(next(&diff, [], hiddenIDs: [hidden.id]))

            XCTAssertNil(next(&diff, [hidden]), "shown again, it is not new")
            XCTAssertEqual(next(&diff, [hidden, event("new", at: 10)])?.key, "new")
        }

        func testTheFirstOverviewOnlySeedsSoExistingAlertsNeverBanner() {
            var diff = AlertBannerDiff()
            XCTAssertNil(next(&diff, [event("old")]))
            XCTAssertNil(next(&diff, [event("old")]), "and they stay quiet afterwards")
        }

        func testANewWaitingEventBanners() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [event("old")])

            let banner = next(&diff, [event("old"), event("new", at: 10)])

            XCTAssertEqual(banner?.key, "new")
            XCTAssertEqual(banner?.bannerTitle, "claude needs input")
            XCTAssertEqual(banner?.detail, "n6-basecode / main · MacBook Pro")
        }

        func testADeviceWithNoAlertsStillCountsItsFirstAlertAsNew() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [])

            XCTAssertEqual(next(&diff, [event("first")])?.key, "first")
        }

        func testATurnedOffKindDoesNotBannerAndNeverSurfacesLater() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [])

            XCTAssertNil(next(&diff, [event("w")], blocked: false))
            XCTAssertNil(next(&diff, [event("w")], blocked: true), "turning the toggle on does not resurrect an alert that already passed")
        }

        func testAFinishedEventBannersOnlyWhenItsToggleIsOn() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [])

            XCTAssertNil(next(&diff, [event("f1", kind: .finished)], finished: false))
            let banner = next(&diff, [event("f1", kind: .finished), event("f2", kind: .finished)], finished: true)

            XCTAssertEqual(banner?.key, "f2")
            XCTAssertEqual(banner?.bannerTitle, "claude finished")
        }

        func testOtherKindsNeverBanner() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [])

            let events = [
                event("exit", kind: .exited), event("fail", kind: .failed), event("bell", kind: .bell), event("later", kind: .comeBackLater),
            ]

            XCTAssertNil(next(&diff, events, blocked: true, finished: true))
        }

        func testTheTerminalBeingWatchedIsSkipped() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [])

            XCTAssertNil(next(&diff, [event("w", session: "session-open")], watching: "session-open"))
            XCTAssertEqual(
                next(&diff, [event("w", session: "session-open"), event("x", session: "session-other")], watching: "session-open")?.key, "x")
        }

        func testTheNewestOfSeveralNewEventsWins() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [])

            XCTAssertEqual(next(&diff, [event("a", at: 1), event("b", at: 5), event("c", at: 3)])?.key, "b")
        }

        func testAReconnectingDeviceReseedsInsteadOfBanneringWhatItMissed() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [])
            diff.forget(deviceID: "device-a")

            XCTAssertNil(next(&diff, [event("while-away")]))
            XCTAssertEqual(next(&diff, [event("while-away"), event("after")])?.key, "after")
        }

        func testClosedStreamsReseedEveryDevice() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [], device: "device-a")
            _ = next(&diff, [], device: "device-b")
            diff.forgetAll()
            let events = [event("a"), event("b", device: "device-b")]

            XCTAssertNil(next(&diff, events, device: "device-a"))
            XCTAssertNil(next(&diff, events, device: "device-b"))
        }

        func testADeviceIsSeededOnlyByItsOwnDelivery() {
            var diff = AlertBannerDiff()
            _ = next(&diff, [], device: "device-a")

            // Device A delivering says nothing about device B, so B's first delivery still only seeds.
            XCTAssertNil(next(&diff, [event("b-old", device: "device-b")], device: "device-b"))
            XCTAssertEqual(next(&diff, [event("a-new")], device: "device-a")?.key, "a-new")
            XCTAssertEqual(next(&diff, [event("b-old", device: "device-b"), event("b-new", device: "device-b")], device: "device-b")?.key, "b-new")
        }
    }
#endif
