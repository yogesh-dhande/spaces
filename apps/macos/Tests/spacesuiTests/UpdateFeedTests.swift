import XCTest

@testable import spacesui

final class UpdateFeedTests: XCTestCase {
    /// Off is the default state of the "Receive pre-release updates" setting: no override, so Sparkle
    /// keeps using the stable feed baked into the app bundle.
    func testDisabledLeavesSparkleOnTheBakedInStableFeed() {
        XCTAssertNil(UpdateFeed.feedURLString(prereleaseUpdatesEnabled: false))
    }

    func testEnabledPointsAtThePrereleaseFeed() {
        XCTAssertEqual(
            UpdateFeed.feedURLString(prereleaseUpdatesEnabled: true), "https://usespaces.dev/releases/prerelease/appcast.xml")
    }
}
