import Foundation

extension CodingAgent {
    /// The command that relaunches `launchCommand` into the conversation `sessionKey` names, or
    /// `launchCommand` unchanged when there is no key to resume or the command launches no supported
    /// agent (the relaunch then starts a fresh conversation with the same command).
    ///
    /// A command that already names a conversation has that conversation swapped for `sessionKey`, and
    /// only a command that names none takes a selector spliced in. A second selector is not a matter of
    /// tidiness: `codex resume <new> resume <old>` is rejected outright, and a duplicated Claude Code
    /// selector can resume the older conversation of the two.
    ///
    /// Each provider takes its resume argument in its own place, so the shape is an exhaustive switch:
    ///  - Claude Code: `--resume <key>` immediately after the executable, composing with every other flag
    ///    and a trailing prompt the command already carried.
    ///  - Codex: `resume <key>` immediately after the executable, because `resume` is a subcommand and
    ///    Codex's own flags belong after it.
    ///  - opencode: `-s <key>` at the end of the agent's own segment, which is where its session option is
    ///    accepted.
    ///
    /// Every rewrite stays inside the command's first segment (see `firstCommandSegmentRange(inCommand:)`),
    /// so a chained command such as `opencode && notify` hands the selector to the agent rather than to
    /// whatever runs after it.
    ///
    /// Every rewrite is made on the original string rather than on re-joined tokens, so quoting and
    /// spacing in the rest of the command (a leading environment prefix, flags, a trailing prompt, the rest
    /// of a chain) survive untouched.
    public static func resumeCommand(launchCommand: String, sessionKey: String?) -> String {
        guard let key = sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return launchCommand }
        guard let agent = matching(command: launchCommand) else { return launchCommand }
        // A one-shot run takes no resume selector at all (see `launchIsOneShotJob`). The capture already
        // drops such a command's conversation id so the offer says it comes back as a new run; this guard
        // is what makes the rewrite itself total, for a caller that still holds one.
        guard !launchIsOneShotJob(launchCommand: launchCommand) else { return launchCommand }
        // Claude Code's `--session-id` names the id a NEW conversation is to be created under, and Claude
        // refuses it alongside `--resume`, so a command carrying one has it dropped: the relaunch is
        // resuming the conversation the capture named, not starting the one the original command asked for.
        let withoutSessionID = agent == .claudeCode ? removingSessionIDOption(inCommand: launchCommand) : launchCommand
        let command = agent.removingPrompt(inCommand: withoutSessionID)
        if let named = agent.namedConversation(inCommand: command) {
            return command.replacingCharacters(in: named.range, with: named.separator + key)
        }
        switch agent {
        case .claudeCode: return insert("--resume \(key)", afterExecutableTokenIn: command)
        case .codex: return insert("resume \(key)", afterExecutableTokenIn: command)
        case .opencode:
            let segment = CodingAgent.firstCommandSegmentRange(inCommand: command)
            return command.replacingCharacters(in: segment.upperBound..<segment.upperBound, with: " -s \(key)")
        }
    }

    /// Whether the command launches a run this rewrite must leave exactly as written rather than a
    /// conversation it can rejoin: `claude -p`/`--print`, a Claude Code subcommand run (`claude attach
    /// <id>`, `claude mcp ...`, `claude update`, and the rest of its `Commands:` list), `codex exec` (and
    /// its `e` alias), `codex review`, `codex fork`, and `opencode run` without `-i`/`--interactive`.
    ///
    /// Most of those are jobs rather than sessions: they print an answer and exit. Codex additionally takes
    /// a one-shot run's conversation as `codex exec resume <key>`, after options whose arity only Codex
    /// knows, so a spliced selector would be rejected outright. A captured one-shot run therefore comes
    /// back as a new run of the command it was launched with, through the same path as an agent that
    /// reported no conversation at all, with its prompt left exactly as written because a fresh run needs
    /// it.
    ///
    /// The scan reads the arguments the way the agent's own CLI reads them (see
    /// `firstAnswer(walkingArgumentsIn:_:)`), so a marker counts only where the CLI would take one: an
    /// option token anywhere in the argv, and a subcommand only at the subcommand position, which is the
    /// first positional argument. Quoting hides nothing, because the shell strips it before the CLI sees
    /// the word, so `claude '-p'` is the print run it will run as; what a quoted phrase gives is one longer
    /// word that matches no marker. An option's value is not a marker either, nor a positional after the
    /// first, nor anything a `--` guards: `codex "exec the plan"`, `codex --model exec`, `claude "attach
    /// the debugger"`, `claude -- -p`, and `codex -- exec` are all read as the conversations they are, and
    /// `claude --append-system-prompt "Be terse" -p "review this"` is read as the one-shot run it is.
    ///
    /// A subcommand marker can be cancelled by an option written after it (`opencode run -i`), so the walk
    /// runs on past such a marker rather than answering at it, and the marker stands only if no cancelling
    /// option turns up in the rest of the arguments.
    public static func launchIsOneShotJob(launchCommand: String) -> Bool {
        guard let agent = matching(command: launchCommand) else { return false }
        let markers = agent.oneShotLaunchMarkers
        var cancellingOptions: Set<String> = []
        let answer = agent.firstAnswer(walkingArgumentsIn: launchCommand) { argument, _ -> Bool? in
            switch argument {
            case .option(let name):
                if cancellingOptions.contains(name) { return false }
                return markers.options.contains(name) ? true : nil
            case .positional(let text, let isSubcommandPosition):
                if isSubcommandPosition, let cancels = markers.subcommands[text] {
                    guard !cancels.isEmpty else { return true }
                    cancellingOptions = cancels
                    return nil
                }
                // A marker already matched is waiting on the options that could cancel it, so the words it
                // was given (`opencode run "do it"`) settle nothing.
                guard cancellingOptions.isEmpty else { return nil }
                // An agent whose markers are all subcommands has its answer here, at the one place it takes
                // one: a first positional that is not a marker is the prompt, a marker written after it is
                // prompt text, and a first positional the command's `--` guards is prompt text however it is
                // spelled (`codex -- exec` runs the interactive TUI on the prompt `exec`). Claude Code also
                // takes an option marker, which counts wherever it is written, so its walk goes on past a
                // prompt to look for one.
                return markers.isSettledAtTheSubcommandPosition ? false : nil
            }
        }
        // A marker whose cancelling options never turned up stands: the walk ended with the question still
        // open only because it had to read to the end of the arguments to be sure.
        return answer ?? !cancellingOptions.isEmpty
    }

    /// Where an agent's one-shot markers sit in its argv, which is what the scan compares tokens against.
    /// An agent can take both shapes: Claude Code's `-p` composes with the rest of the command, while its
    /// subcommands lead one.
    private struct OneShotLaunchMarkers {
        /// Tokens counted as options, wherever among the arguments they are written.
        let options: Set<String>
        /// Tokens counted only at the subcommand position (the first positional argument), each carrying
        /// the options that cancel it: an option in that set, written anywhere after the subcommand, means
        /// the subcommand is running a long-lived session rather than a job. Most markers carry an empty
        /// set, which nothing can cancel.
        let subcommands: [String: Set<String>]

        init(options: Set<String> = [], subcommands: [String: Set<String>] = [:]) {
            self.options = options
            self.subcommands = subcommands
        }

        init(options: Set<String> = [], subcommands: Set<String>) {
            self.init(options: options, subcommands: Dictionary(uniqueKeysWithValues: subcommands.map { ($0, []) }))
        }

        /// Whether the subcommand position settles the question for this agent. It does when subcommands
        /// are all it takes: nothing written later can make such a launch one-shot, and reading a later
        /// positional as a subcommand would take prompt text for one.
        var isSettledAtTheSubcommandPosition: Bool { options.isEmpty }
    }

    /// The tokens that mark a launch as a one-shot run for this agent (see `launchIsOneShotJob`).
    ///
    /// Codex's list covers the subcommands that can be captured carrying a conversation yet cannot take a
    /// spliced `resume`: `exec`/`e` and `review` are non-interactive jobs, and `fork <id>` names the session
    /// it continues from in a position `resume` does not accept, so `codex resume <key> fork <id>` is
    /// rejected outright and the command is relaunched as written instead. Codex's other subcommands never
    /// reach this rewrite and so are not listed: `login`, `logout`, `apply`, `mcp`, `plugin`, `update`, and
    /// `doctor` are short-lived non-agent commands that are over before a capture can name them, and
    /// `cloud`, `agents`, `sandbox`, `debug`, and the `*-server` commands hold no conversation of their own
    /// to report, so no key is ever captured against one.
    ///
    /// opencode's `run` is the one marker an option cancels: `opencode run "fix lint"` prints an answer and
    /// exits, but `-i`/`--interactive` (opencode 1.18.18's `run in direct interactive split-footer mode`)
    /// makes the same subcommand a long-lived session, which is a conversation to rejoin like any other.
    private var oneShotLaunchMarkers: OneShotLaunchMarkers {
        switch self {
        case .claudeCode: OneShotLaunchMarkers(options: ["-p", "--print"], subcommands: Self.claudeCodeSubcommands)
        case .codex: OneShotLaunchMarkers(subcommands: ["exec", "e", "review", "fork"])
        // opencode writes its subcommand first (`opencode run "fix lint"`), which is where the scan reads
        // it; the TUI's own positional in that place is a project path and matches nothing.
        case .opencode: OneShotLaunchMarkers(subcommands: ["run": ["-i", "--interactive"]])
        }
    }

    /// Claude Code's own subcommands, its `Commands:` list with each alias (claude 2.1.270).
    ///
    /// A subcommand run is not a conversation to resume: `claude update`, `claude doctor`, and `claude mcp
    /// ...` manage the installation rather than talk to it, and a spliced `--resume <key>` would be read by
    /// the subcommand rather than by a session, if it were accepted at all. `attach` is the one that is
    /// long-lived, and it is listed for the same reason: `claude attach <id>` opens a background session
    /// that is not the conversation the key names, so resuming it would hand the user a different
    /// conversation from the one they left. Without this the first positional would be stripped as a
    /// prompt as well, turning `claude attach bg123` into `claude --resume <key> bg123`.
    ///
    /// The whole published list is carried, rather than only the subcommands a capture can name the way
    /// Codex's is, because Claude Code hands it over as one list and a name in it is never a prompt: an
    /// entry no capture can reach costs nothing, while one left out is a command rewritten into something
    /// the user did not ask for.
    private static let claudeCodeSubcommands: Set<String> = [
        "agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "kill", "logs", "mcp", "plugin", "plugins", "project",
        "respawn", "rm", "setup-token", "stop", "ultrareview", "update", "upgrade",
    ]

    /// The selectors each provider accepts a conversation through. Codex takes a `resume` subcommand
    /// rather than a flag, which the scan below treats the same way: the word that introduces the
    /// conversation, with the conversation either attached by `=` or standing as the next word.
    private var conversationSelectors: [String] {
        switch self {
        case .claudeCode: ["--resume", "-r"]
        case .codex: ["resume"]
        case .opencode: ["--session", "-s"]
        }
    }

    /// Where a command already names a conversation: the span to overwrite, and the text that carries the
    /// new key into it. A conversation already spelled out is replaced outright; a selector given without
    /// one (`claude --resume`, which picks interactively, or `codex resume --last`) takes the key as the
    /// word after it, which is an empty span plus a separating space.
    private struct NamedConversation {
        let range: Range<String.Index>
        let separator: String
    }

    /// Scans the arguments after the executable for a selector this agent takes a conversation through.
    /// The scan reads the command's shell tokens, so a selector word inside a quoted prompt
    /// (`claude "explain --resume behavior"`) is part of one longer token and matches nothing: the prompt
    /// keeps its text and the captured key is spliced in as a real selector instead. It reads only the
    /// agent's own segment, so a selector belonging to a program later in a chain is not mistaken for one
    /// of the agent's.
    private func namedConversation(inCommand command: String) -> NamedConversation? {
        let tokens = CodingAgent.firstSegmentTokenRanges(inCommand: command)
        guard let executable = CodingAgent.executableTokenRange(inCommand: command), let executableIndex = tokens.firstIndex(of: executable) else {
            return nil
        }
        let arguments = Array(tokens[tokens.index(after: executableIndex)...])

        for (offset, token) in arguments.enumerated() {
            let text = command[token]
            for selector in conversationSelectors {
                if text == selector {
                    if let next = arguments[(offset + 1)...].first, !command[next].hasPrefix("-") {
                        return NamedConversation(range: next, separator: "")
                    }
                    return NamedConversation(range: token.upperBound..<token.upperBound, separator: " ")
                }
                if text.hasPrefix(selector + "=") {
                    let identifier = command.index(token.lowerBound, offsetBy: selector.count + 1)
                    return NamedConversation(range: identifier..<token.upperBound, separator: "")
                }
            }
        }
        return nil
    }

    /// The command without the prompt it was started with, for a relaunch that is resuming a conversation.
    ///
    /// A resumed conversation already contains the prompt it was started with, so sending it again would
    /// make the agent redo work it has already done (and, mid-conversation, act on a stale instruction).
    /// Only a relaunch that carries a conversation id strips it: without one the relaunch is a fresh run
    /// and the prompt is the whole point of it.
    ///
    /// A prompt reaches an agent in one of two places, and both go the same way for the same reason. The
    /// positional prompt is an argument after the executable that is neither an option nor an option's
    /// value, which is why the option tables below exist: `claude --model sonnet "fix"` must strip `"fix"`
    /// and not `sonnet`. A named prompt option carries the same instruction through a flag instead
    /// (opencode's `--prompt "fix the build"`), so it is stripped together with its value, in both the
    /// `--prompt value` and the `--prompt=value` form. Which agent takes which is per agent, not per
    /// command, and both are data: `positionalPromptRule` says which positionals are the prompt (Claude
    /// Code's and Codex's are, opencode's only after its `run` subcommand, since its top-level positional
    /// is the project directory to open), and `promptOptions` names the flags that carry one.
    ///
    /// A conversation selector counts as an option that takes a value for this scan, so
    /// `claude --resume abc "fix"` strips only the prompt and leaves the selector for the rewrite to fill
    /// in. A subcommand sits in the same place as a prompt and would be stripped as one (`claude attach
    /// bg123` would relaunch as `claude --resume <key> bg123`), but every Claude Code and Codex subcommand
    /// that can reach this rewrite is classified one-shot and relaunched exactly as written (see
    /// `launchIsOneShotJob`), so none of them gets here.
    ///
    /// How many of the positionals a rule admits are stripped is the rule's own answer
    /// (`promptSpansEveryAdmittedPositional`). Under `.afterSubcommand` the whole message is stripped,
    /// because opencode's `run` takes it as a variadic positional: `opencode run -i fix the bug` is one
    /// three-word message, and keeping any of those words would re-send a mangled instruction. Under
    /// `.everyPositional` only the LAST positional is stripped rather than the first, because the option
    /// tables below can fall behind the installed CLI: an option they do not know is read as a flag, leaving
    /// its value standing where the first positional would be (see those tables), and that value has to keep
    /// standing.
    ///
    /// A prompt a `--` guards is stripped like any other (`claude -- -p` resumes as `claude --resume <key>
    /// --`), since the guard makes it a prompt rather than a flag.
    private func removingPrompt(inCommand command: String) -> String {
        // Answering nil to every argument walks the whole command, so `positionals` ends up holding every
        // positional the rule admits, in the order they were written. The walk hands an option the span of
        // the option together with the value it consumes, so a named prompt goes with its value however the
        // two are written.
        var positionals: [Range<String.Index>] = []
        var named: [Range<String.Index>] = []
        // A rule tied to a subcommand is settled by the word at the subcommand position, so the walk carries
        // that answer forward to the positionals after it.
        var positionalsArePrompt = positionalPromptRule == .everyPositional
        _ = firstAnswer(walkingArgumentsIn: command) { argument, span -> Range<String.Index>? in
            switch argument {
            case .option(let name): if promptOptions.contains(name) { named.append(span) }
            case .positional(let text, let isSubcommandPosition):
                if case .afterSubcommand(let subcommand) = positionalPromptRule, isSubcommandPosition {
                    positionalsArePrompt = text == subcommand
                } else if positionalsArePrompt {
                    positionals.append(span)
                }
            }
            return nil
        }
        let prompt = positionalPromptRule.promptSpansEveryAdmittedPositional ? positionals : Array(positionals.suffix(1))
        return CodingAgent.removing(spans: named + prompt, inCommand: command)
    }

    /// A token the argument walk below visits, read as the agent's own CLI reads it.
    private enum WalkedArgument {
        /// An option, named without any `=value` attached to it, as the shell hands the name on.
        case option(name: String)
        /// An argument that is neither an option nor the value of one, as the shell hands the word on.
        /// `isSubcommandPosition` marks the one place a CLI reads a subcommand: the first positional, and
        /// only while the command's `--` has not put it past option parsing, since a guarded word can be a
        /// prompt but never a subcommand.
        case positional(text: String, isSubcommandPosition: Bool)
    }

    /// Walks the arguments after the executable the way this agent's CLI reads them, handing each option
    /// and each positional to `visit` along with the span it occupies, and stopping at the first answer
    /// `visit` returns.
    ///
    /// Keeping the walk in one place is what keeps the arity rules in one place: an option's value, a
    /// variadic option's whole list, a shell redirection together with the file it names, and the `--` that
    /// ends option parsing are stepped over rather than visited on their own, so neither the scan for a
    /// one-shot marker nor the scan for the prompt can mistake one of them for an argument the user gave
    /// the agent. An option's span covers the value it consumes, so a caller removing an option removes the
    /// value with it without repeating those rules.
    ///
    /// Every comparison the walk makes is against the shell-unquoted word
    /// (`TerminalForegroundProcessInspector.posixUnquoted`) while every span it hands to `visit` is a range
    /// of raw tokens. A command reaches the rewrite as the text a shell will run, and quoting is invisible
    /// to the CLI that reads it: `claude "--" -p` hands the agent `--` followed by `-p`, so reading the
    /// quoted token literally would miss the end of option parsing and take `-p` for the print flag,
    /// classifying an interactive session as a one-shot run and dropping its resume key. Editing by raw
    /// range is what keeps the rewritten command byte-for-byte the user's own apart from the spans that
    /// are removed or spliced in.
    private func firstAnswer<Answer>(walkingArgumentsIn command: String, _ visit: (WalkedArgument, Range<String.Index>) -> Answer?) -> Answer? {
        let tokens = CodingAgent.firstSegmentTokenRanges(inCommand: command)
        guard let executable = CodingAgent.executableTokenRange(inCommand: command), let executableIndex = tokens.firstIndex(of: executable) else {
            return nil
        }
        let arguments = Array(tokens[tokens.index(after: executableIndex)...])
        let words = arguments.map { TerminalForegroundProcessInspector.posixUnquoted(String(command[$0])) }

        var index = 0
        var endOfOptions = false
        var sawPositional = false
        while index < arguments.count {
            let span = arguments[index]
            let word = words[index]
            // A redirection is part of the command the user wrote, not an argument to the agent, and it does
            // not start with `-`, so the walk has to step over it and over the file it names or it would
            // read `2>&1` as the prompt and cut it out. It is read from the raw token because quoting is
            // exactly what tells a redirection apart from text the agent was given.
            let rawToken = String(command[span])
            if CodingAgent.isRedirection(rawToken) {
                index += 1
                if rawToken.hasSuffix(">") || rawToken.hasSuffix("<"), index < arguments.count { index += 1 }
                continue
            }
            // A `--` is where each of these CLIs stops reading options, so every word after it is a
            // positional however it is spelled (`claude -- -p` runs the TUI on the prompt `-p`). The token
            // itself is neither an option nor a positional: it is punctuation the CLI consumes, and the
            // relaunch keeps it exactly where the user wrote it. Keeping it is safe once the prompt it
            // guarded is stripped: `claude [options] [command] [prompt]` reads a trailing `--` as no
            // operand at all (`claude --resume <key> --` parses and runs), so the guard costs nothing and
            // cutting it would rewrite a line the user typed.
            if !endOfOptions, word == "--" {
                endOfOptions = true
                index += 1
                continue
            }
            let optionName = String(word.split(separator: "=", maxSplits: 1).first ?? "")
            let isOption = !endOfOptions && (word.hasPrefix("-") || conversationSelectors.contains(optionName))
            guard isOption else {
                let isSubcommandPosition = !endOfOptions && !sawPositional
                sawPositional = true
                if let answer = visit(.positional(text: word, isSubcommandPosition: isSubcommandPosition), span) { return answer }
                index += 1
                continue
            }
            // The value the option consumes is located before the visit, so an option is handed over as the
            // whole span the CLI reads it as: an option that is removed goes with its value in one piece.
            var last = index
            if !word.contains("=") {
                if variadicOptions.contains(optionName) {
                    // A variadic option takes every following non-option word, so a prompt written after one
                    // is the option's value as far as the CLI is concerned and stays where the user put it.
                    while last + 1 < arguments.count, !words[last + 1].hasPrefix("-") { last += 1 }
                } else if optionsTakingValue.contains(optionName) || conversationSelectors.contains(optionName) || promptOptions.contains(optionName)
                {
                    if last + 1 < arguments.count, !words[last + 1].hasPrefix("-") { last += 1 }
                }
            }
            if let answer = visit(.option(name: optionName), span.lowerBound..<arguments[last].upperBound) { return answer }
            index = last + 1
        }
        return nil
    }

    /// Whether a token redirects a stream rather than passing an argument. The tokenizer keeps a
    /// redirection together with whatever is attached to it (`2>&1`, `&>`, `>log`), so an unquoted token
    /// carrying `>` or `<` is one; a quoted one is text the agent was given.
    private static func isRedirection(_ token: String) -> Bool {
        guard let first = token.first, first != "'", first != "\"" else { return false }
        return token.contains(">") || token.contains("<")
    }

    /// Which of a command's positional arguments carry the prompt the agent was started with, read from
    /// each CLI's own help the way the option tables below are.
    private enum PositionalPromptRule: Equatable {
        /// Every positional is the prompt (Claude Code and Codex).
        case everyPositional
        /// Only a positional written after this subcommand is the prompt; the subcommand word itself is
        /// not, and a positional in its place when the subcommand is absent is not either.
        case afterSubcommand(String)

        /// Whether the prompt is every positional the rule admits rather than a single one. It is under
        /// `.afterSubcommand`, because the subcommand that takes a prompt takes it variadically (`opencode
        /// run --help`: `message  message to send [array]`), so every word after the subcommand is one
        /// message and the message is only whole if all of them go. Claude Code and Codex take their prompt
        /// as a single positional, so `.everyPositional` admits candidates rather than message words and
        /// only the last of them is the prompt (see `removingPrompt(inCommand:)`).
        var promptSpansEveryAdmittedPositional: Bool {
            switch self {
            case .everyPositional: false
            case .afterSubcommand: true
            }
        }
    }

    /// Where this agent takes the prompt positionally (see `removingPrompt(inCommand:)`).
    ///
    /// opencode's top-level positional is the project directory to open (`opencode --help`: `project  path
    /// to start opencode in`) and survives a resume, while `opencode run`'s positionals are the message it
    /// sends (`opencode run --help`: `message  message to send [array]`) and go the way Claude Code's and
    /// Codex's prompt does, all of them together because the message is the words as one. Only an
    /// interactive `run` reaches this rewrite carrying a message, because a `run`
    /// without `-i`/`--interactive` is a one-shot job relaunched exactly as written (see
    /// `launchIsOneShotJob`); the rule is written against the subcommand rather than the flag so the
    /// message is read out of the same place whichever spelling made the run interactive.
    private var positionalPromptRule: PositionalPromptRule {
        switch self {
        case .claudeCode, .codex: .everyPositional
        case .opencode: .afterSubcommand("run")
        }
    }

    /// Options that carry the prompt the agent was started with, stripped with their value by a relaunch
    /// that is resuming a conversation (see `removingPrompt(inCommand:)`). Read from the installed CLIs'
    /// own `--help` (claude 2.1.270, codex-cli 0.153.4, opencode 1.18.18).
    ///
    /// Only opencode has one: `--prompt <string>`, with no short alias. Claude Code and Codex take the
    /// prompt as their positional argument and offer no option for it, so their tables are empty; Claude
    /// Code's `--system-prompt`, `--append-system-prompt`, and `--prompt-suggestions` configure the session
    /// rather than sending an instruction, and belong with the ordinary value-taking options.
    private var promptOptions: Set<String> {
        switch self {
        case .claudeCode, .codex: []
        case .opencode: ["--prompt"]
        }
    }

    /// Options whose value is the next word, so that word is never the prompt. Read from the installed
    /// CLIs' own `--help` (claude 2.1.270, codex-cli 0.153.4, opencode 1.18.18).
    ///
    /// Claude Code's optional-value options (`--debug [filter]`, `--worktree [name]`) are here too: its
    /// parser takes the next word as the value whenever that word is not itself an option, which is exactly
    /// what this scan does. Resume selectors are not listed; `conversationSelectors` covers them, and a
    /// named prompt option is covered by `promptOptions`.
    ///
    /// opencode's table is one set for the whole CLI, holding the options its help marks `[string]` or
    /// `[number]` both at the top level and under `opencode run`; its `[array]` options take repeated words
    /// and belong in `variadicOptions`. Without it an option's value stands where the first positional
    /// would be, so `opencode --model anthropic/claude run "fix"` reads `anthropic/claude` at the
    /// subcommand position, settles the one-shot scan before it reaches `run`, and sends a job back onto
    /// the resume path with its message replayed into a brand new session.
    ///
    /// These tables are a snapshot of CLIs that keep moving, which is why `removingPrompt` strips the LAST
    /// positional rather than the first for an agent whose prompt is a single positional: an option an
    /// installed agent has grown since is read as a flag, and its value then stands where the first
    /// positional would be. Taking the last one leaves that value with its option and still takes the
    /// prompt, which is conventionally the final word of the line (`claude --new-option value "actual
    /// prompt"`). Under these tables such a command has one positional, so the two readings agree.
    private var optionsTakingValue: Set<String> {
        switch self {
        case .claudeCode:
            [
                "--agent", "--agents", "--append-system-prompt", "--autocompact", "--cloud", "-d", "--debug", "--debug-file", "--effort",
                "--environment", "--fallback-model", "--from-pr", "--input-format", "--json-schema", "--max-budget-usd", "--model", "-n", "--name",
                "--output-format", "--permission-mode", "--permission-prompts", "--plugin-dir", "--plugin-url", "--prompt-suggestions",
                "--remote-control", "--remote-control-session-name-prefix", "--session-id", "--setting-sources", "--settings", "--system-prompt",
                "--system-prompt-snapshot", "--teleport", "-w", "--worktree",
            ]
        case .codex:
            [
                "-a", "--add-dir", "--ask-for-approval", "-C", "-c", "--cd", "--config", "--disable", "--enable", "--local-provider", "-m", "--model",
                "-p", "--profile", "--remote", "--remote-auth-token-env", "-s", "--sandbox",
            ]
        case .opencode:
            [
                "--agent", "--attach", "--command", "--dir", "--format", "--hostname", "--log-level", "--mdns-domain", "-m", "--model", "-p",
                "--password", "--port", "--replay-limit", "--title", "-u", "--username", "--variant",
            ]
        }
    }

    /// Options that take every following non-option word (Claude Code's `--add-dir <directories...>`,
    /// Codex's `-i, --image <FILE>...`, the options opencode's help marks `[array]`), so the scan for the
    /// prompt must run past all of them rather than stopping at the first. Arity is per agent, not per
    /// spelling: Codex's own `--add-dir <DIR>` takes a single directory and belongs with the options above.
    private var variadicOptions: Set<String> {
        switch self {
        case .claudeCode:
            [
                "--add-dir", "--allowed-tools", "--allowedTools", "--betas", "--disallowed-tools", "--disallowedTools", "--file", "--mcp-config",
                "--tools",
            ]
        case .codex: ["-i", "--image"]
        case .opencode: ["--cors", "-f", "--file"]
        }
    }

    /// The command without Claude Code's `--session-id <uuid>` (or `--session-id=<uuid>`) option, read from
    /// the agent's own segment with the same tokenizer the selector scan uses. One separating space goes
    /// with it, so removing the option does not leave a double space behind.
    private static func removingSessionIDOption(inCommand command: String) -> String {
        let tokens = firstSegmentTokenRanges(inCommand: command)
        guard let executable = executableTokenRange(inCommand: command), let executableIndex = tokens.firstIndex(of: executable) else {
            return command
        }
        let arguments = Array(tokens[tokens.index(after: executableIndex)...])
        for (offset, token) in arguments.enumerated() {
            let text = command[token]
            guard text == "--session-id" || text.hasPrefix("--session-id=") else { continue }
            var end = token.upperBound
            // The separated form takes the id as the next word; a flag there means the option was written
            // without one, and only the option itself goes.
            if text == "--session-id", let next = arguments[(offset + 1)...].first, !command[next].hasPrefix("-") { end = next.upperBound }
            return removing(span: token.lowerBound..<end, inCommand: command)
        }
        return command
    }

    /// The command with `span` cut out of it, taking one separating space with it so the removal does not
    /// leave a double space behind. The space before is preferred, so a removal at the end of the command
    /// does not leave a trailing one.
    private static func removing(span: Range<String.Index>, inCommand command: String) -> String { removing(spans: [span], inCommand: command) }

    /// The command with every span in `spans` cut out of it. The spans are ranges of `command` itself, so
    /// the result is assembled in one pass rather than by cutting one span at a time: an index into the
    /// original string means nothing in the shortened one a cut returns.
    private static func removing(spans: [Range<String.Index>], inCommand command: String) -> String {
        var result = ""
        var cursor = command.startIndex
        for cut in spans.map({ withSeparator($0, inCommand: command) }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard cut.lowerBound >= cursor else { continue }
            result += command[cursor..<cut.lowerBound]
            cursor = cut.upperBound
        }
        result += command[cursor...]
        return result
    }

    /// `span` widened by one separating space, so the removal does not leave a double space behind. The
    /// space before is preferred, so a removal at the end of the command does not leave a trailing one, and
    /// two spans can never claim the same space: each takes the one immediately before its own first token.
    private static func withSeparator(_ span: Range<String.Index>, inCommand command: String) -> Range<String.Index> {
        var start = span.lowerBound
        var end = span.upperBound
        if start > command.startIndex, command[command.index(before: start)] == " " {
            start = command.index(before: start)
        } else if end < command.endIndex, command[end] == " " {
            end = command.index(after: end)
        }
        return start..<end
    }

    /// Splices `argument` in directly after the command's executable token, keeping everything on either
    /// side byte-for-byte. The token is located by the same scan `executableToken(inCommand:)` performs,
    /// so a command with leading `VAR=value` assignments or a leading `env` has the argument placed after
    /// the real executable rather than after the first word.
    private static func insert(_ argument: String, afterExecutableTokenIn command: String) -> String {
        guard let range = executableTokenRange(inCommand: command) else { return command }
        return command.replacingCharacters(in: range, with: "\(command[range]) \(argument)")
    }
}
