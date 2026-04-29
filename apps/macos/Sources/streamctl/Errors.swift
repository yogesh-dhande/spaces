import Foundation

public enum MissingTrackedWindowKind: Sendable, Equatable {
    case browserSession
    case process
    case codingAgent
    case window
}

public struct MissingTrackedWindowContext: Sendable {
    public let kind: MissingTrackedWindowKind
    public let workspaceID: String
    public let windowID: Int?
    public let targetURL: String?
    public let processID: String?
    public let title: String

    public init(
        kind: MissingTrackedWindowKind, workspaceID: String, windowID: Int? = nil, targetURL: String? = nil, processID: String? = nil, title: String
    ) {
        self.kind = kind
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.targetURL = targetURL
        self.processID = processID
        self.title = title
    }
}

public enum MuxyError: LocalizedError {
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
    case databaseMigrationFailed(message: String)
    case missingTrackedWindow(MissingTrackedWindowContext)

    public var errorDescription: String? {
        switch self {
        case .missingProject(let dir): return "Project not found: \(dir)"
        case .projectAlreadyExists(let dir): return "Project already exists: \(dir)"
        case .missingWorkspace(let project, let workspace): return "Workspace not found for project \(project): \(workspace)"
        case .workspaceAlreadyExists(let project, let workspace): return "Workspace already exists for project \(project): \(workspace)"
        case .invalidWorkspace(let path): return "Workspace path does not exist: \(path)"
        case .gitCommandFailed(let message): return "Git command failed: \(message)"
        case .invalidArgument(let message): return "Invalid argument: \(message)"
        case .yabaiUnavailable(let message): return "yabai not available: \(message)"
        case .dependencyMissing(let message): return "Missing dependency: \(message)"
        case .configError(let message): return "Configuration error: \(message)"
        case .databaseMigrationFailed(let message): return message
        case .missingTrackedWindow(let context):
            switch context.kind {
            case .browserSession: return "Window missing: Browser session '\(context.title)' is no longer available."
            case .process: return "Window missing: Process '\(context.title)' is no longer available."
            case .codingAgent: return "Window missing: Coding agent '\(context.title)' is no longer available."
            case .window: return "Window missing: '\(context.title)' is no longer available."
            }
        }
    }
}
