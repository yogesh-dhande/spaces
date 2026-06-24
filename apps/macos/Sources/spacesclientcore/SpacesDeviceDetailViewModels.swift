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
    }
}
