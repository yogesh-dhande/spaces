import Foundation
import XCTest

/// Launch and navigation helpers shared by every SpacesMobile XCUITest target: the blocking smoke
/// suite (`SpacesMobileSmokeUITests`) and the on-demand suites (`SpacesMobileUITests`) both compile
/// this directory, so a change to the way a tab is selected or a terminal row is opened lands in one
/// place.
///
/// These are free functions on a namespace rather than an `XCTestCase` extension: the on-demand
/// target already carries private helpers of the same names against a live daemon (its `selectTab`
/// reports failure as a `Bool` instead of failing the test), and an extension would put two
/// same-named members in scope inside those classes.
enum SpacesMobileUITestDriver {
    // MARK: - Launch state

    /// Overrides the persistence keys through the argument domain so init-time reads see a clean,
    /// not-paired, Demo-off slate with no alert dismissed, regardless of what a shared simulator left on
    /// disk. The Data-typed device/settings keys and the string-array dismissal key are shadowed with the
    /// non-Data, non-array string "unset" so `UserDefaults.data(forKey:)` and `stringArray(forKey:)`
    /// return nil (empty devices, default unpaired settings, no dismissals); the Bool flag is shadowed to
    /// 0. The shadow value must not start with "-" or `NSArgumentDomain` parses it as the next option key
    /// and the shadow silently never registers.
    static func applyCleanSlateLaunchArguments(to app: XCUIApplication) {
        app.launchArguments += [
            "-spaces.mobile.demo-mode-enabled", "0", "-spaces.mobile.paired-devices", "unset", "-spaces.mobile.connection-settings", "unset",
            "-spaces.mobile.dismissed-alert-ids-by-device", "unset",
        ]
    }

    // MARK: - Launch

    /// Launches the app on a clean, not-paired, Demo-off slate with the DEBUG paywall bypassed, settles
    /// one run loop turn, and returns it in portrait. Every smoke class starts here, so the fixture a
    /// screen is asserted against is defined in one place: no daemon, no network, no paired Mac.
    static func launchApp(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SPACES_MOBILE_PAYWALL_BYPASS"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        applyCleanSlateLaunchArguments(to: app)
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        return app
    }

    /// Enters Demo Mode the way a user does: from the not-paired Spaces empty state's Try Demo Mode
    /// button. Leaves the app on the Spaces tab with the bundled sample data loaded.
    static func enterDemoMode(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        selectTab("Spaces", in: app, file: file, line: line)
        let tryDemoButton = app.buttons["spaces.tryDemoMode"]
        guard tryDemoButton.waitForExistence(timeout: 20) else {
            XCTFail("The unpaired empty state did not offer Try Demo Mode", file: file, line: line)
            return
        }
        tryDemoButton.tap()
        // Confirm the fixture is actually up before handing the app back. Several screens look the same
        // not paired as they do in Demo Mode (an empty Automations tab, for one), so a Try Demo Mode tap
        // that stopped working would otherwise leave those tests passing against the unpaired state.
        guard app.descendants(matching: .any)["demo.banner"].waitForExistence(timeout: 20) else {
            XCTFail("Demo Mode did not activate: the sample-data banner never appeared", file: file, line: line)
            return
        }
    }

    // MARK: - Navigation helpers

    /// Taps a bottom tab bar button by its label, mirroring `SpacesMobileScreenshotUITests`.
    static func selectTab(_ label: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
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
        XCTFail("Timed out selecting the \(label) tab", file: file, line: line)
    }

    /// Opens the terminal row for `sessionID`, walking the list in both directions when an earlier
    /// lookup left it scrolled past the row (the same recovery `waitForText` needs).
    static func openTerminalRow(sessionID: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["terminal.row.\(sessionID)"]
        guard scanWhileScrolling(in: app, timeout: 20, check: { row.exists }) else {
            XCTFail("Timed out opening terminal row \(sessionID)", file: file, line: line)
            return
        }
        row.tap()
    }

    /// Dismisses the terminal detail back to the Spaces list, matching the resilient lookup the other
    /// UI tests use: the back chrome resolves as a button or a plain identified element, with a
    /// top-left coordinate tap as the last resort.
    static func leaveTerminalDetail(in app: XCUIApplication) {
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

    // MARK: - Assertion helpers

    /// Walks the current screen while `check` reports unsatisfied: six swipes toward the bottom, then
    /// seven back to the top, repeating until `check` passes or `timeout` elapses. Both directions are
    /// walked because a screen's targets are not all below the starting position: the Spaces list, for
    /// one, is checked for rows that sit above the fold once an earlier target has scrolled it down.
    private static func scanWhileScrolling(in app: XCUIApplication, timeout: TimeInterval, check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var swipes = 0
        while Date() < deadline {
            if check() { return true }
            if swipes < 6 {
                app.swipeUp()
                swipes += 1
            } else {
                for _ in 0..<7 { app.swipeDown() }
                swipes = 0
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return check()
    }

    /// Matches visible text case-insensitively across static texts and button labels, scrolling the
    /// current tab if the target is out of view. Robust to whether SwiftUI exposes a band's title as a
    /// nested static text or folds it into the enclosing button's label.
    static func waitForText(containing substring: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", substring)
        return scanWhileScrolling(in: app, timeout: timeout) {
            app.staticTexts.matching(predicate).firstMatch.exists || app.buttons.matching(predicate).firstMatch.exists
        }
    }

    /// Waits for every one of `identifiers` to exist, scrolling the current screen when a target is out
    /// of view, and returns the ones still missing. Checks the whole set on each pass so a screen worth
    /// of rows costs one scroll walk rather than one per identifier.
    static func waitForElements(identifiers: [String], in app: XCUIApplication, timeout: TimeInterval) -> [String] {
        var missing = identifiers
        _ = scanWhileScrolling(in: app, timeout: timeout) {
            missing = missing.filter { !app.descendants(matching: .any)[$0].exists }
            return missing.isEmpty
        }
        return missing
    }

    /// Convenience over `waitForElements` for a single identifier.
    static func waitForElement(identifier: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForElements(identifiers: [identifier], in: app, timeout: timeout).isEmpty
    }

    /// The identifier of the first element whose identifier starts with `prefix`, once one exists.
    /// Rows keyed by a fixture id (an alert event, an agent entry) are addressed this way rather than by
    /// hard-coding the recording's UUIDs into the test.
    static func firstIdentifier(withPrefix prefix: String, in app: XCUIApplication, timeout: TimeInterval) -> String? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let element = app.descendants(matching: .any).matching(predicate).firstMatch
            if element.exists { return element.identifier }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        return element.exists ? element.identifier : nil
    }

    static func waitForAnyElement(withIdentifierPrefix prefix: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.descendants(matching: .any).matching(predicate).firstMatch.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return app.descendants(matching: .any).matching(predicate).firstMatch.exists
    }

    static func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !element.exists
    }
}
