import Foundation

/// Builds the shell command a coding-agent hook runs to report a lifecycle signal to Spaces.
///
/// The command invokes an absolute `spaces` path resolved at install time rather than relying on
/// `spaces` being on the hook process's `PATH`. Agents run hooks with whatever environment they
/// inherited, which need not contain the directory the Spaces CLI lives in — and because the command
/// discards output and swallows failures, an unresolvable `spaces` would make every hook a silent
/// no-op that still reports as installed. Resolving once, at install time, is what makes a reported
/// "hooks installed" mean the hook can actually run. The path is captured when hooks are installed, so
/// moving or reinstalling the `spaces` binary requires reinstalling hooks.
///
/// Output is discarded and failures are swallowed so a transient Spaces outage never surfaces as noisy
/// or failed agent hook execution. A trailing `# spaces-agent-hook v<N>` comment marks Spaces-owned
/// entries so the installer can find and replace them idempotently, and records which version of the
/// hook shape wrote them.
public enum AgentHookCommand {
    /// Executable name probed on `PATH` and common install directories to build hook commands.
    public static let spacesExecutableName = "spaces"

    /// SPACES_HOOK_VERSION. Bump by hand whenever `signalCommand`, the opencode plugin body, or an
    /// agent's event bindings change. A config carrying an older number reads back as `.outdated`,
    /// which is what re-offers the update to a user whose hooks a previous Spaces release installed.
    ///
    /// v2: per-tool `working` bindings (Claude/Codex `PreToolUse`, opencode `tool.execute.before`) so
    /// an agent resuming after a permission approval leaves `blocked`.
    /// v3: post-approval `working` bindings (Claude/Codex `PostToolUse`, opencode `permission.replied`).
    /// v2's `PreToolUse` fires *before* the permission decision, so it can never end the block it
    /// precedes — the row stayed `waiting` until a *later*, different tool call, or until `Stop`.
    public static let hookVersion = 3

    /// Version-less ownership token. Every Spaces-owned entry, of every version, contains it.
    ///
    /// Never embed the version here. Stripping on reinstall matches on this token, and that is exactly
    /// what removes an entry an older Spaces wrote. A version-aware ownership test would leave the old
    /// entry in place and append a second one beside it on every reinstall.
    public static let marker = "spaces-agent-hook"

    /// The trailing comment actually written: `spaces-agent-hook v<hookVersion>`. `marker` is a prefix
    /// of it, so `isSpacesOwned` keeps matching every version.
    static func versionedMarker(_ version: Int = hookVersion) -> String { "\(marker) v\(version)" }

    /// Builds the `spaces agent signal` invocation for `event`.
    public static func signalCommand(event: AgentHookLifecycleEvent, spacesExecutablePath: String) -> String {
        "\(shellQuoted(spacesExecutablePath)) agent signal \(event.rawValue) >/dev/null 2>&1 || true # \(versionedMarker())"
    }

    /// True when `command` is a Spaces-owned hook command (carries the marker), whatever its version.
    public static func isSpacesOwned(_ command: String) -> Bool { command.contains("# \(marker)") }

    /// The hook version embedded in Spaces-owned text (a shell command or the opencode plugin header),
    /// or nil when the text predates versioned markers. Reads the whole digit run, so `v1` never
    /// matches the `v1` prefix of `v10`.
    static func embeddedVersion(in text: String) -> Int? {
        guard let markerRange = text.range(of: "\(marker) v") else { return nil }
        let digits = text[markerRange.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// True when `text` carries the hook version this build writes. Distinct from `isSpacesOwned`, and
    /// used only on the status path — never to decide what to strip.
    static func isCurrent(_ text: String) -> Bool { embeddedVersion(in: text) == hookVersion }

    /// Single-quotes a path for `sh -c`, which is how every supported agent runs a `type: "command"`
    /// hook. A home directory containing a space or a quote would otherwise split into extra arguments.
    static func shellQuoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
