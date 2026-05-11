import Foundation
import XCTest
import systembridge

final class SetupCheckerTests: XCTestCase {

    // MARK: - iTerm2 check

    // Tests terminalInstalled returns true when iTerm2 adapter reports availability.
    func testTerminalInstalled_available() {
        let mock = MockAvailableIterm2()
        mock.availableResult = true
        let checker = SetupChecker(iterm2: mock, ghostty: MockAvailableGhostty())
        XCTAssertTrue(checker.run(.terminalInstalled))
    }

    // Tests terminalInstalled still passes when external terminal apps are unavailable because Spaces includes a built-in host.
    func testTerminalInstalled_passesWithBuiltInSpacesHostWhenExternalAppsUnavailable() {
        let mock = MockAvailableIterm2()
        mock.availableResult = false
        let ghostty = MockAvailableGhostty()
        ghostty.availableResult = false
        let checker = SetupChecker(iterm2: mock, ghostty: ghostty)
        XCTAssertTrue(checker.run(.terminalInstalled))
    }

    // Tests the terminal prerequisite passes when Ghostty is available even if iTerm2 is not.
    func testTerminalInstalled_passesWhenGhosttyAvailable() {
        let iterm = MockAvailableIterm2()
        iterm.availableResult = false
        let ghostty = MockAvailableGhostty()
        ghostty.availableResult = true
        let checker = SetupChecker(iterm2: iterm, ghostty: ghostty)
        XCTAssertTrue(checker.run(.terminalInstalled))
    }

    // Tests host-specific availability uses the same shared setup-check path as terminalInstalled.
    func testIsTerminalHostAvailable_namedIterm2() {
        let iterm = MockAvailableIterm2()
        iterm.availableResult = true
        let ghostty = MockAvailableGhostty()
        ghostty.availableResult = false
        let checker = SetupChecker(iterm2: iterm, ghostty: ghostty)
        XCTAssertTrue(checker.isTerminalHostAvailable(named: "iterm2"))
        XCTAssertFalse(checker.isTerminalHostAvailable(named: "ghostty"))
    }

    // Tests unknown host names fail closed.
    func testIsTerminalHostAvailable_unknownHost() {
        let checker = SetupChecker(iterm2: MockAvailableIterm2(), ghostty: MockAvailableGhostty())
        XCTAssertFalse(checker.isTerminalHostAvailable(named: "alacritty"))
    }

    // MARK: - tmux check

    // Tests isTmuxInstalled returns true when the tmux adapter reports availability.
    func testIsTmuxInstalled_available() {
        let mock = MockAvailableTmux()
        mock.availableResult = true
        let checker = SetupChecker(tmux: mock)
        XCTAssertTrue(checker.run(.tmuxInstalled))
    }

    // Tests isTmuxInstalled returns false when the tmux adapter reports unavailability.
    func testIsTmuxInstalled_unavailable() {
        let mock = MockAvailableTmux()
        mock.availableResult = false
        let checker = SetupChecker(tmux: mock)
        XCTAssertFalse(checker.run(.tmuxInstalled))
    }

    // MARK: - yabai installed check

    // Tests isYabaiInstalled returns true when yabai --version exits 0.
    func testIsYabaiInstalled_success() throws {
        try withMockCommands(["yabai": "#!/bin/bash\necho 'yabai 7.0.0'\nexit 0"]) {
            let checker = SetupChecker()
            XCTAssertTrue(checker.run(.yabaiInstalled))
        }
    }

    // Tests isYabaiInstalled returns false when yabai --version exits non-zero.
    func testIsYabaiInstalled_failure() throws {
        try withMockCommands(["yabai": "#!/bin/bash\necho 'not found' >&2\nexit 1"]) {
            let checker = SetupChecker()
            XCTAssertFalse(checker.run(.yabaiInstalled))
        }
    }

    // MARK: - yabai service running check

    // Tests isYabaiServiceRunning returns true when signal --list succeeds.
    func testIsYabaiServiceRunning_success() throws {
        let script = """
            #!/bin/bash
            if [[ "$*" == *"signal --list"* ]]; then
              echo '[]'
              exit 0
            fi
            echo 'unhandled' >&2
            exit 1
            """
        try withMockCommands(["yabai": script]) {
            let checker = SetupChecker()
            XCTAssertTrue(checker.run(.yabaiServiceRunning))
        }
    }

    // Tests isYabaiServiceRunning returns false when signal --list fails.
    func testIsYabaiServiceRunning_failure() throws {
        let script = """
            #!/bin/bash
            echo 'service not running' >&2
            exit 1
            """
        try withMockCommands(["yabai": script]) {
            let checker = SetupChecker()
            XCTAssertFalse(checker.run(.yabaiServiceRunning))
        }
    }

    // MARK: - yabai accessibility check

    // Tests hasYabaiAccessibility returns true when query --windows returns non-empty JSON array.
    func testHasYabaiAccessibility_granted() throws {
        let script = """
            #!/bin/bash
            if [[ "$*" == *"query --windows"* ]]; then
              echo '[{"id":1,"pid":11,"app":"Finder"}]'
              exit 0
            fi
            echo 'unhandled' >&2
            exit 1
            """
        try withMockCommands(["yabai": script]) {
            let checker = SetupChecker()
            XCTAssertTrue(checker.run(.yabaiAccessibility))
        }
    }

    // Tests hasYabaiAccessibility returns false when query --windows returns empty array (AX denied).
    func testHasYabaiAccessibility_denied() throws {
        let script = """
            #!/bin/bash
            if [[ "$*" == *"query --windows"* ]]; then
              echo '[]'
              exit 0
            fi
            echo 'unhandled' >&2
            exit 1
            """
        try withMockCommands(["yabai": script]) {
            let checker = SetupChecker()
            XCTAssertFalse(checker.run(.yabaiAccessibility))
        }
    }

    // Tests hasYabaiAccessibility returns false when query --windows fails (service not running).
    func testHasYabaiAccessibility_queryFails() throws {
        let script = """
            #!/bin/bash
            echo 'error' >&2
            exit 1
            """
        try withMockCommands(["yabai": script]) {
            let checker = SetupChecker()
            XCTAssertFalse(checker.run(.yabaiAccessibility))
        }
    }

    // MARK: - runAll

    // Tests runAll returns all passing when all checks pass.
    func testRunAll_allPass() throws {
        let yabaiScript = """
            #!/bin/bash
            if [[ "$*" == *"--version"* ]]; then echo 'yabai 7.0.0'; exit 0; fi
            if [[ "$*" == *"signal --list"* ]]; then echo '[]'; exit 0; fi
            if [[ "$*" == *"query --windows"* ]]; then echo '[{"id":1}]'; exit 0; fi
            exit 1
            """
        try withMockCommands(["yabai": yabaiScript]) {
            let tmux = MockAvailableTmux()
            tmux.availableResult = true
            let iterm = MockAvailableIterm2()
            iterm.availableResult = true
            let checker = SetupChecker(iterm2: iterm, ghostty: MockAvailableGhostty(), tmux: tmux)
            let results = checker.runAll()
            XCTAssertEqual(results.count, 5)
            XCTAssertTrue(results.allSatisfy(\.passed))
            let firstFail = results.firstIndex(where: { !$0.passed })
            XCTAssertNil(firstFail)
        }
    }

    // Tests runAll reports the first failing external dependency after the built-in terminal prerequisite passes.
    func testRunAll_firstFails() throws {
        let mock = MockAvailableIterm2()
        mock.availableResult = false
        let tmux = MockAvailableTmux()
        tmux.availableResult = false
        let checker = SetupChecker(iterm2: mock, ghostty: MockAvailableGhostty(), tmux: tmux)
        let results = checker.runAll()
        XCTAssertTrue(results[0].passed)
        XCTAssertEqual(results[0].id, .terminalInstalled)
        let firstFailIndex = results.firstIndex(where: { !$0.passed })
        XCTAssertEqual(firstFailIndex, 1)
        XCTAssertEqual(results[firstFailIndex ?? 0].id, .tmuxInstalled)
    }

    // Tests runStartupBlockingChecks skips the deferred yabai readiness checks.
    func testRunStartupBlockingChecks_skipsDeferredYabaiChecks() throws {
        let yabaiScript = """
            #!/bin/bash
            if [[ "$*" == *"--version"* ]]; then echo 'yabai 7.0.0'; exit 0; fi
            echo "unexpected command: $*" >&2
            exit 1
            """
        try withMockCommands(["yabai": yabaiScript]) {
            let tmux = MockAvailableTmux()
            tmux.availableResult = true
            let checker = SetupChecker(iterm2: MockAvailableIterm2(), ghostty: MockAvailableGhostty(), tmux: tmux)
            let results = checker.runStartupBlockingChecks()
            XCTAssertEqual(results.map(\.id), [.yabaiInstalled])
            XCTAssertTrue(results.allSatisfy(\.passed))
        }
    }

    func testRunStartupBlockingChecksDoesNotRequireTmux() throws {
        let yabaiScript = """
            #!/bin/bash
            if [[ "$*" == *"--version"* ]]; then echo 'yabai 7.0.0'; exit 0; fi
            """
        try withMockCommands(["yabai": yabaiScript]) {
            let tmux = MockAvailableTmux()
            tmux.availableResult = false
            let checker = SetupChecker(iterm2: MockAvailableIterm2(), ghostty: MockAvailableGhostty(), tmux: tmux)
            let results = checker.runStartupBlockingChecks()
            XCTAssertEqual(results.map(\.id), [.yabaiInstalled])
            XCTAssertTrue(results.allSatisfy(\.passed))
        }
    }
}

// MARK: - Test doubles

private final class MockAvailableIterm2: Iterm2Adapter, @unchecked Sendable {
    var availableResult = false
    override func isAvailable() -> Bool { availableResult }
}

private final class MockAvailableGhostty: GhosttyAdapter, @unchecked Sendable {
    var availableResult = false
    override func isAvailable() -> Bool { availableResult }
}

private final class MockAvailableTmux: TmuxAdapter, @unchecked Sendable {
    var availableResult = false
    override func isAvailable() -> Bool { availableResult }
}
