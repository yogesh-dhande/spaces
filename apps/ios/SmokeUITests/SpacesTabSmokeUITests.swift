import Foundation
import XCTest

/// Blocking screen-level coverage for the Spaces tab: the not-paired empty state a first launch lands
/// on, and the list Demo Mode fills it with.
///
/// Fixture: Demo Mode's bundled recording (see `TerminalViewerSmokeUITests` for why it is the only
/// backend a CI runner can drive). Everything asserted here is view wiring — which affordances the
/// screen offers, which rows it renders — the layer a model test cannot reach.
final class SpacesTabSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The recorded sessions the demo workspaces' rows open, keyed by the row identifier the list gives
    /// a row that has a session. `atlas-docs`'s two rows have never been started, so they carry
    /// `workspace.row.<id>` instead and are covered by their band rendering at all.
    private let demoSessionRowIdentifiers = [
        "terminal.row.demo-harbor-frontend", "terminal.row.demo-harbor-backend", "terminal.row.demo-harbor-agent",
        "terminal.row.demo-lantern-frontend", "terminal.row.demo-lantern-backend",
    ]

    /// The Spaces tab walked once: not paired it offers the two ways forward and nothing that needs a
    /// device, and in Demo Mode it lists the sample workspaces with their runtime rows.
    func testSpacesTabChrome() throws {
        let app = SpacesMobileUITestDriver.launchApp()
        SpacesMobileUITestDriver.selectTab("Spaces", in: app)

        // Not paired: pair for real, or look around with sample data. Nothing else is offered, because
        // nothing else can work without a device.
        XCTAssertTrue(app.buttons["spaces.scanToPair"].waitForExistence(timeout: 20), "The unpaired empty state did not offer Scan QR Code")
        XCTAssertTrue(app.buttons["spaces.tryDemoMode"].exists, "The unpaired empty state did not offer Try Demo Mode")
        XCTAssertFalse(app.buttons["spaces.newWorkspace"].exists, "An unpaired device must not offer New Workspace")
        XCTAssertFalse(demoBanner(in: app).exists, "The demo banner must be absent before Demo Mode is enabled")

        SpacesMobileUITestDriver.enterDemoMode(in: app)

        // The banner is the standing "this is sample data" marker, on every tab for as long as Demo Mode
        // is on.
        XCTAssertTrue(demoBanner(in: app).waitForExistence(timeout: 20), "The Demo Mode banner did not appear after enabling Demo Mode")

        // Listed in the order the demo device reports its projects, so the scroll walk that finds the
        // later ones does not have to climb back for an earlier one.
        for workspace in ["atlas-docs", "harbor-web", "lantern-api"] {
            XCTAssertTrue(
                SpacesMobileUITestDriver.waitForText(containing: workspace, in: app, timeout: 20),
                "Demo workspace \(workspace) did not render on the Spaces tab")
        }

        let missingRows = SpacesMobileUITestDriver.waitForElements(identifiers: demoSessionRowIdentifiers, in: app, timeout: 30)
        XCTAssertTrue(missingRows.isEmpty, "The demo workspaces rendered no row for \(missingRows.joined(separator: ", "))")

        // New Workspace stays hidden in Demo Mode: the demo backend refuses `createWorkspace`, so the
        // action is not offered rather than offered and left to fail (see `SpacesTabView.toolbarContent`).
        XCTAssertFalse(app.buttons["spaces.newWorkspace"].exists, "Demo Mode must not offer New Workspace")
    }

    /// The persistent Demo Mode banner. Its identifier sits on a plain `HStack`, so it lands on the
    /// banner's own children too; matching across the hierarchy takes whichever the runtime surfaces.
    private func demoBanner(in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["demo.banner"].firstMatch }
}
