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
}

private func shellQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }
