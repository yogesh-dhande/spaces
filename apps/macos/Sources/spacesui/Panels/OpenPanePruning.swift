import Foundation
import spacesdevicecore

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

    /// The keep-set both prune call sites pass as `catalogSessionIDs`: every terminal session id whose
    /// pane must stay open. A pane closes only when its session id is absent here.
    ///
    /// The daemon publishes this as `SpacesDeviceOverviewPayload.retainedTerminalSessionIDs` — its own
    /// authoritative retention rule (live interactive sessions unioned with sessions referenced by a
    /// `running_processes`, `agent_sessions`, or `runtime_targets` row, matching the session garbage
    /// collector's `SQLiteStore.terminalSessionIsReferencedByProduct`). The client reads the daemon's
    /// verdict directly rather than re-deriving it from overview row surfaces: the daemon's `sessions`
    /// list drops an ad hoc shell's id the instant it exits, but the shell's `runtime_targets` row still
    /// holds its transcript, so `retainedTerminalSessionIDs` keeps that id and the ended pane stays open
    /// for scrollback until the row is removed. Since the daemon owns the rule, the client and collector
    /// cannot drift.
    ///
    /// Ids are re-trimmed here (the daemon already trims) purely to parse the wire field defensively, so
    /// a malformed entry cannot inject an empty string into the keep-set.
    static func referencedTerminalSessionIDs(overview: SpacesDeviceOverviewPayload) -> Set<String> {
        var referenced = Set<String>()
        for trackingID in overview.retainedTerminalSessionIDs {
            let normalized = trackingID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            referenced.insert(normalized)
        }
        return referenced
    }
}
