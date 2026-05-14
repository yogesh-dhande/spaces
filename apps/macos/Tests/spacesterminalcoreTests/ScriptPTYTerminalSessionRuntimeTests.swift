import XCTest

@testable import spacesterminalcore

final class ScriptPTYTerminalSessionRuntimeTests: XCTestCase {
    func testMakeLaunchCommandPrefixesInitialTerminalSizeForCommands() {
        let command = ScriptPTYTerminalSessionRuntime.makeLaunchCommand(shell: "/bin/zsh", command: "codex")

        XCTAssertTrue(command.hasPrefix("stty rows 40 cols 120 2>/dev/null; "))
        XCTAssertTrue(command.hasSuffix("codex"))
    }

    func testMakeLaunchCommandExecsInteractiveShellWithInitialTerminalSize() {
        let command = ScriptPTYTerminalSessionRuntime.makeLaunchCommand(shell: "/bin/zsh", command: nil)

        XCTAssertEqual(command, "stty rows 40 cols 120 2>/dev/null; exec '/bin/zsh' -l")
    }

    func testMakeLaunchCommandEscapesShellPathForInteractiveShell() {
        let command = ScriptPTYTerminalSessionRuntime.makeLaunchCommand(shell: "/tmp/te'st-shell", command: nil)

        XCTAssertEqual(command, "stty rows 40 cols 120 2>/dev/null; exec '/tmp/te'\"'\"'st-shell' -l")
    }
}
