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

public struct SpacesDeviceWorkspaceRow: Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let projectName: String
    public let title: String
    public let branch: String?
    public let baseBranch: String?
    public let dir: String
    public let isRunning: Bool
    public let isArchived: Bool
    public let isHidden: Bool
    public let isDefault: Bool
    public let notes: String?

    public init(
        id: String, projectID: String, projectName: String, title: String, branch: String?, baseBranch: String?, dir: String, isRunning: Bool,
        isArchived: Bool, isHidden: Bool, isDefault: Bool, notes: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.title = title
        self.branch = branch
        self.baseBranch = baseBranch
        self.dir = dir
        self.isRunning = isRunning
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.isDefault = isDefault
        self.notes = notes
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
    public let workspacesByProject: [String: [SpacesDeviceWorkspaceRow]]
    public let workspaceRuntimeStatusByID: [String: SpacesDeviceWorkspaceRuntime]

    public init(overview: SpacesDeviceOverviewPayload) {
        if overview.projects.isEmpty {
            let grouped = Dictionary(grouping: overview.workspaces, by: \.projectID)
            projects = grouped.values.compactMap { workspaces in
                guard let first = workspaces.first else { return nil }
                return SpacesDeviceProjectRow(
                    id: first.projectID, name: first.projectName, dir: "", isGitRepo: first.branch != nil || first.baseBranch != nil,
                    defaultBranch: first.baseBranch)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } else {
            projects = overview.projects.map {
                SpacesDeviceProjectRow(
                    id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch, isCollapsed: $0.isCollapsed)
            }
        }

        workspacesByProject = Dictionary(
            grouping: overview.workspaces.map {
                SpacesDeviceWorkspaceRow(
                    id: $0.id, projectID: $0.projectID, projectName: $0.projectName, title: $0.title, branch: $0.branch, baseBranch: $0.baseBranch,
                    dir: $0.dir, isRunning: $0.isRunning, isArchived: $0.isArchived, isHidden: $0.isHidden, isDefault: $0.isDefault, notes: $0.notes)
            }, by: \.projectID
        ).mapValues { rows in rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }

        workspaceRuntimeStatusByID = Dictionary(
            uniqueKeysWithValues: overview.workspaces.map { workspace in
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
            })
    }
}
