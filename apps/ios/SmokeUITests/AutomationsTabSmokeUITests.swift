import Foundation
import XCTest

/// Blocking screen-level coverage for the Automations tab.
///
/// Demo Mode's recording carries no automations and no runs (`overview.automations` and
/// `overview.automationRuns` are both empty), so what a demo user sees on this tab is its empty state.
/// That is what this asserts: the tab renders its own screen rather than a blank one, it tells the user
/// where automations come from, and its Runs segment shows its own empty state because there is no run.
/// Detail-screen coverage (the run history, the next-run affordance and its sheet) needs an automation in
/// the recording to reach, so it is not asserted here.
final class AutomationsTabSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The Automations tab walked once against a device with no automations.
    func testAutomationsTabEmptyState() throws {
        let app = SpacesMobileUITestDriver.launchApp()
        SpacesMobileUITestDriver.enterDemoMode(in: app)
        SpacesMobileUITestDriver.selectTab("Automations", in: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["automations.empty"].waitForExistence(timeout: 20),
            "The Automations tab rendered neither rows nor its empty state")
        XCTAssertFalse(
            SpacesMobileUITestDriver.waitForAnyElement(withIdentifierPrefix: "automations.row.", in: app, timeout: 2),
            "A device with no automations listed an automation row")

        // Runs is a segment of the tab itself, and with nothing fired it says so.
        let runs = app.buttons["Runs"]
        XCTAssertTrue(runs.waitForExistence(timeout: 10), "The Automations tab offered no Runs segment")
        runs.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["automations.runs.empty"].waitForExistence(timeout: 10),
            "A device with no runs did not show the empty Runs state")
    }
}
