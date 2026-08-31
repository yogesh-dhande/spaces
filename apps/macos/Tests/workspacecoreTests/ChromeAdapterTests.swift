import Foundation
import XCTest
import spacestestsupport

@testable import systembridge

final class ChromeAdapterTests: XCTestCase {
    // Mocked-osascript tests aren't exercising the AppleScript timeout itself; widen it so
    // process-spawn latency on a loaded machine can't trip the production 10s default (#196).
    private func makeAdapter() -> ChromeAdapter { ChromeAdapter(appleScriptTimeoutSeconds: 30) }

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
            let snapshot = try makeAdapter().tabSnapshot(inWindowIDs: [202, 101, 101, -1, 0])

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

    func testTabSnapshotInWindowIDsParsesRowsWhenFrontmostURLIsEmpty() throws {
        let mock = """
            #!/bin/sh
            printf '\\n'
            printf '__SPACES_FRONTMOST_TABS__\\n'
            printf '101\t1\tDocs\thttp://localhost:3000/docs\\n'
            """

        try withMockCommands(["osascript": mock]) {
            let snapshot = try makeAdapter().tabSnapshot(inWindowIDs: [101])

            XCTAssertNil(snapshot.frontmostActiveTabURL)
            XCTAssertEqual(snapshot.tabs.map(\.windowID), [101])
            XCTAssertEqual(snapshot.tabs.map(\.tabIndex), [1])
            XCTAssertEqual(snapshot.tabs.map(\.url), ["http://localhost:3000/docs"])
        }
    }

    func testTabSnapshotInWindowIDsReturnsEmptyWithoutAppleScriptForEmptyInput() throws {
        let mock = """
            #!/bin/sh
            exit 99
            """

        try withMockCommands(["osascript": mock]) {
            let snapshot = try makeAdapter().tabSnapshot(inWindowIDs: [])

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
            let match = try makeAdapter().focusFirstMatchingTabMatch(
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
            XCTAssertLessThan(
                script.distance(from: script.startIndex, to: exactRange.lowerBound),
                script.distance(from: script.startIndex, to: prefixRange.lowerBound))
        }
    }

    // Focusing a browser session must raise only that Chrome window, not every Chrome window.
    // AppleScript's `activate` lifts an app's whole window stack, so the generated script must
    // reorder the target window (`set index of window id … to 1`) and leave the actual activation to Swift
    // (ChromeAdapter.bringChromeForward), which always calls NSRunningApplication.activate(options: [])
    // rather than .activateAllWindows.
    func testFocusFirstMatchingTabMatchRaisesOnlyTargetWindowNotAllChromeWindows() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '303\t4\tMoved Docs\thttp://localhost:3000/docs\\n'
            """

        try withMockCommands(["osascript": mock]) {
            _ = try makeAdapter().focusFirstMatchingTabMatch(urlPrefix: "http://localhost:3000")

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set index of window id wid to 1"))
            let hasBareActivateCommand = script.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "activate" }
            XCTAssertFalse(hasBareActivateCommand, "script must not call AppleScript activate, which would raise every Chrome window")
        }
    }

    // A minimized target window sits in the Dock and shows on no Space, so raising it has to
    // un-minimize it first. Doing that inside the script, immediately before the reorder, puts the
    // window back on the Space it belongs to so the raise can cross to that Space.
    func testFocusFirstMatchingTabMatchUnminimizesTargetWindowBeforeRaisingIt() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '303\t4\tMoved Docs\thttp://localhost:3000/docs\\n'
            """

        try withMockCommands(["osascript": mock]) {
            _ = try makeAdapter().focusFirstMatchingTabMatch(urlPrefix: "http://localhost:3000")

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            assertUnminimizesBeforeRaising(script)
        }
    }

    // Same rule as focusFirstMatchingTabMatch above, scoped to a known window id.
    func testFocusMatchingTabInWindowUnminimizesTargetWindowBeforeRaisingIt() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '1'
            """

        try withMockCommands(["osascript": mock]) {
            _ = try makeAdapter().focusMatchingTabInWindow(windowID: 202, urlPrefix: "http://localhost:3000")

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            assertUnminimizesBeforeRaising(script)
        }
    }

    // Adding a session tab to an already-tracked window raises that existing window, which the user
    // may have minimized, so this path un-minimizes it too.
    func testOpenTabInFirstAvailableWindowUnminimizesTargetWindowBeforeRaisingIt() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '202'
            """

        try withMockCommands(["osascript": mock]) {
            _ = try makeAdapter().openTabInFirstAvailableWindow(
                windowIDs: [202], containingAnyURLPrefix: ["http://localhost:3000"], url: "http://localhost:4000/admin")

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            assertUnminimizesBeforeRaising(script)
        }
    }

    // Chrome activates itself when a tab is created, and that activation raises whichever window
    // Chrome currently has in front, so a tab created before the raise lifts an unrelated Chrome
    // window above Spaces too. The raise must happen first, and everything after it must address
    // the window by id (`window id wid`) rather than through `w`, which aliases another window once
    // the raise renumbers the window list.
    func testOpenTabInFirstAvailableWindowRaisesTargetWindowBeforeCreatingTheTab() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '202'
            """

        try withMockCommands(["osascript": mock]) {
            _ = try makeAdapter().openTabInFirstAvailableWindow(
                windowIDs: [202], containingAnyURLPrefix: ["http://localhost:3000"], url: "http://localhost:4000/admin")

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            let raiseRange = try XCTUnwrap(script.range(of: "set index of window id wid to 1"))
            let makeTabRange = try XCTUnwrap(script.range(of: "make new tab"))
            XCTAssertLessThan(
                script.distance(from: script.startIndex, to: raiseRange.lowerBound),
                script.distance(from: script.startIndex, to: makeTabRange.lowerBound), "the raise must happen before the tab is created")
            XCTAssertTrue(script.contains("make new tab at end of tabs of window id wid"), "the tab must be created in window id wid, not w")
            XCTAssertTrue(script.contains("return wid as string"), "the returned window id must be the one captured before the raise")
        }
    }

    /// Every window raise in `script` must be immediately preceded by un-minimizing that same window,
    /// so a target the user minimized is back on the Space it belongs to before the raise crosses to it.
    /// A raise line reads `set index of <ref> to 1` for some window reference `<ref>` (`window id wid`,
    /// or `window id` with a literal), and the un-minimize line must reference that same `<ref>`.
    private func assertUnminimizesBeforeRaising(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        let lines = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let raisePrefix = "set index of "
        let raiseSuffix = " to 1"
        let raiseIndexes = lines.indices.filter { lines[$0].hasPrefix(raisePrefix) && lines[$0].hasSuffix(raiseSuffix) }
        XCTAssertFalse(raiseIndexes.isEmpty, "script is expected to raise the target window", file: file, line: line)
        for raiseIndex in raiseIndexes {
            let ref = lines[raiseIndex].dropFirst(raisePrefix.count).dropLast(raiseSuffix.count)
            XCTAssertEqual(
                raiseIndex > 0 ? lines[raiseIndex - 1] : "", "set minimized of \(ref) to false",
                "each `set index of \(ref) to 1` must follow un-minimizing that window", file: file, line: line)
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
                try makeAdapter().focusMatchingTabInWindow(
                    windowID: 202, urlPrefix: "http://localhost:3000", excludingURLPrefixes: ["http://localhost:3000/admin"]))

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set requestedWindowID to \"202\""))
            XCTAssertTrue(script.contains("set exactTargetURLs to {\"http://localhost:3000\", \"http://localhost:3000/\"}"))
            XCTAssertTrue(script.contains("set excludedURLPrefixes to {\"http://localhost:3000/admin\"}"))
            let exactRange = try XCTUnwrap(script.range(of: "repeat with exactTargetURL in exactTargetURLs"))
            let prefixRange = try XCTUnwrap(script.range(of: "if u starts with targetURLPrefix then"))
            XCTAssertLessThan(
                script.distance(from: script.startIndex, to: exactRange.lowerBound),
                script.distance(from: script.startIndex, to: prefixRange.lowerBound))
        }
    }

    // Same rule as focusFirstMatchingTabMatch above, scoped to a known window id: raise only the
    // target Chrome window, never every Chrome window.
    func testFocusMatchingTabInWindowRaisesOnlyTargetWindowNotAllChromeWindows() throws {
        let scriptLog = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-adapter-\(UUID().uuidString).applescript")
        let mock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(scriptLog.path))
            printf '1'
            """

        try withMockCommands(["osascript": mock]) {
            _ = try makeAdapter().focusMatchingTabInWindow(windowID: 202, urlPrefix: "http://localhost:3000")

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set index of window id 202 to 1"))
            let hasBareActivateCommand = script.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "activate" }
            XCTAssertFalse(hasBareActivateCommand, "script must not call AppleScript activate, which would raise every Chrome window")
        }
    }

    // The post-activation re-raise is what crosses to the Space holding the target window. It runs with
    // Chrome already active, so it only has to reorder the target: an AppleScript `activate` would lift
    // Chrome's whole window stack over the Spaces window, and a `delay` would stall the focus path for
    // a settle the raise does not need.
    func testRaiseWindowScriptReordersTargetWindowWithoutActivatingOrDelaying() {
        let script = ChromeAdapter.raiseWindowScript(windowID: 303)

        XCTAssertTrue(script.contains("set index of window id 303 to 1"))
        XCTAssertTrue(script.contains("set minimized of window id 303 to false"))
        let hasBareActivateCommand = script.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "activate" }
        XCTAssertFalse(hasBareActivateCommand, "script must not call AppleScript activate, which would raise every Chrome window")
        XCTAssertFalse(script.contains("delay"), "the re-raise needs no settle delay after activation")
    }

    // `w` is an index-based reference into `windows`, so it aliases a different window once a raise
    // renumbers the window list: a raise expressed through `w` is a latent wrong-window bug. Every
    // raise site must address the window by id instead.
    func testEveryWindowRaiseAddressesTheWindowByID() throws {
        var scripts: [String] = []

        let focusMatchingTabInWindowLog = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chrome-adapter-\(UUID().uuidString).applescript")
        let focusMatchingTabInWindowMock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(focusMatchingTabInWindowLog.path))
            printf '1'
            """
        try withMockCommands(["osascript": focusMatchingTabInWindowMock]) {
            _ = try makeAdapter().focusMatchingTabInWindow(windowID: 202, urlPrefix: "http://localhost:3000")
        }
        scripts.append(try String(contentsOf: focusMatchingTabInWindowLog, encoding: .utf8))

        let focusFirstMatchingTabMatchLog = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chrome-adapter-\(UUID().uuidString).applescript")
        let focusFirstMatchingTabMatchMock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(focusFirstMatchingTabMatchLog.path))
            printf '303\t4\tMoved Docs\thttp://localhost:3000/docs\\n'
            """
        try withMockCommands(["osascript": focusFirstMatchingTabMatchMock]) {
            _ = try makeAdapter().focusFirstMatchingTabMatch(urlPrefix: "http://localhost:3000")
        }
        scripts.append(try String(contentsOf: focusFirstMatchingTabMatchLog, encoding: .utf8))

        let openTabInFirstAvailableWindowLog = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chrome-adapter-\(UUID().uuidString).applescript")
        let openTabInFirstAvailableWindowMock = """
            #!/bin/sh
            printf '%s' "$2" > \(shellQuoted(openTabInFirstAvailableWindowLog.path))
            printf '202'
            """
        try withMockCommands(["osascript": openTabInFirstAvailableWindowMock]) {
            _ = try makeAdapter().openTabInFirstAvailableWindow(
                windowIDs: [202], containingAnyURLPrefix: ["http://localhost:3000"], url: "http://localhost:4000/admin")
        }
        scripts.append(try String(contentsOf: openTabInFirstAvailableWindowLog, encoding: .utf8))

        scripts.append(ChromeAdapter.raiseWindowScript(windowID: 303))

        for script in scripts {
            XCTAssertFalse(
                script.contains("set index of w to 1"), "a raise through `w` aliases a different window once the raise renumbers the window list")
            XCTAssertTrue(script.contains("set index of window id"), "expected a raise addressing the window by id")
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
                try makeAdapter().closeMatchingTabsInWindow(
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
            let windowID = try makeAdapter().openTabInFirstAvailableWindow(
                windowIDs: [202, 101, 202, -1, 0], containingAnyURLPrefix: ["http://localhost:3000", "http://localhost:3000"],
                url: "http://localhost:4000/admin")

            XCTAssertEqual(windowID, 202)

            let script = try String(contentsOf: scriptLog, encoding: .utf8)
            XCTAssertTrue(script.contains("set requestedWindowIDs to {\"202\", \"101\"}"))
            XCTAssertTrue(script.contains("set workspaceURLPrefixes to {\"http://localhost:3000\"}"))
            XCTAssertTrue(script.contains("if existingURL starts with (workspaceURLPrefix as string) then"))
            XCTAssertTrue(script.contains("make new tab at end of tabs of window id wid"))
            XCTAssertTrue(script.contains("set active tab index of window id wid to count of tabs of window id wid"))
        }
    }

    func testOpenTabInFirstAvailableWindowReturnsNilWithoutAppleScriptForEmptyInput() throws {
        let mock = """
            #!/bin/sh
            exit 99
            """

        try withMockCommands(["osascript": mock]) {
            XCTAssertNil(
                try makeAdapter().openTabInFirstAvailableWindow(
                    windowIDs: [], containingAnyURLPrefix: ["http://localhost:3000"], url: "http://localhost:4000/admin"))
            XCTAssertNil(
                try makeAdapter().openTabInFirstAvailableWindow(windowIDs: [202], containingAnyURLPrefix: [], url: "http://localhost:4000/admin"))
        }
    }
}

private func shellQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }
