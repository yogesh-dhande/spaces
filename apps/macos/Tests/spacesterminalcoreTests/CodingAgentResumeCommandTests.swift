import XCTest

@testable import spacesterminalcore

/// Coverage for `CodingAgent.resumeCommand(launchCommand:sessionKey:)`, the rewrite that turns a
/// restorable session's original launch command into one that resumes its conversation. Each provider
/// takes its resume argument in a different place, so the cases below pin one per provider plus the
/// executable-token scan that makes the splice land after the real executable rather than after a
/// leading environment assignment.
final class CodingAgentResumeCommandTests: XCTestCase {
    // MARK: - Claude Code: --resume <key> right after the executable

    func testClaudeCodeInsertsResumeFlagAfterExecutableKeepingOtherFlags() {
        let result = CodingAgent.resumeCommand(launchCommand: #"claude --model opus "fix the bug""#, sessionKey: "abc")
        XCTAssertEqual(result, "claude --resume abc --model opus")
    }

    func testClaudeCodeWithAbsolutePathExecutableKeepsThePathAndInsertsAfterIt() {
        let result = CodingAgent.resumeCommand(launchCommand: "/usr/local/bin/claude -c", sessionKey: "xyz")
        XCTAssertEqual(result, "/usr/local/bin/claude --resume xyz -c")
    }

    /// `--session-id` names the id a new conversation is to be created under, and Claude refuses it
    /// alongside `--resume`, so a relaunch that kept it would exit immediately while the record that could
    /// have brought the agent back was already cleared.
    func testClaudeCodeDropsASessionIDOptionWhenItResumes() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "claude --session-id 1111 --verbose", sessionKey: "abc"), "claude --resume abc --verbose")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude --session-id=1111", sessionKey: "abc"), "claude --resume abc")
        let both = CodingAgent.resumeCommand(launchCommand: "claude --resume old --session-id 1111 --verbose", sessionKey: "abc")
        XCTAssertEqual(both, "claude --resume abc --verbose")
        XCTAssertEqual(both.components(separatedBy: "--resume").count - 1, 1)
        XCTAssertFalse(both.contains("--session-id"))
    }

    /// A relaunch command keeps the executable the agent was invoked with, so every name a detection
    /// variant matches has to reach an agent here, and so does each agent's own canonical name for the node
    /// wrapper that is rewritten to it. A name this scan does not know silently skips the rewrite, and the
    /// agent comes back on a fresh conversation while the offer said it would be resumed. Checking the
    /// whole variant table is what keeps a variant added later (another wrapper name, another node script)
    /// from regressing it unnoticed.
    func testEveryDetectionVariantExecutableNameIsReachedByTheGate() {
        for agent in CodingAgent.allCases {
            XCTAssertEqual(
                CodingAgent.matching(command: agent.primaryCommandName), agent,
                "a node-wrapped capture relaunches as `\(agent.primaryCommandName)`, which matches no agent")
            for variant in agent.detectionVariants {
                XCTAssertEqual(variant.kind.agent, agent, "\(variant.kind) is detected for \(agent) but maps back to another agent")
                for name in variant.executableNames {
                    XCTAssertEqual(
                        CodingAgent.matching(command: "\(name) --model opus"), agent,
                        "a \(variant.kind) capture relaunches as `\(name)`, which matches no agent")
                    XCTAssertEqual(
                        CodingAgent.matching(command: "/opt/x/bin/\(name) --model opus"), agent,
                        "a \(variant.kind) capture run from an absolute path matches no agent")
                }
            }
        }
    }

    // MARK: - Codex: resume <key> subcommand before the original flags

    func testCodexInsertsResumeSubcommandBeforeOriginalFlags() {
        let result = CodingAgent.resumeCommand(launchCommand: #"codex -m gpt-5 "ship it""#, sessionKey: "session-key")
        XCTAssertEqual(result, "codex resume session-key -m gpt-5")
    }

    /// A one-shot run prints an answer and exits rather than holding a conversation to come back to, so it
    /// is recognised here and brought back as a new run with its prompt intact. Codex additionally hides its
    /// resume selector behind `exec`, among options only Codex knows the arity of.
    func testOneShotRunsAreRecognisedSoTheyComeBackAsNewRuns() {
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: #"codex exec --sandbox read-only "fix it""#))
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: #"codex -m gpt-5 exec "fix""#))
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: "codex -C dir e"))
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: #"claude -p "summarise the diff""#))
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: #"claude --print "summarise the diff""#))
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: #"opencode run "fix lint""#))
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: #"codex "fix exec bug""#))
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: "codex -m gpt-5"))
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: "claude exec"), "the exec marker belongs to Codex alone")
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: "opencode --port 1234"))
    }

    /// A one-shot run is relaunched exactly as it was typed, prompt included: it has no conversation to
    /// rejoin, so the prompt is the whole of what it does.
    func testOneShotRunsAreRelaunchedExactlyAsTyped() {
        for command in [#"claude -p "summarise the diff""#, #"claude --print "x""#, #"codex exec "fix it""#, #"opencode run "fix lint""#] {
            XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: command, sessionKey: "abc"), command)
        }
    }

    /// A marker is read where the agent's CLI reads it rather than merely somewhere among the tokens.
    /// Claude Code's `-p` is an option, so it counts wherever it is written, including after an option
    /// whose value is a quoted string; read as interactive, this job would be rewritten into a resume that
    /// re-sends or drops the prompt it exists to run.
    func testAClaudeCodePrintFlagIsReadAfterAQuotedOptionValue() {
        let command = #"claude --append-system-prompt "Be terse" -p "review this""#
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: command))
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: command, sessionKey: "abc"), command)
    }

    /// An option's value is never a marker, and neither is a prompt: an interactive run whose words happen
    /// to include one is resumed like any other, and its prompt is dropped because the conversation it
    /// rejoins already holds it.
    func testAMarkerWordThatIsAnOptionValueOrAPromptLeavesTheRunInteractive() {
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: #"claude --model opus "review this""#))
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude --model opus "review this""#, sessionKey: "abc"), "claude --resume abc --model opus")
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: #"codex "exec the plan""#))
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"codex "exec the plan""#, sessionKey: "abc"), "codex resume abc")
    }

    /// Codex takes its markers in the subcommand position, which is the first positional argument and so
    /// sits after whatever global options were written first. Each of these is relaunched exactly as
    /// written because a spliced selector would be rejected: `codex resume <key> --base main` is not the
    /// review the user asked for, and `codex resume <key> fork <id>` is refused outright.
    func testCodexSubcommandsThatCannotTakeASplicedResumeAreRelaunchedAsWritten() {
        for command in ["codex review --base main", #"codex --yolo exec "do it""#, "codex fork 1111-2222"] {
            XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: command), command)
            XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: command, sessionKey: "abc"), command)
        }
    }

    /// Claude Code takes subcommands of its own, and a subcommand run is not a conversation to resume:
    /// `claude update` and `claude mcp ...` manage the installation, and `claude attach <id>`, the one that
    /// is long-lived, opens a background session that is not the conversation the captured key names. Each
    /// is relaunched exactly as written, which also leaves its argument alone: read as a prompt, `claude
    /// attach bg123` would come back as `claude --resume <key> bg123`, resuming the wrong conversation and
    /// dropping the id the run is about.
    func testClaudeCodeSubcommandRunsAreRelaunchedAsWritten() {
        for command in ["claude attach bg123", "claude mcp serve", "claude update", "claude --model opus attach x", "claude plugins list"] {
            XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: command), command)
            XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: command, sessionKey: "abc"), command)
        }
    }

    /// A subcommand counts only where Claude Code reads one, so a prompt that opens with a subcommand's
    /// word is still a prompt: it is one quoted token, it is not in the subcommand position once another
    /// positional precedes it, and a `--` guards it whatever it is spelled like.
    func testAClaudeCodeSubcommandWordInsideAPromptLeavesTheRunInteractive() {
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: #"claude "attach the debugger""#))
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude "attach the debugger""#, sessionKey: "abc"), "claude --resume abc")
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: "claude -- attach"))
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude -- attach", sessionKey: "abc"), "claude --resume abc --")
    }

    /// A subcommand run is still recognised as one when a print flag follows it, and a print run is still
    /// recognised when its prompt comes first: Claude Code takes both shapes of marker, so neither reading
    /// stops at the other's position.
    func testAClaudeCodeMarkerCountsWhicheverShapeComesFirst() {
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: "claude logs bg123 --verbose"))
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: #"claude "summarise the diff" -p"#))
    }

    /// opencode writes its subcommand first as well, and the TUI's own positional in that place is a
    /// project path rather than a one-shot run.
    func testOpencodeReadsItsRunSubcommandAndNotItsProjectPath() {
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: #"opencode run "x""#))
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: "opencode ../other-project"))
    }

    /// `opencode run` is a job only while its interactive flag is absent: `-i`/`--interactive` starts a
    /// long-lived session, which is a conversation to rejoin like any other. Read as a job, it would come
    /// back with its resume key dropped and its prompt re-sent into a brand new session.
    func testOpencodeRunIsAJobOnlyWithoutItsInteractiveFlag() {
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: #"opencode run "do it""#))
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"opencode run "do it""#, sessionKey: "abc"), #"opencode run "do it""#)

        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: "opencode run -i"))
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode run -i", sessionKey: "abc"), "opencode run -i -s abc")

        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: #"opencode run --interactive "start here""#))
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode run --interactive "start here""#, sessionKey: "abc"),
            "opencode run --interactive -s abc")
    }

    /// opencode's value-taking options are read as such, so a subcommand written after one is still found
    /// at the subcommand position. Read as a flag, `--model` would leave `anthropic/claude` standing there,
    /// settling the one-shot scan as an interactive session before it ever reached `run` and sending a job
    /// back with a resume selector spliced on and its message replayed.
    func testOpencodeReadsItsSubcommandPastAValueTakingOption() {
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: #"opencode --model anthropic/claude run "fix""#))
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode --model anthropic/claude run "fix""#, sessionKey: "abc"),
            #"opencode --model anthropic/claude run "fix""#)

        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: "opencode --model anthropic/claude"))
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "opencode --model anthropic/claude", sessionKey: "abc"),
            "opencode --model anthropic/claude -s abc")

        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: #"opencode --model anthropic/claude run -i "go""#))
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode --model anthropic/claude run -i "go""#, sessionKey: "abc"),
            "opencode --model anthropic/claude run -i -s abc")
    }

    // MARK: - `--` ends option parsing

    /// `--` is where each of these CLIs stops reading options, so every word after it is a prompt word
    /// whatever it is spelled like. Read as options, `claude -- -p` would be taken for a one-shot print run
    /// and `codex -- exec` for an `exec` job, and each would come back as a new run instead of the
    /// conversation the user left.
    func testEndOfOptionsMakesEveryFollowingWordAPrompt() {
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: "claude -- -p"))
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: "codex -- exec"))
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: "claude -p -- fix"), "a marker written before the `--` is still an option")
    }

    /// The prompt a `--` guards is dropped like any other prompt, and the `--` itself stays where the user
    /// wrote it: Claude Code reads a trailing `--` as no operand at all, so keeping it costs the relaunch
    /// nothing while cutting it would rewrite a line the user typed.
    func testResumingStripsThePromptAfterEndOfOptionsAndKeepsTheGuard() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude -- -p", sessionKey: "abc"), "claude --resume abc --")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "claude -- 'prompt'", sessionKey: "abc"), "claude --resume abc --")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude --model opus -- "fix it""#, sessionKey: "abc"), "claude --resume abc --model opus --")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "codex -- exec", sessionKey: "abc"), "codex resume abc --")
    }

    // MARK: - Quoting is the shell's, not the agent's

    /// A shell strips quotes before the CLI sees a word, so the walk compares the unquoted word: `claude
    /// "--" -p` hands the agent `--` and then `-p`, which ends option parsing and makes `-p` the prompt.
    /// Read as written, the quoted guard would be missed, `-p` would count as the print flag, and an
    /// interactive session would come back as a fresh one-shot run with its resume key dropped. The guard
    /// itself stays exactly as the user typed it, quotes included, because only the prompt span is cut.
    func testAQuotedEndOfOptionsGuardStillEndsOptionParsing() {
        XCTAssertFalse(CodingAgent.launchIsOneShotJob(launchCommand: #"claude "--" -p"#))
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude "--" -p"#, sessionKey: "abc"), #"claude --resume abc "--""#)
    }

    /// A quoted marker is the marker: the agent is handed `-p` or `exec` whatever quotes carried it there,
    /// so the run is the one-shot job it will be and comes back as a new run written exactly as typed.
    func testAQuotedOneShotMarkerIsStillAMarker() {
        for command in [#"claude '-p' 'prompt'"#, #"codex 'exec' "do it""#] {
            XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: command), command)
            XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: command, sessionKey: "abc"), command)
        }
    }

    /// Reading the unquoted word changes only what the walk compares against. A quoted option value is
    /// still the option's value and keeps its quotes in the relaunch, and the prompt after it is still the
    /// one span that goes.
    func testQuotedOptionValuesKeepTheirQuotesThroughAResume() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude --model 'opus' 'prompt'"#, sessionKey: "abc"), "claude --resume abc --model 'opus'")
    }

    // MARK: - A resumed conversation already holds its prompt

    /// The conversation being resumed already contains the prompt the agent was started with, so sending it
    /// again would have the agent redo work it has already done. Every option the command carried is kept,
    /// including the values that would otherwise look like a prompt.
    func testResumingStripsThePositionalPromptAndKeepsEveryOptionValue() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude "fix the build""#, sessionKey: "abc"), "claude --resume abc")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude --model sonnet --permission-mode plan "fix""#, sessionKey: "abc"),
            "claude --resume abc --model sonnet --permission-mode plan")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "claude --model=sonnet --verbose 'fix'", sessionKey: "abc"),
            "claude --resume abc --model=sonnet --verbose")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"codex --yolo "add tests""#, sessionKey: "abc"), "codex resume abc --yolo")
    }

    /// The option tables are a snapshot of CLIs that keep moving, so an installed agent can carry an
    /// option they do not know: the walk reads it as a flag, and its value then stands where the first
    /// positional would be. Stripping the last positional keeps that value with its option and still takes
    /// the prompt, which is conventionally the final word of the line.
    func testAnOptionTheTablesDoNotKnowKeepsItsValueAndThePromptIsStillStripped() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "claude --new-option value 'actual prompt'", sessionKey: "abc"),
            "claude --resume abc --new-option value")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"codex --unknown v "prompt""#, sessionKey: "abc"), "codex resume abc --unknown v")
    }

    /// The command a typed agent is recorded from is POSIX-quoted by the foreground inspector, so its
    /// prompt arrives in single quotes rather than double ones. The rewrite reads the same tokens either
    /// way: the executable is still the first word, and the whole quoted prompt is one token to drop.
    func testAPromptQuotedTheWayACapturedCommandQuotesItIsStillReadAsOneToken() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude --model opus 'fix the build'"#, sessionKey: "abc"), "claude --resume abc --model opus")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude 'it'\''s broken --resume'"#, sessionKey: "abc"), "claude --resume abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"codex '*.swift is failing'"#, sessionKey: "abc"), "codex resume abc")
    }

    /// A variadic option takes every following non-option word, so a prompt written after one belongs to
    /// that option as far as the CLI is concerned; cutting a word out of it would change what the agent can
    /// reach rather than what it was asked to do.
    func testAPromptAfterAVariadicOptionIsLeftWhereTheCLIReadsIt() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude --add-dir ../x "fix""#, sessionKey: "abc"), #"claude --resume abc --add-dir ../x "fix""#
        )
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude --add-dir ../x --verbose "fix""#, sessionKey: "abc"),
            "claude --resume abc --add-dir ../x --verbose")
    }

    /// Codex's `-i, --image <FILE>...` takes every following word, so both images survive the relaunch.
    /// Read as an option taking a single value, the second image would be mistaken for the prompt and cut
    /// out, and the relaunched agent would come back one attachment short. A word written after the images
    /// is another image as far as Codex is concerned, so it stays where the user put it; the prompt is
    /// stripped once an option has ended the image list.
    func testCodexImageOptionKeepsEveryImageAndStripsThePromptAfterTheListEnds() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"codex -i a.png b.png "fix the build""#, sessionKey: "abc"),
            #"codex resume abc -i a.png b.png "fix the build""#)
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"codex --image a.png b.png --yolo "fix""#, sessionKey: "abc"),
            "codex resume abc --image a.png b.png --yolo")
    }

    /// opencode's top-level positional is the project directory to open, never a prompt, so nothing is
    /// stripped from its command.
    func testOpencodeKeepsItsPositionalProjectPath() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode ../other-project", sessionKey: "abc"), "opencode ../other-project -s abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode /path/to/project", sessionKey: "abc"), "opencode /path/to/project -s abc")
    }

    /// After `run` the positionals are the message opencode sends, so an interactive run drops them the way
    /// Claude Code's and Codex's positional prompt is dropped: the conversation being rejoined already
    /// holds it, and sending it again would have the agent redo the work.
    func testOpencodeStripsTheMessageOfAnInteractiveRun() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"opencode run -i "start here""#, sessionKey: "abc"), "opencode run -i -s abc")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode run --interactive "start here""#, sessionKey: "abc"),
            "opencode run --interactive -s abc")
    }

    /// `opencode run` takes its message as a variadic positional, so an unquoted message is several words
    /// and every one of them is the message. Dropping only the last would relaunch the run with a mangled
    /// fragment of the instruction standing in the command.
    func testOpencodeStripsEveryWordOfAnUnquotedMessage() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode run -i fix the bug", sessionKey: "abc"), "opencode run -i -s abc")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode run --interactive "start" here"#, sessionKey: "abc"),
            "opencode run --interactive -s abc")
    }

    /// An option's value is not part of the message however many words follow it, so a run whose message
    /// words trail a value-taking option keeps the option with its value and loses only the message.
    func testOpencodeKeepsAnOptionValueBesideAnUnquotedMessage() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "opencode run -i --title t fix it", sessionKey: "abc"), "opencode run -i --title t -s abc")
    }

    /// opencode carries its prompt in `--prompt` rather than positionally, and a named prompt goes the same
    /// way a positional one does: the conversation being rejoined already holds it, so a resumed agent that
    /// received it again would redo the work. The project path beside it is not a prompt and stays.
    func testOpencodeStripsItsNamedPromptOptionAndKeepsTheProjectPath() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"opencode --prompt "fix the build""#, sessionKey: "abc"), "opencode -s abc")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode --prompt "fix" /path/to/project"#, sessionKey: "abc"),
            "opencode /path/to/project -s abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode --prompt=fix", sessionKey: "abc"), "opencode -s abc")
    }

    /// Without a conversation to rejoin the relaunch is a fresh run, so the named prompt stays exactly where
    /// the user wrote it, the same way a positional prompt does.
    func testOpencodeKeepsItsNamedPromptWhenThereIsNoConversation() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode --prompt "fix the build""#, sessionKey: nil), #"opencode --prompt "fix the build""#)
    }

    /// Without a conversation to rejoin the relaunch is a fresh run, and the prompt is what it runs.
    func testNoConversationKeepsThePrompt() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude "fix the build""#, sessionKey: nil), #"claude "fix the build""#)
    }

    /// An interactive Codex run whose prompt merely mentions `exec` is resumed like any other: the word is
    /// inside the quoted prompt, which the scan stops at. Global options are carried through untouched.
    func testCodexInteractiveRunsAreResumedWhateverTheirPromptAndFlagsSay() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"codex "fix exec bug""#, sessionKey: "abc"), "codex resume abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"codex --full-auto "fix""#, sessionKey: "abc"), "codex resume abc --full-auto")
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
            CodingAgent.resumeCommand(launchCommand: "claude -r old-conversation", sessionKey: "new-conversation"), "claude -r new-conversation")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: "claude --resume=old-conversation --verbose", sessionKey: "new-conversation"),
            "claude --resume=new-conversation --verbose")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"codex resume old-conversation -m gpt-5 "ship it""#, sessionKey: "new-conversation"),
            "codex resume new-conversation -m gpt-5")
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
            CodingAgent.resumeCommand(launchCommand: "codex resume --last", sessionKey: "new-conversation"), "codex resume new-conversation --last")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode -s", sessionKey: "new-conversation"), "opencode -s new-conversation")
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
        // The prompt goes with the resume, but it goes as a prompt: read as a selector it would instead have
        // taken the captured key in place of the word `behavior`.
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude "explain --resume behavior""#, sessionKey: "abc"), "claude --resume abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "codex 'walk me through resume'", sessionKey: "abc"), "codex resume abc")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"opencode "use --session carefully""#, sessionKey: "abc"),
            #"opencode "use --session carefully" -s abc"#)
    }

    /// The real selector still wins when both are present: the conversation the command names is the one
    /// replaced, and the quoted prompt is read as the prompt (and so dropped) rather than as a selector.
    func testARealSelectorIsReplacedWhileAQuotedPromptIsReadAsThePrompt() {
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: #"claude --resume old-id "explain --resume behavior""#, sessionKey: "new-id"),
            "claude --resume new-id")
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
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude explain\ --resume\ behavior"#, sessionKey: "abc"), "claude --resume abc")
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
            CodingAgent.resumeCommand(launchCommand: #"opencode "compare \"a && b\"""#, sessionKey: "abc"), #"opencode "compare \"a && b\"" -s abc"#)
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: #"claude 'it'\''s'"#, sessionKey: "abc"), "claude --resume abc")
    }

    /// A redirection is part of the command, not the end of it. `2>&1` and `&>` both carry an `&` that ends
    /// nothing, and splitting there would splice the selector into the middle of the redirection.
    func testRedirectionsDoNotEndTheAgentsSegment() {
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode 2>&1", sessionKey: "abc"), "opencode 2>&1 -s abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode &> log", sessionKey: "abc"), "opencode &> log -s abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode &>> log", sessionKey: "abc"), "opencode &>> log -s abc")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: "opencode 2>&1 | tee log", sessionKey: "abc"), "opencode 2>&1 -s abc | tee log")
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
