import Foundation
import spacesdevicecore

/// Activity bands on the Agents tab, in display order.
enum SpacesMobileAgentGroupKind: String, CaseIterable, Sendable {
    case waiting
    case running
    case notRunning

    var label: String {
        switch self {
        case .waiting: "Waiting"
        case .running: "Running"
        case .notRunning: "Not running"
        }
    }
}

/// One coding-agent row plus the workspace context needed to render and activate it outside
/// its home workspace list.
struct SpacesMobileAgentEntry: Identifiable, Equatable, Sendable {
    let row: SpacesDeviceWorkspaceCodingAgentRow
    let workspaceDisplayName: String
    let projectName: String

    var id: String { "\(row.workspaceID):\(row.id)" }

    /// "project · branch"; a non-git workspace whose project and workspace share a name shows
    /// the name once.
    var detail: String {
        if projectName.caseInsensitiveCompare(workspaceDisplayName) == .orderedSame { return workspaceDisplayName }
        return "\(projectName) · \(workspaceDisplayName)"
    }

    var runtimeRow: SpacesMobileWorkspaceRuntimeRow { SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(row)) }
}

struct SpacesMobileAgentGroup: Identifiable, Equatable, Sendable {
    let kind: SpacesMobileAgentGroupKind
    let entries: [SpacesMobileAgentEntry]

    var id: String { kind.rawValue }
}

/// Pure grouping of every coding-agent row across visible workspaces into activity bands.
/// Empty bands are omitted.
enum SpacesMobileAgentGrouping {
    static func groups(in overview: SpacesDeviceOverviewPayload) -> [SpacesMobileAgentGroup] {
        var entriesByKind: [SpacesMobileAgentGroupKind: [SpacesMobileAgentEntry]] = [:]
        for workspace in overview.workspaces where !workspace.isArchived && !workspace.isHidden {
            for agent in workspace.codingAgentRows {
                let entry = SpacesMobileAgentEntry(row: agent, workspaceDisplayName: workspace.displayName, projectName: workspace.projectName)
                entriesByKind[kind(for: agent), default: []].append(entry)
            }
        }
        return SpacesMobileAgentGroupKind.allCases.compactMap { kind in
            guard let entries = entriesByKind[kind], !entries.isEmpty else { return nil }
            return SpacesMobileAgentGroup(kind: kind, entries: entries)
        }
    }

    static func kind(for agent: SpacesDeviceWorkspaceCodingAgentRow) -> SpacesMobileAgentGroupKind {
        if agent.activityState == .waiting { return .waiting }
        if agent.runState == .running { return .running }
        return .notRunning
    }
}
