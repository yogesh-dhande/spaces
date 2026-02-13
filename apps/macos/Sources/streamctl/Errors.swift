import Foundation

public enum SpaceshipError: LocalizedError {
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
        case .missingProject(let dir):
            return "Project not found: \(dir)"
        case .projectAlreadyExists(let dir):
            return "Project already exists: \(dir)"
        case .missingWorkspace(let project, let workspace):
            return "Workspace not found for project \(project): \(workspace)"
        case .workspaceAlreadyExists(let project, let workspace):
            return "Workspace already exists for project \(project): \(workspace)"
        case .invalidWorkspace(let path):
            return "Workspace path does not exist: \(path)"
        case .gitCommandFailed(let message):
            return "Git command failed: \(message)"
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .yabaiUnavailable(let message):
            return "yabai not available: \(message)"
        case .dependencyMissing(let message):
            return "Missing dependency: \(message)"
        case .configError(let message):
            return "Configuration error: \(message)"
        }
    }
}
