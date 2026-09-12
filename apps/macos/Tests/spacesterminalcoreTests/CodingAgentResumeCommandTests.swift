import XCTest

@testable import spacesterminalcore

/// Coverage for `CodingAgent.resumeCommand(launchCommand:sessionKey:)`, the rewrite that turns a
/// restorable session's original launch command into one that resumes its conversation. Each provider
/// takes its resume argument in a different place, so the cases below pin one per provider plus the
/// executable-token scan that makes the splice land after the real executable rather than after a
/// leading environment assignment.
final class CodingAgentResumeCommandTests: XCTestCase {
    // MARK: - Claude Code: --resume <key> right after the executable

    func testClaudeCodeInsertsResumeFlagAfterExecutableKeepingOtherFlagsAndPrompt() {
        let result = CodingAgent.resumeCommand(launchCommand: #"claude --model opus "fix the bug""#, sessionKey: "abc")
        XCTAssertEqual(result, #"claude --resume abc --model opus "fix the bug""#)
    }

    func testClaudeCodeWithAbsolutePathExecutableKeepsThePathAndInsertsAfterIt() {
        let result = CodingAgent.resumeCommand(launchCommand: "/usr/local/bin/claude -c", sessionKey: "xyz")
        XCTAssertEqual(result, "/usr/local/bin/claude --resume xyz -c")
    }

    /// `--session-id` names the id a new conversation is to be created under, and Claude refuses it
    /// alongside `--resume`, so a relaunch that kept it would exit immediately while the record that could
    /// have brought the agent back was already cleared.
    func testClaudeCodeDropsASessionIDOptionWhenItResumes() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude --session-id 1111 -p x", sessionKey: "abc"), "claude --resume abc -p x")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude --session-id=1111", sessionKey: "abc"), "claude --resume abc")
        let both = CodingAgent.resumeCommand(launchCommand: "claude --resume old --session-id 1111 -p x", sessionKey: "abc")
        XCTAssertEqual(both, "claude --resume abc -p x")
        XCTAssertEqual(both.components(separatedBy: "--resume").count - 1, 1)
        XCTAssertFalse(both.contains("--session-id"))
    }

    // MARK: - Codex: resume <key> subcommand before the original flags

    func testCodexInsertsResumeSubcommandBeforeOriginalFlags() {
        let result = CodingAgent.resumeCommand(launchCommand: #"codex -m gpt-5 "ship it""#, sessionKey: "session-key")
        XCTAssertEqual(result, #"codex resume session-key -m gpt-5 "ship it""#)
    }

    /// A Codex `exec` run is a one-shot job: its options belong to the `exec` subcommand, and only Codex
    /// knows their arity, so the relaunch never tries to place a resume selector among them. Such a run is
    /// recognised here and brought back as a new run instead.
    func testCodexExecRunsAreRecognisedSoTheyComeBackAsNewRuns() {
        XCTAssertTrue(CodingAgent.launchIsOneShotCodexExec(launchCommand: #"codex exec --sandbox read-only "fix it""#))
        XCTAssertTrue(CodingAgent.launchIsOneShotCodexExec(launchCommand: #"codex -m gpt-5 exec "fix""#))
        XCTAssertTrue(CodingAgent.launchIsOneShotCodexExec(launchCommand: "codex -C dir e"))
        XCTAssertFalse(CodingAgent.launchIsOneShotCodexExec(launchCommand: #"codex "fix exec bug""#))
        XCTAssertFalse(CodingAgent.launchIsOneShotCodexExec(launchCommand: "codex -m gpt-5"))
        XCTAssertFalse(CodingAgent.launchIsOneShotCodexExec(launchCommand: "claude exec"), "the rule is about Codex's own subcommand")
    }

    /// An interactive Codex run whose prompt merely mentions `exec` is resumed like any other: the word is
    /// inside the quoted prompt, which the scan stops at. Global options are carried through untouched.
    func testCodexInteractiveRunsAreResumedWhateverTheirPromptAndFlagsSay() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"codex "fix exec bug""#, sessionKey: "abc"), #"codex resume abc "fix exec bug""#)
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"codex --full-auto "fix""#, sessionKey: "abc"), #"codex resume abc --full-auto "fix""#)
    }

    // MARK: - opencode: -s <key> appended

    func testOpencodeAppendsSessionFlagAtTheEnd() {
        let result = CodingAgent.resumeCommand(launchCommand: "opencode --port 1234", sessionKey: "session-key")
        XCTAssertEqual(result, "opencode --port 1234 -s session-key")
    }

    // MARK: - A command that already names a conversation has that conversation replaced

    /// A restored agent's own command already carries its provider's selector, so the newest key replaces
    /// the conversation it names. A second selector would be worse than untidy: `codex resume A resume B`
    /// is rejected outright, and a duplicated Claude Code selector can resume the older conversation.
    func testExistingConversationIsReplacedRatherThanJoinedBySecondSelector() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "claude --resume old-conversation --model opus", sessionKey: "new-conversation"),
            "claude --resume new-conversation --model opus")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "claude -r old-conversation", sessionKey: "new-conversation"),
            "claude -r new-conversation")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "claude --resume=old-conversation --verbose", sessionKey: "new-conversation"),
            "claude --resume=new-conversation --verbose")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"codex resume old-conversation -m gpt-5 "ship it""#, sessionKey: "new-conversation"),
            #"codex resume new-conversation -m gpt-5 "ship it""#)
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "opencode -s old-conversation --port 1234", sessionKey: "new-conversation"),
            "opencode -s new-conversation --port 1234")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "opencode --session old-conversation", sessionKey: "new-conversation"),
            "opencode --session new-conversation")
    }

    /// A selector carrying no conversation of its own (`claude --resume` picks one interactively, `codex
    /// resume --last` takes the most recent) names the captured one instead of being duplicated.
    func testSelectorWithoutAConversationTakesTheCapturedOne() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "claude --resume --model opus", sessionKey: "new-conversation"),
            "claude --resume new-conversation --model opus")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "codex resume --last", sessionKey: "new-conversation"),
            "codex resume new-conversation --last")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "opencode -s", sessionKey: "new-conversation"),
            "opencode -s new-conversation")
    }

    /// Rewriting twice is the restore loop: whatever a command already names, resuming it again names the
    /// newest conversation exactly once.
    func testRewritingAnAlreadyRewrittenCommandKeepsOneConversation() {
        for command in ["claude --model opus", "codex -m gpt-5", "opencode --port 1234"] {
            let once = CodingAgent.resumeCommand(launchCommand: command, sessionKey: "first-conversation")
            let twice = CodingAgent.resumeCommand(launchCommand: once, sessionKey: "second-conversation")
            XCTAssertFalse(twice.contains("first-conversation"), "rewriting \(once) again kept the older conversation: \(twice)")
            XCTAssertEqual(twice.components(separatedBy: "second-conversation").count - 1, 1, twice)
        }
    }

    // MARK: - A quoted prompt is text, not argv

    /// A selector word inside a quoted prompt is part of the prompt. Reading it as a selector would rewrite
    /// what the user asked the agent to do, and leave the relaunch resuming nothing.
    func testSelectorWordsInsideAQuotedPromptAreLeftAloneAndTheRealSelectorIsStillAdded() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude "explain --resume behavior""#, sessionKey: "abc"),
            #"claude --resume abc "explain --resume behavior""#)
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "codex 'walk me through resume'", sessionKey: "abc"),
            "codex resume abc 'walk me through resume'")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode "use --session carefully""#, sessionKey: "abc"),
            #"opencode "use --session carefully" -s abc"#)
    }

    /// The real selector still wins when both are present: the quoted prompt keeps its text and the
    /// conversation the command names is the one replaced.
    func testARealSelectorIsReplacedWhileAQuotedPromptKeepsItsText() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude --resume old-id "explain --resume behavior""#, sessionKey: "new-id"),
            #"claude --resume new-id "explain --resume behavior""#)
    }

    /// A conversation id given in quotes is replaced whole, quotes included, so the relaunch carries the
    /// captured key rather than a quoted fragment of the old one.
    func testAQuotedConversationIdIsReplacedByTheCapturedKey() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude --resume "old id""#, sessionKey: "new-id"), "claude --resume new-id")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "codex resume 'old id' --yolo", sessionKey: "new-id"), "codex resume new-id --yolo")
    }

    /// A backslash-escaped space keeps a prompt in one token, so a selector word inside that prompt is
    /// still part of the prompt and not a selector the agent was launched with.
    func testEscapedWhitespaceKeepsAPromptInOneTokenSoItsSelectorWordsAreNotRead() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude explain\ --resume behavior"#, sessionKey: "abc"),
            #"claude --resume abc explain\ --resume behavior"#)
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"opencode say\ hi"#, sessionKey: "abc"), #"opencode say\ hi -s abc"#)
    }

    // MARK: - A chained command belongs to more than one program

    /// A launch command can chain programs, and only the first segment is the agent's own argv. An appended
    /// selector would otherwise be handed to whatever runs after the operator: `opencode | tee agent.log -s
    /// <key>` passes the session to `tee`, and the relaunched agent starts a fresh conversation.
    func testOpencodeTakesItsSessionFlagInsideItsOwnSegmentOfAChain() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode && notify", sessionKey: "abc"), "opencode -s abc && notify")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode || echo failed", sessionKey: "abc"), "opencode -s abc || echo failed")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "opencode --port 1234 | tee agent.log", sessionKey: "abc"),
            "opencode --port 1234 -s abc | tee agent.log")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode; echo done", sessionKey: "abc"), "opencode -s abc; echo done")
    }

    /// The agents that splice after the executable land in the first segment already, and the rest of the
    /// chain is carried through untouched.
    func testClaudeCodeAndCodexSpliceIntoTheirOwnSegmentOfAChain() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude && notify", sessionKey: "abc"), "claude --resume abc && notify")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "codex -m gpt-5 | tee log", sessionKey: "abc"), "codex resume abc -m gpt-5 | tee log")
    }

    /// A selector in a later segment belongs to that program, not to the agent, so it is left alone and the
    /// agent still gets one of its own.
    func testASelectorInALaterSegmentIsNotMistakenForTheAgents() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "opencode && claude --resume other", sessionKey: "abc"),
            "opencode -s abc && claude --resume other")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "codex -m gpt-5 ; codex resume other", sessionKey: "abc"),
            "codex resume abc -m gpt-5 ; codex resume other")
    }

    /// An operator inside quotes is text the agent was given, not a chain, so the whole command stays one
    /// segment. A backslash-escaped quote inside a double-quoted span does not close it, so an operator
    /// after that escape is still inside the prompt; a single-quoted span escapes nothing, which is what
    /// makes the `'it'\''s'` way of writing an apostrophe work.
    func testAnOperatorInsideQuotesDoesNotEndTheAgentsSegment() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode "compare a && b""#, sessionKey: "abc"), #"opencode "compare a && b" -s abc"#)
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode "compare \"a && b\"""#, sessionKey: "abc"),
            #"opencode "compare \"a && b\"" -s abc"#)
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude 'it'\''s'"#, sessionKey: "abc"), #"claude --resume abc 'it'\''s'"#)
    }

    /// A redirection is part of the command, not the end of it. `2>&1` and `&>` both carry an `&` that ends
    /// nothing, and splitting there would splice the selector into the middle of the redirection.
    func testRedirectionsDoNotEndTheAgentsSegment() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode 2>&1", sessionKey: "abc"), "opencode 2>&1 -s abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode &> log", sessionKey: "abc"), "opencode &> log -s abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode &>> log", sessionKey: "abc"), "opencode &>> log -s abc")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "opencode 2>&1 | tee log", sessionKey: "abc"), "opencode 2>&1 -s abc | tee log")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "claude 2>&1 && echo done", sessionKey: "abc"), "claude --resume abc 2>&1 && echo done")
    }

    /// An escaped operator is a literal character the command carries, so it ends nothing either.
    func testAnEscapedOperatorDoesNotEndTheAgentsSegment() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"opencode a\&b"#, sessionKey: "abc"), #"opencode a\&b -s abc"#)
    }

    // MARK: - Leading environment assignments / `env` are skipped when locating the executable

    func testLeadingEnvironmentAssignmentIsSkippedSoTheFlagLandsAfterTheExecutable() {
        let result = CodingAgent.resumeCommand(launchCommand: "FOO=bar claude --verbose", sessionKey: "abc")
        XCTAssertEqual(result, "FOO=bar claude --resume abc --verbose")
    }

    /// The assignment's own value can be the literal word `claude`; the scan must not mistake that for
    /// the executable token and must still find the real one that follows.
    func testLeadingAssignmentWhoseValueIsAnAgentNameDoesNotConfuseTheExecutableScan() {
        let result = CodingAgent.resumeCommand(launchCommand: "AGENT=claude claude -c", sessionKey: "abc")
        XCTAssertEqual(result, "AGENT=claude claude --resume abc -c")
    }

    // MARK: - No key, or no supported agent, returns the command unchanged

    func testNilSessionKeyReturnsCommandUnchanged() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude --verbose", sessionKey: nil), "claude --verbose")
    }

    func testBlankOrWhitespaceSessionKeyReturnsCommandUnchanged() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude --verbose", sessionKey: ""), "claude --verbose")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude --verbose", sessionKey: "   "), "claude --verbose")
    }

    func testCommandLaunchingNoSupportedAgentReturnsCommandUnchanged() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "vim notes.txt", sessionKey: "abc"), "vim notes.txt")
    }
}
