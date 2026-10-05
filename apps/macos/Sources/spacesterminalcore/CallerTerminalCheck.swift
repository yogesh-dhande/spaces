import Foundation

/// Decides whether a request that took its terminal from the caller's environment really comes from that
/// terminal.
///
/// A process carries the terminal's `SPACES_TERMINAL_TRACKING_ID` wherever it is carried: Codex's shared
/// app-server, a tmux server, an IDE, or a background agent session all inherit it from whichever
/// terminal started them and then serve other terminals. Trusting the variable alone would put their
/// signals and briefs on the wrong row, so the daemon counts the claim only when the terminal's shell is
/// an ancestor of the calling process.
///
/// The daemon makes this check rather than the client because it owns the shell pids, including those of
/// sessions it adopted across an update handoff, which no environment variable could name.
public struct CallerTerminalCheck: Sendable {
    /// The shell pid of a live session, or nil when the session is unknown or has ended.
    let liveShellPID: @Sendable (String) -> Int32?

    public init(liveShellPID: @escaping @Sendable (String) -> Int32?) { self.liveShellPID = liveShellPID }

    /// Reads the shell pid from the session's persisted runtime state, which the session core keeps
    /// current through spawn and handoff adoption.
    public static let persistedRuntimeState = CallerTerminalCheck { sessionID in
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let state = try? TerminalSessionPersistence.readRuntimeState(paths: paths), state.state.isInteractive
        else { return nil }
        return state.childPID
    }

    /// Whether the request may act for `sessionID`. A request that carries no caller pid named its
    /// terminal explicitly, and a session with no live shell is left to the request's own handling of an
    /// unknown or ended terminal.
    public func permits(sessionID: String, callerProcessID: Int32?) -> Bool {
        guard let callerProcessID, let shellPID = liveShellPID(sessionID) else { return true }
        return ProcessAncestry.isDescendant(callerProcessID, of: shellPID)
    }

    /// Throws `CallerOutsideTerminalError` when `permits` is false.
    public func require(sessionID: String, callerProcessID: Int32?) throws {
        guard permits(sessionID: sessionID, callerProcessID: callerProcessID) else { throw CallerOutsideTerminalError() }
    }
}

/// A request defaulted its terminal from the environment but its process does not run inside that
/// terminal.
public struct CallerOutsideTerminalError: LocalizedError, Equatable {
    public init() {}

    public var errorDescription: String? {
        "The calling process is not running inside the Spaces terminal its environment names, so Spaces can't tell which terminal is calling. This happens with Codex's shared background server, or with tmux or IDE processes started from another terminal. Pass the session explicitly to target a terminal."
    }
}
