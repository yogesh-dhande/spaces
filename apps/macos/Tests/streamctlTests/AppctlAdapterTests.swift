import Foundation
import XCTest
import appctl

final class AppctlAdapterTests: XCTestCase {
    // Tests yabai adapter queries validation and window operations by arranging representative inputs and asserting the expected result.
    func testYabaiAdapterQueriesValidationAndWindowOperations() throws {
        // Mocked dependency: `yabai` CLI.
        // Why: exercise JSON parsing and adapter control-flow deterministically without requiring a running window manager.
        // Remaining risk: does not validate real-world yabai output variants, timing, permissions, or window lifecycle races.
        try withMockCommands(["yabai": Self.yabaiMockScript]) {
            let adapter = YabaiAdapter()
            XCTAssertTrue(adapter.isAvailable())

            let displays = try adapter.listDisplays()
            XCTAssertEqual(displays.map(\.index), [1, 2])

            let spaces = try adapter.listSpaces()
            XCTAssertEqual(spaces.count, 2)
            let validation = try adapter.validate(displayIndex: 1, spaceIndex: 2)
            XCTAssertTrue(validation.displayExists)
            XCTAssertTrue(validation.spaceExists)
            let missingValidation = try adapter.validate(displayIndex: 9, spaceIndex: 9)
            XCTAssertFalse(missingValidation.displayExists)
            XCTAssertFalse(missingValidation.spaceExists)

            let allWindows = try adapter.listWindows()
            XCTAssertEqual(allWindows.count, 2)
            let oneSpace = try adapter.listWindows(spaceIndex: 1)
            XCTAssertEqual(oneSpace.count, 1)

            let focused = try adapter.focusedWindow()
            XCTAssertEqual(focused?.id, 101)

            XCTAssertTrue(try adapter.focusWindow(id: 101))
            XCTAssertFalse(try adapter.focusWindow(id: 999))
            XCTAssertTrue(try adapter.windowExists(id: 202))
            XCTAssertFalse(try adapter.windowExists(id: 999))

            XCTAssertNoThrow(try adapter.minimizeWindow(id: 101))
            XCTAssertNoThrow(try adapter.closeWindow(id: 101))
        }
    }

    // Tests yabai adapter returns nil when focused window query fails by arranging representative inputs and asserting the expected result.
    func testYabaiAdapterReturnsNilWhenFocusedWindowQueryFails() throws {
        // Mocked dependency: focused-window query failure path from `yabai`.
        // Why: guarantee the adapter's "return nil on failure" behavior without forcing a real focus-state failure.
        // Remaining risk: real error messages and transient failures from yabai are broader than this single simulated case.
        try withMockCommands(["yabai": Self.yabaiMockScript]) {
            try withEnv(name: "YABAI_FAIL_FOCUSED", value: "1") {
                let adapter = YabaiAdapter()
                XCTAssertNil(try adapter.focusedWindow())
            }
        }
    }

    // Tests chrome, iTerm, and Ghostty adapters parse AppleScript output by arranging representative inputs and asserting the expected result.
    func testChromeITermAndGhosttyAdaptersParseAppleScriptOutput() throws {
        // Mocked dependency: `osascript` command output for Chrome/iTerm automation.
        // Why: verify script parsing and adapter logic in a hermetic environment.
        // Remaining risk: does not execute against actual app scripting dictionaries or app availability/version differences.
        try withMockCommands(["osascript": Self.osaScriptSuccessMock]) {
            let chrome = ChromeAdapter()
            XCTAssertTrue(chrome.isAvailable())
            XCTAssertEqual(try chrome.openWindow(url: "https://docs.example.com"), 31)

            let matches = try chrome.windowMatches(forURLPrefix: "https://docs.example.com")
            XCTAssertEqual(matches.count, 2)
            XCTAssertEqual(matches[0].windowID, 11)
            XCTAssertEqual(matches[0].tabIndex, 1)
            XCTAssertEqual(matches[0].title, "Docs")
            XCTAssertEqual(matches[1].url, "https://docs.example.com/page")
            let allTabs = try chrome.allTabs()
            XCTAssertEqual(allTabs.count, 2)
            XCTAssertEqual(allTabs[1].tabIndex, 2)
            XCTAssertEqual(try chrome.tabURL(windowID: 11, tabIndex: 1), "https://docs.example.com")
            XCTAssertNil(try chrome.tabURL(windowID: 12, tabIndex: 1))
            XCTAssertNil(try chrome.tabURL(windowID: 11, tabIndex: 99))
            XCTAssertTrue(try chrome.focusTab(windowID: 11, tabIndex: 1))
            XCTAssertFalse(try chrome.focusTab(windowID: 12, tabIndex: 1))
            XCTAssertFalse(try chrome.focusTab(windowID: 11, tabIndex: 99))
            XCTAssertTrue(try chrome.focusTab(forExactURL: "https://docs.example.com"))
            XCTAssertTrue(try chrome.focusTab(forExactURL: "https://docs.example.com", windowID: 11))
            XCTAssertFalse(try chrome.focusTab(forExactURL: "https://docs.example.com", windowID: 12))
            XCTAssertFalse(try chrome.focusTab(forExactURL: "https://missing.example.com"))
            XCTAssertFalse(try chrome.focusTab(forExactURL: "https://missing.example.com", windowID: 11))
            XCTAssertTrue(try chrome.focusTab(forURLPrefix: "https://docs.example.com"))
            XCTAssertTrue(try chrome.focusTab(forURLPrefix: "https://docs.example.com", windowID: 11))
            XCTAssertFalse(try chrome.focusTab(forURLPrefix: "https://docs.example.com", windowID: 12))
            XCTAssertFalse(try chrome.focusTab(forURLPrefix: "https://missing.example.com"))
            XCTAssertFalse(try chrome.focusTab(forURLPrefix: "https://missing.example.com", windowID: 11))
            XCTAssertTrue(try chrome.closeTabs(forExactURL: "https://docs.example.com"))
            XCTAssertTrue(try chrome.closeTabs(forExactURL: "https://docs.example.com", windowID: 11))
            XCTAssertFalse(try chrome.closeTabs(forExactURL: "https://docs.example.com", windowID: 12))
            XCTAssertFalse(try chrome.closeTabs(forExactURL: "https://missing.example.com"))
            XCTAssertFalse(try chrome.closeTabs(forExactURL: "https://missing.example.com", windowID: 11))
            XCTAssertTrue(try chrome.closeTabs(forURLPrefix: "https://docs.example.com"))
            XCTAssertTrue(try chrome.closeTabs(forURLPrefix: "https://docs.example.com", windowID: 11))
            XCTAssertFalse(try chrome.closeTabs(forURLPrefix: "https://docs.example.com", windowID: 12))
            XCTAssertFalse(try chrome.closeTabs(forURLPrefix: "https://missing.example.com"))
            XCTAssertFalse(try chrome.closeTabs(forURLPrefix: "https://missing.example.com", windowID: 11))
            XCTAssertEqual(try chrome.frontmostActiveTabURL(), "https://docs.example.com")

            let iterm = Iterm2Adapter()
            XCTAssertTrue(iterm.isAvailable())
            let window = try iterm.openWindowAndRun(command: "echo \"hi\"")
            XCTAssertEqual(window.id, 77)
            XCTAssertEqual(window.sessionID, "session-77")
            XCTAssertEqual(window.tabIndex, 2)
            let itermTerminalAdapter: any TerminalAdapter = iterm
            let itermLaunch = try itermTerminalAdapter.openWindowAndRun(command: "echo \"hi\"", cwd: "/tmp", background: false)
            XCTAssertEqual(itermLaunch.fallbackWindowID, 77)
            XCTAssertEqual(itermLaunch.terminalID, "session-77")
            XCTAssertEqual(itermLaunch.containerID, "77")
            XCTAssertEqual(itermLaunch.tabIndex, 2)
            XCTAssertTrue(
                try itermTerminalAdapter.focusTrackedTerminal(
                    TerminalFocusTarget(terminalID: "session-77", windowID: 77, tabIndex: 2)))
            XCTAssertNoThrow(try iterm.runInWindow(id: 77, command: "pwd"))
            XCTAssertNoThrow(try iterm.closeWindow(id: 77))
            XCTAssertTrue(try iterm.closeSessionOrTab(preferredSessionID: "session-77", tabIndex: 2, windowID: 77))
            XCTAssertTrue(try iterm.focusSessionOrTab(preferredSessionID: "session-77", tabIndex: 2, windowID: 77))

            let ghostty = GhosttyAdapter()
            XCTAssertTrue(ghostty.isAvailable())
            let ghosttyWindow = try ghostty.openWindowAndRun(command: "echo hi", cwd: "/tmp")
            XCTAssertEqual(ghosttyWindow.windowID, "ghostty-window-1")
            XCTAssertEqual(ghosttyWindow.tabID, "ghostty-tab-1")
            XCTAssertEqual(ghosttyWindow.terminalID, "ghostty-terminal-1")
            let ghosttyTerminalAdapter: any TerminalAdapter = ghostty
            let ghosttyLaunch = try ghosttyTerminalAdapter.openWindowAndRun(command: "echo hi", cwd: "/tmp", background: false)
            XCTAssertNil(ghosttyLaunch.fallbackWindowID)
            XCTAssertEqual(ghosttyLaunch.terminalID, "ghostty-terminal-1")
            XCTAssertEqual(ghosttyLaunch.containerID, "ghostty-window-1")
            XCTAssertTrue(
                try ghosttyTerminalAdapter.focusTrackedTerminal(
                    TerminalFocusTarget(terminalID: "ghostty-terminal-1", windowID: nil, tabIndex: nil)))
            XCTAssertEqual(try ghosttyTerminalAdapter.listLiveTerminalIDs(), ["ghostty-terminal-1"])
            XCTAssertEqual(try ghostty.focusTerminal(id: "ghostty-terminal-1"), "ghostty-window-1")
            XCTAssertNoThrow(try ghostty.closeWindow(id: "ghostty-window-1"))
            XCTAssertEqual(try ghostty.listWindowTabAndTerminalIDs().count, 1)
        }
    }

    // Tests iTerm session focus activates the app before selecting the target session by arranging representative inputs and asserting the expected result.
    func testItermSessionFocusActivatesBeforeSelectingTargetSession() throws {
        // Mocked dependency: `osascript` verifier for the generated iTerm focus AppleScript.
        // Why: lock in the activation ordering needed to reliably front iTerm when switching from a browser to a terminal session.
        // Remaining risk: real iTerm AppleScript behavior can still vary by app version or OS automation quirks.
        try withMockCommands(["osascript": Self.osaScriptSessionFocusActivationMock]) {
            let iterm = Iterm2Adapter()
            XCTAssertTrue(try iterm.focusSessionOrTab(preferredSessionID: "session-77", tabIndex: 2, windowID: 77))
        }
    }

    // Tests apple script run throws on failure by arranging representative inputs and asserting the expected result.
    func testAppleScriptRunThrowsOnFailure() throws {
        // Mocked dependency: failing `osascript`.
        // Why: force deterministic AppleScript error propagation.
        // Remaining risk: only one failure shape is covered; localized/structured osascript errors remain untested.
        try withMockCommands(["osascript": Self.osaScriptFailureMock]) { XCTAssertThrowsError(try AppleScript.run("FAIL_APPLESCRIPT")) }
    }

    private func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
        // Mock mechanism: PATH shim that injects executable stubs ahead of system binaries.
        // Why: keep tests fast and deterministic while targeting adapter behavior instead of external tools.
        // Remaining risk: integration with real binaries is not validated here; that belongs in smoke/e2e testing.
        let directory = try makeTempDirectory()
        for (name, script) in commands {
            let file = directory.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        sharedPathMutationLock.lock()
        defer { sharedPathMutationLock.unlock() }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let updatedPath = originalPath.isEmpty ? directory.path : "\(directory.path):\(originalPath)"
        setenv("PATH", updatedPath, 1)
        defer { setenv("PATH", originalPath, 1) }

        try run()
    }

    private func withEnv(name: String, value: String, run: () throws -> Void) throws {
        let original = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let original { setenv(name, original, 1) } else { unsetenv(name) } }
        try run()
    }

    private static let yabaiMockScript = """
        #!/bin/bash
        # Mock contract for YabaiAdapter tests:
        # - Returns stable JSON payloads for query commands
        # - Supports explicit failure toggles via env vars
        # Residual risk: real yabai schemas may evolve and include fields/ordering not represented here.
        args="$*"
        window_json='{"id":101,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}'

        if [[ "$args" == *"query --displays"* ]]; then
          echo '[{"index":1},{"index":2}]'
          exit 0
        fi

        if [[ "$args" == *"query --spaces"* ]]; then
          echo '[{"index":1,"display":1},{"index":2,"display":2}]'
          exit 0
        fi

        if [[ "$args" == *"query --windows --window"* ]]; then
          if [[ "${YABAI_FAIL_FOCUSED:-}" == "1" ]]; then
            echo "no focused window" >&2
            exit 1
          fi
          echo "$window_json"
          exit 0
        fi

        if [[ "$args" == *"query --windows --space 1"* ]]; then
          echo "[$window_json]"
          exit 0
        fi

        if [[ "$args" == *"query --windows"* ]]; then
          echo "[$window_json,${window_json/101/202}]"
          exit 0
        fi

        if [[ "$args" == *"window --focus 999"* ]]; then
          echo "focus failed" >&2
          exit 1
        fi

        if [[ "$args" == *"window --focus"* || "$args" == *"window --minimize"* || "$args" == *"window --close"* ]]; then
          echo "ok"
          exit 0
        fi

        echo "unhandled command: $args" >&2
        exit 1
        """

    private static let osaScriptSuccessMock = """
        #!/bin/bash
        # Mock contract for AppleScript adapters:
        # - Emulates the subset of AppleScript calls used by ChromeAdapter/Iterm2Adapter
        # - Returns canned IDs/tab listings for parser assertions
        # Residual risk: no validation against real app script behavior, stateful windows/tabs, or permission prompts.
        script="${*: -1}"

        if [[ "$script" == *'tell application "Google Chrome" to version'* ]]; then
          echo "122"
          exit 0
        fi

        if [[ "$script" == *'set URL of active tab of newWindow'* ]]; then
          echo "31"
          exit 0
        fi

        if [[ "$script" == *'set output to ""'* ]]; then
          printf '11\\t1\\tDocs\\thttps://docs.example.com\\n12\\t2\\tDocs 2\\thttps://docs.example.com/page\\n'
          exit 0
        fi

        if [[ "$script" == *'set u to URL of tab requestedTabIndex of w'* ]]; then
          requested_window_id="$(printf '%s\n' "$script" | awk -F'set requestedWindowID to \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -z "$requested_window_id" || "$requested_window_id" != "11" ]]; then
            echo ""
            exit 0
          fi
          if [[ "$script" == *'set requestedTabIndex to 1'* ]]; then
            echo "https://docs.example.com"
          else
            echo ""
          fi
          exit 0
        fi

        if [[ "$script" == *'set requestedTabIndex to'* ]]; then
          requested_window_id="$(printf '%s\n' "$script" | awk -F'set requestedWindowID to \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -z "$requested_window_id" || "$requested_window_id" != "11" ]]; then
            echo "0"
            exit 0
          fi
          if [[ "$script" == *'set requestedTabIndex to 99'* ]]; then
            echo "0"
          else
            echo "1"
          fi
          exit 0
        fi

        if [[ "$script" == *'set tabCount to count of tabs of w'* ]]; then
          requested_window_id="$(printf '%s\n' "$script" | awk -F'set requestedWindowID to \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -n "$requested_window_id" && "$requested_window_id" != "11" ]]; then
            echo "0"
            exit 0
          fi
          if [[ "$script" == *'if id of w is '* ]]; then
            echo "0"
            exit 0
          fi
          if [[ "$script" == *'close tab i of w'* ]]; then
            if [[ "$script" == *'https://missing.example.com'* ]]; then
              echo "0"
            else
              echo "1"
            fi
            exit 0
          fi
          if [[ "$script" == *'https://missing.example.com'* ]]; then
            echo "0"
          else
            echo "1"
          fi
          exit 0
        fi

        if [[ "$script" == *'URL of active tab of front window'* ]]; then
          echo "https://docs.example.com"
          exit 0
        fi

        if [[ "$script" == *'tell application "iTerm2" to version'* ]]; then
          echo "3.5.0"
          exit 0
        fi

        if [[ "$script" == *'tell application id "com.mitchellh.ghostty" to version'* ]]; then
          echo "1.3.1"
          exit 0
        fi

        if [[ "$script" == *'create window with default profile'* ]]; then
          echo "77|session-77|2"
          exit 0
        fi

        if [[ "$script" == *'set targetSessionID to'* && "$script" == *'tell application "iTerm2"'* ]]; then
          if [[ "$script" == *'activate'* || "$script" == *'set current window to w'* ]]; then
            echo "session"
          else
            echo "session"
          fi
          exit 0
        fi

        if [[ "$script" == *'set sessionIDs to {}'* && "$script" == *'tell application "iTerm2"'* ]]; then
          printf 'session-77\nsession-88\n'
          exit 0
        fi

        if [[ "$script" == *'write text'* || "$script" == *'close w'* ]]; then
          echo ""
          exit 0
        fi

        if [[ "$script" == *'tell application id "com.mitchellh.ghostty"'* && "$script" == *'new window with configuration cfg'* ]]; then
          echo 'ghostty-window-1|ghostty-tab-1|ghostty-terminal-1'
          exit 0
        fi

        if [[ "$script" == *'tell terminal id "ghostty-terminal-1" to focus'* ]]; then
          echo 'ghostty-window-1'
          exit 0
        fi

        if [[ "$script" == *'tell window id "ghostty-window-1" to close window'* ]]; then
          echo 'ok'
          exit 0
        fi

        if [[ "$script" == *'repeat with w in windows'* && "$script" == *'com.mitchellh.ghostty'* ]]; then
          printf 'ghostty-window-1|ghostty-tab-1|ghostty-terminal-1\n'
          exit 0
        fi

        echo "unexpected script" >&2
        exit 1
        """

    private static let osaScriptSessionFocusActivationMock = """
        #!/bin/bash
        script="${*: -1}"

        if [[ "$script" == *'tell application "iTerm2" to version'* ]]; then
          echo "3.5.0"
          exit 0
        fi

        if [[ "$script" == *'set targetSessionID to'* && "$script" == *'tell application "iTerm2"'* ]]; then
          activate_line=$(printf '%s\n' "$script" | nl -ba | awk '/^[[:space:]]*[0-9]+[[:space:]]+activate$/ { print $1; exit }')
          select_line=$(printf '%s\n' "$script" | nl -ba | awk '/tell w to select/ { print $1; exit }')
          if [[ -n "$activate_line" && -n "$select_line" && "$activate_line" -lt "$select_line" ]]; then
            echo "session"
            exit 0
          fi
          echo "activate must precede window selection" >&2
          exit 1
        fi

        echo "unexpected script" >&2
        exit 1
        """

    private static let osaScriptFailureMock = """
        #!/bin/bash
        # Failure stub used to force deterministic AppleScript error handling paths.
        # Residual risk: only generic non-zero exit handling is exercised.
        echo "mock failure" >&2
        exit 1
        """
}
