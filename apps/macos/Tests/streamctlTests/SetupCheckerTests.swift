import Foundation
import XCTest
import appctl

final class SetupCheckerTests: XCTestCase {

    // MARK: - iTerm2 check

    // Tests isIterm2Installed returns true when iTerm2 adapter reports availability.
    func testIsIterm2Installed_available() {
        let mock = MockAvailableIterm2()
        mock.availableResult = true
        let checker = SetupChecker(iterm2: mock)
        XCTAssertTrue(checker.run(.iterm2Installed))
    }

    // Tests isIterm2Installed returns false when iTerm2 adapter reports unavailability.
    func testIsIterm2Installed_unavailable() {
        let mock = MockAvailableIterm2()
        mock.availableResult = false
        let checker = SetupChecker(iterm2: mock)
        XCTAssertFalse(checker.run(.iterm2Installed))
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

    // Tests isYabaiServiceRunning returns true when query --spaces returns valid JSON array.
    func testIsYabaiServiceRunning_success() throws {
        let script = """
            #!/bin/bash
            if [[ "$*" == *"query --spaces"* ]]; then
              echo '[{"index":1}]'
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

    // Tests isYabaiServiceRunning returns false when query --spaces fails.
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
            if [[ "$*" == *"query --spaces"* ]]; then echo '[{"index":1}]'; exit 0; fi
            if [[ "$*" == *"query --windows"* ]]; then echo '[{"id":1}]'; exit 0; fi
            exit 1
            """
        let mock = MockAvailableIterm2()
        mock.availableResult = true
        try withMockCommands(["yabai": yabaiScript]) {
            let checker = SetupChecker(iterm2: mock)
            let results = checker.runAll()
            XCTAssertEqual(results.count, 4)
            XCTAssertTrue(results.allSatisfy(\.passed))
            let firstFail = results.firstIndex(where: { !$0.passed })
            XCTAssertNil(firstFail)
        }
    }

    // Tests runAll reports the first failing step correctly.
    func testRunAll_firstFails() throws {
        let mock = MockAvailableIterm2()
        mock.availableResult = false
        // yabai not relevant since first check fails
        let checker = SetupChecker(iterm2: mock)
        let results = checker.runAll()
        XCTAssertFalse(results[0].passed)
        XCTAssertEqual(results[0].id, .iterm2Installed)
        let firstFailIndex = results.firstIndex(where: { !$0.passed })
        XCTAssertEqual(firstFailIndex, 0)
    }

    // MARK: - Helpers

    private func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
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
}

// MARK: - Test doubles

private final class MockAvailableIterm2: Iterm2Adapter, @unchecked Sendable {
    var availableResult = false
    override func isAvailable() -> Bool { availableResult }
}
