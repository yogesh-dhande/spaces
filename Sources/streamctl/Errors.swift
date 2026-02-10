import Foundation

public enum AgentmuxError: LocalizedError {
    case missingProject(dir: String)
    case projectAlreadyExists(dir: String)
    case missingWorkspace(project: String, workspace: String)
    case workspaceAlreadyExists(project: String, workspace: String)
    case invalidWorkspace(path: String)
    case gitCommandFailed(message: String)
    case invalidArgument(message: String)
    case yabaiUnavailable(message: String)
    case dependencyMissing(message: String)
    case configError(message: String)

    public var errorDescription: String? {
        switch self {
        case let .missingProject(dir):
            return "Project not found: \(dir)"
        case let .projectAlreadyExists(dir):
            return "Project already exists: \(dir)"
        case let .missingWorkspace(project, workspace):
            return "Workspace not found for project \(project): \(workspace)"
        case let .workspaceAlreadyExists(project, workspace):
            return "Workspace already exists for project \(project): \(workspace)"
        case let .invalidWorkspace(path):
            return "Workspace path does not exist: \(path)"
        case let .gitCommandFailed(message):
            return "Git command failed: \(message)"
        case let .invalidArgument(message):
            return "Invalid argument: \(message)"
        case let .yabaiUnavailable(message):
            return "yabai not available: \(message)"
        case let .dependencyMissing(message):
            return "Missing dependency: \(message)"
        case let .configError(message):
            return "Configuration error: \(message)"
        }
    }
}
