import Foundation

/// The result of foreground-process classification: which coding agent (if any) is running as a
/// terminal's foreground process, as observed live from the OS process table.
///
/// Deliberately splits `claude` from `claudeCode` ("claude-code") even though both map to the same
/// `CodingAgent.claudeCode` registry entry (see `TerminalDetectedAgentKind.agent`): the classifier
/// can tell the plain `claude` executable apart from a wrapper/shim literally named `claude-code`,
/// and callers care which one was actually observed running.
///
/// Raw values are load-bearing: they are persisted in the SQLite `foreground_detected_agent_kind`
/// column (see `TerminalSessionPersistence`) and decoded off the device-overview wire in
/// `spacescli/SpacesCommand.swift`. Never rename a case or change its raw value.
public enum TerminalDetectedAgentKind: String, Codable, Sendable, Equatable, CaseIterable {
    case codex
    case claude
    case claudeCode = "claude-code"
    case opencode

    public var displayLabel: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .claudeCode: "claude-code"
        case .opencode: "opencode"
        }
    }

    var commandName: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .claudeCode: "claude-code"
        case .opencode: "opencode"
        }
    }
}
