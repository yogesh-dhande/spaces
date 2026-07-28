#if canImport(UIKit)
    import XCTest
    import spacesterminalcore
    @testable import SpacesMobile

    /// Pins the two things the app depends on for the terminal font size setting: the persisted
    /// `UserDefaults` key string, and that the raw `Int` `@AppStorage` stores under that key resolves
    /// through `TerminalFontSize(persistedRawValue:)` the way the settings picker and terminal view expect.
    @MainActor final class TerminalFontSizeSettingTests: XCTestCase {
        private let key = TerminalFontSizeStorage.key
        private var originalValue: Any?

        override func setUp() {
            super.setUp()
            originalValue = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }

        override func tearDown() {
            if let originalValue { UserDefaults.standard.set(originalValue, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            super.tearDown()
        }

        func testKeyMatchesTheMobileConvention() { XCTAssertEqual(key, "spaces.mobile.terminal-font-size") }

        func testStoredNineResolvesToNine() {
            UserDefaults.standard.set(9, forKey: key)
            XCTAssertEqual(TerminalFontSize(persistedRawValue: UserDefaults.standard.object(forKey: key) as? Int), .nine)
        }

        func testAbsentKeyResolvesToTen() {
            XCTAssertNil(UserDefaults.standard.object(forKey: key))
            XCTAssertEqual(TerminalFontSize(persistedRawValue: UserDefaults.standard.object(forKey: key) as? Int), .ten)
        }

        func testOutOfRangeStoredValueResolvesToTen() {
            UserDefaults.standard.set(20, forKey: key)
            XCTAssertEqual(TerminalFontSize(persistedRawValue: UserDefaults.standard.object(forKey: key) as? Int), .ten)
        }
    }
#endif
