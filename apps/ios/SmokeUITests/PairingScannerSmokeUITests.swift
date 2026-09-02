import Foundation
import XCTest

/// Blocking screen-level coverage for the way into pairing: the not-paired Spaces empty state's Scan QR
/// Code button presents the scanner full-screen, and the scanner can be left again.
///
/// Only the presentation is asserted. The simulator has no camera, so the scanner never recognizes a
/// code there, and pairing itself — parsing a pairing link, storing the device — is covered by unit
/// tests. What a screen test is needed for is that the button reaches the scanner at all and that the
/// scanner has a way out: a scanner a user cannot back out of strands them on a black screen.
final class PairingScannerSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testScanToPairPresentsAndDismissesTheScanner() throws {
        let app = SpacesMobileUITestDriver.launchApp()
        SpacesMobileUITestDriver.selectTab("Spaces", in: app)

        let scanToPair = app.buttons["spaces.scanToPair"]
        XCTAssertTrue(scanToPair.waitForExistence(timeout: 20), "The unpaired empty state did not offer Scan QR Code")
        scanToPair.tap()

        let scanner = app.descendants(matching: .any)["pairing.scanner"]
        XCTAssertTrue(scanner.waitForExistence(timeout: 20), "Scan QR Code did not present the pairing scanner")

        let close = app.buttons["pairing.scanner.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The pairing scanner offered no way out")
        XCTAssertTrue(close.isHittable, "The pairing scanner's close control is not hit-testable")
        close.tap()

        XCTAssertTrue(SpacesMobileUITestDriver.waitForDisappearance(of: scanner, timeout: 10), "Closing the pairing scanner did not dismiss it")
        XCTAssertTrue(scanToPair.waitForExistence(timeout: 10), "Closing the pairing scanner did not return to the unpaired empty state")
    }
}
