import Foundation
import XCTest
import systembridge

final class ShellTests: XCTestCase {
    // Tests run returns exit status by arranging representative inputs and asserting the expected result.
    func testRunReturnsExitStatus() throws {
        let status = try Shell.run(["sh", "-lc", "exit 7"])
        XCTAssertEqual(status, 7)
    }

    // Tests run uses working directory by arranging representative inputs and asserting the expected result.
    func testRunUsesWorkingDirectory() throws {
        let directory = try makeTempDirectory()
        let output = try Shell.runAndCapture(["pwd"], cwd: directory.path)
        let reported = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        let expected = directory.resolvingSymlinksInPath().path
        XCTAssertEqual(reported, expected)
    }

    // Tests run and capture returns stdout by arranging representative inputs and asserting the expected result.
    func testRunAndCaptureReturnsStdout() throws {
        let output = try Shell.runAndCapture(["sh", "-lc", "printf 'hello'"])
        XCTAssertEqual(output, "hello")
    }

    // Tests run and capture throws with stderr on failure by arranging representative inputs and asserting the expected result.
    func testRunAndCaptureThrowsWithStderrOnFailure() throws {
        XCTAssertThrowsError(try Shell.runAndCapture(["sh", "-lc", "echo boom >&2; exit 9"])) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "spaces.shell")
            XCTAssertEqual(nsError.code, 9)
            XCTAssertTrue((nsError.localizedDescription).contains("boom"))
        }
    }

    // Tests run throws for empty command by arranging representative inputs and asserting the expected result.
    func testRunThrowsForEmptyCommand() {
        XCTAssertThrowsError(try Shell.run([])) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "spaces.shell")
        }
    }

    // Tests runAndCapture throws for empty command by arranging representative inputs and asserting the expected result.
    func testRunAndCaptureThrowsForEmptyCommand() {
        XCTAssertThrowsError(try Shell.runAndCapture([])) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "spaces.shell")
        }
    }

    // Tests AppleScript.run fails fast in XCTest when the test has not installed an osascript mock.
    func testAppleScriptRunRequiresMockDuringTests() {
        XCTAssertThrowsError(try AppleScript.run("return \"hello\"")) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "spaces.applescript")
            XCTAssertTrue(nsError.localizedDescription.contains("Unmocked AppleScript call during tests"))
        }
    }

    // Tests run(lines:) joins lines with newlines and executes the resulting script.
    func testAppleScriptRunJoinsLines() throws {
        try withMockCommands(["osascript": "#!/bin/bash\necho 'hello'\n"]) {
            let result = try AppleScript.run(lines: ["return \"hello\""])
            XCTAssertEqual(result, "hello")
        }
    }

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

        try withTestAppleScriptOptIn(enabled: commands.keys.contains("osascript")) { try run() }
    }
}
