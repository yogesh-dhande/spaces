import Foundation
import spacesterminalcore

/// Why a coding-agent row cannot be pinned right now. It rides on the overview row so every client
/// disables Pin with the same reason, and the daemon refuses a pin request with the same message, so the
/// action and the menu can never disagree about eligibility.
public enum SpacesDeviceAgentPinUnavailableReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The agent has not reported a resumable conversation yet.
    case noConversation
    /// The agent was launched as a one-shot job (`claude -p`, `codex exec`, ...), which has no conversation to rejoin.
    case oneShotRun
    /// A pin already holds this conversation.
    case conversationPinned

    public var message: String {
        switch self {
        case .noConversation: "Available once the agent has started a conversation."
        case .oneShotRun: "One-shot runs have no conversation to resume."
        case .conversationPinned: "This conversation is already pinned."
        }
    }

    /// The single eligibility rule for pinning a conversation, nil when it can be pinned. A conversation
    /// is pinnable only when `CodingAgent.resumeCommand` would actually resume it, so a pin can always be
    /// brought back. The checks run in this order so a pinned one-shot row (which cannot exist) would still
    /// report the pin.
    public static func evaluate(sessionKey: String?, relaunchCommand: String?, conversationIsPinned: Bool) -> Self? {
        if conversationIsPinned { return .conversationPinned }
        let command = relaunchCommand ?? ""
        if CodingAgent.launchIsOneShotJob(launchCommand: command) { return .oneShotRun }
        if CodingAgent.resumableSessionKey(launchCommand: command, sessionKey: sessionKey) == nil { return .noConversation }
        return nil
    }
}
