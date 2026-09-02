import Foundation
import XCTest

/// Blocking screen-level coverage for the iOS terminal viewer, run by `scripts/ios-test-lane.sh` on
/// every verify and every PR.
///
/// Fixture: Demo Mode's bundled recording. It is the only backend that renders a real terminal with
/// no daemon, no network and no paired Mac, so it is what a lane running on a CI runner can drive.
/// Everything asserted here is view wiring — identifiers, presence, hit-testability, navigation —
/// which is exactly the layer a model test cannot reach; terminal *content* is covered by the
/// on-demand demo tour's render dump and by the model unit tests.
final class TerminalViewerSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let harborFrontendSessionID = "demo-harbor-frontend"
    /// A relative path printed in the recorded frontend transcript. Ghostty's link regex matches bare
    /// relative paths, so this is the kind of link a user's tap lands on in this session.
    private let frontendTranscriptLink = ".spaces-e2e-demo/site"

    /// The terminal detail's own chrome, walked once: the pane opens for the tapped session, the
    /// read-only demo notice is shown, no ownership or input affordance is offered on a view-only
    /// pane, and back navigation returns to the list it came from.
    func testDemoTerminalViewerChrome() throws {
        let app = launchDemoModeApp()
        openHarborFrontendTerminal(in: app)

        let detail = app.descendants(matching: .any)["terminal.detail.\(harborFrontendSessionID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "The harbor frontend terminal detail did not open")

        XCTAssertTrue(app.descendants(matching: .any)["demo.terminalNotice"].waitForExistence(timeout: 10), "The demo read-only notice was absent")

        // A demo pane is a viewer, never an owner: no owner marker, and none of the affordances that
        // only an owned pane offers.
        XCTAssertFalse(app.descendants(matching: .any)["terminal.ownerBadge"].exists, "A demo terminal must never report ownership")
        XCTAssertFalse(app.buttons["terminal.takeover"].exists, "Demo terminals must not offer Take Over")
        XCTAssertFalse(app.descendants(matching: .any)["composer.sheet"].exists, "Demo terminals must not present the message composer")
        XCTAssertFalse(app.textViews["composer.message-field"].exists, "Demo terminals must not expose a message field")
        XCTAssertFalse(app.buttons["composer.send"].exists, "Demo terminals must not expose a send control")
        XCTAssertEqual(app.keyboards.count, 0, "A demo terminal must not raise the software keyboard")

        // Back returns to the list the row was tapped from, and tears the detail down with it.
        SpacesMobileUITestDriver.leaveTerminalDetail(in: app)
        XCTAssertTrue(
            app.buttons["terminal.row.\(harborFrontendSessionID)"].waitForExistence(timeout: 20),
            "Back navigation did not return to the terminal list")
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForDisappearance(of: detail, timeout: 10), "The terminal detail stayed mounted after back navigation")
    }

    /// Regression coverage for #650: the link-open banners are dismissable by tapping them.
    ///
    /// The bug that shipped was pure view wiring — the whole banner stack carried a blanket
    /// `.allowsHitTesting(false)`, so each dismiss control existed and could never be tapped — which is
    /// why this is asserted on a rendered screen rather than on the model, and why it asserts
    /// hit-testability and not just presence.
    ///
    /// The banners are reached through the existing file-based E2E command request rather than by
    /// tapping a link in the recorded transcript: Ghostty's link hit-test is refused on a
    /// column-cropped frame, and a Demo Mode frame is always a few columns wider than the phone's
    /// viewport (the recording is served at its captured grid), so no tap on demo content can ever
    /// open a link. See `consumeE2ECommandRequestsIfNeeded` in `TerminalDetailView`.
    func testDemoTerminalLinkBannersAreDismissable() throws {
        let eventLogPath = FileManager.default.temporaryDirectory.appendingPathComponent(
            "smoke-terminal-events-\(UUID().uuidString).log", isDirectory: false
        ).path
        let app = launchDemoModeApp(eventLogPath: eventLogPath)
        openHarborFrontendTerminal(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.detail.\(harborFrontendSessionID)"].waitForExistence(timeout: 20),
            "The harbor frontend terminal detail did not open")

        // A loopback URL is answered by the client itself with the "runs on the session's host" notice.
        openLink("http://localhost:3000", eventLogPath: eventLogPath)
        assertBannerIsDismissable(
            identifier: "terminal.linkNotice", dismissIdentifier: "terminal.linkNotice.dismiss", in: app, eventLogPath: eventLogPath,
            context: "loopback link notice")

        // A file link is resolved by the daemon, which Demo Mode has none of: the refused resolve is
        // the failed link open whose error banner had no way out before #650.
        openLink(frontendTranscriptLink, eventLogPath: eventLogPath)
        assertBannerIsDismissable(
            identifier: "terminal.errorBanner", dismissIdentifier: "terminal.errorBanner.dismiss", in: app, eventLogPath: eventLogPath,
            context: "link-open error banner")
    }

    // MARK: - Fixture

    private func launchDemoModeApp(eventLogPath: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SPACES_MOBILE_PAYWALL_BYPASS"] = "1"
        if let eventLogPath {
            app.launchEnvironment["SPACES_MOBILE_E2E_EVENT_LOG_PATH"] = eventLogPath
            app.launchEnvironment["SPACES_MOBILE_E2E_TARGET_SESSION_ID"] = harborFrontendSessionID
        }
        SpacesMobileUITestDriver.applyCleanSlateLaunchArguments(to: app)
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        SpacesMobileUITestDriver.selectTab("Spaces", in: app)
        let tryDemoButton = app.buttons["spaces.tryDemoMode"]
        XCTAssertTrue(tryDemoButton.waitForExistence(timeout: 20), "The unpaired empty state did not offer Try Demo Mode")
        tryDemoButton.tap()
        return app
    }

    private func openHarborFrontendTerminal(in app: XCUIApplication) {
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForText(containing: "harbor-web", in: app, timeout: 20), "Demo Mode did not render the harbor workspace")
        SpacesMobileUITestDriver.openTerminalRow(sessionID: harborFrontendSessionID, in: app)
    }

    // MARK: - Link opens

    /// Asks the open terminal detail to open a link, through the command-request file its e2e config
    /// already watches. The app deletes the file once it has consumed it.
    private func openLink(_ link: String, eventLogPath: String, file: StaticString = #filePath, line: UInt = #line) {
        let request = ["id": UUID().uuidString, "link": link]
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            try data.write(to: URL(fileURLWithPath: commandRequestPath(eventLogPath: eventLogPath)), options: .atomic)
        } catch { XCTFail("Could not write the link-open request for \(link): \(error)", file: file, line: line) }
    }

    private func commandRequestPath(eventLogPath: String) -> String { "\(eventLogPath).command-request.json" }

    /// The whole #650 contract for one banner: it appears, its dismiss control can actually be tapped,
    /// and tapping it clears the banner.
    private func assertBannerIsDismissable(
        identifier: String, dismissIdentifier: String, in app: XCUIApplication, eventLogPath: String, context: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let banner = app.descendants(matching: .any)[identifier]
        guard banner.waitForExistence(timeout: 20) else {
            let consumed = !FileManager.default.fileExists(atPath: commandRequestPath(eventLogPath: eventLogPath))
            XCTFail("The \(context) never appeared (link-open request consumed by the app: \(consumed))", file: file, line: line)
            return
        }
        let dismiss = app.buttons[dismissIdentifier]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "The \(context) offered no dismiss control", file: file, line: line)
        // The #650 wiring itself: the control has to be reachable by a tap, not merely present.
        XCTAssertTrue(dismiss.isHittable, "The \(context)'s dismiss control is not hit-testable", file: file, line: line)
        dismiss.tap()
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForDisappearance(of: banner, timeout: 10), "Dismissing the \(context) did not clear it", file: file,
            line: line)
    }
}
