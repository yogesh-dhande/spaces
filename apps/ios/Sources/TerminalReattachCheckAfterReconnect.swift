/// A reconnect's pending answer to "does this client need to reattach": armed by `TerminalViewerModel.connect()`
/// when the client held an attachment going into this connect (the pre-subscribe attach's own moment,
/// `attachViewerForCurrentLifecycle` already covers a first connect), and settled by
/// `TerminalViewerModel.applyReducedState` at the first authoritative snapshot this reconnect applies.
///
/// That settling point is a snapshot, not the bootstrap read specifically, because the bootstrap read is
/// only one of two sources for it: the read can answer nothing at all (a request failure, or the fixed
/// timeout `readStateForConnectBootstrap` waits out), and when it does the subscription's own stream
/// payload is the reconnect's other, equally authoritative source for the same fact, arriving in the same
/// snapshot shape and reduced through the same pipeline. Deciding on the bootstrap alone would leave a
/// client with no live attachment on a stream that keeps delivering frames regardless, with nothing
/// scheduled to ever attach it again; deciding on whichever snapshot answers first covers both sources
/// with one rule.
@MainActor struct TerminalReattachCheckAfterReconnect {
    /// Whether this client owned the session going into this connect, read at the same moment the check
    /// is armed. A former owner is handed back its one automatic takeover once the reattach succeeds and
    /// the settling snapshot still shows the session as ownerless; a former viewer simply becomes an
    /// attached viewer again.
    let wasOwner: Bool
    /// The viewer lifecycle this check belongs to, so a settling snapshot for a lifecycle this check was
    /// not armed for (a stop, a restart) never fires it.
    let lifecycle: UInt64
    /// The remote client this check belongs to, checked alongside `lifecycle` for the same reason.
    let clientID: String
    /// `submittedStateCount` at the moment this check was armed. Only a snapshot whose apply stands for a
    /// submission past this boundary was produced by this reconnect itself (its bootstrap read, or its
    /// subscription's stream); anything at or below it was submitted by the connection this reconnect
    /// replaced, still draining through the reduction pipeline behind it.
    ///
    /// `lifecycle` and `clientID` alone do not catch that stale submission: a reconnect keeps the same
    /// viewer lifecycle and the same remote client as the connection it replaces (only a stop or a restart
    /// bumps the lifecycle), so a snapshot the old stream submitted just before disconnecting can still
    /// pass both those checks after landing late, behind the reconnect's own arm. If it still names this
    /// client attached, consuming it here as the settling snapshot would clear the check without this
    /// client ever having reattached to the new connection, and the new connection's own snapshot that
    /// follows finds nothing armed to settle. The submission boundary is the one fact that distinguishes
    /// the two: it is a fact about *when a snapshot was produced*, not about what it names, so it is the
    /// only field of the three immune to the old and new connections looking identical on paper.
    let submissionBoundary: UInt64
}
