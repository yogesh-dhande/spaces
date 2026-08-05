import Foundation

/// One matchable "shape" a `CodingAgent` can appear as in a foreground process: a native executable
/// name, or a Node.js script invocation (script basename or path fragment) run under `node`/`nodejs`.
///
/// `kind` carries the `TerminalDetectedAgentKind` this variant reports when matched — see that
/// enum's doc comment for why it can differ from the owning `CodingAgent` (the `claude` vs
/// `claude-code` split).
public struct CodingAgentDetectionVariant: Sendable {
    let kind: TerminalDetectedAgentKind
    let executableNames: Set<String>
    let nodeScriptNames: Set<String>
    let nodePathFragments: [String]

    var commandName: String { kind.commandName }
    var displayLabel: String { kind.displayLabel }
}

extension CodingAgent {
    /// The foreground-process shapes `TerminalForegroundProcessInspector` matches against for this
    /// agent.
    ///
    /// `.claudeCode` owns two variants because `TerminalDetectedAgentKind` deliberately splits
    /// `claude-code` from plain `claude` (see that enum's doc comment); the more specific
    /// `claude-code` variant is listed first so it is tried before the broader `claude` variant.
    public var detectionVariants: [CodingAgentDetectionVariant] {
        switch self {
        case .codex:
            return [
                CodingAgentDetectionVariant(
                    kind: .codex, executableNames: ["codex"], nodeScriptNames: ["codex", "codex.js"],
                    nodePathFragments: ["/@openai/codex/", "/codex/bin/codex.js", "/codex/bin/codex"])
            ]
        case .claudeCode:
            return [
                CodingAgentDetectionVariant(
                    kind: .claudeCode, executableNames: ["claude-code"], nodeScriptNames: ["claude-code", "claude-code.js"], nodePathFragments: []),
                CodingAgentDetectionVariant(
                    kind: .claude, executableNames: ["claude"], nodeScriptNames: ["claude", "claude.js"], nodePathFragments: []),
            ]
        case .opencode:
            // The `opencode-ai` npm package installs the selected Darwin binary at
            // `bin/opencode.exe`; npm exposes it to users as `opencode`.
            return [
                CodingAgentDetectionVariant(
                    kind: .opencode, executableNames: ["opencode", "opencode.exe"], nodeScriptNames: ["opencode", "opencode.js"],
                    nodePathFragments: ["/opencode-ai/", "/opencode/bin/opencode"])
            ]
        }
    }
}

extension TerminalDetectedAgentKind {
    /// The registry entry this detected process kind belongs to.
    public var agent: CodingAgent {
        switch self {
        case .claude, .claudeCode: .claudeCode
        case .codex: .codex
        case .opencode: .opencode
        }
    }
}
