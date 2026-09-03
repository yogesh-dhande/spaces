import Foundation

/// Liveness contract for a terminal session's state stream (the Device API `subscribe` relay), shared by
/// the daemon that writes the stream and by every client that reads it.
///
/// A terminal session stream carries frames only when the terminal paints. An idle terminal is therefore
/// byte-identical to a stream whose transport has died in a way TCP cannot see: a middlebox that drops
/// payload while keeping the peer socket open, a sleeping radio, an NAT rebind. The client keeps rendering
/// the last frame it received, and because the request channel redials on its own, typing still appears to
/// work while the screen is frozen. The stream needs a liveness signal of its own, so the daemon writes one
/// and the client watches for it.
public enum TerminalStreamLiveness {
    /// The daemon writes a keepalive when a terminal relay has written nothing for this long.
    ///
    /// 15s is chosen against the client's `silenceTimeout`: it is short enough that a dead stream is
    /// detected in well under a minute with no keystrokes, and its cost is one small TLS record every 15s
    /// per open terminal view, only while a view is open, which is negligible against the frames the same
    /// stream carries the moment the terminal paints.
    public static let keepaliveIntervalSeconds: Double = 15

    /// A client gives up on a terminal stream after receiving no bytes at all for this long.
    ///
    /// 40s must stay above `2 * keepaliveIntervalSeconds` plus network slack: one missed keepalive (a
    /// stalled write, a scheduling hiccup, a slow link) must never be read as a dead stream, and the
    /// daemon's own worst-case gap is ~20s (see `daemonCheckIntervalSeconds`). Changing either constant
    /// means rechecking that relationship.
    public static let silenceTimeoutSeconds: Double = 40

    /// The keepalive frame: a single empty line.
    ///
    /// Every consumer of this stream drops empty lines before decoding, so an empty line is inert payload
    /// on the wire that still proves the transport is carrying bytes end to end. The drop sites are
    /// `StreamSubscription.receiveNext` (iOS), both `SpacesPinnedTLSConnection` receive loops (Darwin and
    /// Linux), and `GhosttyRemoteSessionStateStream`'s line handler.
    public static let keepaliveFrame = Data([0x0A])

    /// How often the daemon's relay checks whether a keepalive is due.
    ///
    /// A third of the interval, so a keepalive lands between 15s and 20s after the last write rather than
    /// between 15s and 30s. Only the first gap after a real frame can reach 20s; once the relay is idle,
    /// keepalives land every 15s.
    public static var daemonCheckIntervalSeconds: Double { keepaliveIntervalSeconds / 3 }

    /// How often a client checks its stream for silence, derived from the timeout so that shortening the
    /// timeout in a test also tightens the poll without a second knob to keep in sync.
    public static func silenceCheckIntervalSeconds(forTimeout timeout: Double) -> Double {
        max(timeout / 8, 0.02)
    }
}
