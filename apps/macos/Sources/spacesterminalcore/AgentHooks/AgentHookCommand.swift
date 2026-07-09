import Foundation

/// Builds the shell command a coding-agent hook runs to report a lifecycle signal to Spaces.
///
/// The command relies on `spaces agent signal` to read Spaces session environment and no-op outside
/// Spaces-managed sessions. Hook output is discarded and failures are swallowed so a transient Spaces
/// outage never surfaces as noisy or failed agent hook execution. A trailing `# spaces-agent-hook`
/// comment marks Spaces-owned entries so the installer can find and replace them idempotently.
public enum AgentHookCommand {
    /// Marker comment appended to every generated command. Used by the writers to identify and
    /// replace Spaces-owned hook entries without disturbing the user's other hooks.
    public static let marker = "spaces-agent-hook"

    /// Builds the `spaces agent signal` invocation for `event`.
    public static func signalCommand(event: AgentHookLifecycleEvent) -> String {
        "spaces agent signal \(event.rawValue) >/dev/null 2>&1 || true # \(marker)"
    }

    /// True when `command` is a Spaces-owned hook command (carries the marker).
    public static func isSpacesOwned(_ command: String) -> Bool { command.contains("# \(marker)") }
}
