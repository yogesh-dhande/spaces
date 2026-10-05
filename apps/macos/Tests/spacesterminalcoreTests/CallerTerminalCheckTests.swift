import Foundation
import XCTest

@testable import spacesterminalcore

final class CallerTerminalCheckTests: XCTestCase {
    private func check(shellPID: Int32?) -> CallerTerminalCheck { CallerTerminalCheck { _ in shellPID } }

    func testExplicitTerminalCarriesNoPidAndIsNeverChecked() { XCTAssertTrue(check(shellPID: 999_999).permits(sessionID: "s", callerProcessID: nil)) }

    func testCallerInsideTheShellsProcessTreeIsPermitted() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shell.arguments = ["30"]
        try shell.run()
        defer {
            shell.terminate()
            shell.waitUntilExit()
        }
        // The test process is the "shell"; the sleeping child stands in for a hook running beneath it.
        XCTAssertTrue(check(shellPID: getpid()).permits(sessionID: "s", callerProcessID: shell.processIdentifier))
    }

    func testCallerOutsideTheShellsProcessTreeIsRefused() {
        XCTAssertFalse(check(shellPID: getpid()).permits(sessionID: "s", callerProcessID: getppid()))
        XCTAssertThrowsError(try check(shellPID: getpid()).require(sessionID: "s", callerProcessID: getppid())) {
            XCTAssertEqual($0 as? CallerOutsideTerminalError, CallerOutsideTerminalError())
        }
    }

    func testUnknownOrEndedTerminalKeepsItsOwnHandling() { XCTAssertTrue(check(shellPID: nil).permits(sessionID: "s", callerProcessID: getpid())) }

    func testRefusalNamesTheCauseAndTheExplicitSessionEscape() throws {
        let message = try XCTUnwrap(CallerOutsideTerminalError().errorDescription)
        XCTAssertTrue(message.contains("not running inside the Spaces terminal"))
        XCTAssertTrue(message.contains("Codex's shared background server"))
        XCTAssertTrue(message.contains("Pass the session explicitly"))
    }
}
