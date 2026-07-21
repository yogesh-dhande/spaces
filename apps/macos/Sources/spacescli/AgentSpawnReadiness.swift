import Foundation
import spacesterminalcore

/// Foreground-detection-based readiness for `spaces agent spawn`, expressed as pure polling logic over
/// injected clock / sleep / read closures. The CLI wires those closures to real profile commands (local)
/// or the Device API overview (remote); unit tests drive them deterministically.
///
/// Rationale (validated on the real system): the daemon's foreground process classifier identifies a
/// spawned coding agent within ~1s, uniformly across every supported coding agent (see `CodingAgent`), and hook-free. That makes
/// detection — not a hook signal — the reliable "the agent is up" marker: a promptless Codex never emits
/// `SessionStart`, so first-signal readiness would time out. Spawn returns at detection and delivers no
/// prompt itself; the orchestrator sends the prompt with `terminal send` and confirms work with
/// `terminal tail`/`agent status`, because only the orchestrator can see and answer the common first-run
/// dialogs (trust/onboarding, auth gates) that a spawn-internal heuristic cannot.
enum AgentSpawnReadiness {
    /// Polls `detectedKind` until it returns a non-nil foreground agent kind or the deadline passes.
    /// Returns the detected kind, or nil on timeout.
    static func awaitForegroundDetection(
        deadline: Date, pollInterval: TimeInterval, now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, detectedKind: () throws -> TerminalDetectedAgentKind?
    ) throws -> TerminalDetectedAgentKind? {
        while true {
            if let kind = try detectedKind() { return kind }
            if now() >= deadline { return nil }
            sleep(pollInterval)
        }
    }
}
