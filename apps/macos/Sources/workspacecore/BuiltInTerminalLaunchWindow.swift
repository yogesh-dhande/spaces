import Foundation

/// How long after its recorded creation a built-in terminal session's launch still counts as coming up.
///
/// One definition for both readers of the rule: the per-session probe
/// (`WorkspaceOrchestrator.builtInSessionLaunchIsPending`) and the batched classification
/// (`EndedTerminalSessions`), which must agree on what a pending launch is or a workspace's run state
/// would depend on which of them asked.
enum BuiltInTerminalLaunchWindow {
    /// The window opens slightly before the recorded creation so a launch stamped by a clock a little
    /// ahead of the reader's still reads as pending rather than as coming from the future.
    private static let ages: Range<TimeInterval> = -5..<60

    static func covers(createdAt: Date, now: Date) -> Bool { ages.contains(now.timeIntervalSince(createdAt)) }
}
