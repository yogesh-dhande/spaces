import Foundation

/// What pinning an agent row captures: the conversation and how to resume it, read with the same
/// command and directory rule the restorable-session capture uses. Any part can be missing for a row
/// that has not reported a conversation or whose launch command is unknown; eligibility decides whether
/// that blocks the pin.
public struct PinnableConversation: Sendable, Equatable {
    public let sessionKey: String?
    public let launchCommand: String?
    public let workingDirectory: String?
}
