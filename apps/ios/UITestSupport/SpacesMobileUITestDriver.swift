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

    static func openTerminalRow(sessionID: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
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
        XCTFail("Timed out opening terminal row \(sessionID)", file: file, line: line)
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

    /// Matches visible text case-insensitively across static texts and button labels, scrolling the
    /// current tab if the target is below the fold. Robust to whether SwiftUI exposes a band's title
    /// as a nested static text or folds it into the enclosing button's label.
    static func waitForText(containing substring: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
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
