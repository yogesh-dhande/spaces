import Foundation

public enum AgentWindowStatus: String, Codable, Sendable {
    case idle = "idle"
    case spinning = "spinning"
    case waiting = "waiting"
    case done = "done"
}
