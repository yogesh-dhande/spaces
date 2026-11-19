import Foundation

/// Groups one transcript's messages into turns: a user prompt together with the assistant replies after
/// it, up to the next user prompt. A turn is the unit the index searches, so a query's words must all
/// occur within one turn.
struct SessionTurns {
    struct Turn {
        var text: String
        /// The newest message timestamp in the turn; nil when none of its messages carries one.
        var latest: Date?
    }

    private(set) var turns: [Turn] = []
    /// True when the messages begin with a reply, which continues the turn the transcript already has
    /// instead of starting one: an incremental read picks up mid-conversation.
    private(set) var continuesPreviousTurn = false

    mutating func add(_ message: AgentSessionMessage) {
        if message.role == .user || turns.isEmpty {
            if turns.isEmpty && message.role == .assistant { continuesPreviousTurn = true }
            turns.append(Turn(text: message.text, latest: message.timestamp))
        } else {
            turns[turns.count - 1].text += "\n\n" + message.text
            if let timestamp = message.timestamp, turns[turns.count - 1].latest.map({ $0 < timestamp }) ?? true {
                turns[turns.count - 1].latest = timestamp
            }
        }
    }
}
