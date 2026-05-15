import Foundation
import XCTest
import systembridge

final class SetupCheckerTests: XCTestCase {
    func testIsYabaiInstalledSuccess() throws {
        try withMockCommands(["yabai": "#!/bin/bash\necho 'yabai 7.0.0'\nexit 0"]) {
            let checker = SetupChecker()
            XCTAssertTrue(checker.run(.yabaiInstalled))
        }
    }

    func testIsYabaiInstalledFailure() throws {
        try withMockCommands(["yabai": "#!/bin/bash\necho 'not found' >&2\nexit 1"]) {
            let checker = SetupChecker()
            XCTAssertFalse(checker.run(.yabaiInstalled))
        }
    }

    func testIsYabaiServiceRunningSuccess() throws {
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

    func testIsYabaiServiceRunningFailure() throws {
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

    func testHasYabaiAccessibilityGranted() throws {
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

    func testHasYabaiAccessibilityDenied() throws {
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

    func testHasYabaiAccessibilityQueryFails() throws {
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

    func testRunAllAllPass() throws {
        let yabaiScript = """
            #!/bin/bash
            if [[ "$*" == *"--version"* ]]; then echo 'yabai 7.0.0'; exit 0; fi
            if [[ "$*" == *"signal --list"* ]]; then echo '[]'; exit 0; fi
            if [[ "$*" == *"query --windows"* ]]; then echo '[{"id":1}]'; exit 0; fi
            exit 1
            """
        try withMockCommands(["yabai": yabaiScript]) {
            let checker = SetupChecker()
            let results = checker.runAll()
            XCTAssertEqual(results.map(\.id), [.yabaiInstalled, .yabaiServiceRunning, .yabaiAccessibility])
            XCTAssertTrue(results.allSatisfy(\.passed))
        }
    }

    func testRunAllFirstFailureIsYabaiInstalledWhenMissing() throws {
        try withMockCommands(["yabai": "#!/bin/bash\nexit 1"]) {
            let checker = SetupChecker()
            let results = checker.runAll()
            let firstFailIndex = results.firstIndex(where: { !$0.passed })
            XCTAssertEqual(firstFailIndex, 0)
            XCTAssertEqual(results[firstFailIndex ?? 0].id, .yabaiInstalled)
        }
    }

    func testRunStartupBlockingChecksSkipsDeferredYabaiChecks() throws {
        let yabaiScript = """
            #!/bin/bash
            if [[ "$*" == *"--version"* ]]; then echo 'yabai 7.0.0'; exit 0; fi
            echo "unexpected command: $*" >&2
            exit 1
            """
        try withMockCommands(["yabai": yabaiScript]) {
            let checker = SetupChecker()
            let results = checker.runStartupBlockingChecks()
            XCTAssertEqual(results.map(\.id), [.yabaiInstalled])
            XCTAssertTrue(results.allSatisfy(\.passed))
        }
    }
}
