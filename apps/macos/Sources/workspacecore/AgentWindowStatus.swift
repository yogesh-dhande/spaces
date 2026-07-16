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

    /// Whether an agent in this status leaves its subscriber terminal ready to receive queued child
    /// notifications. Idle and done are ready; spinning and waiting are busy (queue); exited means the
    /// process is gone but the terminal survives as a bare shell, so a line would be typed into a shell —
    /// queue until a new agent inits and the row resets to idle. The single authority for both the
    /// notification engine's live idle check and the daemon signal path's flush-on-resulting-status
    /// decision, so those two never disagree about what "idle" means.
    public var leavesSubscriberIdle: Bool {
        switch self {
        case .idle, .done: true
        case .spinning, .waiting, .exited: false
        }
    }
}
