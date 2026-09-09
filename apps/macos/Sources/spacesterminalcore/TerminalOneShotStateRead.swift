import Foundation

/// What a one-shot state read asks a live session for.
///
/// A subscription is the only thing that needs a screen delivered to it unasked: it has no other way to
/// get a baseline. Every other reader says here what it is actually after, so the session spends a
/// full-grid capture and encode only when the answer is going to be looked at.
public enum TerminalOneShotStateRead: Sendable, Equatable {
    /// The session's metadata and the screen with it, exported self-contained so the reader can paint it
    /// with no baseline of its own. `heldFrame`, when the reader named one, is the frame it already
    /// displays: an exact match means the read carries no render update at all, because the reader's
    /// picture already is the session's current screen (see `TerminalHeldFrameIdentity`).
    case screen(heldFrame: TerminalHeldFrameIdentity?)
    /// The session's metadata alone: ownership, runtime state, title and working directory, with no
    /// screen on it. This is what a reader asks for when something else is already bringing it a frame,
    /// which on a terminal open is the subscription's own initial frame.
    case metadataOnly

    /// Whether this read wants the screen exported at all. A read that does not skips the capture and the
    /// encode outright, and leaves the session's delta chain exactly where it was.
    public var includesScreen: Bool {
        switch self {
        case .screen: return true
        case .metadataOnly: return false
        }
    }

    /// The frame the reader already displays, for the read that asked for a screen and named one.
    public var heldFrame: TerminalHeldFrameIdentity? {
        switch self {
        case .screen(let heldFrame): return heldFrame
        case .metadataOnly: return nil
        }
    }
}
