import Foundation
import spacesterminalcore

/// What one lifecycle signal does to the conversation id an agent row stores.
///
/// The three cases are spelled out rather than carried as an optional id because the row has to tell
/// "this signal says nothing about my conversation" apart from "the conversation I hold is not one a
/// resume can rejoin". Only the first leaves the stored id in place; the second drops it, so the next
/// restorable capture offers the agent back as a fresh conversation instead of relaunching `--resume`
/// against one it has left.
public enum AgentSessionKeyUpdate: Equatable, Sendable {
    /// The signal reports nothing, so the row keeps the newest id it was told.
    case keep
    /// The signal reports a conversation that cannot be resumed, so the stored id is dropped.
    case clear
    /// The signal reports a resumable conversation, which replaces whatever the row held.
    case set(String)

    /// The id the row stores after this update, given the id it holds now.
    public func applied(to storedKey: String?) -> String? {
        switch self {
        case .keep: storedKey
        case .clear: nil
        case .set(let key): key
        }
    }

    /// The id an agent-row lookup can match on when no terminal tracking id resolves the row. Only a
    /// `set` names one: `keep` and `clear` carry no id to match against.
    public var matchableKey: String? {
        guard case .set(let key) = self else { return nil }
        return key
    }
}

extension AgentHookSessionKeyReport {
    /// The row update a hook report asks for. The two "no usable id" reports diverge here: a signal
    /// that names no conversation leaves the row alone, while one naming a conversation that is not
    /// resumable yet supersedes the stored id with nothing.
    public var sessionKeyUpdate: AgentSessionKeyUpdate {
        switch self {
        case .unreported: .keep
        case .pending: .clear
        case .resumable(let key): .set(key)
        }
    }
}
