import Foundation

/// The three states a terminal view's connection banner can be in, shared by the Mac and iOS clients.
///
/// A terminal state stream can go quiet for reasons a client cannot tell apart from the outside: a
/// transport disconnect, a stalled relay caught by `TerminalStreamLiveness`, or a redial that is simply
/// slow. `.reconnecting` covers all of those uniformly; a client only escalates to `.unreachable` once a
/// redial attempt has hard evidence that every candidate address failed to dial. See
/// `TerminalConnectionStageTracker` for the state machine that drives these transitions.
public enum TerminalConnectionStage: Sendable, Equatable {
    /// The stream is live: frames are arriving (or nothing has happened yet). No banner.
    case connected
    /// The stream was lost and a redial is in flight. The banner shows "Reconnecting…" once the grace
    /// period in `TerminalConnectionNotice.bannerGraceSeconds` has elapsed without a frame.
    case reconnecting
    /// A redial attempt exhausted every candidate address without dialing one. The banner shows "Device
    /// unreachable" with a Retry action immediately, no grace.
    case unreachable
}
