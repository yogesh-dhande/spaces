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

/// Gate for `spaces agent spawn`: the command must launch a supported coding agent whose Spaces hooks
/// are fully installed (`.current`), otherwise the spawned agent would never report the lifecycle
/// signal spawn blocks on. Kept pure over a supplied `[AgentHookStatus]` so the caller owns the
/// filesystem read (`AgentHookInstaller.status()`) and tests can supply synthetic statuses.
public enum AgentSpawnCommandGate {
    public enum GateError: Error, LocalizedError, Equatable {
        case unsupportedCommand
        case hooksNotInstalled(SupportedCodingAgentHook, AgentHookInstallState)

        public var errorDescription: String? {
            switch self {
            case .unsupportedCommand:
                return "Agent spawn requires a supported coding agent command (claude, codex, or opencode)."
            case .hooksNotInstalled(let hook, _):
                return
                    "\(hook.displayName) hooks are not installed on this device, so a spawned session would never report readiness. Install coding-agent hooks from the Spaces app (Settings → Coding Agents or device setup), then retry."
            }
        }
    }

    /// Resolves the supported agent a spawn command launches, requiring its hooks to be `.current`.
    /// Throws `GateError` otherwise.
    public static func resolveSpawnableAgent(command: String, statuses: [AgentHookStatus]) throws -> SupportedCodingAgentHook {
        guard let hook = SupportedCodingAgentHook.matching(command: command) else { throw GateError.unsupportedCommand }
        let state = statuses.first { $0.kind == hook }?.installState ?? .notInstalled
        guard state == .current else { throw GateError.hooksNotInstalled(hook, state) }
        return hook
    }
}
