#if canImport(UIKit)
    import XCTest
    @testable import SpacesMobile

    final class AutomationsPreferencesTests: XCTestCase {
        private func makeDefaults() throws -> UserDefaults {
            let suite = "AutomationsPreferencesTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            return defaults
        }

        func testARememberedPairedDeviceIsShown() {
            XCTAssertEqual(AutomationsPreferences.resolvedDeviceID(remembered: "b", pairedDeviceIDs: ["a", "b", "c"]), "b")
        }

        func testARememberedDeviceThatIsNoLongerPairedIsDropped() {
            XCTAssertEqual(AutomationsPreferences.resolvedDeviceID(remembered: "gone", pairedDeviceIDs: ["a", "b"]), "a")
        }

        func testWithNothingRememberedTheFirstPairedDeviceIsShown() {
            XCTAssertEqual(AutomationsPreferences.resolvedDeviceID(remembered: nil, pairedDeviceIDs: ["a", "b"]), "a")
        }

        func testNoPairedDeviceResolvesToNothing() {
            XCTAssertNil(AutomationsPreferences.resolvedDeviceID(remembered: "a", pairedDeviceIDs: []))
        }

        func testTheChoiceSurvivesANewPreferencesInstance() throws {
            let defaults = try makeDefaults()
            AutomationsPreferences(defaults: defaults).deviceID = "b"

            XCTAssertEqual(AutomationsPreferences(defaults: defaults).deviceID, "b")
        }
    }
#endif
