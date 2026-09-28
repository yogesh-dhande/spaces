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

    /// Two tap targets live inside one workspace band row: the name area (`workspace.band.<id>`) and the
    /// trailing actions menu (`workspace.actions.<id>`), plus, when the band has rows, a third
    /// (`workspace.collapse.<id>`). Only a UI test can prove the three do not interfere: that opening the
    /// menu leaves the band's rows alone, and that the name button and the chevron button both toggle the
    /// same collapse state.
    ///
    /// `atlas-docs` (stopped, two never-started rows) and `harbor-web` (running, two live terminal rows)
    /// give the two lifecycle states `WorkspaceActionsMenu` renders differently (Start alone for a
    /// stopped workspace, Restart and Stop but no Start for a running one whose configured processes are
    /// all already up), so asserting both in one test also pins that the menu tracks workspace state
    /// rather than always offering every action. Workspace ids are the demo recording's own UUIDs
    /// (`apps/ios/Resources/DemoRecording/overview.json`), fixed by the checked-in fixture.
    func testWorkspaceBandMenuAndCollapse() throws {
        let app = SpacesMobileUITestDriver.launchApp()
        SpacesMobileUITestDriver.enterDemoMode(in: app)

        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForElement(identifier: "workspace.band.\(Self.atlasDocsWorkspaceID)", in: app, timeout: 20),
            "The atlas-docs band never appeared")
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForElement(identifier: "workspace.band.\(Self.harborWebWorkspaceID)", in: app, timeout: 20),
            "The harbor-web band never appeared")
        attach("compact-list", in: app)

        // Stopped workspace: the menu offers Start alone, and opening it does not touch the band's own
        // rows (never-started process rows, surfaced as `workspace.row.*` rather than `terminal.row.*`
        // since they carry no session yet).
        assertRowsVisible(
            withIdentifierPrefix: Self.atlasRowIdentifierPrefix, bandID: Self.atlasDocsWorkspaceID, in: app, expected: true,
            "before opening its menu")
        app.buttons["workspace.actions.\(Self.atlasDocsWorkspaceID)"].tap()
        XCTAssertTrue(
            app.buttons["workspace.start.\(Self.atlasDocsWorkspaceID)"].waitForExistence(timeout: 10),
            "The stopped atlas-docs menu did not offer Start")
        XCTAssertFalse(app.buttons["workspace.restart.\(Self.atlasDocsWorkspaceID)"].exists, "A stopped workspace's menu must not offer Restart")
        XCTAssertFalse(app.buttons["workspace.stop.\(Self.atlasDocsWorkspaceID)"].exists, "A stopped workspace's menu must not offer Stop")
        // New Terminal, Hide, and Delete all stay off the menu in Demo Mode (see `SpacesTabView.workspaceSection`).
        XCTAssertFalse(app.buttons["workspace.newTerminal.\(Self.atlasDocsWorkspaceID)"].exists, "Demo Mode must not offer New Terminal")
        XCTAssertFalse(app.buttons["workspace.hide.\(Self.atlasDocsWorkspaceID)"].exists, "Demo Mode must not offer Hide")
        XCTAssertFalse(app.buttons["workspace.delete.\(Self.atlasDocsWorkspaceID)"].exists, "Demo Mode must not offer Delete")
        assertRowsVisible(
            withIdentifierPrefix: Self.atlasRowIdentifierPrefix, bandID: Self.atlasDocsWorkspaceID, in: app, expected: true, "with its menu open")
        attach("menu-open-stopped", in: app)
        dismissMenu(itemIdentifier: "workspace.start.\(Self.atlasDocsWorkspaceID)", in: app)

        // Running workspace: both configured processes are already up, so the menu offers Restart and
        // Stop but not Start, and its own rows (already carrying sessions) stay listed too.
        assertRowsVisible(
            identifiers: Self.harborRowIdentifiers, bandID: Self.harborWebWorkspaceID, in: app, expected: true, "before opening its menu")
        app.buttons["workspace.actions.\(Self.harborWebWorkspaceID)"].tap()
        XCTAssertFalse(app.buttons["workspace.start.\(Self.harborWebWorkspaceID)"].exists, "A fully running workspace's menu must not offer Start")
        XCTAssertTrue(
            app.buttons["workspace.restart.\(Self.harborWebWorkspaceID)"].waitForExistence(timeout: 10),
            "The running harbor-web menu did not offer Restart")
        XCTAssertTrue(app.buttons["workspace.stop.\(Self.harborWebWorkspaceID)"].exists, "The running harbor-web menu did not offer Stop")
        assertRowsVisible(
            identifiers: Self.harborRowIdentifiers, bandID: Self.harborWebWorkspaceID, in: app, expected: true, "with its menu open")
        attach("menu-open-running", in: app)
        dismissMenu(itemIdentifier: "workspace.stop.\(Self.harborWebWorkspaceID)", in: app)

        // The name button collapses and expands atlas-docs.
        app.buttons["workspace.band.\(Self.atlasDocsWorkspaceID)"].tap()
        assertRowsVisible(
            withIdentifierPrefix: Self.atlasRowIdentifierPrefix, bandID: Self.atlasDocsWorkspaceID, in: app, expected: false,
            "after tapping the band once")
        app.buttons["workspace.band.\(Self.atlasDocsWorkspaceID)"].tap()
        assertRowsVisible(
            withIdentifierPrefix: Self.atlasRowIdentifierPrefix, bandID: Self.atlasDocsWorkspaceID, in: app, expected: true,
            "after tapping the band twice")

        // The chevron toggles the same collapse state as the band, exercised on harbor-web instead of
        // atlas-docs so the two workspaces stay independent checks rather than double-testing one band.
        app.buttons["workspace.collapse.\(Self.harborWebWorkspaceID)"].tap()
        assertRowsVisible(
            identifiers: Self.harborRowIdentifiers, bandID: Self.harborWebWorkspaceID, in: app, expected: false,
            "after tapping the chevron once")
        app.buttons["workspace.collapse.\(Self.harborWebWorkspaceID)"].tap()
        assertRowsVisible(
            identifiers: Self.harborRowIdentifiers, bandID: Self.harborWebWorkspaceID, in: app, expected: true,
            "after tapping the chevron twice")
    }

    /// atlas-docs: stopped, two configured processes neither has ever run.
    private static let atlasDocsWorkspaceID = "743C3026-4782-438B-B8E5-858035261E27"
    /// harbor-web: running, both configured processes already up with live sessions.
    private static let harborWebWorkspaceID = "4F037C9C-B1AD-43F1-A238-3860D731CF78"

    /// `SpacesTabView.runtimeRow` identifies a row `workspace.row.<id>` only when it carries no session:
    /// true of atlas-docs's two rows and no others in this recording, so the prefix alone picks them out
    /// without coupling the test to `SpacesMobileWorkspaceRuntimeRow.id`'s own string format.
    private static let atlasRowIdentifierPrefix = "workspace.row."
    private static let harborRowIdentifiers = ["terminal.row.demo-harbor-frontend", "terminal.row.demo-harbor-backend"]

    /// Anchors on the workspace's own band first (scroll-aware, like every other driver wait) before
    /// checking its rows: the band and its rows sit together, so getting the band on screen is what
    /// keeps a row check honest rather than reading "not currently on screen" as "collapsed".
    private func anchorOnBand(_ bandID: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForElement(identifier: "workspace.band.\(bandID)", in: app, timeout: 10),
            "Workspace band \(bandID) was not on screen", file: file, line: line)
    }

    private func assertRowsVisible(
        identifiers: [String], bandID: String, in app: XCUIApplication, expected: Bool, _ when: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        anchorOnBand(bandID, in: app, file: file, line: line)
        for identifier in identifiers {
            let element = app.buttons[identifier]
            if expected {
                XCTAssertTrue(element.waitForExistence(timeout: 10), "Row \(identifier) was missing \(when)", file: file, line: line)
            } else {
                XCTAssertTrue(
                    SpacesMobileUITestDriver.waitForDisappearance(of: element, timeout: 10), "Row \(identifier) was still visible \(when)",
                    file: file, line: line)
            }
        }
    }

    private func assertRowsVisible(
        withIdentifierPrefix prefix: String, bandID: String, in app: XCUIApplication, expected: Bool, _ when: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        anchorOnBand(bandID, in: app, file: file, line: line)
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        let deadline = Date().addingTimeInterval(10)
        var matchCount = 0
        repeat {
            matchCount = app.descendants(matching: .any).matching(predicate).count
            if expected ? matchCount > 0 : matchCount == 0 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        if expected {
            XCTAssertGreaterThan(matchCount, 0, "No row with prefix \(prefix) was visible \(when)", file: file, line: line)
        } else {
            XCTAssertEqual(matchCount, 0, "A row with prefix \(prefix) was still visible \(when)", file: file, line: line)
        }
    }

    /// Dismisses an open `Menu` by tapping outside it, without selecting an action, and waits until
    /// `itemIdentifier` (one of the menu's items) is gone so the next step never taps through a menu
    /// that is still up. The tap lands on the navigation bar's large title: the menu opens near the
    /// tapped ellipsis pill, lower in the list, so it never covers the title, and the title carries no
    /// control. A tap in the status bar strip does not work: it goes to the system status bar rather
    /// than the app, and the menu stays open.
    private func dismissMenu(itemIdentifier: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.navigationBars["Spaces"].tap()
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForDisappearance(of: app.buttons[itemIdentifier], timeout: 5),
            "The workspace actions menu was still open after tapping outside it", file: file, line: line)
    }

    /// Attaches a screenshot a staging script can pull back out of the run's `.xcresult` (`xcrun
    /// xcresulttool export attachments`), named for what it shows rather than when it was taken.
    private func attach(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The persistent Demo Mode banner. Its identifier sits on a plain `HStack`, so it lands on the
    /// banner's own children too; matching across the hierarchy takes whichever the runtime surfaces.
    private func demoBanner(in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["demo.banner"].firstMatch }
}
