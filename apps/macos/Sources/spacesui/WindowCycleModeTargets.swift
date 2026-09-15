import Foundation
import spacesclientcore
import spacesdevicecore
import workspacecore

/// One device's slice of the input a cross-device cycle mode is built from: the device's id and the
/// overview the sidebar last installed for it.
struct WindowCycleDeviceSnapshot: Sendable {
    let deviceID: String
    let overview: SpacesDeviceOverviewPayload
}

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
    /// `agentTargets`.
    static func targets(
        mode: WindowCycleMode, devices: [WindowCycleDeviceSnapshot], openTerminalSessionIDsByWorkspace: [String: [String]],
        openBrowserSessionsByWorkspace: [String: [BrowserSession]], trackedBrowserWindowIDsByWorkspace: [String: Set<Int>], recentCursors: [String],
        retaining retainedCursors: [WorkspaceWindowCycle.Cursor]
    ) -> [WindowCycleTarget] {
        switch mode {
        // Workspace mode rotates over one workspace's own windows, built from that workspace's
        // overview by `WindowFocusController.cycleWindowTargets`, so there is nothing cross-device
        // to gather for it here.
        case .workspace: return []
        case .attention: return agentTargets(devices: devices, activityStates: [.waiting, .done], retaining: Set(retainedCursors))
        // An idle row is a terminal no agent has started in yet and an exited row is an agent that is
        // over: neither is an agent the user can go back to work with, so neither is in this mode.
        case .allAgents: return agentTargets(devices: devices, activityStates: [.spinning, .waiting, .done], retaining: Set(retainedCursors))
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
        retaining retainedCursors: Set<WorkspaceWindowCycle.Cursor>
    ) -> [WindowCycleTarget] {
        var candidates: [(target: WindowCycleTarget, sidebarIndex: Int, stateChangedAt: Date?)] = []
        var sidebarIndex = 0
        for device in devices {
            for workspace in cycleableWorkspaces(of: device) {
                let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: workspace)
                let rowsByAgentID = Dictionary(detail.codingAgentRows.map { ($0.agentID ?? $0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for target in AppKitController.workspaceShortcutTargets(detail: detail, browserSessions: []) where target.kind == .agent {
                    guard let agentID = target.agentWindow?.id, let row = rowsByAgentID[agentID] else { continue }
                    // A row with no session has no terminal to land in, so it is not a cycle target.
                    guard let sessionID = row.sessionID, !sessionID.isEmpty else { continue }
                    let candidate = cycleTarget(
                        device: device, workspaceID: workspace.id, detail: detail, target: target, trackedBrowserWindowIDs: [])
                    guard activityStates.contains(row.activityState) || retainedCursors.contains(candidate.cursorKey) else { continue }
                    sidebarIndex += 1
                    candidates.append((candidate, sidebarIndex, row.updatedAt.flatMap { iso8601Formatter.date(from: $0) }))
                }
            }
        }
        candidates.sort { first, second in
            switch (first.stateChangedAt, second.stateChangedAt) {
            case (let firstDate?, let secondDate?): return firstDate == secondDate ? first.sidebarIndex < second.sidebarIndex : firstDate > secondDate
            // A row whose daemon-reported timestamp is missing or unparseable carries no recency, so it
            // sorts after every row that does, in sidebar order.
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return first.sidebarIndex < second.sidebarIndex
            }
        }
        return candidates.map(\.target)
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
                let openBrowserSessions = openBrowserSessionsByWorkspace[workspace.id] ?? []
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
