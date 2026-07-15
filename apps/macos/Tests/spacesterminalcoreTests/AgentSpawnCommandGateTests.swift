import XCTest

@testable import spacesterminalcore

final class AgentSpawnCommandGateTests: XCTestCase {
    // MARK: - Executable-token parsing / matching

    func testMatchingResolvesSupportedAgentsAcrossCommandShapes() {
        let cases: [(command: String, expected: SupportedCodingAgentHook?)] = [
            ("claude", .claudeCode),
            ("codex --yolo", .codex),
            ("FOO=1 claude", .claudeCode),
            ("env FOO=1 codex", .codex),
            ("/usr/local/bin/claude -c", .claudeCode),
            ("opencode", .opencode),
            ("vim", nil),
            ("", nil),
            ("env", nil),
        ]
        for testCase in cases {
            XCTAssertEqual(
                SupportedCodingAgentHook.matching(command: testCase.command), testCase.expected,
                "matching(command: \"\(testCase.command)\")")
        }
    }

    // MARK: - Spawn gate

    private func status(_ kind: SupportedCodingAgentHook, _ state: AgentHookInstallState) -> AgentHookStatus {
        AgentHookStatus(kind: kind, displayName: kind.displayName, available: true, installState: state)
    }

    func testResolveSpawnableAgentAcceptsCurrentHooks() throws {
        let hook = try AgentSpawnCommandGate.resolveSpawnableAgent(
            command: "claude", statuses: [status(.claudeCode, .current), status(.codex, .notInstalled)])
        XCTAssertEqual(hook, .claudeCode)
    }

    func testResolveSpawnableAgentRejectsUnsupportedCommand() {
        XCTAssertThrowsError(try AgentSpawnCommandGate.resolveSpawnableAgent(command: "vim", statuses: [status(.claudeCode, .current)])) { error in
            XCTAssertEqual(error as? AgentSpawnCommandGate.GateError, .unsupportedCommand)
        }
    }

    func testResolveSpawnableAgentRejectsUninstalledHooks() {
        XCTAssertThrowsError(
            try AgentSpawnCommandGate.resolveSpawnableAgent(command: "codex", statuses: [status(.codex, .outdated)])
        ) { error in
            XCTAssertEqual(error as? AgentSpawnCommandGate.GateError, .hooksNotInstalled(.codex, .outdated))
        }
        // No status entry for the matched agent reads as not-installed.
        XCTAssertThrowsError(
            try AgentSpawnCommandGate.resolveSpawnableAgent(command: "codex", statuses: [status(.claudeCode, .current)])
        ) { error in
            XCTAssertEqual(error as? AgentSpawnCommandGate.GateError, .hooksNotInstalled(.codex, .notInstalled))
        }
    }
}
