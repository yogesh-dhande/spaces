import spacesterminalcore

/// The last screen each terminal session painted on this device, kept where it outlives the viewer that
/// painted it.
///
/// `TerminalDetailView` owns its `TerminalViewerModel` as `@State`, so popping the route destroys the
/// model and everything it held: reopening the same terminal had to earn its first paint back over the
/// network, several sequential round trips after the tap (#674). The mac client has no such problem:
/// `DeviceTerminalSessionStateModel` keeps the last payload for the pane's lifetime and replays it
/// synchronously to a new listener. On iOS the app model holds this store instead, and a reopen paints
/// the screen the app already had before it asks the device anything.
///
/// What an entry holds is exactly what painting takes: the snapshot the surface last drew and the
/// identity of the render epoch it drew it under. Deliberately not the payload that carried it. A
/// retained screen is a picture, never state: it must not become `latestState`, seed the reduction
/// pipeline's delta baseline, or stand in for a frame a lifecycle actually received, and keeping only
/// the picture makes that structural rather than a rule to remember. It also keeps the encoded render
/// update a payload carries from being held for as long as the session exists.
///
/// One entry per session id. Entries are dropped by the viewer when the session ends or another client
/// is found to own it (that screen is not this device's to bring back), by the app model when the
/// overview stops listing the session, and wholesale when the active connection changes, so the store
/// never holds screens for sessions the app can no longer reach.
@MainActor final class TerminalRetainedScreenStore {
    /// One session's retained screen. Paintable by construction: `retain` is the only way to make one and
    /// it takes the snapshot the caller painted, so an entry always has a screen and a grid.
    struct Entry {
        let snapshot: GhosttyTerminalSnapshot
        /// The render epoch the snapshot was drawn under, reused when a reopen paints it. Reusing the id
        /// is also what lets a live bootstrap reporting the same, unchanged screen re-apply as a no-op
        /// instead of repainting an identical frame.
        let epochID: String
        let ownerEpoch: UInt64

        /// The grid the screen was captured at, which is the grid a reopen paints it at until the live
        /// screen arrives at this phone's own grid.
        var columns: Int { snapshot.columns }
        var rows: Int { snapshot.rows }
    }

    private var entriesBySessionID: [String: Entry] = [:]
    /// Every terminal client id a viewer of this app has minted. The overview lists a session's active
    /// owner by client id, and the app model must tell its own viewer (still attached while a detach is
    /// in flight, or open on another tab) from an owner on another device before it drops a screen as
    /// stale. Ids are UUIDs minted here, so no other device can present one; a few hundred strings over
    /// a long session is the whole cost.
    private(set) var ownViewerClientIDs: Set<String> = []

    var retainedSessionIDs: Set<String> { Set(entriesBySessionID.keys) }

    func entry(forSessionID sessionID: String) -> Entry? { entriesBySessionID[sessionID] }

    func noteOwnViewerClient(id: String) { ownViewerClientIDs.insert(id) }

    /// Whether the session's active owner, if any, is a viewer of this app rather than another device.
    func isOwnedElsewhere(_ attachmentSnapshot: TerminalSessionAttachmentSnapshot) -> Bool {
        attachmentSnapshot.attachments.contains { $0.mode == .owner && $0.detachedAt == nil && !ownViewerClientIDs.contains($0.clientID) }
    }

    func retain(snapshot: GhosttyTerminalSnapshot, epochID: String, ownerEpoch: UInt64, forSessionID sessionID: String) {
        entriesBySessionID[sessionID] = Entry(snapshot: snapshot, epochID: epochID, ownerEpoch: ownerEpoch)
    }

    func drop(sessionID: String) { entriesBySessionID.removeValue(forKey: sessionID) }

    /// Keeps only the sessions the device still lists. Called on every published overview, which is the
    /// one place that knows which sessions still exist.
    func retainOnly(sessionIDs: Set<String>) { entriesBySessionID = entriesBySessionID.filter { sessionIDs.contains($0.key) } }

    func removeAll() { entriesBySessionID.removeAll() }
}
