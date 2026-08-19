import Foundation

/// One reduced payload, handed to the main actor for application.
public struct TerminalRemoteStateReductionOutput: Sendable {
    /// The payload exactly as it arrived. The clipboard one-shot reads its write from here, so the
    /// reduction's merge, which deliberately drops the field, cannot swallow it.
    public let incomingPayload: GhosttyRemoteSessionStatePayload
    /// Nil for a payload the pipeline deliberately does not reduce (`clipboard_write`, which carries an
    /// event and no state).
    public let reduction: TerminalRemoteStateReductionResult?
    /// How long the reduction took, reported as the receive metric's decode cost.
    public let reduceMS: Int
    /// How many earlier outputs the apply mailbox collapsed into this one. Reported on this apply's
    /// metrics, which is the only place the skipped payloads are accounted for.
    public let coalescedAwayCount: Int
    /// A resync one of the coalesced-away outputs asked for. Read through `requestsResync`.
    public let inheritedResyncRequest: Bool

    public init(
        incomingPayload: GhosttyRemoteSessionStatePayload, reduction: TerminalRemoteStateReductionResult?, reduceMS: Int, coalescedAwayCount: Int = 0,
        inheritedResyncRequest: Bool = false
    ) {
        self.incomingPayload = incomingPayload
        self.reduction = reduction
        self.reduceMS = reduceMS
        self.coalescedAwayCount = coalescedAwayCount
        self.inheritedResyncRequest = inheritedResyncRequest
    }

    /// Whether applying this output must ask the session for a full frame: because its own reduction
    /// could not apply a delta, or because an output coalesced away before it could not.
    public var requestsResync: Bool { reduction?.didRequestResync == true || inheritedResyncRequest }

    /// True when this output's *reason* is the coalescible kind — necessary but not sufficient for the
    /// mailbox to actually drop it; see `ApplyMailbox.mayCollapse` for the full rule, which also checks
    /// whether a frame would be lost.
    ///
    /// Derived from the notification routing rather than listed as its own table:
    /// `TerminalRemoteSessionStateNotificationRouting.isOutputShaped(reason:)` is true for a reason that
    /// posts exactly the output-shaped notification, describing screen content with no state transition
    /// of its own, and a newer frame renders everything an older frame would have. Every reason that
    /// *does* carry a transition (attachment, ownership, session metadata, runtime state, termination)
    /// posts a different notification, and `clipboard_write` posts none because its effect is a
    /// pasteboard write whose position among the state around it matters. Both are barriers, as is a
    /// reason this build does not know, which is the safe side to fail on.
    ///
    /// This property alone says nothing about whether the payload actually carries a frame: `input`
    /// routes here despite never exporting screen state, and a delta that failed to reduce against a
    /// stale grid routes here too despite reducing to no frame at all. "A newer frame renders everything
    /// an older frame would have" only holds when the newer output has one — `ApplyMailbox.mayCollapse`
    /// is what checks that before actually collapsing.
    var isCoalescibleOnApply: Bool { TerminalRemoteSessionStateNotificationRouting.isOutputShaped(reason: incomingPayload.reason) }

    /// This output, carrying forward the one-shot effects of the older output it replaces, plus the
    /// skipped frame's scroll rects merged into the surviving frame.
    ///
    /// The reduction chain already folds the skipped payload's state into this one's `storedPayload`,
    /// and its metrics describe a frame that never reached the screen, so those need no extra work here.
    /// `scrollRects` is different: the mirror's drag-carry buffer (`GhosttyMirrorTerminalView`)
    /// accumulates rects only from frames that actually get applied, so a coalesced-away frame's rects
    /// would otherwise vanish with no trace, and the surviving frame would still report
    /// `scrollRectsOverflowed == false` as if nothing had been skipped. A drag rebased against that
    /// under-reports how far the content moved and lands on the wrong rows. So when both this output and
    /// the skipped one carry a frame, the surviving frame is rebuilt with the skipped frame's rects
    /// (older) ahead of this frame's own rects (newer), and `scrollRectsOverflowed` ORed across both.
    /// When the skipped output carries no frame there is nothing to merge: `ApplyMailbox.mayCollapse`
    /// already forbids collapsing a frameless newer output onto a pending frame-carrying one, so the
    /// reverse (frame-carrying newer output, frameless skipped one) is the only case that reaches here,
    /// and it needs no rect merge.
    func inheritingEffects(ofCoalesced skipped: TerminalRemoteStateReductionOutput) -> TerminalRemoteStateReductionOutput {
        var mergedReduction = reduction
        if let base = reduction, let survivingFrame = base.frameToApply, let skippedFrame = skipped.reduction?.frameToApply {
            let mergedFrame = GhosttyRenderFrame(
                version: survivingFrame.version, sessionRevision: survivingFrame.sessionRevision, ownerEpoch: survivingFrame.ownerEpoch,
                snapshot: survivingFrame.snapshot, scrollRects: skippedFrame.scrollRects + survivingFrame.scrollRects,
                scrollRectsOverflowed: skippedFrame.scrollRectsOverflowed || survivingFrame.scrollRectsOverflowed)
            mergedReduction = TerminalRemoteStateReductionResult(
                payload: base.payload, storedPayload: base.storedPayload, decodedUpdate: base.decodedUpdate, frameToApply: mergedFrame,
                dropReason: base.dropReason, didRequestResync: base.didRequestResync, isRefusedOutOfBandPayload: base.isRefusedOutOfBandPayload)
        }
        return TerminalRemoteStateReductionOutput(
            incomingPayload: incomingPayload, reduction: mergedReduction, reduceMS: reduceMS,
            coalescedAwayCount: coalescedAwayCount + skipped.coalescedAwayCount + 1,
            inheritedResyncRequest: inheritedResyncRequest || skipped.requestsResync)
    }
}

/// One session's remote-state payloads, reduced off the main actor in arrival order.
///
/// Reducing a payload (decoding the incoming render-update blob and applying it to the render-update
/// baseline) is pure compute, it dominates the cost of a session under steady output, and none of it
/// touches UI state. So the pipeline, not the main actor, owns the reducer: the render-update baseline
/// and the previous stored payload the next reduce chains from live here. The main actor is left with
/// only the work that needs it (the terminal-view frame application, the metrics, the notifications,
/// and the clipboard one-shot), which it does from `TerminalRemoteStateReductionOutput`.
///
/// Every entry point submits here, the state subscription and the direct `.state` fetch alike,
/// because a render update is a chain. A fetched full frame that overtook a queued delta, or a delta
/// reduced against a baseline a queued full frame had not yet replaced, breaks that chain and costs a
/// resync round trip. FIFO therefore has to span both routes, not just hold within one.
///
/// **Reduction is 1:1 and strictly ordered. Application is latest-frame-wins.**
///
/// `submit` is callable from any thread and preserves call order. The single consumer reduces every
/// payload, one at a time, in submission order: reduction correctness depends only on the reducer's own
/// chained state, so it must never skip or reorder a payload. It hands each result to an apply mailbox
/// instead of awaiting the main actor, so a busy main actor cannot stall reduction and cannot build an
/// unbounded backlog of frames the screen will never show. A session under steady output flushes a
/// render update every few milliseconds while one main-actor apply drives a synchronous GPU draw, so
/// awaiting each apply would make the main thread the pipeline's rate limiter and let every pane's
/// backlog grow without bound.
///
/// The mailbox keeps the queue in order and collapses each run of consecutive coalescible outputs to
/// its newest member (see `isCoalescibleOnApply`), except where doing so would make a still-pending frame
/// vanish rather than merely go undrawn (see `ApplyMailbox.mayCollapse`): a superseded frame is never
/// drawn, but a frame is never silently dropped either, and one main-actor drain task at a time applies
/// whatever has accumulated. What survives a collapse is exactly what the
/// screen and the session need: the newest frame, the merged state the reducer chained through every
/// skipped payload, and the one-shot effects (`requestsResync`) of the outputs that were dropped. Their
/// per-payload metrics do not survive; the surviving apply reports how many were folded into it
/// (`coalescedAwayCount`).
public final class TerminalRemoteStateReductionPipeline: Sendable {
    /// One queued payload and where it came from: the session's stream, or a direct `.state` read whose
    /// response has to prove it is not stale when it reaches the reducer (see `TerminalRemoteStateReducer`).
    private struct QueuedPayload: Sendable {
        let payload: GhosttyRemoteSessionStatePayload
        let isOutOfBand: Bool
    }

    private let continuation: AsyncStream<QueuedPayload>.Continuation
    private let consumer: Task<Void, Never>

    /// - Parameters:
    ///   - shouldUseFrame: Decides whether a materialized frame may be rendered. Pure, so it runs in
    ///     the pipeline alongside the reduction it gates.
    ///   - apply: Applies one reduction result on the main actor. Hold the host weakly here: the
    ///     consumer task outlives nothing, but a payload already being reduced when the host is
    ///     released must apply to nothing rather than to a torn-down host.
    ///   - didSubmitForTesting: Called synchronously, still on the consumer's own thread, immediately
    ///     after each payload is handed to the apply mailbox. Nil in production. `shouldUseFrame` runs
    ///     *during* reduction, before the output it gates is even constructed, so a test that needs to
    ///     know "every payload has reached the mailbox" (to then release a main thread it is holding, and
    ///     make a coalescing burst deterministic) cannot use `shouldUseFrame` as that signal without a
    ///     race: the reduction of the last payload can be observed as done before its `mailbox.submit`
    ///     actually runs, letting the release land, and a first drain, ahead of that submit — which then
    ///     shows up as a spurious second apply once it lands. This fires after the submit that would
    ///     otherwise race the test, closing that window.
    public init(
        shouldUseFrame: @escaping @Sendable (GhosttyRenderFrame, GhosttyRemoteSessionStatePayload) -> Bool,
        apply: @escaping @MainActor @Sendable (TerminalRemoteStateReductionOutput) -> Void, didSubmitForTesting: (@Sendable () -> Void)? = nil
    ) {
        let (stream, continuation) = AsyncStream<QueuedPayload>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        let mailbox = ApplyMailbox(apply: apply)
        consumer = Task.detached(priority: .userInitiated) {
            var reducer = TerminalRemoteStateReducer()
            var previousPayload: GhosttyRemoteSessionStatePayload?
            for await queued in stream {
                let incomingPayload = queued.payload
                let output: TerminalRemoteStateReductionOutput
                // A `clipboard_write` payload exports no screen state, and its runtime/attachment
                // snapshot is a repeat of the output turn that carried the escape sequence, so it is
                // carried through the queue (its position relative to the state around it is preserved)
                // but never reduced, which would risk an out-of-order payload regressing the cached
                // title, runtime state, or ownership.
                if incomingPayload.reason == TerminalRemoteSessionStateReason.clipboardWrite {
                    output = TerminalRemoteStateReductionOutput(incomingPayload: incomingPayload, reduction: nil, reduceMS: 0)
                } else {
                    let reduceStartedAt = Date()
                    let reduction = reducer.reduce(
                        incomingPayload: incomingPayload, previousPayload: previousPayload, shouldUseFrame: shouldUseFrame,
                        requestResyncOnApplyFailure: true, isOutOfBand: queued.isOutOfBand)
                    previousPayload = reduction.storedPayload
                    output = TerminalRemoteStateReductionOutput(
                        incomingPayload: incomingPayload, reduction: reduction, reduceMS: TerminalPerformance.elapsedMS(since: reduceStartedAt))
                }
                mailbox.submit(output)
                didSubmitForTesting?()
            }
        }
    }

    deinit {
        // Ending the stream ends the consumer loop; cancelling stops it from reducing whatever is still
        // queued for an owner that no longer exists.
        continuation.finish()
        consumer.cancel()
    }

    /// Enqueues one payload. Callable from any thread; payloads are reduced in call order.
    ///
    /// - Parameter isOutOfBand: True for the response to a direct `.state` read, which re-enters here
    ///   beside a stream that never stopped and so must prove at the head of the queue that it is not
    ///   stale. Ordering it anywhere earlier — at the request's completion, say — cannot see a newer
    ///   stream payload that is already submitted and still reducing.
    public func submit(_ payload: GhosttyRemoteSessionStatePayload, isOutOfBand: Bool = false) {
        continuation.yield(QueuedPayload(payload: payload, isOutOfBand: isOutOfBand))
    }
}

/// The ordered, coalescing hand-off from the reduce loop to the main actor.
///
/// The queue is guarded by a lock rather than an actor because `submit` runs on the reduce loop and must
/// not suspend there: suspending would restore the very coupling the mailbox removes.
private final class ApplyMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [TerminalRemoteStateReductionOutput] = []
    /// True while a drain task exists that has not yet found the queue empty. It is the slot that keeps
    /// exactly one drain in flight, so a burst of submissions schedules one task rather than one each.
    private var isDrainScheduled = false
    private let apply: @MainActor @Sendable (TerminalRemoteStateReductionOutput) -> Void

    init(apply: @escaping @MainActor @Sendable (TerminalRemoteStateReductionOutput) -> Void) { self.apply = apply }

    /// The collapse rule: `output` may replace the queue's last entry only when doing so cannot make a
    /// pending frame vanish. Both entries must be coalescible-on-apply reasons (`isCoalescibleOnApply`),
    /// AND either `output` itself carries a frame (`reduction?.frameToApply != nil`) or the pending entry
    /// never carried one either (`pending.reduction?.frameToApply == nil`). Without that second half, a
    /// frameless newer output — a reason that never exports a render update at all (`input`, which
    /// `TerminalRemoteSessionStatePolicy.shouldIncludeScreenState` excludes screen state for) or a delta
    /// that failed to reduce against a stale grid (`frameToApply == nil` with no resync requested to make
    /// up for it) — would silently erase a still-pending frame from the queue: the collapsed entry applies
    /// as the frameless output, and the frame the pending entry was carrying is gone with nothing left to
    /// ask the session to resend it. Failing this check appends `output` as a new barrier instead; the
    /// queue stays ordered and its growth is bounded by the rate of frameless payloads, which stays low
    /// relative to full-frame output.
    private static func mayCollapse(_ output: TerminalRemoteStateReductionOutput, onto pending: TerminalRemoteStateReductionOutput) -> Bool {
        output.isCoalescibleOnApply && pending.isCoalescibleOnApply
            && (output.reduction?.frameToApply != nil || pending.reduction?.frameToApply == nil)
    }

    func submit(_ output: TerminalRemoteStateReductionOutput) {
        lock.lock()
        if let pending = queued.last, Self.mayCollapse(output, onto: pending) {
            queued[queued.count - 1] = output.inheritingEffects(ofCoalesced: pending)
        } else {
            queued.append(output)
        }
        let needsDrain = !isDrainScheduled
        isDrainScheduled = true
        lock.unlock()
        guard needsDrain else { return }
        Task { @MainActor [weak self] in self?.drain() }
    }

    /// Applies one queued segment in order, then hands the main actor back and schedules the next drain
    /// if anything arrived meanwhile. Looping in place instead would let a session that keeps producing
    /// hold the main actor indefinitely, which is the stall this whole mailbox exists to end.
    @MainActor private func drain() {
        let segment = takeQueuedSegment()
        guard !segment.isEmpty else { return }
        for output in segment { apply(output) }
        Task { @MainActor [weak self] in self?.drain() }
    }

    private func takeQueuedSegment() -> [TerminalRemoteStateReductionOutput] {
        lock.lock()
        defer { lock.unlock() }
        let segment = queued
        queued.removeAll(keepingCapacity: true)
        // The drain slot is released only on an empty take, so a submission that lands while a segment
        // is being applied is picked up by the drain this one schedules rather than by a second one.
        if segment.isEmpty { isDrainScheduled = false }
        return segment
    }
}
