import Foundation

/// The lifecycle status of a single automation execution attempt.
public enum AutomationRunStatus: String, Codable, Sendable, CaseIterable {
    /// A queue-policy run waiting for the current run to finish before it executes.
    case queued
    /// The command's terminal session is live.
    case running
    /// The command exited with code 0.
    case succeeded
    /// The command exited with a non-zero code (recorded in `exitCode`) or its session failed to launch.
    case failed
    /// The command exceeded the automation's timeout and was terminated.
    case timedOut = "timed_out"
    /// The run was canceled through the cancel entry point.
    case canceled
    /// The fire never executed a command: a concurrency policy blocked it, or a missed cron occurrence
    /// was skipped on daemon start. `skipReason` records which.
    case skipped

    /// Whether this status is terminal (the run will never change again on its own).
    public var isTerminal: Bool {
        switch self {
        case .queued, .running: false
        case .succeeded, .failed, .timedOut, .canceled, .skipped: true
        }
    }
}
