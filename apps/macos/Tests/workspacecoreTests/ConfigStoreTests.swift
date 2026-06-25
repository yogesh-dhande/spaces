import XCTest

@testable import workspacecore

final class AppConfigStoreTests: XCTestCase {
    // Tests defaults when not set by arranging representative inputs and asserting the expected result.
    func testDefaultsWhenNotSet() throws {
        let store = try makeTemporaryStore()
        let config = try store.appConfig()
        XCTAssertEqual(config.portRange.start, 20000)
        XCTAssertEqual(config.portRange.end, 30000)
    }

    // Tests round trip by arranging representative inputs and asserting the expected result.
    func testRoundTrip() throws {
        let store = try makeTemporaryStore()
        let config = AppConfig(portRange: PortRange(start: 10000, end: 20000))
        try store.setAppConfig(config)
        let loaded = try store.appConfig()
        XCTAssertEqual(loaded.portRange.start, 10000)
        XCTAssertEqual(loaded.portRange.end, 20000)
    }

    // Tests resets invalid port range by arranging representative inputs and asserting the expected result.
    func testResetsInvalidPortRange() throws {
        let store = try makeTemporaryStore()
        // Manually write invalid values
        try store.setSetting(key: SettingsKey.appPortRangeStart, value: "30000")
        try store.setSetting(key: SettingsKey.appPortRangeEnd, value: "20000")
        let config = try store.appConfig()
        XCTAssertEqual(config.portRange.start, 20000)
        XCTAssertEqual(config.portRange.end, 30000)
    }
}
