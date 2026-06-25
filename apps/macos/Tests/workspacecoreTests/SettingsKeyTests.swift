import XCTest

@testable import workspacecore

final class SettingsKeyTests: XCTestCase {
    func testWindowFocusPulseColorParsesConfiguredColor() { assertColor(SettingsKey.windowFocusPulseColor(from: "10,20,30"), r: 10, g: 20, b: 30) }

    func testWindowFocusPulseColorUsesDefaultForMissingBlankOrMalformedValues() {
        let expected = SettingsKey.windowFocusPulseColor(from: nil)

        assertColor(expected, r: 72, g: 98, b: 110)
        assertColor(SettingsKey.windowFocusPulseColor(from: ""), r: expected.r, g: expected.g, b: expected.b)
        assertColor(SettingsKey.windowFocusPulseColor(from: "not-a-color"), r: expected.r, g: expected.g, b: expected.b)
        assertColor(SettingsKey.windowFocusPulseColor(from: "1,2"), r: expected.r, g: expected.g, b: expected.b)
    }

    private func assertColor(_ color: (r: Int, g: Int, b: Int), r: Int, g: Int, b: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(color.r, r, file: file, line: line)
        XCTAssertEqual(color.g, g, file: file, line: line)
        XCTAssertEqual(color.b, b, file: file, line: line)
    }
}
