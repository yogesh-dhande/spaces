import Foundation

public enum AgentWindowStatus: String, Codable, Sendable {
    case idle = "idle"
    case spinning = "spinning"
    case waiting = "waiting"
    case done = "done"
    /// The agent process ended but its terminal session is still open. The row survives so the terminal
    /// stays addressable and a restart in the same terminal reuses it; distinct from `idle`, which means
    /// no agent has started in that terminal yet.
    case exited = "exited"
}
