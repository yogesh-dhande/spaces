import Foundation
import XCTest
import appctl

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
            XCTAssertEqual(nsError.domain, "muxy.shell")
            XCTAssertEqual(nsError.code, 9)
            XCTAssertTrue((nsError.localizedDescription).contains("boom"))
        }
    }
}
