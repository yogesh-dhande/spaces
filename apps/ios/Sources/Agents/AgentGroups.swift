import Foundation
import spacesdevicecore

/// Activity bands on the Agents tab, in display order: the agents that need the user come first,
/// then the ones with a result to read, then the ones still working, then everything idle.
enum SpacesMobileAgentGroupKind: String, CaseIterable, Sendable {
    case blocked
    case done
    case working
    case notRunning

    var label: String {
        switch self {
        case .blocked: "Blocked"
        case .done: "Done"
        case .working: "Working"
        case .notRunning: "Not running"
        }
    }
}

/// One coding-agent row plus the workspace and device context needed to render and activate it outside
/// its home workspace list.
struct SpacesMobileAgentEntry: Identifiable, Equatable, Sendable {
    let row: SpacesDeviceWorkspaceCodingAgentRow
    let deviceID: String
    let projectName: String
    let workspaceDisplayName: String
    /// "Device Name" / "Device Name (offline)", or nil when the device segment is hidden (see
    /// `SpacesMobileDeviceDisplay.showsDeviceSegment`). Demo Mode's single always-online device always
    /// derives nil here.
    let deviceText: String?
    let isDeviceOffline: Bool

    /// Qualified by device id, not just the row's own workspace-scoped id: the Agents tab lists every
    /// paired device's rows in one set of bands, and two devices' rows must never collide in SwiftUI's
    /// `ForEach` identity or in the row's own accessibility identifier.
    var id: String { "\(deviceID):\(row.workspaceID):\(row.id)" }

    /// "project / workspace" or "project / workspace · device".
    var detail: String {
        let projectWorkspace = SpacesMobileDeviceDisplay.projectWorkspace(projectName: projectName, workspaceDisplayName: workspaceDisplayName)
        guard let deviceText else { return projectWorkspace }
        return "\(projectWorkspace) · \(deviceText)"
    }

    var runtimeRow: SpacesMobileWorkspaceRuntimeRow { SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(row)) }
}

struct SpacesMobileAgentGroup: Identifiable, Equatable, Sendable {
    let kind: SpacesMobileAgentGroupKind
    let entries: [SpacesMobileAgentEntry]

    var id: String { kind.rawValue }
}

/// Pure grouping of every coding-agent row, across every paired device's overview, into activity bands.
/// Empty bands are omitted, and "Not running" is never listed at all: the tab surfaces agents with a
/// state worth acting on, while stopped agents stay reachable from their workspace's rows on the
/// Spaces tab.
enum SpacesMobileAgentGrouping {
    /// `devices` order decides the order agents from different devices appear in a shared band: each
    /// device's own agents keep the overview's own workspace order (unchanged from the single-device
    /// rule), and one device's agents are never interleaved with another's.
    ///
    /// `showsDeviceSegment` comes from the caller, not `devices.count`: `devices` only lists devices with
    /// a cached overview, but the show/hide rule needs the full paired count, since a second paired device
    /// that has not streamed anything yet still has to widen it.
    static func groups(devices: [SpacesMobileDeviceOverviewContext], showsDeviceSegment: Bool) -> [SpacesMobileAgentGroup] {
        var entriesByKind: [SpacesMobileAgentGroupKind: [SpacesMobileAgentEntry]] = [:]
        for device in devices {
            // Excludes a workspace hidden by its own flag or by its project's (see
            // `SpacesDeviceOverviewPayload.isWorkspaceVisible`), the same rule the Spaces tab's browse list uses.
            for workspace in device.overview.workspaces where device.overview.isWorkspaceVisible(workspace) {
                for agent in workspace.codingAgentRows {
                    let entry = SpacesMobileAgentEntry(
                        row: agent, deviceID: device.deviceID, projectName: workspace.projectName, workspaceDisplayName: workspace.displayName,
                        deviceText: showsDeviceSegment ? SpacesMobileDeviceDisplay.text(name: device.deviceName, isOffline: device.isOffline) : nil,
                        isDeviceOffline: device.isOffline)
                    entriesByKind[kind(for: agent), default: []].append(entry)
                }
            }
        }
        return SpacesMobileAgentGroupKind.allCases.compactMap { kind in
            guard kind != .notRunning, let entries = entriesByKind[kind], !entries.isEmpty else { return nil }
            return SpacesMobileAgentGroup(kind: kind, entries: entries)
        }
    }

    static func kind(for agent: SpacesDeviceWorkspaceCodingAgentRow) -> SpacesMobileAgentGroupKind {
        switch agent.activityState {
        case .waiting: return .blocked
        case .done: return .done
        case .spinning: return .working
        // An exited agent still owns an interactive terminal (runState `.running`), but the agent process
        // is gone — it belongs in "Not running", not the Working band.
        case .exited: return .notRunning
        // Idle says nothing about the agent, so its terminal decides: a live one is still working, a
        // stopped one is not running.
        case .idle: return agent.runState == .running ? .working : .notRunning
        }
    }
}
