import XCTest

@testable import spacesterminalcore

final class AgentSpawnCommandGateTests: XCTestCase {
    // MARK: - Executable-token parsing / matching

    func testMatchingResolvesSupportedAgentsAcrossCommandShapes() {
        let cases: [(command: String, expected: CodingAgent?)] = [
            ("claude", .claudeCode), ("codex --yolo", .codex), ("FOO=1 claude", .claudeCode), ("env FOO=1 codex", .codex),
            ("/usr/local/bin/claude -c", .claudeCode), ("opencode", .opencode), ("vim", nil), ("", nil), ("env", nil),
        ]
        for testCase in cases {
            XCTAssertEqual(
                CodingAgent.matching(command: testCase.command), testCase.expected, "matching(command: \"\(testCase.command)\")")
        }
    }

    // MARK: - Spawn gate

    /// The gate is command-shape only: it resolves which supported agent the command launches so spawn
    /// readiness knows which foreground kind to await. It does NOT require installed hooks — readiness is
    /// foreground-detection-based, so a supported command spawns regardless of hook state.
    func testResolveSpawnableAgentResolvesSupportedCommandWithoutHookState() throws {
        XCTAssertEqual(try AgentSpawnCommandGate.resolveSpawnableAgent(command: "claude"), .claudeCode)
        XCTAssertEqual(try AgentSpawnCommandGate.resolveSpawnableAgent(command: "codex --yolo"), .codex)
        XCTAssertEqual(try AgentSpawnCommandGate.resolveSpawnableAgent(command: "env FOO=1 opencode"), .opencode)
    }

    func testResolveSpawnableAgentRejectsUnsupportedCommand() {
        XCTAssertThrowsError(try AgentSpawnCommandGate.resolveSpawnableAgent(command: "vim")) { error in
            XCTAssertEqual(error as? AgentSpawnCommandGate.GateError, .unsupportedCommand)
        }
        XCTAssertThrowsError(try AgentSpawnCommandGate.resolveSpawnableAgent(command: "")) { error in
            XCTAssertEqual(error as? AgentSpawnCommandGate.GateError, .unsupportedCommand)
        }
    }
}
