import XCTest

@testable import spacesterminalcore

/// `runKey` is what a client-local scrollback replay is armed against, so these cover the one
/// distinction it exists to make: a relaunch invalidates a replay's bytes, an exit does not.
final class TerminalSessionRunKeyTests: XCTestCase {
    func testTheSameProcessExitingKeepsItsRunKey() {
        let running = runtimeState(childPID: 4321, exitedAt: nil)
        let exited = runtimeState(childPID: 4321, exitedAt: "2026-06-04T14:23:31Z")

        XCTAssertNotEqual(running.runIdentity, exited.runIdentity, "setup: an exit advances the run identity's exit half")
        XCTAssertEqual(
            TerminalSessionRuntimeState.runKey(for: running.runIdentity), TerminalSessionRuntimeState.runKey(for: exited.runIdentity),
            "a process exiting writes no new transcript and truncates nothing, so the bytes read under it still belong to the same run")
    }

    func testARelaunchChangesTheRunKey() {
        let first = runtimeState(childPID: 4321, exitedAt: "2026-06-04T14:23:31Z")
        let relaunched = runtimeState(childPID: 9876, exitedAt: nil)

        XCTAssertNotEqual(
            TerminalSessionRuntimeState.runKey(for: first.runIdentity), TerminalSessionRuntimeState.runKey(for: relaunched.runIdentity),
            "a new child process truncates `output.log`, so bytes read under the previous one no longer exist")
    }

    func testASessionWithNoChildProcessYetKeepsAKeyOfItsOwn() {
        let launching = runtimeState(childPID: nil, exitedAt: nil)
        let running = runtimeState(childPID: 4321, exitedAt: nil)

        XCTAssertNotEqual(
            TerminalSessionRuntimeState.runKey(for: launching.runIdentity), TerminalSessionRuntimeState.runKey(for: running.runIdentity),
            "a session that has not exec'd its child yet is not the run that child goes on to write")
    }

    func testThereIsNoRunKeyWithoutARunIdentity() {
        XCTAssertNil(TerminalSessionRuntimeState.runKey(for: nil), "a read the daemon could not attribute to a run keys against nothing")
    }

    private func runtimeState(childPID: Int32?, exitedAt: String?) -> TerminalSessionRuntimeState {
        TerminalSessionRuntimeState(
            sessionID: "terminal-session", servicePID: 100, childPID: childPID, state: exitedAt == nil ? .running : .exited,
            updatedAt: "2026-06-04T14:23:31Z", exitedAt: exitedAt)
    }
}
