import XCTest

@testable import spacesterminalcore

final class TerminalForegroundProcessInspectorTests: XCTestCase {
    func testClassifiesNativeCodexCommand() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 100, executablePath: "/opt/homebrew/bin/codex", argv: ["/opt/homebrew/bin/codex", "--model", "gpt-5"])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .codex)
        XCTAssertEqual(detected?.displayLabel, "codex")
        XCTAssertEqual(detected?.displayCommand, "codex --model gpt-5")
    }

    func testClassifiesNodeWrappedCodexCommand() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 101, executablePath: "/opt/homebrew/bin/node",
            argv: ["/opt/homebrew/bin/node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "--ask-for-approval", "never"])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .codex)
        XCTAssertEqual(detected?.displayCommand, "codex --ask-for-approval never")
    }

    func testClassifiesNodeWrappedCodexCommandAfterNodeOptions() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 101, executablePath: "/opt/homebrew/bin/node",
            argv: [
                "/opt/homebrew/bin/node", "--require", "source-map-support/register", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js",
                "--ask-for-approval", "never",
            ])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .codex)
        XCTAssertEqual(detected?.displayCommand, "codex --ask-for-approval never")
    }

    func testClassifiesClaudeCommands() {
        let claude = TerminalForegroundProcessSnapshot(pid: 102, executablePath: "/usr/local/bin/claude", argv: ["claude"])
        let claudeCode = TerminalForegroundProcessSnapshot(pid: 103, executablePath: "/usr/local/bin/claude-code", argv: ["claude-code", "resume"])

        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claude)?.detectedAgentKind, .claude)
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claude)?.displayLabel, "claude")
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claudeCode)?.detectedAgentKind, .claudeCode)
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claudeCode)?.displayLabel, "claude-code")
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claudeCode)?.displayCommand, "claude-code resume")
    }

    func testClassifiesClaudeVersionedBinaryFromInvokedCommandName() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 104, executablePath: "/Users/yogesh/.local/share/claude/versions/2.1.168", argv: ["claude", "--dangerously-skip-permissions"])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .claude)
        XCTAssertEqual(detected?.displayCommand, "claude --dangerously-skip-permissions")
    }

    func testClassifiesLinuxClaudeVersionedBinaryFromProcArguments() {
        let argv = TerminalForegroundProcessInspector.procCmdlineArguments(from: Data("claude\0--dangerously-skip-permissions\0".utf8))
        let process = TerminalForegroundProcessSnapshot(pid: 104, executablePath: "/home/user/.local/share/claude/versions/2.1.168", argv: argv)

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .claude)
        XCTAssertEqual(detected?.displayCommand, "claude --dangerously-skip-permissions")
    }

    func testParsesProcCmdlineArgumentsWithOrWithoutTrailingTerminator() {
        XCTAssertEqual(
            TerminalForegroundProcessInspector.procCmdlineArguments(from: Data("node\0/usr/lib/node_modules/@openai/codex/bin/codex.js\0".utf8)),
            ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js"])
        XCTAssertEqual(
            TerminalForegroundProcessInspector.procCmdlineArguments(from: Data("opencode\0run\0fix lint".utf8)), ["opencode", "run", "fix lint"])
    }

    func testClassifiesOpencodeCommands() {
        let opencode = TerminalForegroundProcessSnapshot(pid: 104, executablePath: "/usr/local/bin/opencode", argv: ["opencode", "run", "fix lint"])
        let npmOpencode = TerminalForegroundProcessSnapshot(
            pid: 105, executablePath: "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.exe", argv: ["opencode", "tui"])

        XCTAssertEqual(TerminalForegroundProcessInspector.classify(opencode)?.detectedAgentKind, .opencode)
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(opencode)?.displayLabel, "opencode")
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(opencode)?.displayCommand, "opencode run 'fix lint'")
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(npmOpencode)?.detectedAgentKind, .opencode)
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(npmOpencode)?.displayCommand, "opencode tui")
    }

    func testDoesNotClassifyShellOrUnknownProcess() {
        let shell = TerminalForegroundProcessSnapshot(pid: 106, executablePath: "/bin/zsh", argv: ["zsh"])
        let unknown = TerminalForegroundProcessSnapshot(pid: 107, executablePath: "/usr/bin/vim", argv: ["vim", "README.md"])

        XCTAssertNil(TerminalForegroundProcessInspector.classify(shell))
        XCTAssertNil(TerminalForegroundProcessInspector.classify(unknown))
    }

    func testDoesNotClassifyAgentNamesInNonExecutableArguments() {
        let grep = TerminalForegroundProcessSnapshot(pid: 108, executablePath: "/usr/bin/grep", argv: ["grep", "codex", "README.md"])
        let editor = TerminalForegroundProcessSnapshot(pid: 109, executablePath: "/usr/bin/vim", argv: ["vim", "./claude-code"])

        XCTAssertNil(TerminalForegroundProcessInspector.classify(grep))
        XCTAssertNil(TerminalForegroundProcessInspector.classify(editor))
    }

    func testDoesNotClassifyAgentNamesInLaterNodeArguments() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 110, executablePath: "/opt/homebrew/bin/node", argv: ["node", "/tmp/print-args.js", "codex", "claude"])

        XCTAssertNil(TerminalForegroundProcessInspector.classify(process))
    }

    func testDoesNotClassifyAgentNamesInNodeEvalCode() {
        let process = TerminalForegroundProcessSnapshot(pid: 111, executablePath: "/opt/homebrew/bin/node", argv: ["node", "-e", "codex"])

        XCTAssertNil(TerminalForegroundProcessInspector.classify(process))
    }

    func testDisplayCommandQuotesWhitespaceAndBoundsArguments() {
        let longArgument = String(repeating: "x", count: 180)
        let process = TerminalForegroundProcessSnapshot(
            pid: 112, executablePath: "/usr/local/bin/codex", argv: ["codex", "hello world", longArgument])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.displayCommand, "codex 'hello world' \(String(repeating: "x", count: 160))...")
    }
}
