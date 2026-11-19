import Foundation

/// Collects what a read finds, applying the rules every agent's reader shares: blank text is not a
/// message, the first user message is the session's first prompt, and activity is the latest timestamp.
struct SessionReadAccumulator {
    private(set) var messages: [AgentSessionMessage] = []
    var metadata = AgentSessionMetadata()

    /// `isSessionOwnPrompt` is false for a user message that is really a parent agent's briefing to a folded
    /// child session, which is searchable but is not what the user typed.
    mutating func addMessage(
        _ role: AgentSessionMessage.Role, text: String, timestamp: Date?, isSessionOwnPrompt: Bool = true, originSessionID: String? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(AgentSessionMessage(role: role, text: trimmed, timestamp: timestamp, originSessionID: originSessionID))
        if role == .user, isSessionOwnPrompt, metadata.firstUserPrompt == nil { metadata.firstUserPrompt = trimmed }
        noteActivity(timestamp)
    }

    mutating func noteActivity(_ timestamp: Date?) {
        guard let timestamp else { return }
        if let current = metadata.lastActivity, current >= timestamp { return }
        metadata.lastActivity = timestamp
    }

    func result(nextState: AgentSessionResumeState) -> AgentSessionReadResult {
        AgentSessionReadResult(messages: messages, metadata: metadata, nextState: nextState)
    }
}
