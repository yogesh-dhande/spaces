import Foundation
import spacesdevicecore

public struct SpacesDeviceProjectActions: Equatable, Sendable {
    public let showsSettings: Bool
    public let showsAddWorkspace: Bool

    public init(isGitRepo: Bool) {
        self.showsSettings = true
        self.showsAddWorkspace = isGitRepo
    }
}

public struct SpacesDeviceProjectRow: Equatable, Sendable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    public let isCollapsed: Bool
    public let actions: SpacesDeviceProjectActions

    public init(id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.isCollapsed = isCollapsed
        self.actions = SpacesDeviceProjectActions(isGitRepo: isGitRepo)
    }
}

public enum SpacesDeviceWorkspaceLifecycle: String, Equatable, Sendable {
    case stopped
    case running

    public init(isRunning: Bool) { self = isRunning ? .running : .stopped }
}

public struct SpacesDeviceWorkspaceRuntime: Equatable, Sendable {
    public let workspaceID: String
    public let lifecycleState: SpacesDeviceWorkspaceLifecycle
    public let hasTrackedRuntimeIndicators: Bool
    public let runningProcessCount: Int
    public let exitedProcessCount: Int
    public let waitingAgentWindowCount: Int
    public let missingConfiguredProcessCount: Int
    public let missingConfiguredBrowserSessionCount: Int

    public init(
        workspaceID: String, lifecycleState: SpacesDeviceWorkspaceLifecycle, hasTrackedRuntimeIndicators: Bool, runningProcessCount: Int,
        exitedProcessCount: Int, waitingAgentWindowCount: Int, missingConfiguredProcessCount: Int = 0, missingConfiguredBrowserSessionCount: Int = 0
    ) {
        self.workspaceID = workspaceID
        self.lifecycleState = lifecycleState
        self.hasTrackedRuntimeIndicators = hasTrackedRuntimeIndicators
        self.runningProcessCount = runningProcessCount
        self.exitedProcessCount = exitedProcessCount
        self.waitingAgentWindowCount = waitingAgentWindowCount
        self.missingConfiguredProcessCount = missingConfiguredProcessCount
        self.missingConfiguredBrowserSessionCount = missingConfiguredBrowserSessionCount
    }
}

public struct SpacesDeviceOverviewViewModel: Equatable, Sendable {
    public let projects: [SpacesDeviceProjectRow]
    public let workspacesByProject: [String: [SpacesDeviceWorkspaceSummary]]
    public let workspaceRuntimeStatusByID: [String: SpacesDeviceWorkspaceRuntime]

    public init(overview: SpacesDeviceOverviewPayload) {
        projects = overview.projects.map {
            SpacesDeviceProjectRow(id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch)
        }

        workspacesByProject = Dictionary(grouping: overview.workspaces, by: \.projectID).mapValues { workspaces in
            workspaces.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }

        workspaceRuntimeStatusByID = Dictionary(
            overview.workspaces.map { workspace -> (String, SpacesDeviceWorkspaceRuntime) in
                let runningProcessCount =
                    workspace.processRows.filter { $0.runState == .running }.count + workspace.terminalRows.filter { $0.runState == .running }.count
                let exitedProcessCount =
                    workspace.processRows.filter { $0.runState == .exited }.count + workspace.codingAgentRows.filter { $0.runState == .exited }.count
                    + workspace.terminalRows.filter { $0.runState == .exited }.count
                let waitingAgentCount = workspace.codingAgentRows.filter { $0.activityState == .waiting }.count
                let hasTrackedIndicators = runningProcessCount > 0 || exitedProcessCount > 0 || waitingAgentCount > 0 || workspace.sessionCount > 0
                return (
                    workspace.id,
                    SpacesDeviceWorkspaceRuntime(
                        workspaceID: workspace.id, lifecycleState: SpacesDeviceWorkspaceLifecycle(isRunning: workspace.isRunning),
                        hasTrackedRuntimeIndicators: hasTrackedIndicators, runningProcessCount: runningProcessCount,
                        exitedProcessCount: exitedProcessCount, waitingAgentWindowCount: waitingAgentCount)
                )
            },
            // A malformed or racy overview payload could repeat a workspace id; keep
            // the last occurrence instead of trapping and crashing the client.
            uniquingKeysWith: { _, latest in latest })
    }
}
