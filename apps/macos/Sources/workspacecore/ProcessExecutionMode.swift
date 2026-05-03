import Foundation

public enum ProcessExecutionMode: String, CaseIterable, Codable, Sendable {
    case direct
    case shell

    public var displayName: String {
        switch self {
        case .direct: "Direct"
        case .shell: "Shell"
        }
    }
}
