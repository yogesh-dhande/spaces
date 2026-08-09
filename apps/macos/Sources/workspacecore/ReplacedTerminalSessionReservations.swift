import Foundation
import spacesterminalcore

/// The panes a programmatic restart asked the client to hold open for a replacement, keyed by the
/// configured process each one belongs to.
///
/// A restart stops a workspace's processes and launches fresh ones, and the replacement sessions carry
/// new ids, so without this the client would tear each pane down and re-add the replacement at the end
/// of the tab strip, losing the tab position, the split, and the window the user arranged. The stop
/// closes those sessions as `awaitReplacement` instead, and each replacement's open names the session it
/// takes over from, so the pane is claimed in place.
///
/// The hold is bounded by the restart itself rather than by a timer: the daemon is the only party that
/// knows whether a replacement is still coming, so whatever is left unclaimed when the restart returns
/// (a relaunch that threw, a template the user removed between stop and launch) is released as an
/// ordinary teardown close. A wall-clock bound would either cut short a slow launch or leave a dead pane
/// held for the length of the guess.
final class ReplacedTerminalSessionReservations {
    private var sessionIDsByProcessKey: [String: String]
    /// The captured sessions whose hold was actually emitted to the client. Capturing a session is not
    /// the same as holding its pane: a stop that fails before, or part way through, closing them leaves
    /// the rest untouched, and releasing a pane whose hold was never sent would close a pane whose
    /// session is still running. Only what was held is ever released.
    private var heldSessionIDs: Set<String> = []
    private var claimedSessionIDs: Set<String> = []

    init(sessionIDsByProcessKey: [String: String]) { self.sessionIDsByProcessKey = sessionIDsByProcessKey }

    /// How the stop should close `sessionID`, recording the hold when it asks for one. This is the only
    /// place a hold is registered, so the record cannot drift from what was actually sent.
    func closeDisposition(for sessionID: String) -> TerminalPaneCloseDisposition {
        guard sessionIDsByProcessKey.values.contains(sessionID) else { return .teardown }
        heldSessionIDs.insert(sessionID)
        return .awaitReplacement
    }

    /// The session a newly launched process takes over from, consuming the reservation so it is not
    /// released afterwards. Answers nil for a process that had no live session before the restart.
    func claimSessionID(processKey: String) -> String? {
        guard let sessionID = sessionIDsByProcessKey.removeValue(forKey: processKey) else { return nil }
        claimedSessionIDs.insert(sessionID)
        return sessionID
    }

    /// The panes this restart is still holding: held by the stop, and never claimed by a replacement.
    var unclaimedHeldSessionIDs: [String] { Array(heldSessionIDs.subtracting(claimedSessionIDs)) }
}
