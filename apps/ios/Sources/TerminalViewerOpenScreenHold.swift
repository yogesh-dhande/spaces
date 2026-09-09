import Foundation
import spacesterminalcore

/// One open's wait for a frame at the phone's own settled grid.
///
/// A session runs at whatever grid its daemon last set, so the frames a viewer receives while it opens
/// describe that screen and not this phone's. Painting one and then repainting after the ownership-sync
/// resize round trip is the reflow the user reads as a replay. The viewer therefore holds its screen
/// updates from `start()` until a frame at the grid it reported has reduced, and this box is what the
/// reduce loop answers "is this that frame?" from: `TerminalRemoteStateReductionPipeline`'s
/// `shouldUseFrame` runs off the main actor, so it cannot read the model's viewport or call back into it.
///
/// The target is the *latest* grid the surface reported, not the first. A terminal surface reports its
/// grid more than once as it opens, and a frame at a grid the surface has already moved past is not the
/// one to paint: painting it would reflow to the newer grid a moment later, which is the same replay one
/// step on. A newer report therefore replaces the target and the frame that matched the old one stops
/// counting.
///
/// The hold *decision* is made at reduce time: the reduce loop is what recognizes the frame at the
/// latest reported grid, before that frame even reaches the apply mailbox, which is what lets everything
/// the session flushed behind it still be queued and collapse into the one apply that paints. But the
/// release itself — flipping `setHoldsScreenUpdates(false)` — has to wait until that frame's output is
/// actually queued: releasing at reduce time would let the mailbox drain whatever older, screen-only
/// frame it was already holding before the matching frame is even in line behind it, which paints the
/// stale grid first and the matching one second — the very replay this hold exists to prevent. So
/// `noteReducedFrame` only marks the release pending, and `releasePendingAfterSubmit` — called once the
/// pipeline's consumer has handed that frame's output to the mailbox — is what actually runs it.
///
/// Ending is one-shot however many paths race for it. The reduce loop marks the release pending by
/// matching a frame at the latest reported grid, and `releasePendingAfterSubmit` completes it once that
/// frame's output is queued; the main actor ends it directly when the surface reports a grid the screen
/// already matches, when the handshake produced no frame at all, when no matching frame can arrive (the
/// session ended, another client owns it), when the bounded wait expires, or when the main actor applies
/// a frame at the latest reported grid (`releaseForApplyingMatchingFrame`). Whichever path gets there
/// first runs `release` exactly once: `takeRelease` under the lock is what makes a pending-submit mark
/// unable to resurrect a hold something else already ended.
final class TerminalViewerOpenScreenHold: @unchecked Sendable {
    private let lock = NSLock()
    private var viewport: (columns: Int, rows: Int)?
    /// Whether a frame at the current `viewport` has reduced. Reset by every new grid, because a frame at
    /// the previous grid says nothing about the one the viewer now wants to paint. Read by
    /// `releaseIfNoMatchingFrameArrived`, which is how the ownership handshake tells a settled screen from
    /// one that never arrived.
    private var hasFrameForViewport = false
    /// True from the moment `noteReducedFrame` recognizes the matching frame until
    /// `releasePendingAfterSubmit` runs the release (or something else ends the hold first). Read only by
    /// `releasePendingAfterSubmit`, which is what keeps that call a no-op unless `noteReducedFrame` is the
    /// reason it is being called.
    private var isReleasePendingSubmit = false
    /// The grid of the frame `noteReducedFrame` marked pending, read back by `releasePendingAfterSubmit`
    /// so a caller logging the release (the on-device performance baseline's `terminal_first_paint`) knows
    /// what it painted without the pipeline's `didSubmit` hook, which takes no parameters, having to carry
    /// the frame through itself. Only meaningful alongside `isReleasePendingSubmit`.
    private var pendingFrameSize: (columns: Int, rows: Int)?
    /// Stops the pipeline holding. Non-nil exactly while the hold is armed, so it doubles as that state.
    private var release: (@Sendable () -> Void)?

    var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return release != nil
    }

    /// Arms the hold. `viewport` is nil until the terminal surface has measured itself, which is why
    /// `setViewport` exists: the surface mounts only once this viewer owns the session, so the grid to
    /// match against is usually reported after the first payloads have already arrived.
    func begin(viewport: (columns: Int, rows: Int)?, release: @escaping @Sendable () -> Void) {
        lock.lock()
        self.viewport = viewport
        hasFrameForViewport = false
        isReleasePendingSubmit = false
        self.release = release
        lock.unlock()
    }

    /// A newer grid from the surface. `matchesLatestFrame` says whether the screen the viewer has already
    /// reduced is at that grid, which is how a session already running at the phone's size is recognized:
    /// its frame arrived before there was a viewport to match it against, so no later frame would match
    /// it either, and on a quiet session no later frame is coming at all. That case releases here. True
    /// when this call is what ended the hold.
    @discardableResult func setViewport(columns: Int, rows: Int, matchesLatestFrame: Bool) -> Bool {
        lock.lock()
        if let viewport, viewport.columns == columns, viewport.rows == rows {
            lock.unlock()
            return false
        }
        viewport = (columns, rows)
        hasFrameForViewport = matchesLatestFrame
        // The frame `noteReducedFrame` matched against the old grid no longer counts once the target
        // moves: clear any pending-submit mark it left, exactly like `hasFrameForViewport` above, so a
        // `releasePendingAfterSubmit()` that runs after this call cannot release the hold at the new
        // grid with no frame that actually matched it.
        isReleasePendingSubmit = false
        let pending = matchesLatestFrame ? takeRelease() : nil
        lock.unlock()
        pending?()
        return pending != nil
    }

    /// Called from the reduce loop for every frame the reducer materializes, off the main actor and
    /// before that frame's output reaches the apply mailbox. Only marks the match: the release itself
    /// waits for `releasePendingAfterSubmit`, which the pipeline calls once this same frame's output is
    /// actually queued (see the type doc for why releasing here would race the mailbox).
    func noteReducedFrame(_ frame: GhosttyRenderFrame) {
        lock.lock()
        guard release != nil, let viewport, frame.columns == viewport.columns, frame.rows == viewport.rows else {
            lock.unlock()
            return
        }
        hasFrameForViewport = true
        isReleasePendingSubmit = true
        pendingFrameSize = (frame.columns, frame.rows)
        lock.unlock()
    }

    /// Runs the release `noteReducedFrame` marked pending, once the pipeline confirms that frame's output
    /// reached the apply mailbox. A no-op unless `noteReducedFrame` is the reason this is being called:
    /// nothing else sets `isReleasePendingSubmit`, and `takeRelease` returning nil covers the case where
    /// another path (`end()`, a newer `setViewport`, `releaseIfNoMatchingFrameArrived`) already ended the
    /// hold in between. Returns the released frame's grid exactly when this call is what performed the
    /// release (the same one-shot every other release method here reports via its own `Bool`), so a caller
    /// can log the release without needing to already know the frame.
    @discardableResult func releasePendingAfterSubmit() -> (columns: Int, rows: Int)? {
        lock.lock()
        guard isReleasePendingSubmit else {
            lock.unlock()
            return nil
        }
        isReleasePendingSubmit = false
        let size = pendingFrameSize
        let pending = takeRelease()
        lock.unlock()
        pending?()
        return pending != nil ? size : nil
    }

    /// Called from the main actor while it applies a frame, with that frame's grid. Ends the hold only
    /// when the hold is armed and the frame is at the latest reported grid — the same predicate
    /// `noteReducedFrame` matches at reduce time, re-evaluated here at apply time so the apply that paints
    /// this frame can never observe a hold its own frame already satisfied: the post-submit release runs
    /// on the pipeline's consumer thread with nothing ordering it against this apply, so either side may
    /// get there first, and `takeRelease` is what keeps ending the hold one-shot regardless of which one
    /// does. True when this call is what ended the hold.
    @discardableResult func releaseForApplyingMatchingFrame(columns: Int, rows: Int) -> Bool {
        lock.lock()
        guard release != nil, let viewport, viewport.columns == columns, viewport.rows == rows else {
            lock.unlock()
            return false
        }
        hasFrameForViewport = true
        isReleasePendingSubmit = false
        let pending = takeRelease()
        lock.unlock()
        pending?()
        return pending != nil
    }

    /// Ends the hold when no frame at the current grid has reduced. The ownership handshake calls this
    /// when it settles: past it nothing else is going to produce that frame, and waiting out the whole
    /// bounded wait for one that is not coming would leave the viewer on its preparing state for seconds.
    /// True when this call is what ended the hold.
    @discardableResult func releaseIfNoMatchingFrameArrived() -> Bool {
        lock.lock()
        guard release != nil, !hasFrameForViewport else {
            lock.unlock()
            return false
        }
        let pending = takeRelease()
        lock.unlock()
        pending?()
        return pending != nil
    }

    /// Ends the hold from the main actor. Safe to call after something else already ended it: the
    /// release closure runs at most once whichever path gets there first. True when this call is what
    /// ended the hold, the same one-shot signal every other release method here reports.
    @discardableResult func end() -> Bool {
        lock.lock()
        let pending = takeRelease()
        lock.unlock()
        pending?()
        return pending != nil
    }

    /// Claims the release closure under the caller's lock. Running it is left to the caller, outside the
    /// lock, because it re-enters the pipeline and the pipeline's own drain can call back into this box.
    private func takeRelease() -> (@Sendable () -> Void)? {
        let pending = release
        release = nil
        return pending
    }
}
