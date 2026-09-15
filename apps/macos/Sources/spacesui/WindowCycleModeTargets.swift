import Foundation
import spacesclientcore
import spacesdevicecore
import workspacecore

/// Builds the ordered target list a cross-device cycle mode rotates over. Pure, so the cycle itself
/// and any surface that reports the mode's contents derive the same set the same way.
///
/// Devices are walked in sidebar order and each device's workspaces in the order its overview lists
/// them, so "sidebar order", the tie-break every mode falls back to, means one thing here.
enum WindowCycleModeTargets {
    /// `ISO8601DateFormatter` construction is expensive and this type is nonisolated. The formatter is
    /// documented thread-safe, so one shared instance is reused, matching `AlertsController`'s.
    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    /// The mode's ordered set. `retainedCursors` carries the cursors of the rotation a live cycle burst
    /// froze, which the set keeps hold of even where the mode's filter no longer admits them: see
    /// `agentTargets`. `dismissedAlertIDs` is the Alerts pane's own dismissal set, passed in rather
    /// than read here so this stays pure and so the pane and the Alerts rotation hide the same rows.
    static func targets(
        mode: WindowCycleMode, devices: [WindowCycleDeviceSnapshot], openTerminalSessionIDsByWorkspace: [String: [String]],
        openBrowserSessionsByWorkspace: [String: [BrowserSession]], trackedBrowserWindowIDsByWorkspace: [String: Set<Int>],
        dismissedAlertIDs: Set<String>, recentCursors: [String], retaining retainedCursors: [WorkspaceWindowCycle.Cursor]
    ) -> [WindowCycleTarget] {
        switch mode {
        // Workspace mode rotates over one workspace's own windows, built from that workspace's
        // overview by `WindowFocusController.cycleWindowTargets`, so there is nothing cross-device
        // to gather for it here.
        case .workspace: return []
        case .alerts:
            return alertTargets(
                devices: devices, openTerminalSessionIDsByWorkspace: openTerminalSessionIDsByWorkspace, dismissedAlertIDs: dismissedAlertIDs,
                retaining: Set(retainedCursors))
        // An exited row is an agent that is over, so it is not an agent the user can go back to work
        // with. An idle row is: the agent is launched and waiting for its first prompt, which is a
        // terminal the user has reason to reach.
        case .allAgents:
            return agentTargets(
                devices: devices, activityStates: [.idle, .spinning, .waiting, .done],
                openTerminalSessionIDsByWorkspace: openTerminalSessionIDsByWorkspace, retaining: Set(retainedCursors))
        case .openSessions:
            // Nothing for a burst to retain here: this mode's filter is existence itself, an open pane
            // or a tracked browser tab, so the only way a target leaves this set is by vanishing.
            return openSessionTargets(
                devices: devices, openTerminalSessionIDsByWorkspace: openTerminalSessionIDsByWorkspace,
                openBrowserSessionsByWorkspace: openBrowserSessionsByWorkspace,
                trackedBrowserWindowIDsByWorkspace: trackedBrowserWindowIDsByWorkspace, recentCursors: recentCursors)
        }
    }

    /// Coding-agent targets in the given activity states, newest state change first, plus every target
    /// named by `retainedCursors` that still exists.
    ///
    /// A cycle burst is frozen by target identity, not by the state that admitted the target. The user
    /// lands on a waiting agent, answers it so it starts working, and presses Next again inside the
    /// burst window; in All agents, an agent the burst is walking exits. Letting the mode's filter drop
    /// that target would leave a cursor of the frozen rotation missing from the candidate list,
    /// `WorkspaceWindowCycle.cycleOrdering` would reject the rotation, and the order would shift under
    /// the user's fingers mid-burst. So a retained target stays a candidate until the burst ends, and
    /// only a target that has genuinely vanished (its row is gone from the overview, or it lost the
    /// session that makes it focusable) leaves the rotation, exactly as a workspace rotation loses a
    /// target whose pane closed.
    ///
    /// Retained targets take their place in the mode's own order rather than being pinned ahead of it:
    /// the frozen session is what walks them first, and it also places any target that appeared
    /// mid-burst after them. That leaves this order free to be the mode's order, which is the order the
    /// rotation rebuilds into once the burst ends.
    private static func agentTargets(
        devices: [WindowCycleDeviceSnapshot], activityStates: Set<SpacesDeviceCodingAgentActivityState>,
        openTerminalSessionIDsByWorkspace: [String: [String]], retaining retainedCursors: Set<WorkspaceWindowCycle.Cursor>
    ) -> [WindowCycleTarget] {
        var candidates: [RecencyCandidate] = []
        var sidebarIndex = 0
        for device in devices {
            for workspace in cycleableWorkspaces(of: device) {
                let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: workspace)
                let rowsByAgentID = Dictionary(detail.codingAgentRows.map { ($0.agentID ?? $0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let openSessionIDs = Set(openTerminalSessionIDsByWorkspace[workspace.id] ?? [])
                for target in AppKitController.workspaceShortcutTargets(detail: detail, browserSessions: []) where target.kind == .agent {
                    guard let agentID = target.agentWindow?.id, let row = rowsByAgentID[agentID] else { continue }
                    // A row with no session has no terminal to land in, so it is not a cycle target.
                    guard let sessionID = row.sessionID, !sessionID.isEmpty else { continue }
                    // A device the sidebar cannot currently reach keeps its last-known overview (see
                    // `WindowCycleDeviceSnapshot`), so its agent rows still show up here even while the
                    // device is offline. Landing a cycle press on one without an open pane hits
                    // `openOrFocusTerminalPane`'s synchronous refusal, which surfaces a modal error, and
                    // `cycleWindows` then advances to the next candidate: one press can raise one modal
                    // per stale agent. An already-open pane is still focusable locally, so only that
                    // case is exempt; Open sessions applies the same rule to its browser targets in
                    // `openSessionTargets`, so its panes are always focusable. "Open" here means
                    // materialized in memory, or persisted on a device the sidebar reaches: see
                    // `persistedLayoutKeys` for why an unreachable device's persisted-only panes do not
                    // count.
                    guard device.isReachable || openSessionIDs.contains(sessionID) else { continue }
                    let candidate = cycleTarget(
                        device: device, workspaceID: workspace.id, detail: detail, target: target, trackedBrowserWindowIDs: [])
                    guard activityStates.contains(row.activityState) || retainedCursors.contains(candidate.cursorKey) else { continue }
                    sidebarIndex += 1
                    candidates.append(
                        RecencyCandidate(
                            target: candidate, sidebarIndex: sidebarIndex, eventDate: row.updatedAt.flatMap { iso8601Formatter.date(from: $0) }))
                }
            }
        }
        return newestFirst(candidates)
    }

    /// Every window the Alerts pane can send the user to, newest alert first.
    ///
    /// The set is derived from the pane's own derivation (`AlertsController.buildOverviewAlertsGroups`
    /// filtered by `visibleAlertsGroups`) rather than from a second reading of the overview, so the
    /// rotation and the pane cannot disagree about what is alerting: a dismissal, a hidden workspace, or
    /// a consumed bell takes a row out of both at once. Both are pure and device-scoped, so this runs
    /// them again here instead of reaching for the merged, device-blind list the pane renders. Each alert
    /// is resolved to its own terminal session id first (`alertSessionID`, reading the process row, the
    /// agent record, or the bell's session directly, never a `focusable` target's kind-specific slot),
    /// then matched to a window through `indexBySessionID` alone, so a landing runs the same resolution
    /// any other cycle landing does. Resolving session id before target is what keeps an exited configured
    /// process's alert live even when its own target was dropped: a process whose session a coding agent
    /// also occupies has no `.process` entry in `focusable` at all (`AppKitController.workspaceShortcutTargets`,
    /// by way of `orderedWorkspaceRunProcessEntries`, keeps only the agent's target for a shared session,
    /// per the process+agent-stop rule in docs/implementation.md), yet the process row itself still carries
    /// that session id, so its alert still finds the agent's target through `indexBySessionID`. An alert
    /// with no window to land in is left in the pane and out of the rotation: a failed automation run (its
    /// card deep-links to the Runs tab and carries no focus request), and any alert whose row has no
    /// terminal session. Landing on an alert does not dismiss it, exactly as clicking its pane row does
    /// not.
    ///
    /// A window is one terminal session, so two alerts that name the same session (an exited process
    /// whose session also rang a bell, or a configured process and the coding agent running in it) fold
    /// into one target, dated by the newer alert: admission is keyed by session id, and `indexBySessionID`
    /// names one representative target per session (the agent's, when the session is agent-claimed; see
    /// its construction below), so every alert for that session lands on the same candidate regardless of
    /// which kind of row named it.
    private static func alertTargets(
        devices: [WindowCycleDeviceSnapshot], openTerminalSessionIDsByWorkspace: [String: [String]], dismissedAlertIDs: Set<String>,
        retaining retainedCursors: Set<WorkspaceWindowCycle.Cursor>
    ) -> [WindowCycleTarget] {
        var candidates: [RecencyCandidate] = []
        var sidebarIndex = 0
        for device in devices {
            let alertItemsByWorkspace = Dictionary(
                AlertsController.visibleAlertsGroups(
                    in: AlertsController.buildOverviewAlertsGroups(from: device.overview, deviceID: device.deviceID),
                    dismissedAttentionItemIDs: dismissedAlertIDs
                ).map { ($0.workspaceID, $0.items) }, uniquingKeysWith: { first, _ in first })
            for workspace in cycleableWorkspaces(of: device) {
                let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: workspace)
                let openSessionIDs = Set(openTerminalSessionIDsByWorkspace[workspace.id] ?? [])
                // The workspace's focusable windows, in the one runtime-target order sidebar rows,
                // palette items, and numbered shortcuts share, indexed by the session each backs.
                var focusable: [WindowCycleTarget] = []
                var indexBySessionID: [String: Int] = [:]
                // Every focusable target's own session, so admission below can dedupe alerts by session
                // rather than by whichever index happened to resolve first.
                var sessionIDByIndex: [Int: String] = [:]
                for target in AppKitController.workspaceShortcutTargets(detail: detail, browserSessions: []) {
                    // A row with no session has no terminal to land in, and the reachability rule is the
                    // one `agentTargets` applies: see its comment for why an unreachable device's row
                    // stays out unless its pane is already open.
                    guard let sessionID = WindowFocusController.cycleTargetSessionID(for: target, detail: detail), !sessionID.isEmpty else {
                        continue
                    }
                    guard device.isReachable || openSessionIDs.contains(sessionID) else { continue }
                    let index = focusable.count
                    focusable.append(
                        cycleTarget(device: device, workspaceID: workspace.id, detail: detail, target: target, trackedBrowserWindowIDs: []))
                    sessionIDByIndex[index] = sessionID
                    // `AppKitController.workspaceShortcutTargets` (by way of `orderedWorkspaceRunProcessEntries`)
                    // already drops a configured process's own target when its session is agent-claimed, so in
                    // practice a session backs at most one target here. This is the belt: an agent target always
                    // claims (or reclaims) its session's slot rather than only filling it when empty, matching
                    // that same precedent (`WindowFocusController.cycleWindowTargets` never lets a process
                    // target stand for an agent-claimed session either), for any future target family that
                    // shares a session with an agent without going through that exclusion.
                    if target.kind == .agent || indexBySessionID[sessionID] == nil { indexBySessionID[sessionID] = index }
                }
                // Sidebar order for the whole workspace, claimed before any alert is read, so the
                // tie-break between two alerts stamped at the same instant is the order their rows sit
                // in rather than the order the pane happened to sort them into.
                let workspaceSidebarBase = sidebarIndex
                sidebarIndex += focusable.count
                // Sessions this workspace has already dated a candidate for, not indices: two indices can
                // share a session (see `indexBySessionID` above), and the rotation is over windows, i.e.
                // sessions, so a second target for an already-dated session must not double the pane.
                var admittedSessionIDs: Set<String> = []
                // Group items arrive newest first, so the first alert admitting a session dates it.
                for item in alertItemsByWorkspace[workspace.id] ?? [] {
                    guard let sessionID = alertSessionID(for: item.focusRequest, detail: detail), let index = indexBySessionID[sessionID] else {
                        continue
                    }
                    guard admittedSessionIDs.insert(sessionID).inserted else { continue }
                    candidates.append(
                        RecencyCandidate(target: focusable[index], sidebarIndex: workspaceSidebarBase + index, eventDate: item.eventDate))
                }
                // A window whose alert was dismissed, consumed, or answered mid-burst stays a candidate
                // for as long as the frozen rotation names it, for the reasons `agentTargets` documents.
                // It carries no alert to be dated by, so it sorts with the undated; the frozen session is
                // what decides where the burst walks it. Skipping an already-admitted session here too,
                // and recording what it retains, keeps a retained cursor from reintroducing a pane an
                // alert (or an earlier retained cursor in this same loop) already placed.
                for (index, target) in focusable.enumerated() {
                    guard let sessionID = sessionIDByIndex[index], !admittedSessionIDs.contains(sessionID) else { continue }
                    guard retainedCursors.contains(target.cursorKey) else { continue }
                    admittedSessionIDs.insert(sessionID)
                    candidates.append(RecencyCandidate(target: target, sidebarIndex: workspaceSidebarBase + index, eventDate: nil))
                }
            }
        }
        return newestFirst(candidates)
    }

    /// The terminal session id an Alerts item's focus request names, read from the row or record the
    /// alert was built from rather than from any `focusable` target's own slot. That distinction is why
    /// an exited configured process's alert still resolves when its session is agent-claimed: the process
    /// row (`detail.processRows`) still carries the session id even though `workspaceShortcutTargets`
    /// dropped that process's own target in favor of the agent's (see `alertTargets`'s doc comment). An
    /// agent alert reads the same session off the `AgentWindowRecord` the alert carries
    /// (`terminalTrackingID`), matching how `AlertsController.buildOverviewAlertsGroups` built that record
    /// from the agent row in the first place. A bell alert already carries its session id directly. A nil
    /// request is a failed automation run, which has no window; the remaining request kinds are never
    /// built for an alert.
    private static func alertSessionID(for focusRequest: AppKitController.WindowFocusRequest?, detail: SpacesDeviceWorkspaceDetailViewModel)
        -> String?
    {
        switch focusRequest {
        case .workspaceProcess(_, let processID): return detail.processRows.first(where: { ($0.processID ?? $0.id) == processID })?.sessionID
        case .agentWindow(let record): return record.terminalTrackingID
        case .terminalSession(_, let sessionID): return sessionID
        case .workspaceBrowserSession, .workspaceWindow, .workspaceMissingConfiguredProcess, nil: return nil
        }
    }

    /// One candidate of a recency-ordered mode's set, with the tie-breaks `newestFirst` applies.
    private struct RecencyCandidate {
        let target: WindowCycleTarget
        /// Position in the walk over devices and their workspaces, which is sidebar order.
        let sidebarIndex: Int
        /// When the thing that put this target in the set happened: the agent's last state change, or
        /// the alert's own event. Nil when the daemon reported no timestamp, one that did not parse, or
        /// (for a retained target) when nothing admits the target any more.
        let eventDate: Date?
    }

    /// Newest event first, ties in sidebar order, undated last.
    private static func newestFirst(_ candidates: [RecencyCandidate]) -> [WindowCycleTarget] {
        candidates.sorted { first, second in
            switch (first.eventDate, second.eventDate) {
            case (let firstDate?, let secondDate?): return firstDate == secondDate ? first.sidebarIndex < second.sidebarIndex : firstDate > secondDate
            // A row whose daemon-reported timestamp is missing or unparseable carries no recency, so it
            // sorts after every row that does, in sidebar order.
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return first.sidebarIndex < second.sidebarIndex
            }
        }.map(\.target)
    }

    /// Every workspace's open terminal-backed panes and open browser sessions, ordered by how
    /// recently each was visited, with targets that have never been visited after them in sidebar
    /// order.
    private static func openSessionTargets(
        devices: [WindowCycleDeviceSnapshot], openTerminalSessionIDsByWorkspace: [String: [String]],
        openBrowserSessionsByWorkspace: [String: [BrowserSession]], trackedBrowserWindowIDsByWorkspace: [String: Set<Int>], recentCursors: [String]
    ) -> [WindowCycleTarget] {
        var sidebarOrdered: [WindowCycleTarget] = []
        for device in devices {
            for workspace in cycleableWorkspaces(of: device) {
                let openTerminalSessionIDs = Set(openTerminalSessionIDsByWorkspace[workspace.id] ?? [])
                // Focusing a browser target of a remote workspace resolves its SSH-forwarded route
                // through the device record (`WindowFocusController`'s `.openURL` case), which an
                // unreachable device has none of: the press would raise the offline modal and
                // `cycleWindows` would skip it, same as an agent row without an open pane. An open
                // pane is exempt because it focuses locally and asks the device for nothing. The local
                // device is exempt too (`device.isLocal`): its browser sessions focus through this
                // Mac's Chrome with no device record involved, so its own `spacesd` being down (which
                // is what makes its section read unreachable) does not affect them.
                let openBrowserSessions = (device.isReachable || device.isLocal) ? openBrowserSessionsByWorkspace[workspace.id] ?? [] : []
                guard !openTerminalSessionIDs.isEmpty || !openBrowserSessions.isEmpty else { continue }
                let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: workspace)
                let targets = WindowFocusController.cycleWindowTargets(
                    detail: detail, browserSessions: openBrowserSessions, openTerminalSessionIDs: openTerminalSessionIDs)
                let trackedBrowserWindowIDs = trackedBrowserWindowIDsByWorkspace[workspace.id] ?? []
                sidebarOrdered.append(
                    contentsOf: targets.map {
                        cycleTarget(
                            device: device, workspaceID: workspace.id, detail: detail, target: $0,
                            // Only a browser target can be matched against a Chrome window.
                            trackedBrowserWindowIDs: $0.kind == .browser ? trackedBrowserWindowIDs : [])
                    })
            }
        }
        var unvisited = sidebarOrdered
        var ordered: [WindowCycleTarget] = []
        for cursor in recentCursors {
            guard let index = unvisited.firstIndex(where: { $0.cursorKey == cursor }) else { continue }
            ordered.append(unvisited.remove(at: index))
        }
        ordered.append(contentsOf: unvisited)
        return ordered
    }

    /// The workspaces of one device a cross-device mode may draw targets from: the sidebar visibility
    /// rule, `SpacesDeviceOverviewPayload.isWorkspaceVisible` (neither the workspace nor its project is
    /// hidden), which is the rule the outline, the command palette, and the workspace cycle order all
    /// read. A hidden workspace has no sidebar row to land on, so none of its agents or open sessions
    /// enters a global mode's set. That applies to retention too: a retained frozen target whose
    /// workspace is hidden mid-burst leaves the rotation exactly as one whose row vanished does.
    private static func cycleableWorkspaces(of device: WindowCycleDeviceSnapshot) -> [SpacesDeviceWorkspaceSummary] {
        device.overview.workspaces.filter { device.overview.isWorkspaceVisible($0) }
    }

    /// The persisted-layout keys a cross-device open-pane read should merge in: every workspace of
    /// every REACHABLE device, in device and overview order.
    ///
    /// Persisted layouts are merged into the open-pane set only for devices the sidebar reaches,
    /// because a persisted-only pane (one held in a workspace's stored layout but not yet restored
    /// into memory this launch) is opened by restoring it through its device's daemon
    /// (`openOrFocusTerminalPane`), which an unreachable device cannot do. Merging an unreachable
    /// device's persisted layouts in would mark such a pane "open" when a cycle press cannot actually
    /// land on it, the exact modal-refusal case `agentTargets`' reachability exemption and
    /// `openSessionTargets` exist to keep out. An unreachable device therefore contributes only the
    /// panes materialized in memory (from the caller's own in-memory pass, not from this list), which
    /// are the ones that focus without the daemon. A reachable device's persisted-only panes are fine
    /// to merge: restoring them attaches through a daemon that is actually there.
    ///
    /// Not private, so a unit test can assert the filter directly.
    nonisolated static func persistedLayoutKeys(for devices: [WindowCycleDeviceSnapshot]) -> [PanelLayoutEngine.WorkspaceKey] {
        devices.filter(\.isReachable).flatMap { device in
            device.overview.workspaces.map { PanelLayoutEngine.WorkspaceKey(deviceID: device.deviceID, workspaceID: $0.id) }
        }
    }

    private static func cycleTarget(
        device: WindowCycleDeviceSnapshot, workspaceID: String, detail: SpacesDeviceWorkspaceDetailViewModel,
        target: AppKitController.WorkspaceRunShortcutTarget, trackedBrowserWindowIDs: Set<Int>
    ) -> WindowCycleTarget {
        WindowCycleTarget(
            deviceID: device.deviceID, workspaceID: workspaceID,
            cursorKey: WindowCycleTarget.globalCursorKey(
                deviceID: device.deviceID, workspaceID: workspaceID, cursorKey: WindowFocusController.cycleCursorKey(for: target, detail: detail)),
            target: target, detail: detail, trackedBrowserWindowIDs: trackedBrowserWindowIDs)
    }
}
