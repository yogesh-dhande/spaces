import Foundation

/// THE registry of coding agents Spaces integrates: every per-agent facet — display metadata, config
/// locations, executable names, and hook wiring — is an exhaustive `switch self` over this enum, so
/// adding a new integration means adding one case and filling in each switch's missing arm.
///
/// Raw values are device-API wire format for hook install/status payloads (see
/// `SpacesDeviceInstallAgentHooksRequest.kinds` and `AgentHookStatus.kind`) — never rename a case.
/// A client decoding a wire list typed by this enum must tolerate raw values it does not know, since a
/// newer daemon can report an agent an older client lacks (see `SkippingUnreadableList`).
///
/// Distinct from `TerminalDetectedAgentKind` (which splits `claude`/`claude-code` for foreground
/// process classification): here "Claude Code" is one target that owns `~/.claude/settings.json`.
public enum CodingAgent: String, CaseIterable, Sendable, Codable {
    case claudeCode
    case codex
    case opencode
    case copilot

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "opencode"
        case .copilot: "Copilot"
        }
    }

    /// Two-letter tile text used in the settings row, matching the workspace agent-row tiles.
    public var tileText: String {
        switch self {
        case .claudeCode: "CL"
        case .codex: "CX"
        case .opencode: "OC"
        case .copilot: "CP"
        }
    }

    /// Executable names to probe on PATH / common install dirs for availability. The first entry is the
    /// agent's canonical CLI command (see `primaryCommandName`); probing/matching against the rest of
    /// the list is set-like and does not depend on this order.
    var executableNames: [String] {
        switch self {
        case .claudeCode: ["claude"]
        case .codex: ["codex"]
        case .opencode: ["opencode"]
        case .copilot: ["copilot"]
        }
    }

    /// The agent's canonical CLI command — `executableNames`' first entry.
    public var primaryCommandName: String { executableNames[0] }

    /// All agents' `primaryCommandName`s joined in prose, Oxford-comma style: "claude, codex,
    /// opencode, or copilot". Derived from `allCases` so a new agent appears automatically in help/error text that
    /// enumerates supported commands.
    public static var commandListText: String {
        let names = allCases.map(\.primaryCommandName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) or \(names[1])"
        default: return "\(names.dropLast().joined(separator: ", ")), or \(names.last!)"
        }
    }

    /// The agent's config directory, relative to home.
    public func configDirectoryURL(home: URL) -> URL {
        switch self {
        case .claudeCode: home.appendingPathComponent(".claude", isDirectory: true)
        case .codex: home.appendingPathComponent(".codex", isDirectory: true)
        case .opencode: home.appendingPathComponent(".config/opencode", isDirectory: true)
        // Copilot's `COPILOT_HOME` override is not read: like `CODEX_HOME`, it names a home the user's
        // shell chose, which the daemon's environment need not share.
        case .copilot: home.appendingPathComponent(".copilot", isDirectory: true)
        }
    }
}
