import Foundation
import XCTest
import systembridge

final class ChromeAdapterTests: XCTestCase {
    func testTabsInWindowIDsParsesRowsAndScopesAppleScriptToRequestedWindows() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '101\t1\tDocs\thttp://localhost:3000/docs\\n'
            printf '202\t2\tAdmin\thttp://localhost:4000/admin\\n'
            """

        try withMockCommands(["osascript": mock]) {
            let tabs = try ChromeAdapter().tabs(inWindowIDs: [202, 101, 101, -1, 0])

            XCTAssertEqual(tabs.map(\.windowID), [101, 202])
            XCTAssertEqual(tabs.map(\.tabIndex), [1, 2])
            XCTAssertEqual(tabs.map(\.url), ["http://localhost:3000/docs", "http://localhost:4000/admin"])

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set requestedWindowIDs to {\"101\", \"202\"}"))
            XCTAssertTrue(script.contains("if requestedWindowIDs contains (wid as string) then"))
        }
    }

    func testTabsInWindowIDsReturnsEmptyWithoutAppleScriptForEmptyInput() throws {
        let mock = """
            #!/bin/sh
            exit 99
            """

        try withMockCommands(["osascript": mock]) { XCTAssertTrue(try ChromeAdapter().tabs(inWindowIDs: []).isEmpty) }
    }

    func testTabSnapshotInWindowIDsParsesFrontmostURLAndScopedRows() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf 'https://front.example/current\\n'
            printf '__SPACES_FRONTMOST_TABS__\\n'
            printf '101\t1\tDocs\thttp://localhost:3000/docs\\n'
            printf '202\t2\tAdmin\thttp://localhost:4000/admin\\n'
            """

        try withMockCommands(["osascript": mock]) {
            let snapshot = try ChromeAdapter().tabSnapshot(inWindowIDs: [202, 101, 101, -1, 0])

            XCTAssertEqual(snapshot.frontmostActiveTabURL, "https://front.example/current")
            XCTAssertEqual(snapshot.tabs.map(\.windowID), [101, 202])
            XCTAssertEqual(snapshot.tabs.map(\.tabIndex), [1, 2])
            XCTAssertEqual(snapshot.tabs.map(\.url), ["http://localhost:3000/docs", "http://localhost:4000/admin"])

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set requestedWindowIDs to {\"101\", \"202\"}"))
            XCTAssertTrue(script.contains("set frontmostURL to URL of active tab of front window"))
            XCTAssertTrue(script.contains("return frontmostURL &"))
        }
    }

    func testTabSnapshotInWindowIDsReturnsEmptyWithoutAppleScriptForEmptyInput() throws {
        let mock = """
            #!/bin/sh
            exit 99
            """

        try withMockCommands(["osascript": mock]) {
            let snapshot = try ChromeAdapter().tabSnapshot(inWindowIDs: [])

            XCTAssertTrue(snapshot.tabs.isEmpty)
            XCTAssertNil(snapshot.frontmostActiveTabURL)
        }
    }

    func testFocusFirstMatchingTabMatchParsesFocusedTab() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '303\t4\tMoved Docs\thttp://localhost:3000/docs\\n'
            """

        try withMockCommands(["osascript": mock]) {
            let match = try ChromeAdapter().focusFirstMatchingTabMatch(
                urlPrefix: "http://localhost:3000", excludingURLPrefixes: ["http://localhost:3000/admin"])

            XCTAssertEqual(match?.windowID, 303)
            XCTAssertEqual(match?.tabIndex, 4)
            XCTAssertEqual(match?.title, "Moved Docs")
            XCTAssertEqual(match?.url, "http://localhost:3000/docs")

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set exactTargetURLs to {\"http://localhost:3000\", \"http://localhost:3000/\"}"))
            XCTAssertTrue(script.contains("set excludedURLPrefixes to {\"http://localhost:3000/admin\"}"))
            XCTAssertTrue(script.contains("repeat with w in windows"))
            XCTAssertTrue(script.contains("set active tab index of w to i"))
            XCTAssertTrue(script.contains("return wid &"))
            let exactRange = try XCTUnwrap(script.range(of: "repeat with exactTargetURL in exactTargetURLs"))
            let prefixRange = try XCTUnwrap(script.range(of: "if u starts with targetURLPrefix then"))
            XCTAssertLessThan(script.distance(from: script.startIndex, to: exactRange.lowerBound), script.distance(from: script.startIndex, to: prefixRange.lowerBound))
        }
    }

    func testFocusMatchingTabInWindowUsesExactPassBeforePrefixFallback() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '1'
            """

        try withMockCommands(["osascript": mock]) {
            XCTAssertTrue(
                try ChromeAdapter().focusMatchingTabInWindow(
                    windowID: 202, urlPrefix: "http://localhost:3000", excludingURLPrefixes: ["http://localhost:3000/admin"]))

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set requestedWindowID to \"202\""))
            XCTAssertTrue(script.contains("set exactTargetURLs to {\"http://localhost:3000\", \"http://localhost:3000/\"}"))
            XCTAssertTrue(script.contains("set excludedURLPrefixes to {\"http://localhost:3000/admin\"}"))
            let exactRange = try XCTUnwrap(script.range(of: "repeat with exactTargetURL in exactTargetURLs"))
            let prefixRange = try XCTUnwrap(script.range(of: "if u starts with targetURLPrefix then"))
            XCTAssertLessThan(script.distance(from: script.startIndex, to: exactRange.lowerBound), script.distance(from: script.startIndex, to: prefixRange.lowerBound))
        }
    }

    func testCloseMatchingTabsInWindowExcludesSiblingPrefixes() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '1'
            """

        try withMockCommands(["osascript": mock]) {
            XCTAssertTrue(
                try ChromeAdapter().closeMatchingTabsInWindow(
                    windowID: 202, urlPrefix: "http://localhost:3000", excludingURLPrefixes: ["http://localhost:3000/admin"]))

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set requestedWindowID to \"202\""))
            XCTAssertTrue(script.contains("set exactTargetURLs to {\"http://localhost:3000\", \"http://localhost:3000/\"}"))
            XCTAssertTrue(script.contains("set excludedURLPrefixes to {\"http://localhost:3000/admin\"}"))
            XCTAssertTrue(script.contains("if excludedMatch is false then set shouldClose to true"))
        }
    }

    func testOpenTabInFirstAvailableWindowReturnsFocusedWindowID() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '202'
            """

        try withMockCommands(["osascript": mock]) {
            let windowID = try ChromeAdapter().openTabInFirstAvailableWindow(
                windowIDs: [202, 101, 202, -1, 0], containingAnyURLPrefix: ["http://localhost:3000", "http://localhost:3000"],
                url: "http://localhost:4000/admin")

            XCTAssertEqual(windowID, 202)

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set requestedWindowIDs to {\"202\", \"101\"}"))
            XCTAssertTrue(script.contains("set workspaceURLPrefixes to {\"http://localhost:3000\"}"))
            XCTAssertTrue(script.contains("if existingURL starts with (workspaceURLPrefix as string) then"))
            XCTAssertTrue(script.contains("make new tab at end of tabs of w"))
            XCTAssertTrue(script.contains("set active tab index of w to count of tabs of w"))
        }
    }

    func testOpenTabInFirstAvailableWindowReturnsNilWithoutAppleScriptForEmptyInput() throws {
        let mock = """
            #!/bin/sh
            exit 99
            """

        try withMockCommands(["osascript": mock]) {
            XCTAssertNil(
                try ChromeAdapter().openTabInFirstAvailableWindow(
                    windowIDs: [], containingAnyURLPrefix: ["http://localhost:3000"], url: "http://localhost:4000/admin"))
            XCTAssertNil(
                try ChromeAdapter().openTabInFirstAvailableWindow(windowIDs: [202], containingAnyURLPrefix: [], url: "http://localhost:4000/admin"))
        }
    }
}

private func shellQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }
