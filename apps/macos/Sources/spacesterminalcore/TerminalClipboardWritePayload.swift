import Foundation

/// One OSC 52 clipboard write a program performed inside a session, addressed to the client that
/// currently owns it.
///
/// A program's copy belongs on the machine the user is typing on, so the daemon forwards the write to
/// the attached owner instead of writing its own pasteboard: for a remote (Linux) daemon its own
/// pasteboard is a different machine entirely, and for a local daemon it is a machine-wide side effect
/// nobody asked for.
///
/// The payload rides the session state stream under the `clipboard_write` reason, which fans out to
/// every subscriber of that session. Observers drop it by comparing `targetClientID` against their own
/// attachment id. The fan-out is accepted rather than unicast: every subscriber to a session is a
/// device the same user paired, the state stream is the only ordered per-session channel to a client
/// that already exists, and a unicast channel would have to be built and kept alive purely for this
/// one-shot.
///
/// It is a one-shot: `GhosttyRemoteSessionStatePayload.merged(with:)` and `replacingRenderUpdate` both
/// drop it, so it never rides a later payload and no client can replay the paste.
public struct TerminalClipboardWritePayload: Codable, Sendable, Equatable {
    /// The attachment id of the owner client this write is addressed to. Every other subscriber
    /// ignores the payload.
    public let targetClientID: String
    /// The decoded clipboard text. Empty means the program asked for the destination to be CLEARED
    /// (an OSC 52 write carrying no payload), which the owner applies by clearing its pasteboard —
    /// a program that clears the terminal's clipboard is asking for the user's clipboard to be
    /// cleared, and dropping the empty write would leave stale content the program meant to remove.
    public let text: String

    public init(targetClientID: String, text: String) {
        self.targetClientID = targetClientID
        self.text = text
    }
}
