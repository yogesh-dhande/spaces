import Foundation

/// Pure decision for live, overview-driven pane pruning.
///
/// A terminal pane exists only while its session is in the owning device's session
/// catalog — the same rule startup restore already applies through
/// `PanelLayoutEngine.prunedLayout(_:keepingSessionIDs:)`. This type extends that rule to
/// live overview updates: when a device's authoritative session catalog arrives and no
/// longer lists an open pane's session (its product row was removed, possibly from another
/// device), that pane must close so its ended-session scrollback replay does not later read
/// a transcript the daemon garbage-collector has purged.
enum OpenPanePruning {
    /// One open terminal pane's identity across all panels: the device that owns the
    /// session and the session id. Taken from each pane's `PaneContentDescriptor`.
    struct OpenPane: Equatable {
        let deviceID: String
        let sessionID: String
    }

    /// Session ids whose panes must close given one device's authoritative catalog.
    ///
    /// Closes exactly the panes owned by `deviceID` whose session is absent from
    /// `catalogSessionIDs`. Panes owned by other devices are never touched — their catalog
    /// did not arrive with this overview. A session still present in the catalog stays open,
    /// including a merely-ended session kept for scrollback (issue #189): the catalog lists a
    /// session while its product row exists and drops it only when that row is removed.
    ///
    /// The caller MUST invoke this only with a successfully received, authoritative catalog
    /// for `deviceID`. An offline, unreachable, or wire-incompatible device produces no
    /// overview, so it must not reach here: absence of an overview is not evidence a session's
    /// product row was removed, and pruning against a missing catalog would wrongly close
    /// live panes. An authoritative catalog that is legitimately empty (device online, every
    /// session gone) is a valid input and closes all of that device's open panes.
    static func sessionsToClose(openPanes: [OpenPane], deviceID: String, catalogSessionIDs: Set<String>) -> [String] {
        openPanes.filter { $0.deviceID == deviceID && !catalogSessionIDs.contains($0.sessionID) }.map(\.sessionID)
    }
}
