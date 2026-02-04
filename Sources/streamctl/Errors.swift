import Foundation

public enum StreamctlError: LocalizedError {
    case missingProject(name: String)
    case projectAlreadyExists(name: String)
    case missingStream(project: String, stream: String)
    case streamAlreadyExists(project: String, stream: String)
    case invalidWorktree(path: String)
    case gitCommandFailed(message: String)
    case invalidArgument(message: String)

    public var errorDescription: String? {
        switch self {
        case let .missingProject(name):
            return "Project not found: \(name)"
        case let .projectAlreadyExists(name):
            return "Project already exists: \(name)"
        case let .missingStream(project, stream):
            return "Stream not found for project \(project): \(stream)"
        case let .streamAlreadyExists(project, stream):
            return "Stream already exists for project \(project): \(stream)"
        case let .invalidWorktree(path):
            return "Worktree path does not exist: \(path)"
        case let .gitCommandFailed(message):
            return "Git command failed: \(message)"
        case let .invalidArgument(message):
            return "Invalid argument: \(message)"
        }
    }
}
