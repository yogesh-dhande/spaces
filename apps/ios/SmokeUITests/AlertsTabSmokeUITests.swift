import Foundation
import XCTest

/// Blocking screen-level coverage for the Alerts tab: the attention events Demo Mode's recording
/// produces, and the two ways a user gets rid of them — a swipe on one row, and Clear on all of them.
///
/// Dismissal is asserted on the rendered screen rather than on the model because the swipe tray is the
/// only way to reach a single row's Dismiss: `alert.dismiss.<id>` exists only once the row is swiped,
/// which is view wiring a model test cannot see.
final class AlertsTabSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The Alerts tab walked once: the demo events render, a swipe dismisses one of them, and Clear
    /// empties what is left down to the empty state.
    func testAlertsTabDismissAndClear() throws {
        let app = SpacesMobileUITestDriver.launchApp()
        SpacesMobileUITestDriver.enterDemoMode(in: app)
        SpacesMobileUITestDriver.selectTab("Alerts", in: app)

        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForAnyElement(withIdentifierPrefix: "alert.row.", in: app, timeout: 20),
            "The Alerts tab rendered no attention events")
        // Nothing on a row advertises the swipe, so the caption that says so rides along with the alerts.
        XCTAssertTrue(app.descendants(matching: .any)["alerts.swipeHint"].exists, "The alerts list did not show the swipe hint")

        // Dismiss one row: its Dismiss button lives in the swipe tray, so the row has to be swiped first.
        guard let rowIdentifier = SpacesMobileUITestDriver.firstIdentifier(withPrefix: "alert.row.", in: app, timeout: 20) else {
            return XCTFail("No alert row to dismiss")
        }
        let row = app.descendants(matching: .any)[rowIdentifier].firstMatch
        let eventID = String(rowIdentifier.dropFirst("alert.row.".count))
        row.swipeLeft()
        let dismiss = app.buttons["alert.dismiss.\(eventID)"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "Swiping the alert row offered no Dismiss action")
        dismiss.tap()
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForDisappearance(of: row, timeout: 10), "Dismissing \(rowIdentifier) did not remove it from the list")

        // Clear takes the rest. Demo Mode is not special here: dismissal is client-side state on the
        // events derived from the overview, so it needs nothing from the backend.
        //
        // The dismissals this writes reach real `UserDefaults` (the clean-slate launch arguments shadow
        // reads, not writes) and are deliberately not restored. An attention event's dismissal identity
        // carries its timestamp, and the demo recording rebases every timestamp to launch time, so the
        // ids stored here match nothing on the next launch and the model prunes them off the demo
        // device's bucket on its first overview refresh: a later Demo Mode session shows its sample
        // alerts, and the store stays bounded.
        let clear = app.buttons["alerts.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "The Alerts toolbar offered no Clear")
        XCTAssertTrue(clear.isEnabled, "Clear was disabled while alerts were still listed")
        clear.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["alerts.empty"].waitForExistence(timeout: 10), "Clearing every alert did not leave the empty state")
        XCTAssertFalse(
            SpacesMobileUITestDriver.waitForAnyElement(withIdentifierPrefix: "alert.row.", in: app, timeout: 2), "An alert row survived Clear")
        XCTAssertFalse(app.buttons["alerts.clear"].isEnabled, "Clear stayed enabled with nothing left to clear")
    }
}
