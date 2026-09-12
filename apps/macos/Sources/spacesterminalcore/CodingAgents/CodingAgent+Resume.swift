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
        // Claude Code's `--session-id` names the id a NEW conversation is to be created under, and Claude
        // refuses it alongside `--resume`, so a command carrying one has it dropped: the relaunch is
        // resuming the conversation the capture named, not starting the one the original command asked for.
        let command = agent == .claudeCode ? removingSessionIDOption(inCommand: launchCommand) : launchCommand
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

    /// Whether the command launches Codex's non-interactive `exec` (or its `e` alias) run.
    ///
    /// Such a run is a one-shot job: its options belong to `exec` rather than to `codex`, and Codex takes
    /// its conversation as `codex exec resume <key>`, after options whose arity only Codex knows. Rather
    /// than carry that option table here and be wrong whenever it changes, a captured `exec` run comes back
    /// as a new run of the command it was launched with, through the same path as an agent that reported no
    /// conversation at all.
    ///
    /// The scan is deliberately lenient: it reads the tokens after the executable up to the first quoted
    /// one, and any unquoted `exec` or `e` among them counts. An unquoted prompt word that happens to be
    /// `exec` is therefore a false positive, which costs that one run its resume and nothing else, while a
    /// missed `exec` would build a relaunch Codex rejects outright.
    public static func launchIsOneShotCodexExec(launchCommand: String) -> Bool {
        guard matching(command: launchCommand) == .codex else { return false }
        let tokens = firstSegmentTokenRanges(inCommand: launchCommand)
        guard let executable = executableTokenRange(inCommand: launchCommand), let executableIndex = tokens.firstIndex(of: executable) else {
            return false
        }
        for token in tokens[tokens.index(after: executableIndex)...] {
            let text = launchCommand[token]
            guard !text.hasPrefix("'"), !text.hasPrefix("\"") else { return false }
            if text == "exec" || text == "e" { return true }
        }
        return false
    }

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
        guard let executable = CodingAgent.executableTokenRange(inCommand: command),
            let executableIndex = tokens.firstIndex(of: executable)
        else { return nil }
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
            var start = token.lowerBound
            if start > command.startIndex, command[command.index(before: start)] == " " {
                start = command.index(before: start)
            } else if end < command.endIndex, command[end] == " " {
                end = command.index(after: end)
            }
            return command.replacingCharacters(in: start..<end, with: "")
        }
        return command
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
