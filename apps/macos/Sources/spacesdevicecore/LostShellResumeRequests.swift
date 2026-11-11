import Foundation
import spacesterminalcore

/// Decides which shown terminals ask their device to replace a shell it lost, answers each session at
/// most once per client launch, and says when a failed session must not yet look failed. Shared by the
/// Mac and iOS clients so they apply one rule.
///
/// The device decides whether a session really is a lost shell; the client only avoids asking about
/// sessions that cannot be one. A session qualifies for a request when the overview reports it `.failed`
/// and a workspace terminal row names it, which excludes a finished shell (`.exited`), a configured
/// process, and a coding agent. The session is recorded as asked when the request is claimed, whatever
/// the outcome, so a refused or failed request is never repeated by showing the terminal again. The one
/// exception is a refusal because a pending restore offer holds the shell, which is released.
public struct LostShellResumeRequests {
    private var askedSessionIDs: Set<String> = []
    private var inFlightSessionIDs: Set<String> = []
    private var releasedSessionIDs: Set<String> = []

    public init() {}

    /// Whether the terminal for `sessionID` should send a request now, recording the session as asked
    /// (and its request as in flight, until `finish`) when it should. An overview that does not yet list
    /// the session leaves it unasked, so a later show of the terminal still can.
    public mutating func claim(sessionID: String, overview: SpacesDeviceOverviewPayload?) -> Bool {
        guard !askedSessionIDs.contains(sessionID), let overview, Self.isFailedTerminalRowSession(sessionID, in: overview) else { return false }
        askedSessionIDs.insert(sessionID)
        inFlightSessionIDs.insert(sessionID)
        releasedSessionIDs.remove(sessionID)
        return true
    }

    /// Records that the device answered the request for `sessionID`, success or refusal. Call after a
    /// successful answer's overview is installed, so the terminal has already moved to the replacement.
    public mutating func finish(sessionID: String) { inFlightSessionIDs.remove(sessionID) }

    /// Makes `sessionID` eligible again, for a request the device refused only because a pending restore
    /// offer held the shell (`isRestorePending`). The next overview install or show asks again, which is
    /// how a Skip frees the shell. Until then the terminal shows its failed state: the shell is
    /// legitimately held while the offer is open, so nothing is pending.
    public mutating func release(sessionID: String) {
        askedSessionIDs.remove(sessionID)
        inFlightSessionIDs.remove(sessionID)
        releasedSessionIDs.insert(sessionID)
    }

    /// Whether a terminal that is told `sessionID` failed must keep its previous presentation instead of
    /// showing the failed state: a request is in flight, or this terminal would ask as soon as the
    /// overview can say so. The caller applies it only to a session whose own state stream reports
    /// `.failed`; that report can precede the overview that lists the failure, so a session no terminal
    /// row is known to name yet is held rather than shown failed for the moment before the request.
    ///
    /// A session that will never be asked is not held: one the overview shows as exited or names by no
    /// terminal row (a process, an agent), one already answered (the refusal is the outcome to show), and
    /// one released while a restore offer holds the shell.
    public func holdsFailedState(sessionID: String, overview: SpacesDeviceOverviewPayload?) -> Bool {
        if inFlightSessionIDs.contains(sessionID) { return true }
        guard !askedSessionIDs.contains(sessionID), !releasedSessionIDs.contains(sessionID) else { return false }
        guard let overview else { return true }
        guard Self.isNamedByTerminalRow(sessionID, in: overview) else { return false }
        return overview.sessions.first(where: { $0.id == sessionID })?.state != .exited
    }

    private static func isFailedTerminalRowSession(_ sessionID: String, in overview: SpacesDeviceOverviewPayload) -> Bool {
        overview.sessions.contains { $0.id == sessionID && $0.state == .failed } && isNamedByTerminalRow(sessionID, in: overview)
    }

    private static func isNamedByTerminalRow(_ sessionID: String, in overview: SpacesDeviceOverviewPayload) -> Bool {
        overview.workspaces.contains { workspace in workspace.terminalRows.contains { $0.sessionID == sessionID } }
    }

    /// Whether the device refused because a pending restore offer holds the shell, a refusal that ends
    /// when the offer is answered and so does not use up the session's one request.
    public static func isRestorePending(_ error: Error) -> Bool {
        (error as? any SpacesDeviceErrorCodeProviding)?.spacesDeviceErrorCode == .restorePending
    }

    /// Whether a refused request means the shell's folder is gone, the one refusal the dead terminal
    /// reports. Every other failure, including `.conflict` for a session that is not a lost shell or that
    /// another client already handled, leaves the terminal as it is.
    public static func isFolderMissing(_ error: Error) -> Bool {
        (error as? any SpacesDeviceErrorCodeProviding)?.spacesDeviceErrorCode == .workingDirectoryMissing
    }
}
