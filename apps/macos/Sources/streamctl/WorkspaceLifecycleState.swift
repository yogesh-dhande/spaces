import Foundation

public enum WorkspaceLifecycleState: String, Codable, Sendable {
    case stopped
    case running

    public init(isRunning: Bool) {
        self = isRunning ? .running : .stopped
    }
}
