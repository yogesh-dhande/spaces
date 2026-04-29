import Foundation

public enum RunningProcessState: String, Codable, Sendable {
    case running
    case exited
    case idle
}
