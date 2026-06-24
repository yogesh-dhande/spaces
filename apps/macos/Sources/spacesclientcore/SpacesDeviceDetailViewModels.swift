import Foundation
import spacesdevicecore

public struct SpacesDeviceProjectSettingsViewModel: Equatable, Sendable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    public let config: SpacesDeviceProjectConfig
    public let actions: SpacesDeviceProjectActions

    public init(project: SpacesDeviceProjectSummary) {
        id = project.id
        name = project.name
        dir = project.dir
        isGitRepo = project.isGitRepo
        defaultBranch = project.defaultBranch
        config = project.config
        actions = SpacesDeviceProjectActions(isGitRepo: project.isGitRepo)
    }
}

public enum SpacesDeviceWorkspaceLifecycleCommand: String, Equatable, Sendable {
    case launch
    case restart
}

public struct SpacesDeviceWorkspaceDetailActions: Equatable, Sendable {
    public let launchOrRestart: SpacesDeviceWorkspaceLifecycleCommand
    public let showsStop: Bool
    public let showsOverflow: Bool
    public let showsOpenTerminal: Bool
    public let showsOpenEditor: Bool
    public let showsRevealInFinder: Bool
    public let showsRunSetup: Bool

    public init(isRunning: Bool) {
        launchOrRestart = isRunning ? .restart : .launch
        showsStop = true
        showsOverflow = true
        showsOpenTerminal = true
        showsOpenEditor = true
        showsRevealInFinder = true
        showsRunSetup = true
    }
}

public struct SpacesDeviceWorkspaceDetailSurface: Equatable, Sendable {
    public let showsNotes: Bool
    public let showsPorts: Bool
    public let showsProcesses: Bool
    public let showsBrowserSessions: Bool
    public let showsAgentLaunchers: Bool
    public let showsTerminals: Bool
    public let showsStopScript: Bool
    public let configuredPortCount: Int
    public let assignedPortCount: Int
    public let configuredProcessCount: Int
    public let runningProcessCount: Int
    public let configuredBrowserSessionCount: Int
    public let resolvedBrowserSessionCount: Int
    public let configuredAgentLauncherCount: Int
    public let runningCodingAgentCount: Int
    public let terminalCount: Int

    public init(workspace: SpacesDeviceWorkspaceSummary) {
        showsNotes = true
        showsPorts = true
        showsProcesses = true
        showsBrowserSessions = true
        showsAgentLaunchers = true
        showsTerminals = true
        showsStopScript = true
        configuredPortCount = workspace.config.ports.count
        assignedPortCount = workspace.assignedPorts.count
        configuredProcessCount = workspace.config.processes.count
        runningProcessCount = workspace.processRows.filter { $0.runState == .running }.count
        configuredBrowserSessionCount = workspace.config.browserSessions.count
        resolvedBrowserSessionCount = workspace.config.resolvedBrowserSessions.count
        configuredAgentLauncherCount = workspace.config.agentLaunchers.count
        runningCodingAgentCount = workspace.codingAgentRows.filter { $0.runState == .running }.count
        terminalCount = workspace.terminalRows.count
    }
}

public struct SpacesDeviceWorkspaceDetailViewModel: Equatable, Sendable {
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
    public let assignedPorts: [SpacesDeviceAssignedPort]
    public let setupState: SpacesDeviceWorkspaceSetupState?
    public let config: SpacesDeviceWorkspaceConfig
    public let processRows: [SpacesDeviceWorkspaceProcessRow]
    public let codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow]
    public let terminalRows: [SpacesDeviceWorkspaceTerminalRow]
    public let actions: SpacesDeviceWorkspaceDetailActions
    public let surface: SpacesDeviceWorkspaceDetailSurface

    public init(workspace: SpacesDeviceWorkspaceSummary) {
        id = workspace.id
        projectID = workspace.projectID
        projectName = workspace.projectName
        title = workspace.title
        branch = workspace.branch
        baseBranch = workspace.baseBranch
        dir = workspace.dir
        isRunning = workspace.isRunning
        isArchived = workspace.isArchived
        isHidden = workspace.isHidden
        isDefault = workspace.isDefault
        notes = workspace.notes
        assignedPorts = workspace.assignedPorts
        setupState = workspace.setupState
        config = workspace.config
        processRows = workspace.processRows
        codingAgentRows = workspace.codingAgentRows
        terminalRows = workspace.terminalRows
        actions = SpacesDeviceWorkspaceDetailActions(isRunning: workspace.isRunning)
        surface = SpacesDeviceWorkspaceDetailSurface(workspace: workspace)
    }
}
