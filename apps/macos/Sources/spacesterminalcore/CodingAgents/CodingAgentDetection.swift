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
        case .copilot:
            // Homebrew and standalone installs run the native `copilot` binary directly (and keep that
            // name when auto-update runs a newer build from its package cache). An npm install runs
            // `node .../@github/copilot/npm-loader.js`, which spawns the native `copilot` child from
            // `@github/copilot-<platform>-<arch>/` with inherited stdio; either process classifies as
            // Copilot, the script by its package path since `npm-loader.js` alone says nothing.
            return [
                CodingAgentDetectionVariant(
                    kind: .copilot, executableNames: ["copilot"], nodeScriptNames: ["copilot", "copilot.js"],
                    nodePathFragments: ["/@github/copilot/"])
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
        case .copilot: .copilot
        }
    }
}
