import Foundation

public enum WorkspaceSetupStatus: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

public struct WorkspaceSetupState: Sendable {
    public let status: WorkspaceSetupStatus
    public let errorMessage: String?
    public let startedAt: String?
    public let finishedAt: String?

    public init(status: WorkspaceSetupStatus, errorMessage: String?, startedAt: String?, finishedAt: String?) {
        self.status = status
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
