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
        case .pi:
            // An npm install runs `node .../@earendil-works/pi-coding-agent/dist/bundle/cli.js`, which sets
            // `process.title = "pi"`. On macOS that overwrites the whole argv area, so `ps` shows comm and
            // args `pi` and the inspector sees argv `["pi"]` under a node executable; its argv[0] candidate
            // is what matches `executableNames` (verified against pi 1.1.0). A bun-compiled standalone
            // binary is named `pi`. The deprecated `@mariozechner/pi-coding-agent` package (0.73.x) lacks the
            // extension events the integration needs, so its path is not matched; once it sets its title it
            // still reads as `pi`, and its row gets no status because the Spaces extension registers nothing
            // below pi 1.1.0.
            return [
                CodingAgentDetectionVariant(
                    kind: .pi, executableNames: ["pi"], nodeScriptNames: ["pi"],
                    nodePathFragments: ["/@earendil-works/pi-coding-agent/"])
            ]
        case .amp:
            // The official installer puts a Mach-O binary at `~/.amp/bin/amp`, and `ps` shows comm `amp`
            // with the real argv (verified against amp 0.0.1791849701). An npm install of
            // `@sourcegraph/amp` runs a node script under that package, matched by its path.
            return [
                CodingAgentDetectionVariant(
                    kind: .amp, executableNames: ["amp"], nodeScriptNames: ["amp", "amp.js"],
                    nodePathFragments: ["/@sourcegraph/amp/"])
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
        case .pi: .pi
        case .amp: .amp
        }
    }
}
