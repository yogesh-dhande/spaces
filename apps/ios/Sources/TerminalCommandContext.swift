import Foundation

/// The identity every terminal input/control command carries: which session to command, which attached
/// client is issuing it, and the owner epoch that command is gated against. Bundled so call chains
/// forward one value instead of re-threading the same three parameters through every hop between a
/// gesture and the `SpacesDeviceAPIClient` request that sends it.
///
/// `timeout` and `commandChannel` stay as separate trailing parameters on each method rather than
/// joining this struct: timeout defaults deliberately differ per method (3s for interactive input, 30s
/// for `pasteImage`, 6s for `readSelectionText`), and `commandChannel` is a per-call transport override,
/// not part of a command's identity.
struct TerminalCommandContext: Sendable {
    var sessionID: String
    var clientID: String
    var ownerEpoch: UInt64?

    init(sessionID: String, clientID: String, ownerEpoch: UInt64?) {
        self.sessionID = sessionID
        self.clientID = clientID
        self.ownerEpoch = ownerEpoch
    }
}
