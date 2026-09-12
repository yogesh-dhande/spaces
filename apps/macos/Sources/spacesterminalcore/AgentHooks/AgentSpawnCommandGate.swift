import Foundation

extension CodingAgent {
    /// Parses the executable token from a shell command line and matches it against a supported coding
    /// agent by executable name. Leading `VAR=value` environment assignments and a leading `env` (with
    /// its own assignments) are skipped, then the executable's basename is compared to each agent's
    /// `executableNames`. Returns `nil` when the command does not launch a supported coding agent.
    ///
    /// Used both to gate `spaces agent spawn` (only supported agents report the lifecycle signals spawn
    /// readiness depends on) and to derive a spawned session's default title from the agent it launches.
    public static func matching(command: String) -> CodingAgent? {
        guard let token = executableToken(inCommand: command) else { return nil }
        let name = (token as NSString).lastPathComponent
        return allCases.first { $0.executableNames.contains(name) }
    }

    /// The executable token of a command line: the first token that is neither a `VAR=value` assignment
    /// nor a leading `env` (whose own trailing assignments are also skipped).
    public static func executableToken(inCommand command: String) -> String? {
        guard let range = executableTokenRange(inCommand: command) else { return nil }
        return String(command[range])
    }

    /// Where the executable token sits in the command line. Callers that rewrite the command (see
    /// `resumeCommand(launchCommand:sessionKey:)`) splice at this range rather than re-joining tokens, so
    /// quoting and spacing in the rest of the line survive; `executableToken(inCommand:)` reads the same
    /// range, so both answers come from one scan rule.
    static func executableTokenRange(inCommand command: String) -> Range<String.Index>? {
        var tokens = firstSegmentTokenRanges(inCommand: command)
        while let first = tokens.first, isEnvironmentAssignment(String(command[first])) { tokens.removeFirst() }
        if let first = tokens.first, command[first] == "env" {
            tokens.removeFirst()
            while let next = tokens.first, isEnvironmentAssignment(String(command[next])) { tokens.removeFirst() }
        }
        return tokens.first
    }

    /// The tokens of the command's first segment, as ranges into the original string, split on spaces and
    /// tabs outside quotes. The first segment is the agent's own argv (see
    /// `firstCommandSegmentRange(inCommand:)`); scanning it rather than the whole line is also what
    /// separates a program from an operator written straight after it: `opencode; echo done` starts with
    /// the token `opencode`, not `opencode;`.
    ///
    /// A single- or double-quoted span is part of the token it sits in, whitespace and all, the way a shell
    /// reads it: `claude "explain --resume behavior"` is two tokens, not four. The returned range covers
    /// the quotes as written, because callers splice text back into the original string.
    ///
    /// Shared with `resumeCommand(launchCommand:sessionKey:)`, which reads the arguments after the
    /// executable to find a conversation the command already names. Quoting is what keeps that scan off a
    /// prompt: a selector word inside a quoted prompt is part of a longer token and matches nothing, so
    /// the prompt is left exactly as the user wrote it. An unterminated quote runs to the end of the
    /// segment, which is the whole of what the shell would have to work with too.
    static func firstSegmentTokenRanges(inCommand command: String) -> [Range<String.Index>] {
        let bounds = firstCommandSegmentRange(inCommand: command)
        var ranges: [Range<String.Index>] = []
        var index = bounds.lowerBound
        while index < bounds.upperBound {
            guard command[index] != " ", command[index] != "\t" else {
                index = command.index(after: index)
                continue
            }
            let start = index
            var quote: Character?
            while index < bounds.upperBound {
                let character = command[index]
                if quote == nil, character == "\\" {
                    // Outside quotes a backslash makes the next character literal, an escaped space or quote
                    // included, so both stay inside this token rather than ending it.
                    index = command.index(after: index)
                    if index < bounds.upperBound { index = command.index(after: index) }
                    continue
                }
                if let open = quote {
                    // Inside double quotes a backslash escapes the next character, so an escaped quote does
                    // not close the span. Inside single quotes a shell escapes nothing, so it does.
                    if open == "\"", character == "\\" {
                        index = command.index(after: index)
                        if index < bounds.upperBound { index = command.index(after: index) }
                        continue
                    }
                    if character == open { quote = nil }
                } else if character == "'" || character == "\"" {
                    quote = character
                } else if character == " " || character == "\t" {
                    break
                }
                index = command.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    /// The span of the command's first segment: everything before the first shell control operator
    /// (`&&`, `||`, `|`, `;`, `&`) outside quotes, with trailing whitespace left out.
    ///
    /// A launch command can chain programs (`opencode && notify`, `opencode | tee agent.log`), and only the
    /// first segment is the agent's own argv. `resumeCommand(launchCommand:sessionKey:)` works inside this
    /// span for both halves of its job: a selector appended to the whole string would be handed to the last
    /// program in the chain instead of the agent, and a selector found in a later segment belongs to that
    /// other program, not to the conversation being resumed.
    static func firstCommandSegmentRange(inCommand command: String) -> Range<String.Index> {
        var index = command.startIndex
        var quote: Character?
        var previous: Character?
        while index < command.endIndex {
            let character = command[index]
            if let open = quote {
                // Inside double quotes a backslash escapes the next character, so an escaped quote does not
                // close the span and an operator inside it is still text. Single quotes escape nothing.
                if open == "\"", character == "\\" {
                    index = command.index(after: index)
                    if index < command.endIndex { index = command.index(after: index) }
                    previous = nil
                    continue
                }
                if character == open { quote = nil }
                previous = character
                index = command.index(after: index)
                continue
            }
            if character == "\\" {
                // A backslash makes the next character literal, so an escaped operator is text the command
                // carries rather than the end of it. Both characters are stepped over together.
                index = command.index(after: index)
                if index < command.endIndex { index = command.index(after: index) }
                previous = nil
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "|" || character == ";" {
                break
            } else if character == "&", !Self.isRedirectionAmpersand(inCommand: command, at: index, previous: previous) {
                break
            }
            previous = character
            index = command.index(after: index)
        }
        var end = index
        while end > command.startIndex {
            let previous = command.index(before: end)
            guard command[previous] == " " || command[previous] == "\t" else { break }
            end = previous
        }
        return command.startIndex..<end
    }

    /// Whether the `&` at `index` belongs to a redirection rather than ending the command. `2>&1` and
    /// `<&3` bind a descriptor to another one, and `&>`/`&>>` send both streams to a file: in none of them
    /// does a new command start, so a segment that ended there would splice an argument into the middle of
    /// a redirection. A bare `&` (background) and `&&` still end the segment.
    private static func isRedirectionAmpersand(inCommand command: String, at index: String.Index, previous: Character?) -> Bool {
        if previous == ">" || previous == "<" { return true }
        let next = command.index(after: index)
        return next < command.endIndex && command[next] == ">"
    }

    /// A `NAME=value` shell assignment, where `NAME` is a valid environment-variable identifier.
    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

/// Gate for `spaces agent spawn`: the command must launch a supported coding agent (see `CodingAgent`).
/// This is only a command-shape gate — it identifies *which* coding agent the command
/// launches so spawn readiness knows which foreground kind to await. Hooks are deliberately NOT a
/// prerequisite: spawn readiness is foreground-detection-based (the daemon's foreground classification
/// identifies the running agent), and a promptless Codex never emits `SessionStart`, so requiring a
/// hook signal to spawn would time out. Hook signals still power live status once they arrive; they
/// just don't gate the spawn.
public enum AgentSpawnCommandGate {
    public enum GateError: Error, LocalizedError, Equatable {
        case unsupportedCommand

        public var errorDescription: String? {
            switch self {
            case .unsupportedCommand: return "Agent spawn requires a supported coding agent command (\(CodingAgent.commandListText))."
            }
        }
    }

    /// Resolves the supported agent a spawn command launches, throwing `GateError.unsupportedCommand`
    /// when the command does not launch one. Pure over the command string.
    public static func resolveSpawnableAgent(command: String) throws -> CodingAgent {
        guard let agent = CodingAgent.matching(command: command) else { throw GateError.unsupportedCommand }
        return agent
    }
}
