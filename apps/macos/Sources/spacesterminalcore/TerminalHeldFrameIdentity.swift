import Foundation

/// The render frame a client currently displays, quoted back to the daemon on a request that answers
/// with session state.
///
/// The daemon compares it against the frame its live session would export for that request. An exact
/// match means the client's screen already IS the session's current screen, so the response carries the
/// session's metadata with no render update at all: a mobile viewer returning from the background
/// confirms its screen in one round trip and no frame bytes instead of decoding a full frame it already
/// holds and dropping it.
///
/// The pair is exactly the identity the daemon's delta chain is keyed by (`GhosttyRenderFrame`'s
/// `ownerEpoch` and `sessionRevision`), which is what makes equality mean identical grid content: the
/// daemon advances a session's revision monotonically and never lets two different screens share one,
/// and a frame from a different owner epoch belongs to another session generation entirely. A client
/// holding a frame with no revision cannot be ordered this way and sends no identity.
public struct TerminalHeldFrameIdentity: Codable, Sendable, Equatable {
    public let ownerEpoch: UInt64
    public let sessionRevision: UInt64

    public init(ownerEpoch: UInt64, sessionRevision: UInt64) {
        self.ownerEpoch = ownerEpoch
        self.sessionRevision = sessionRevision
    }

    /// The identity of a frame this client actually took onto its screen. Nil for a frame the daemon
    /// exported without a revision, which nothing can order.
    public init?(frame: GhosttyRenderFrame) {
        guard let sessionRevision = frame.sessionRevision else { return nil }
        self.init(ownerEpoch: frame.ownerEpoch, sessionRevision: sessionRevision)
    }

    /// Whether `frame` is the very frame this identity names, and so needs no bytes on the wire.
    public func matches(_ frame: GhosttyRenderFrame) -> Bool {
        frame.ownerEpoch == ownerEpoch && frame.sessionRevision == sessionRevision
    }
}
