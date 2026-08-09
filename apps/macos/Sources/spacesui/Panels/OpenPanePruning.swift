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

    /// The keep-set startup restore prunes persisted layouts against, from one device's overview.
    ///
    /// Restore must apply the same contract as live pruning: keep a pane only while the owning
    /// daemon still retains its session (`referencedTerminalSessionIDs`), not merely while the
    /// session is live in `overview.sessions`. An ad hoc shell that exited leaves `sessions` but its
    /// `runtime_targets` row still holds the transcript, so the daemon keeps its id in
    /// `retainedTerminalSessionIDs`; restoring against the live-session list alone would silently drop
    /// that ended-but-retained pane on relaunch even though a live overview refresh keeps it open. A
    /// nil overview (device not loaded) contributes nothing, so its persisted rows stay pending rather
    /// than pruning against an empty catalog.
    static func restorationKeepSet(overview: SpacesDeviceOverviewPayload?) -> Set<String> {
        guard let overview else { return [] }
        return referencedTerminalSessionIDs(overview: overview)
    }

    /// The restoration keep-set plus the sessions whose panes are being held for a restart's
    /// replacement.
    ///
    /// A held session is deliberately absent from the overview: the restart's stop deleted its row, which
    /// is exactly what makes the keep-set drop it. Restoring a workspace panel between the stop and the
    /// replacement's open would therefore prune the pane whose position the hold exists to preserve, and
    /// the replacement would arrive to find nothing to claim and append itself at the end of the tab
    /// strip. That window is the normal case rather than a narrow race: a programmatic restart usually
    /// targets a workspace the user is not viewing, whose panel is first materialized by the
    /// replacement's own open.
    static func restorationKeepSet(overview: SpacesDeviceOverviewPayload?, heldForReplacementSessionIDs: Set<String>) -> Set<String> {
        restorationKeepSet(overview: overview).union(heldForReplacementSessionIDs)
    }

    /// The restoration keep-set unioned across several devices' overviews, for a global panel window
    /// whose panes can reference more than one device. Each overview follows the single-overview
    /// contract above; a nil overview contributes nothing.
    static func restorationKeepSet(overviews: some Sequence<SpacesDeviceOverviewPayload?>) -> Set<String> {
        overviews.reduce(into: Set<String>()) { $0.formUnion(restorationKeepSet(overview: $1)) }
    }

    /// The multi-device restoration keep-set plus held sessions, for a global panel window whose panes
    /// can reference more than one device. A pending window is exactly where a hold has to outlive the
    /// longest: the window waits for every device it references, so a restart during that wait would
    /// otherwise have its pane pruned the moment the offline device returns.
    static func restorationKeepSet(overviews: some Sequence<SpacesDeviceOverviewPayload?>, heldForReplacementSessionIDs: Set<String>) -> Set<String> {
        restorationKeepSet(overviews: overviews).union(heldForReplacementSessionIDs)
    }
}
