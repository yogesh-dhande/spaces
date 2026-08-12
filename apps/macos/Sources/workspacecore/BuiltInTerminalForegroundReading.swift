import Foundation
import spacesterminalcore

/// Everything the conditional stop of a user-closed ad hoc terminal needs to read off a live session at
/// the instant it decides, gathered in one sample by the daemon's `BuiltInTerminalForegroundProcessSampler`.
///
/// It is deliberately separate from `TerminalForegroundProcessSnapshot`: that type is persisted runtime
/// state with a fixed shape, and the shell's child count is a live fact about this decision, not a field
/// of the foreground process.
public struct BuiltInTerminalForegroundReading: Sendable, Equatable {
    /// The session's foreground process, read from the PTY at sample time. Nil means the foreground pid
    /// could not be inspected (a zombie process-group leader in the instant before the shell reaps it);
    /// the child check below still stands on its own in that case.
    public let process: TerminalForegroundProcessSnapshot?
    /// Whether the session's own shell (the PTY child) has any child process at sample time. A shell
    /// holding background or stopped jobs is the tty's foreground process with an idle prompt's argv, so
    /// the foreground sample alone cannot tell it apart from a shell with nothing to lose.
    public let shellHasChildProcesses: Bool

    public init(process: TerminalForegroundProcessSnapshot?, shellHasChildProcesses: Bool) {
        self.process = process
        self.shellHasChildProcesses = shellHasChildProcesses
    }
}
