import Foundation
import XCTest

/// Pre-submission verification for App Store Demo Mode. This is the gate a reviewer's path relies
/// on: the whole tour must work with no Mac, no daemon, and no network — only the bundled sample
/// recording. The test launches with the DEBUG paywall bypass and *no* host/seed/daemon
/// environment, so a green run proves the entire Demo Mode feature end to end against the in-app
/// `DemoDeviceBackend`.
///
/// Determinism: the app persists both the Demo Mode flag and paired devices in `UserDefaults`, so a
/// simulator carried over from another lane could otherwise launch already paired or already in Demo
/// Mode. The launch arguments shadow those keys through the `NSArgumentDomain` (highest-precedence,
/// volatile) so every run starts from the same not-paired, Demo-off state without mutating on-disk
/// records. See docs/dev.md ("Demo Mode recording + App Review").
final class SpacesMobileDemoModeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let harborFrontendSessionID = "demo-harbor-frontend"
    private let waitingAgentTitle = "Fix checkout 500"
    /// A stable, port-free line from the recorded frontend dev-server banner (see
    /// `spaces_e2e_demo` frontend role). Present in every recorded harbor-frontend frame.
    private let frontendTranscriptMarker = "Lighthouse web"

    func testDemoModeTourWithNoDaemon() throws {
        let renderDumpPath = FileManager.default.temporaryDirectory.appendingPathComponent(
            "demo-mode-render-dump-\(UUID().uuidString).json", isDirectory: false
        ).path

        let app = XCUIApplication()
        app.launchEnvironment["SPACES_MOBILE_PAYWALL_BYPASS"] = "1"
        app.launchEnvironment["SPACES_MOBILE_E2E_RENDER_DUMP_PATH"] = renderDumpPath
        applyCleanSlateLaunchArguments(to: app)
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // 1. Not paired: the Spaces empty state offers Try Demo Mode (no daemon, nothing paired).
        selectTab("Spaces", in: app)
        let tryDemoButton = app.buttons["spaces.tryDemoMode"]
        XCTAssertTrue(tryDemoButton.waitForExistence(timeout: 20), "The unpaired empty state did not offer Try Demo Mode")
        XCTAssertFalse(demoBanner(in: app).exists, "The demo banner should be absent before Demo Mode is enabled")

        // 2. Enter Demo Mode from the empty state: sample workspaces render and the banner appears.
        tryDemoButton.tap()
        for workspace in ["harbor-web", "lantern-api", "atlas-docs"] {
            XCTAssertTrue(waitForText(containing: workspace, in: app, timeout: 20), "Demo workspace \(workspace) did not render on the Spaces tab")
        }
        XCTAssertTrue(demoBanner(in: app).waitForExistence(timeout: 20), "The Demo Mode banner did not appear after enabling Demo Mode")

        // 3. Alerts: the waiting-agent and exited-process events are present (badge count > 0).
        selectTab("Alerts", in: app)
        XCTAssertTrue(waitForAnyElement(withIdentifierPrefix: "alert.row.", in: app, timeout: 20), "The Alerts tab rendered no attention events")
        XCTAssertTrue(waitForText(containing: waitingAgentTitle, in: app, timeout: 20), "The waiting-agent alert was not visible")
        XCTAssertTrue(waitForText(containing: "Waiting for input", in: app, timeout: 10), "The waiting-for-input event kind was not visible")
        XCTAssertTrue(waitForText(containing: "Exited", in: app, timeout: 10), "The exited-process event kind was not visible")

        // 4. Agents: the coding-agent session is listed.
        selectTab("Agents", in: app)
        XCTAssertTrue(waitForAnyElement(withIdentifierPrefix: "agents.row.", in: app, timeout: 20), "The Agents tab rendered no agents")
        XCTAssertTrue(waitForText(containing: waitingAgentTitle, in: app, timeout: 20), "The \"\(waitingAgentTitle)\" agent was not listed")

        // 5. Terminal: open the harbor frontend and confirm the recorded transcript renders read-only.
        selectTab("Spaces", in: app)
        openTerminalRow(sessionID: harborFrontendSessionID, in: app)
        let detail = app.descendants(matching: .any)["terminal.detail.\(harborFrontendSessionID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "The harbor frontend terminal detail did not open")

        // (a) Recorded transcript content is visible through the render-dump plumbing.
        let dump = waitForRenderDump(path: renderDumpPath, timeout: 30) { dump in
            dump.sessionID == self.harborFrontendSessionID && dump.showsTerminalSurface && dump.combinedText.contains(self.frontendTranscriptMarker)
        }
        XCTAssertNotNil(dump, "The demo terminal never rendered the recorded transcript (\(frontendTranscriptMarker))")
        XCTAssertEqual(dump?.isOwner, false, "Demo terminals are view-only and must never report ownership")

        // (b) The read-only notice is shown (by identifier, or by its copy if SwiftUI folds the
        // identified container into its inner text).
        let noticeShown =
            app.descendants(matching: .any)["demo.terminalNotice"].waitForExistence(timeout: 10)
            || waitForText(containing: "terminal input requires a paired Mac", in: app, timeout: 5)
        XCTAssertTrue(noticeShown, "The demo read-only notice was absent")

        // (c) No input affordances: the view-only terminal offers no Take Over, no message composer,
        // and no software keyboard — an owned terminal would surface all three.
        XCTAssertFalse(app.buttons["terminal.takeover"].exists, "Demo terminals must not offer Take Over")
        XCTAssertFalse(app.descendants(matching: .any)["composer.sheet"].exists, "Demo terminals must not present the message composer")
        XCTAssertFalse(app.textViews["composer.message-field"].exists, "Demo terminals must not expose a message field")
        XCTAssertFalse(app.buttons["composer.send"].exists, "Demo terminals must not expose a send control")
        XCTAssertEqual(app.keyboards.count, 0, "A demo terminal must not raise the software keyboard")

        // 6. Turn Demo Mode off from Settings: the app returns to the not-paired empty state.
        leaveTerminalDetail(in: app)
        selectTab("Settings", in: app)
        let demoToggle = demoModeToggle(in: app)
        XCTAssertTrue(demoToggle.waitForExistence(timeout: 20), "The Settings Demo Mode toggle was not found")
        // Confirm the toggle actually cleared Demo Mode: the persistent banner disappears. Tap the
        // trailing switch thumb (a center tap can land on the row label without flipping the switch)
        // and retry if the state has not changed.
        var demoModeCleared = false
        for _ in 0..<3 {
            if (demoToggle.value as? String) == "0" {
                demoModeCleared = true
                break
            }
            demoToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            if waitForDisappearance(of: demoBanner(in: app), timeout: 5) {
                demoModeCleared = true
                break
            }
        }
        XCTAssertTrue(demoModeCleared, "Toggling settings.demoMode off did not clear Demo Mode")

        selectTab("Spaces", in: app)
        XCTAssertTrue(
            app.buttons["spaces.tryDemoMode"].waitForExistence(timeout: 20), "Turning Demo Mode off did not return to the not-paired empty state")
        XCTAssertFalse(demoBanner(in: app).exists, "The Demo Mode banner should be gone after turning Demo Mode off")
    }

    /// The persistent Demo Mode banner. SwiftUI may surface the identified container as an `other`
    /// element or fold it, so match across the whole hierarchy rather than a single element type.
    private func demoBanner(in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["demo.banner"] }

    // MARK: - Launch state

    /// Overrides the persistence keys through the argument domain so init-time reads see a clean,
    /// not-paired, Demo-off slate with no alert dismissed, regardless of what a shared simulator left on
    /// disk. The Data-typed device/settings keys and the string-array dismissal key are shadowed with the
    /// non-Data, non-array string "unset" so `UserDefaults.data(forKey:)` and `stringArray(forKey:)`
    /// return nil (empty devices, default unpaired settings, no dismissals); the Bool flag is shadowed to
    /// 0. The shadow value must not start with "-" or `NSArgumentDomain` parses it as the next option key
    /// and the shadow silently never registers.
    private func applyCleanSlateLaunchArguments(to app: XCUIApplication) {
        app.launchArguments += [
            "-spaces.mobile.demo-mode-enabled", "0", "-spaces.mobile.paired-devices", "unset", "-spaces.mobile.connection-settings", "unset",
            "-spaces.mobile.dismissed-alert-ids-by-device", "unset",
        ]
    }

    // MARK: - Navigation helpers

    /// Taps a bottom tab bar button by its label, mirroring `SpacesMobileScreenshotUITests`.
    private func selectTab(_ label: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label == %@", label)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            for scope in [app.tabBars.buttons, app.buttons] {
                let button = scope.matching(predicate).firstMatch
                guard button.exists else { continue }
                if button.isHittable { button.tap() } else { button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Timed out selecting the \(label) tab")
    }

    private func openTerminalRow(sessionID: String, in app: XCUIApplication) {
        let row = app.buttons["terminal.row.\(sessionID)"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if row.exists, row.isHittable {
                row.tap()
                return
            }
            if row.exists {
                row.tap()
                return
            }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTFail("Timed out opening terminal row \(sessionID)")
    }

    /// Dismisses the terminal detail back to the Spaces list, matching the resilient lookup the other
    /// UI tests use: the back chrome resolves as a button or a plain identified element, with a
    /// top-left coordinate tap as the last resort.
    private func leaveTerminalDetail(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let button = app.buttons["terminal.back"].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                return
            }
            let anyBack = app.descendants(matching: .any)["terminal.back"].firstMatch
            if anyBack.exists, anyBack.isHittable {
                anyBack.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.11)).tap()
    }

    /// The Demo Mode toggle, scrolled into view. SwiftUI `Toggle`s surface as switches.
    private func demoModeToggle(in app: XCUIApplication) -> XCUIElement {
        let toggle = app.switches["settings.demoMode"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !(toggle.exists && toggle.isHittable) {
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return toggle
    }

    // MARK: - Assertion helpers

    /// Matches visible text case-insensitively across static texts and button labels, scrolling the
    /// current tab if the target is below the fold. Robust to whether SwiftUI exposes a band's title
    /// as a nested static text or folds it into the enclosing button's label.
    private func waitForText(containing substring: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", substring)
        let deadline = Date().addingTimeInterval(timeout)
        var swipes = 0
        while Date() < deadline {
            if app.staticTexts.matching(predicate).firstMatch.exists || app.buttons.matching(predicate).firstMatch.exists { return true }
            if swipes < 6 {
                app.swipeUp()
                swipes += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return app.staticTexts.matching(predicate).firstMatch.exists || app.buttons.matching(predicate).firstMatch.exists
    }

    private func waitForAnyElement(withIdentifierPrefix prefix: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.descendants(matching: .any).matching(predicate).firstMatch.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return app.descendants(matching: .any).matching(predicate).firstMatch.exists
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !element.exists
    }

    private func waitForRenderDump(path: String, timeout: TimeInterval, predicate: (DemoRenderDump) -> Bool) -> DemoRenderDump? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let dump = latestRenderDump(path: path), predicate(dump) { return dump }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if let dump = latestRenderDump(path: path), predicate(dump) { return dump }
        return nil
    }

    private func latestRenderDump(path: String) -> DemoRenderDump? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(DemoRenderDump.self, from: data)
    }
}

/// The subset of `SpacesMobileE2ERenderDump` this test reads. Decoded independently because the app
/// model's struct is not visible to the UI test target.
private struct DemoRenderDump: Decodable {
    let sessionID: String
    let renderMode: String
    let isOwner: Bool
    let showsTerminalSurface: Bool
    let snapshotText: String?
    let visibleText: String
    let renderedText: String

    var combinedText: String { [renderedText, snapshotText ?? "", visibleText].joined(separator: "\n") }
}
