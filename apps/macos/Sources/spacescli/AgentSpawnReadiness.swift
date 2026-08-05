import Foundation
import spacesterminalcore

/// Readiness for `spaces agent spawn`, expressed as pure polling logic over injected clock / sleep /
/// read closures. The CLI wires those closures to the spawned session's runtime state (local) or the
/// Device API overview (remote); unit tests drive them deterministically.
///
/// Rationale (validated on the real system): the daemon's foreground process classifier identifies a
/// spawned coding agent within ~1s, uniformly across every supported coding agent (see `CodingAgent`), and hook-free. That makes
/// detection — not a hook signal — the reliable "the agent is up" marker: a promptless Codex never emits
/// `SessionStart`, so first-signal readiness would time out. Spawn returns at detection and delivers no
/// prompt itself; the orchestrator sends the prompt with `terminal send` and confirms work with
/// `terminal tail`/`agent status`, because only the orchestrator can see and answer the common first-run
/// dialogs (trust/onboarding, auth gates) that a spawn-internal heuristic cannot.
///
/// The wait watches the session's own run state alongside detection, because the two failures it has to
/// tell apart look identical to a detection-only poll: an agent that is slow to start, and a command
/// that never ran at all. The second is the common one (a mistyped or unresolvable command), the daemon
/// records it within a second, and waiting out the full detection budget for it costs 90s and then
/// reports the classifier rather than the exit.
enum AgentSpawnReadiness {
    /// One poll of the spawned session: what the daemon's foreground classifier reports for it, and the
    /// run state of the session itself. `state` is nil when the session is not reported at all, which
    /// leaves the wait polling until the deadline.
    struct SessionSnapshot: Equatable {
        let detectedKind: TerminalDetectedAgentKind?
        let state: TerminalSessionState?
    }

    enum Outcome: Equatable {
        /// The classifier identified a coding agent: spawn succeeded.
        case detected(TerminalDetectedAgentKind)
        /// The session's child ended before an agent was identified: the command itself failed to run.
        case ended(TerminalSessionState)
        /// The deadline passed with the child still running and never classified.
        case timedOut
    }

    /// Polls `snapshot` until the child is detected as a coding agent, the child's session ends, or the
    /// deadline passes.
    static func awaitReadiness(
        deadline: Date, pollInterval: TimeInterval, now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, snapshot: () throws -> SessionSnapshot
    ) throws -> Outcome {
        while true {
            let current = try snapshot()
            // An ended child is decided before detection: the session cannot be prompted once its child
            // is gone, so a classification carried in the same read is stale and must not be reported as
            // readiness.
            if let state = current.state, !state.isInteractive { return .ended(state) }
            if let kind = current.detectedKind { return .detected(kind) }
            if now() >= deadline { return .timedOut }
            sleep(pollInterval)
        }
    }

    /// The last non-blank lines of a terminal tail, in order, capped at `limit`.
    ///
    /// This is what a failed spawn reports as the child's own account of why it died — the shell's
    /// diagnosis (`zsh:1: command not found: claude`) is the last thing written before the child exits.
    /// A rendered tail is a fixed-size screen padded with blank lines, so blanks are dropped rather than
    /// counted, and trailing whitespace on a padded line is trimmed.
    static func lastNonBlankLines(inTail tail: String, limit: Int = 3) -> [String] {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty
        }
        return Array(lines.suffix(limit))
    }
}
