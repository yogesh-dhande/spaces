import XCTest

@testable import workspacecore

final class AppConfigStoreTests: XCTestCase {
    // Tests defaults when not set by arranging representative inputs and asserting the expected result.
    func testDefaultsWhenNotSet() throws {
        let store = try makeTemporaryStore()
        let config = try store.appConfig()
        XCTAssertNil(config.editor)
        XCTAssertEqual(config.terminalHost, .iterm2)
        XCTAssertEqual(config.processShell, .zsh)
        XCTAssertEqual(config.portRange.start, 20000)
        XCTAssertEqual(config.portRange.end, 30000)
    }

    // Tests first-run config prefers Ghostty when no terminal host setting has been saved yet.
    func testDefaultsPreferGhosttyOnFirstRun() throws {
        let store = try makeTemporaryStore(defaultTerminalHostResolver: { .ghostty })
        let config = try store.appConfig()
        XCTAssertEqual(config.terminalHost, .ghostty)
    }

    // Tests round trip by arranging representative inputs and asserting the expected result.
    func testRoundTrip() throws {
        let store = try makeTemporaryStore()
        let config = AppConfig(editor: .cursor, portRange: PortRange(start: 10000, end: 20000), terminalHost: .ghostty, processShell: .bash)
        try store.setAppConfig(config)
        let loaded = try store.appConfig()
        XCTAssertEqual(loaded.editor, .cursor)
        XCTAssertEqual(loaded.terminalHost, .ghostty)
        XCTAssertEqual(loaded.processShell, .bash)
        XCTAssertEqual(loaded.portRange.start, 10000)
        XCTAssertEqual(loaded.portRange.end, 20000)
    }

    // Tests clears editor by arranging representative inputs and asserting the expected result.
    func testClearsEditor() throws {
        let store = try makeTemporaryStore()
        try store.setAppConfig(AppConfig(editor: .vscode, portRange: PortRange(start: 20000, end: 30000)))
        try store.setAppConfig(AppConfig(editor: nil, portRange: PortRange(start: 20000, end: 30000)))
        let loaded = try store.appConfig()
        XCTAssertNil(loaded.editor)
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
