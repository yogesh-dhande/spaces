import Foundation
import XCTest

/// Blocking screen-level coverage for the Agents tab: the coding-agent rows Demo Mode's recording
/// carries, the one thing a row does (open that agent's terminal), and the brief the demo agent keeps.
final class AgentsTabSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The recorded coding-agent session the demo's one agent row is attached to.
    private let harborAgentSessionID = "demo-harbor-agent"

    /// The Agents tab walked once: the demo agent is listed under its activity band with its brief
    /// marked, tapping it opens that agent's terminal detail with the brief sheet already up, and back
    /// returns to the list.
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
        XCTAssertTrue(row.label.contains("Has brief"), "The demo agent's row does not mark its brief: \(row.label)")
        row.tap()

        let detail = app.descendants(matching: .any)["terminal.detail.\(harborAgentSessionID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "Tapping the agent row did not open its terminal detail")

        let briefPill = app.buttons["terminal.brief"]
        let briefSheet = app.descendants(matching: .any)["brief.sheet"]
        XCTAssertTrue(briefSheet.waitForExistence(timeout: 20), "An agent's brief did not open on its own over the terminal")
        dismissBriefSheet(briefSheet)
        XCTAssertTrue(briefPill.waitForExistence(timeout: 10), "The brief pill left the chrome with the sheet")

        SpacesMobileUITestDriver.leaveTerminalDetail(in: app)
        XCTAssertTrue(app.buttons[rowIdentifier].waitForExistence(timeout: 20), "Back navigation did not return to the Agents list")
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForDisappearance(of: detail, timeout: 10), "The terminal detail stayed mounted after back navigation")

        // The dismissal belongs to the agent, not to the screen: entering its terminal again keeps the
        // brief down until the pill asks for it.
        app.buttons[rowIdentifier].tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "The agent's terminal detail did not reopen")
        XCTAssertTrue(briefPill.waitForExistence(timeout: 10), "The reopened terminal offered no brief pill")
        XCTAssertFalse(briefSheet.waitForExistence(timeout: 3), "A brief the user dismissed opened again on re-entry")
        briefPill.tap()
        XCTAssertTrue(briefSheet.waitForExistence(timeout: 10), "The brief pill did not bring the brief back")
        dismissBriefSheet(briefSheet)

        SpacesMobileUITestDriver.leaveTerminalDetail(in: app)
        XCTAssertTrue(app.buttons[rowIdentifier].waitForExistence(timeout: 20), "Back navigation did not return to the Agents list")
    }

    /// Swipes the brief sheet down, the way a user puts it away.
    private func dismissBriefSheet(_ sheet: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        sheet.swipeDown(velocity: .fast)
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForDisappearance(of: sheet, timeout: 10), "The brief sheet did not dismiss", file: file, line: line)
    }
}
