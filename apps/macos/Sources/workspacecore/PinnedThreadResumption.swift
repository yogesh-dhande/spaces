import Foundation
import spacesterminalcore

/// The terminal a resume request ended up with.
public struct PinnedThreadResumption: Sendable {
    public let sessionID: String
    /// The session this request launched, nil when the pin was already running and `sessionID` names the
    /// terminal that was already attached to it.
    public let launchedSession: TerminalServiceSessionSummary?
}
