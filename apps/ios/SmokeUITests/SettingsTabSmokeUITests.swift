import Foundation
import XCTest

/// Blocking screen-level coverage for the Settings tab: every row a user reads state off, plus the one
/// setting on this screen that changes how the terminal renders.
final class SettingsTabSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The terminal font sizes the picker offers, in the order it lists them (`TerminalFontSize`).
    private let fontSizeOptions = ["9", "10", "11", "12"]

    /// The Settings tab walked once: the rows render, and changing the terminal font size sticks across
    /// leaving the tab and coming back.
    ///
    /// The font size is restored to what it was before the walk: unlike everything else the smoke suite
    /// touches, it is written to real `UserDefaults` (an `@AppStorage` key, deliberately not shadowed by
    /// the clean-slate launch arguments — a shadowed key would make the picker unable to change at all),
    /// so it would otherwise outlive this test on a shared simulator and change the grid every later
    /// terminal test renders at.
    func testSettingsTabRowsAndFontSizeSetting() throws {
        let app = SpacesMobileUITestDriver.launchApp()
        SpacesMobileUITestDriver.selectTab("Settings", in: app)

        let rows = ["settings.pairedDevices", "settings.subscription.status", "settings.theme", "settings.terminalFontSize", "settings.version"]
        let missing = SpacesMobileUITestDriver.waitForElements(identifiers: rows, in: app, timeout: 20)
        XCTAssertTrue(missing.isEmpty, "The Settings tab did not render \(missing.joined(separator: ", "))")

        // The subscription row reports entitlement, and this fixture launches with the DEBUG paywall
        // bypass, so it has to read as entitled rather than as an unsubscribed device.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "settings.subscription.status", "Active")).firstMatch
                .exists, "The subscription status row did not report the bypassed entitlement as Active")

        XCTAssertTrue(fontSizePicker(in: app).waitForExistence(timeout: 10), "The terminal font size row exposed no picker")
        guard let original = currentFontSize(in: app), let target = fontSizeOptions.first(where: { $0 != original }) else {
            return XCTFail("The font size picker reported no recognizable selection")
        }

        // Restoration is registered before the first mutation, not left to the end of the walk:
        // `continueAfterFailure = false` aborts at the first failed assertion, and the font size is the
        // one setting this suite writes to real `UserDefaults`, so a mid-walk failure would otherwise
        // strand the simulator on a size later terminal tests render at.
        addTeardownBlock {
            guard app.state == .runningForeground else { return }
            SpacesMobileUITestDriver.selectTab("Settings", in: app)
            guard self.fontSizePicker(in: app).waitForExistence(timeout: 10), self.currentFontSize(in: app) != original else { return }
            self.selectFontSize(original, in: app)
        }

        selectFontSize(target, in: app)
        XCTAssertEqual(currentFontSize(in: app), target, "Picking a terminal font size did not change the setting")

        // Leave the tab and come back: the setting is persisted, not view state that a rebuild forgets.
        SpacesMobileUITestDriver.selectTab("Spaces", in: app)
        XCTAssertTrue(app.buttons["spaces.tryDemoMode"].waitForExistence(timeout: 20), "The Spaces tab did not render after leaving Settings")
        SpacesMobileUITestDriver.selectTab("Settings", in: app)
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForElement(identifier: "settings.terminalFontSize", in: app, timeout: 20), "Settings did not return")
        XCTAssertEqual(currentFontSize(in: app), target, "The terminal font size did not survive leaving the tab and coming back")
    }

    /// The font size row's menu picker. The identifier sits on the row's `HStack`, so it lands on both
    /// the row label and the picker; `buttons` is what separates the picker from the label.
    private func fontSizePicker(in app: XCUIApplication) -> XCUIElement { app.buttons["settings.terminalFontSize"].firstMatch }

    /// The size the picker currently reports. Read out of its label and value rather than compared to
    /// them directly: a menu picker states its selection in whichever of the two the runtime chooses, and
    /// no option is a substring of another, so scanning for the option that appears is unambiguous.
    private func currentFontSize(in app: XCUIApplication) -> String? {
        let picker = fontSizePicker(in: app)
        let selection = picker.label + " " + ((picker.value as? String) ?? "")
        return fontSizeOptions.first { selection.contains($0) }
    }

    private func selectFontSize(_ size: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        fontSizePicker(in: app).tap()
        let option = app.buttons[size]
        guard option.waitForExistence(timeout: 10) else { return XCTFail("The font size menu did not offer \(size)", file: file, line: line) }
        option.tap()
    }
}
