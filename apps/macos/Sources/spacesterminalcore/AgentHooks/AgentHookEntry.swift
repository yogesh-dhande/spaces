import Foundation

/// One hook entry as an agent's config carries it: the event it runs on, named as the agent's hooks
/// file names it (`PreToolUse`), and the exact shell command it runs.
public struct AgentHookEntry: Sendable, Equatable, Codable {
    public let eventName: String
    public let command: String

    public init(eventName: String, command: String) {
        self.eventName = eventName
        self.command = command
    }
}
