import Foundation

/// Pure state machine behind the terminal connection banner, driven identically by the Mac and iOS
/// clients so the two never disagree about when the banner should appear or what it should say.
///
/// The tracker owns no timers and no threads: it only reacts to events the caller reports, and returns
/// plain values (a banner-visible flag, a backoff delay) for the caller to act on. That split keeps the
/// transition logic testable without Combine, `Timer`, or async scheduling, and keeps this type
/// Linux-safe (Foundation only) so the daemon-facing parts of `spacesterminalcore` can depend on it too.
///
/// The two stage-2 rules that matter are: stage 2 is entered only on hard evidence (every candidate
/// address failed to dial), never on a timer, and it is exited only by a frame actually arriving, never
/// by a timer. Everything else (the stage 1 grace, the backoff ladder) is just view timing on top of
/// those two facts.
public struct TerminalConnectionStageTracker: Sendable, Equatable {
    /// The current connection stage. Starts `.connected`, since a freshly opened terminal view has not
    /// yet lost its stream.
    public private(set) var stage: TerminalConnectionStage = .connected

    /// Whether the banner should be on screen right now. False in `.connected`, false during the stage 1
    /// grace, true once the grace elapses or stage 2 is entered.
    public private(set) var isBannerVisible = false

    private var backoff = TerminalUnreachableBackoff()

    public init() {}

    /// The stream was lost: a silence-watchdog stall or a transport disconnect. Moves `.connected` to
    /// `.reconnecting` with the banner hidden until `graceElapsed()` fires, so a redial that heals within
    /// the grace window never flashes anything. A no-op once already reconnecting or unreachable, since
    /// those stages already reflect a lost stream.
    public mutating func streamLost() {
        guard stage == .connected else { return }
        stage = .reconnecting
        isBannerVisible = false
    }

    /// The caller's grace timer fired. Shows the banner if the stream is still down; a no-op if a frame
    /// already arrived (or stage 2 was already entered) before the timer fired, so a late grace timer can
    /// never show a banner over a connection that has recovered.
    public mutating func graceElapsed() {
        guard stage == .reconnecting else { return }
        isBannerVisible = true
    }

    /// A redial attempt ended with every candidate address failing to dial. Moves to `.unreachable` with
    /// the banner visible immediately (no grace, since this is the strongest evidence the tracker can
    /// have that the device is actually down), and returns the delay before the caller's next automatic
    /// redial. Safe to call from `.connected` too, even though a dial failing while a stream is still
    /// live should not happen in practice: it is treated the same as a stream loss immediately followed
    /// by exhausted candidates.
    @discardableResult
    public mutating func attemptEndedUnreachable() -> TimeInterval {
        stage = .unreachable
        isBannerVisible = true
        return backoff.nextDelay()
    }

    /// The user tapped Retry. Resets the backoff ladder so the next automatic redial after this one is
    /// the shortest again; the caller redials immediately on top of this, so stage and banner visibility
    /// are unchanged. A no-op unless already `.unreachable`.
    public mutating func retryRequested() {
        guard stage == .unreachable else { return }
        backoff.reset()
    }

    /// A frame arrived on a live stream: proof the connection is back, regardless of which stage the
    /// tracker was in. Returns to `.connected`, hides the banner, and resets the backoff ladder so a
    /// future stream loss starts its automatic redials from the shortest delay again.
    public mutating func frameReceived() {
        stage = .connected
        isBannerVisible = false
        backoff.reset()
    }
}
