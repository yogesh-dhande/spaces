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
/// or failed agent hook execution. A trailing `# spaces-agent-hook` comment marks Spaces-owned entries
/// so the installer can find and replace them idempotently.
public enum AgentHookCommand {
    /// Executable name probed on `PATH` and common install directories to build hook commands.
    public static let spacesExecutableName = "spaces"

    /// Marker comment appended to every generated command. Used by the writers to identify and
    /// replace Spaces-owned hook entries without disturbing the user's other hooks.
    public static let marker = "spaces-agent-hook"

    /// Builds the `spaces agent signal` invocation for `event`.
    public static func signalCommand(event: AgentHookLifecycleEvent, spacesExecutablePath: String) -> String {
        "\(shellQuoted(spacesExecutablePath)) agent signal \(event.rawValue) >/dev/null 2>&1 || true # \(marker)"
    }

    /// True when `command` is a Spaces-owned hook command (carries the marker).
    public static func isSpacesOwned(_ command: String) -> Bool { command.contains("# \(marker)") }

    /// Single-quotes a path for `sh -c`, which is how every supported agent runs a `type: "command"`
    /// hook. A home directory containing a space or a quote would otherwise split into extra arguments.
    static func shellQuoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
