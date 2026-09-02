import Foundation
import XCTest

/// Blocking screen-level coverage for the Agents tab: the coding-agent rows Demo Mode's recording
/// carries, and the one thing a row does — open that agent's terminal.
final class AgentsTabSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The recorded coding-agent session the demo's one agent row is attached to.
    private let harborAgentSessionID = "demo-harbor-agent"

    /// The Agents tab walked once: the demo agent is listed under its activity band, tapping it opens
    /// that agent's terminal detail, and back returns to the list.
    func testAgentsTabRowOpensTerminal() throws {
        let app = SpacesMobileUITestDriver.launchApp()
        SpacesMobileUITestDriver.enterDemoMode(in: app)
        SpacesMobileUITestDriver.selectTab("Agents", in: app)

        guard let rowIdentifier = SpacesMobileUITestDriver.firstIdentifier(withPrefix: "agents.row.", in: app, timeout: 20) else {
            return XCTFail("The Agents tab rendered no agent rows")
        }
        // The demo agent is waiting for input, so it lands in the blocked band rather than an
        // undifferentiated list.
        XCTAssertTrue(
            app.descendants(matching: .any)["agents.band.blocked"].exists, "The waiting agent was not grouped under the blocked activity band")

        let row = app.buttons[rowIdentifier]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(rowIdentifier) is not a tappable row")
        row.tap()

        let detail = app.descendants(matching: .any)["terminal.detail.\(harborAgentSessionID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "Tapping the agent row did not open its terminal detail")

        SpacesMobileUITestDriver.leaveTerminalDetail(in: app)
        XCTAssertTrue(app.buttons[rowIdentifier].waitForExistence(timeout: 20), "Back navigation did not return to the Agents list")
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForDisappearance(of: detail, timeout: 10), "The terminal detail stayed mounted after back navigation")
    }
}
