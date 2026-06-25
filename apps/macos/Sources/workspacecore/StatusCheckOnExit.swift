import Foundation

public enum ProcessExitAction: String, Codable, Sendable, CaseIterable {
    case none = "none"
    case restart = "restart"
    case notify = "notify"
}
