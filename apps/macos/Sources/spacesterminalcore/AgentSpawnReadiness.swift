import Foundation

/// Shared readiness gate for a terminal command expected to become a coding agent. It is deliberately
/// based on observed runtime facts, not an allow-list of commands: the daemon must see a stable detected
/// foreground agent whose TUI has taken ownership of input before this reports readiness.
public enum AgentSpawnReadiness {
    /// Real Claude Code measurements put the longest DECSET-2004-to-composer interval at 2.2 seconds.
    /// Three seconds leaves a fixed margin without adding a caller-controlled timing mode.
    public static let inputReadinessConfirmation: TimeInterval = 3

    /// One poll of the spawned session. `state == nil` means the session has not appeared in a device
    /// overview yet and should remain pending until its deadline.
    public struct SessionSnapshot: Equatable, Sendable {
        public let detectedKind: TerminalDetectedAgentKind?
        public let bracketedPasteActive: Bool
        public let state: TerminalSessionState?

        public init(detectedKind: TerminalDetectedAgentKind?, bracketedPasteActive: Bool, state: TerminalSessionState?) {
            self.detectedKind = detectedKind
            self.bracketedPasteActive = bracketedPasteActive
            self.state = state
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The classifier identified a coding agent and its TUI is reading input.
        case ready(TerminalDetectedAgentKind)
        /// The terminal child ended before it was ready.
        case ended(TerminalSessionState)
        /// The child kept running without reaching readiness before the fixed deadline.
        case timedOut
    }

    /// Incremental counterpart to `awaitReadiness`. UI code calls this from an async polling loop, so
    /// it gets the same stable-detection semantics without blocking the main actor between samples.
    public struct PollTracker: Sendable {
        private let deadline: Date
        private var confirmationStartedAt: Date?
        private var confirmationKind: TerminalDetectedAgentKind?

        public init(deadline: Date) { self.deadline = deadline }

        public mutating func observe(_ snapshot: SessionSnapshot, at observedAt: Date = Date()) -> Outcome? {
            // An ended child wins over a simultaneously stale foreground classification.
            if let state = snapshot.state, !state.isInteractive { return .ended(state) }
            if observedAt >= deadline { return .timedOut }
            if let kind = snapshot.detectedKind, snapshot.bracketedPasteActive {
                if confirmationKind != kind {
                    confirmationKind = kind
                    confirmationStartedAt = observedAt
                } else if let confirmationStartedAt,
                    observedAt.timeIntervalSince(confirmationStartedAt) >= AgentSpawnReadiness.inputReadinessConfirmation
                {
                    return .ready(kind)
                }
            } else {
                confirmationStartedAt = nil
                confirmationKind = nil
            }
            return nil
        }
    }

    /// Polls `snapshot` until the child continuously reports a detected coding agent with bracketed
    /// paste for the input-readiness confirmation interval, the child's session ends, or the deadline
    /// passes. The CLI uses this synchronous form; UI code uses `PollTracker` above.
    public static func awaitReadiness(
        deadline: Date, pollInterval: TimeInterval, now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, snapshot: () throws -> SessionSnapshot
    ) throws -> Outcome {
        var tracker = PollTracker(deadline: deadline)
        while true {
            if let outcome = tracker.observe(try snapshot(), at: now()) { return outcome }
            sleep(pollInterval)
        }
    }

    /// The last non-blank lines of a terminal tail, in order, capped at `limit`.
    public static func lastNonBlankLines(inTail tail: String, limit: Int = 3) -> [String] {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty
        }
        return Array(lines.suffix(limit))
    }
}
