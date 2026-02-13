import Foundation

public enum StatusCheckOnExit: String, Codable, Sendable, CaseIterable {
    case none = "none"
    case restart = "restart"
    case notify = "notify"
}
