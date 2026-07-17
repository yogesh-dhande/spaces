import Foundation

extension SupportedCodingAgentHook {
    /// Parses the executable token from a shell command line and matches it against a supported coding
    /// agent by executable name. Leading `VAR=value` environment assignments and a leading `env` (with
    /// its own assignments) are skipped, then the executable's basename is compared to each agent's
    /// `executableNames`. Returns `nil` when the command does not launch a supported coding agent.
    ///
    /// Used both to gate `spaces agent spawn` (only supported agents report the lifecycle signals spawn
    /// readiness depends on) and to derive a spawned session's default title from the agent it launches.
    public static func matching(command: String) -> SupportedCodingAgentHook? {
        guard let token = executableToken(inCommand: command) else { return nil }
        let name = (token as NSString).lastPathComponent
        return allCases.first { $0.executableNames.contains(name) }
    }

    /// The executable token of a command line: the first token that is neither a `VAR=value` assignment
    /// nor a leading `env` (whose own trailing assignments are also skipped).
    public static func executableToken(inCommand command: String) -> String? {
        var tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = tokens.first, isEnvironmentAssignment(first) { tokens.removeFirst() }
        if tokens.first == "env" {
            tokens.removeFirst()
            while let first = tokens.first, isEnvironmentAssignment(first) { tokens.removeFirst() }
        }
        return tokens.first
    }

    /// A `NAME=value` shell assignment, where `NAME` is a valid environment-variable identifier.
    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

/// Gate for `spaces agent spawn`: the command must launch a supported coding agent (claude, codex, or
/// opencode). This is only a command-shape gate — it identifies *which* coding agent the command
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
            case .unsupportedCommand: return "Agent spawn requires a supported coding agent command (claude, codex, or opencode)."
            }
        }
    }

    /// Resolves the supported agent a spawn command launches, throwing `GateError.unsupportedCommand`
    /// when the command does not launch one. Pure over the command string.
    public static func resolveSpawnableAgent(command: String) throws -> SupportedCodingAgentHook {
        guard let hook = SupportedCodingAgentHook.matching(command: command) else { throw GateError.unsupportedCommand }
        return hook
    }
}
