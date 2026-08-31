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
    /// True for the response to a direct `.state` read. `TerminalViewerModel.applyLatestState` and
    /// `RemoteGhosttySessionHost` read a fetch's verdict off the output that accounted for that
    /// submission (`reduction.payload`, `reduction.isRefusedOutOfBandPayload`), so an out-of-band output
    /// must keep its own apply: `ApplyMailbox.mayCollapse` refuses to collapse it in either direction.
    public let isOutOfBand: Bool
    /// The `reason`s of the outputs this one collapsed away, in collapse order, deduplicated, never
    /// including this output's own reason. Used to build `notificationNames`, which is what lets a
    /// survivor still post the notification a collapsed-away `runtime_state`, `attachment_state`, or
    /// `session_metadata` owed its consumer.
    public let coalescedReasons: [String]

    public init(
        incomingPayload: GhosttyRemoteSessionStatePayload, reduction: TerminalRemoteStateReductionResult?, reduceMS: Int, coalescedAwayCount: Int = 0,
        inheritedResyncRequest: Bool = false, isOutOfBand: Bool = false, coalescedReasons: [String] = []
    ) {
        self.incomingPayload = incomingPayload
        self.reduction = reduction
        self.reduceMS = reduceMS
        self.coalescedAwayCount = coalescedAwayCount
        self.inheritedResyncRequest = inheritedResyncRequest
        self.isOutOfBand = isOutOfBand
        self.coalescedReasons = coalescedReasons
    }

    /// Whether applying this output must ask the session for a full frame: because its own reduction
    /// could not apply a delta, or because an output coalesced away before it could not.
    public var requestsResync: Bool { reduction?.didRequestResync == true || inheritedResyncRequest }

    /// True when this output's *reason* is the coalescible kind — one of two independent ways the
    /// mailbox may drop an older pending output, and on its own neither necessary nor sufficient; see
    /// `ApplyMailbox.mayCollapse` for the full rule. The other way in is `carriesFullFrame`: a newer
    /// output whose reason is a barrier (`runtime_state`, `attachment_state`, `session_metadata`, …) may
    /// still collapse an older pending output when it carries a materialized FULL frame, because that
    /// frame renders everything the older output's screen content would have.
    ///
    /// Derived from the notification routing rather than listed as its own table:
    /// `TerminalRemoteSessionStateNotificationRouting.isOutputShaped(reason:)` is true for a reason that
    /// posts exactly the output-shaped notification, describing screen content with no state transition
    /// of its own, and a newer frame renders everything an older frame would have. Every reason that
    /// *does* carry a transition (attachment, ownership, session metadata, runtime state, termination)
    /// posts a different notification, and `clipboard_write` posts none because its effect is a
    /// pasteboard write whose position among the state around it matters. Both are barriers by reason
    /// shape, as is a reason this build does not know, which is the safe side to fail on — though a
    /// barrier reason can still be collapsed away by a newer full frame, per `carriesFullFrame` above.
    ///
    /// This property alone says nothing about whether the payload actually carries a frame: `input`
    /// routes here despite never exporting screen state, and a delta that failed to reduce against a
    /// stale grid routes here too despite reducing to no frame at all. "A newer frame renders everything
    /// an older frame would have" only holds when the newer output has one — `ApplyMailbox.mayCollapse`
    /// is what checks that before actually collapsing.
    var isCoalescibleOnApply: Bool { TerminalRemoteSessionStateNotificationRouting.isOutputShaped(reason: incomingPayload.reason) }

    /// True when `coalescedReasons` holds a reason that is not output-shaped: an ownership, attachment,
    /// session-metadata, runtime-state, or termination transition this output absorbed while collapsing.
    /// `ApplyMailbox.mayCollapse`'s `carriesFullFrame` branch lets a screen-shaped output (`state_change`,
    /// say) absorb a barrier pending ahead of it, so `isCoalescibleOnApply` alone — which reads only this
    /// output's own reason — cannot tell a survivor apart from one that still owes a transition its
    /// consumer only learns about when this output actually applies. `ApplyMailbox.defersDrain` reads this
    /// to keep such an output from deferring the drain the way a genuinely screen-only output may.
    var absorbedTransition: Bool { coalescedReasons.contains { !TerminalRemoteSessionStateNotificationRouting.isOutputShaped(reason: $0) } }

    /// True when this output's reduction materialized a FULL frame: not a delta, and not a delta that
    /// failed to reduce. A full frame renders the whole grid, so it renders everything any older pending
    /// output's screen content would have, which is what lets `ApplyMailbox.mayCollapse` let it absorb a
    /// pending output regardless of either one's reason.
    var carriesFullFrame: Bool { reduction?.decodedUpdate?.kind == .full && reduction?.frameToApply != nil }

    /// The routing for this output's own reason, followed by the routing for each reason in
    /// `coalescedReasons`, deduplicated and order-stable. This is the union of the notifications every
    /// output folded into this one would each have posted on its own: a collapsed-away `runtime_state`,
    /// `attachment_state`, or `session_metadata` still owes its consumer a refresh even though only the
    /// survivor's apply reaches `RemoteGhosttySessionHost.postLocalNotifications`.
    public var notificationNames: [Notification.Name] {
        // The common case by far: nothing was collapsed away, or everything collapsed away shared this
        // output's reason, so the union is just this reason's routing and none of the merging below is
        // worth its allocations on a path that runs at the session's apply rate.
        guard !coalescedReasons.isEmpty else { return TerminalRemoteSessionStateNotificationRouting.notifications(forReason: incomingPayload.reason) }
        var seen = Set<Notification.Name>()
        var names: [Notification.Name] = []
        for reason in [incomingPayload.reason] + coalescedReasons {
            for name in TerminalRemoteSessionStateNotificationRouting.notifications(forReason: reason) where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    /// This output, carrying forward the one-shot effects of the older output it replaces, plus the
    /// skipped frame's scroll rects merged into the surviving frame.
    ///
    /// The reduction chain already folds the skipped payload's state into this one's `storedPayload`,
    /// and its metrics describe a frame that never reached the screen, so those need no extra work here.
    /// `isOutOfBand` is this output's own and never changes here: `ApplyMailbox.mayCollapse` already
    /// refuses to collapse an out-of-band output in either direction, so `skipped` is never one.
    /// `coalescedReasons` gains `skipped`'s own reason and everything `skipped` itself had already
    /// absorbed, ahead of what this output had already absorbed — arrival order, oldest first — with
    /// this output's own reason filtered out and duplicates dropped; `notificationNames` reads this to
    /// post the union of every reason folded into the survivor. `scrollRects` is different: the mirror's
    /// drag-carry buffer (`GhosttyMirrorTerminalView`)
    /// accumulates rects only from frames that actually get applied, so a coalesced-away frame's rects
    /// would otherwise vanish with no trace, and the surviving frame would still report
    /// `scrollRectsOverflowed == false` as if nothing had been skipped. A drag rebased against that
    /// under-reports how far the content moved and lands on the wrong rows. So when both this output and
    /// the skipped one carry a frame, the surviving frame is rebuilt with the skipped frame's rects
    /// (older) ahead of this frame's own rects (newer), and `scrollRectsOverflowed` ORed across both.
    /// When the skipped output carries no frame there is nothing to merge, and when this one carries none
    /// the skipped frame is adopted whole rather than merged: the surviving output always leaves with the
    /// newest frame either of them had. Only a held pane reaches that adoption
    /// (`ApplyMailbox.mayCollapseWhileHolding`) — a displayed pane's `mayCollapse` refuses to collapse a
    /// frameless newer output onto a pending frame-carrying one, since there the pending entry is about to
    /// be applied on its own. Adopting is what makes the frame outlive the fold: the apply paints
    /// `frameToApply` whatever the surviving output's reason says, so the older screen still reaches the
    /// pane, while the newer output's own state, drop reason, and resync request ride through untouched.
    func inheritingEffects(ofCoalesced skipped: TerminalRemoteStateReductionOutput) -> TerminalRemoteStateReductionOutput {
        var mergedReduction = reduction
        if let base = reduction, base.frameToApply == nil, let skippedFrame = skipped.reduction?.frameToApply {
            mergedReduction = TerminalRemoteStateReductionResult(
                payload: base.payload, storedPayload: base.storedPayload, decodedUpdate: base.decodedUpdate, frameToApply: skippedFrame,
                dropReason: base.dropReason, didRequestResync: base.didRequestResync, isRefusedOutOfBandPayload: base.isRefusedOutOfBandPayload)
        } else if let base = reduction, let survivingFrame = base.frameToApply, let skippedFrame = skipped.reduction?.frameToApply {
            // Bounded like the mirror's own carry buffer: repeated collapses onto one stalled pending
            // output would otherwise grow the merged array (and re-copy it per collapse) without limit.
            // Past the cap the rects are dropped and the frame reports overflowed, which the consumer
            // already treats as a cancelled carry. A producer-side overflow flag alone keeps its rects:
            // the flag rides through untouched and the consumer poisons on it, so the merge only has to
            // bound what the merge itself can grow.
            var mergedRects = skippedFrame.scrollRects + survivingFrame.scrollRects
            var mergedOverflowed = skippedFrame.scrollRectsOverflowed || survivingFrame.scrollRectsOverflowed
            if mergedRects.count > GhosttyRenderFrame.maxAccumulatedScrollRects {
                mergedRects = []
                mergedOverflowed = true
            }
            let mergedFrame = GhosttyRenderFrame(
                version: survivingFrame.version, sessionRevision: survivingFrame.sessionRevision, ownerEpoch: survivingFrame.ownerEpoch,
                snapshot: survivingFrame.snapshot, scrollRects: mergedRects, scrollRectsOverflowed: mergedOverflowed)
            mergedReduction = TerminalRemoteStateReductionResult(
                payload: base.payload, storedPayload: base.storedPayload, decodedUpdate: base.decodedUpdate, frameToApply: mergedFrame,
                dropReason: base.dropReason, didRequestResync: base.didRequestResync, isRefusedOutOfBandPayload: base.isRefusedOutOfBandPayload)
        }
        var mergedCoalescedReasons: [String] = []
        var seenReasons = Set<String>()
        for reason in [skipped.incomingPayload.reason] + skipped.coalescedReasons + coalescedReasons {
            guard reason != incomingPayload.reason, seenReasons.insert(reason).inserted else { continue }
            mergedCoalescedReasons.append(reason)
        }
        return TerminalRemoteStateReductionOutput(
            incomingPayload: incomingPayload, reduction: mergedReduction, reduceMS: reduceMS,
            coalescedAwayCount: coalescedAwayCount + skipped.coalescedAwayCount + 1,
            inheritedResyncRequest: inheritedResyncRequest || skipped.requestsResync, isOutOfBand: isOutOfBand,
            coalescedReasons: mergedCoalescedReasons)
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
/// The mailbox keeps the queue in order and collapses a run of consecutive outputs down to its newest
/// member two ways: by reason shape, when a run of consecutive coalescible outputs share the
/// output-shaped kind (see `isCoalescibleOnApply`), and by frame, when the newest output materialized a
/// FULL frame (see `carriesFullFrame`) — a full frame renders everything any older pending output's
/// screen content would have, so it may collapse a pending output regardless of either one's reason.
/// Both ways stop at the same two hard barriers: an out-of-band output (`isOutOfBand`), because a fetch's
/// waiter reads its verdict off that output's own apply and collapsing it away or letting it collapse
/// something else would break that guarantee, and `clipboard_write` (`reduction == nil`), because its
/// effect is a pasteboard write read from `incomingPayload` at apply and collapsing it away would
/// silently drop the copy. Short of those two, collapsing is a cascade: after absorbing the queue's last
/// entry the incoming output keeps walking backwards, absorbing whatever is legal to absorb next, so a
/// burst that opens with a full frame, a barrier in the middle, and a full frame at the end still
/// collapses to one apply rather than stopping at the barrier (see `ApplyMailbox.mayCollapse` and
/// `ApplyMailbox.submit`). A superseded frame is never drawn, but a frame is never silently dropped
/// either, and one main-actor drain task at a time applies whatever has accumulated. What survives a
/// collapse is exactly what the screen and the session need: the newest frame, the merged state the
/// reducer chained through every skipped payload, the one-shot effects (`requestsResync`) of the outputs
/// that were dropped, and the union of the notifications every dropped output would have posted on its
/// own (`notificationNames`) — a collapsed-away `runtime_state` still owes its consumer's refresh even
/// though only the survivor's apply runs. Their per-payload metrics do not survive; the surviving apply
/// reports how many were folded into it (`coalescedAwayCount`).
///
/// **A pane that is off screen holds its screen updates.** `setHoldsScreenUpdates(true)` stops the
/// mailbox waking the main actor for an output that is nothing but a newer picture, so those outputs
/// collapse into a single held entry, carrying the newest frame and the merged effects of everything
/// folded into it, that is applied when the pane comes back. Reduction is untouched, so that entry is a
/// materialized full frame of the current screen and the pane repaints from it with no round trip.
/// Outputs that carry a state transition stay barriers and apply as they arrive.
public final class TerminalRemoteStateReductionPipeline: Sendable {
    /// One queued payload and where it came from: the session's stream, or a direct `.state` read whose
    /// response has to prove it is not stale when it reaches the reducer (see `TerminalRemoteStateReducer`).
    private struct QueuedPayload: Sendable {
        let payload: GhosttyRemoteSessionStatePayload
        let isOutOfBand: Bool
    }

    private let continuation: AsyncStream<QueuedPayload>.Continuation
    private let consumer: Task<Void, Never>
    private let mailbox: ApplyMailbox

    /// - Parameters:
    ///   - shouldUseFrame: Decides whether a materialized frame may be rendered. Pure, so it runs in
    ///     the pipeline alongside the reduction it gates.
    ///   - apply: Applies one reduction result on the main actor. Hold the host weakly here: the
    ///     consumer task outlives nothing, but a payload already being reduced when the host is
    ///     released must apply to nothing rather than to a torn-down host.
    ///   - didSubmit: Fires synchronously, on the consumer's own thread, immediately after each payload's
    ///     output is handed to the apply mailbox. Nil by default. `shouldUseFrame` runs *during*
    ///     reduction, before the output it gates even reaches the mailbox, so it cannot be used by itself
    ///     to act on a decision that depends on the output actually being queued: production uses this
    ///     hook for exactly that (the iOS open-screen hold's release runs here, not from `shouldUseFrame`,
    ///     because releasing before the frame is queued would let the mailbox drain an older held frame
    ///     first). Tests use it the same way, to make coalescing bursts deterministic: a test that needs
    ///     to know "every payload has reached the mailbox" cannot use `shouldUseFrame` as that signal
    ///     without a race, since the reduction of the last payload can be observed as done before its
    ///     `mailbox.submit` actually runs.
    public init(
        shouldUseFrame: @escaping @Sendable (GhosttyRenderFrame, GhosttyRemoteSessionStatePayload) -> Bool,
        apply: @escaping @MainActor @Sendable (TerminalRemoteStateReductionOutput) -> Void, didSubmit: (@Sendable () -> Void)? = nil
    ) {
        let (stream, continuation) = AsyncStream<QueuedPayload>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        let mailbox = ApplyMailbox(apply: apply)
        self.mailbox = mailbox
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
                if incomingPayload.reasonKind == .clipboardWrite {
                    output = TerminalRemoteStateReductionOutput(
                        incomingPayload: incomingPayload, reduction: nil, reduceMS: 0, isOutOfBand: queued.isOutOfBand)
                } else {
                    let reduceStartedAt = Date()
                    let reduction = reducer.reduce(
                        incomingPayload: incomingPayload, previousPayload: previousPayload, shouldUseFrame: shouldUseFrame,
                        requestResyncOnApplyFailure: true, isOutOfBand: queued.isOutOfBand)
                    previousPayload = reduction.storedPayload
                    output = TerminalRemoteStateReductionOutput(
                        incomingPayload: incomingPayload, reduction: reduction, reduceMS: TerminalPerformance.elapsedMS(since: reduceStartedAt),
                        isOutOfBand: queued.isOutOfBand)
                }
                mailbox.submit(output)
                didSubmit?()
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

    /// Whether an output that carries nothing but screen content may wait in the apply mailbox for a
    /// newer one instead of being applied as it reduces.
    ///
    /// Set while the pane this pipeline feeds is off screen and already holds a frame (see
    /// `RemoteGhosttySessionHost.updateHeldScreenUpdates`). Nothing about the reduction changes: every
    /// payload still reduces, in order, so the delta chain and the reducer's baseline stay exactly where
    /// a displayed pane's would be, and the newest held output carries a materialized FULL frame of the
    /// whole grid. Clearing this applies that one frame, which is the current screen, with no round trip to
    /// the device, and no delta applied onto a baseline the pane never received.
    ///
    /// Only screen content waits. Every reason that carries a state transition (runtime state,
    /// attachment, session metadata, termination, an out-of-band response, a clipboard write) is a
    /// barrier that applies on arrival, so an off-screen pane's title, ownership, ended state and
    /// clipboard keep up with the session.
    public func setHoldsScreenUpdates(_ holds: Bool) { mailbox.setHoldsScreenUpdates(holds) }
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
    /// While true, a submission that carries nothing but screen content leaves the queue undrained, so
    /// the next such submission collapses onto it (`mayCollapseWhileHolding`) instead of the main actor
    /// applying each one. See `TerminalRemoteStateReductionPipeline.setHoldsScreenUpdates`.
    private var holdsScreenUpdates = false
    private let apply: @MainActor @Sendable (TerminalRemoteStateReductionOutput) -> Void

    init(apply: @escaping @MainActor @Sendable (TerminalRemoteStateReductionOutput) -> Void) { self.apply = apply }

    /// The collapse rule: `output` may replace the queue's last entry only when doing so cannot make a
    /// pending frame vanish, and cannot make an out-of-band response or a clipboard write disappear from
    /// where it applies.
    ///
    /// Two hard barriers come first, checked before either reason or frame:
    /// - An out-of-band output (`isOutOfBand`) neither collapses nor is collapsed away. It is the
    ///   response to a direct `.state` read, and it proves its freshness at the head of the queue —
    ///   `TerminalRemoteStateReducer` stamps `stale_out_of_band_frame`/`stale_out_of_band_state` there.
    ///   `TerminalViewerModel.applyLatestState` and `RemoteGhosttySessionHost` read a waiting fetch's
    ///   verdict off the output that accounted for that submission's own apply, so collapsing it into
    ///   another output, or letting another output collapse into it, would leave the fetch reading
    ///   somebody else's verdict.
    /// - A clipboard write (`pending.reduction == nil`) is never collapsed away. Its effect is a
    ///   pasteboard write read from `pending.incomingPayload` at apply, not carried in any reduction, so
    ///   folding it into a later output would silently drop the copy. `output` itself is never a
    ///   clipboard write here: the consumer loop never reduces one, so it can never carry a full frame or
    ///   be reason-coalescible, and `mayCollapse` is only ever asked whether something may replace it,
    ///   never whether it may replace something.
    ///
    /// Past those two, either of two independent conditions lets `output` absorb `pending`:
    /// - `output.carriesFullFrame`: a materialized FULL frame renders the whole grid, so it renders
    ///   everything `pending`'s screen content would have, regardless of either output's reason. This is
    ///   what lets a newer `resize` or `state_change` full frame collapse an older frameless `runtime_state`
    ///   barrier in the middle of a burst, not just another screen-content output.
    /// - The reason-shape rule this collapse used to be the whole of: both entries are coalescible-on-apply
    ///   reasons (`isCoalescibleOnApply`), AND either `output` itself carries a frame
    ///   (`reduction?.frameToApply != nil`) or the pending entry never carried one either
    ///   (`pending.reduction?.frameToApply == nil`). Without that second half, a frameless newer output —
    ///   a reason that never exports a render update at all (`input`, which
    ///   `TerminalRemoteSessionStatePolicy.shouldIncludeScreenState` excludes screen state for) or a delta
    ///   that failed to reduce against a stale grid (`frameToApply == nil` with no resync requested to
    ///   make up for it) — would silently erase a still-pending frame from the queue: the collapsed entry
    ///   applies as the frameless output, and the frame the pending entry was carrying is gone with
    ///   nothing left to ask the session to resend it.
    ///
    /// Failing every check appends `output` as a new barrier instead; the queue stays ordered and its
    /// growth is bounded by the rate of frameless payloads, which stays low relative to full-frame
    /// output. `ApplyMailbox.submit` calls this in a cascade, so a full frame that collapses one barrier
    /// keeps walking backwards to collapse whatever is legal beyond it too.
    private static func mayCollapse(_ output: TerminalRemoteStateReductionOutput, onto pending: TerminalRemoteStateReductionOutput) -> Bool {
        guard !output.isOutOfBand, !pending.isOutOfBand else { return false }
        guard pending.reduction != nil else { return false }
        if output.carriesFullFrame { return true }
        return output.isCoalescibleOnApply && pending.isCoalescibleOnApply
            && (output.reduction?.frameToApply != nil || pending.reduction?.frameToApply == nil)
    }

    /// Whether this submission may leave the queue undrained rather than waking the main actor.
    ///
    /// Only while the pane holds its screen updates, and only for an output that is nothing but a newer
    /// picture of the screen. A resync request is excluded even though its reason is screen-shaped: the
    /// reduction that asks for one has broken the delta chain, and only the applied request makes the
    /// device re-send a full frame. Holding it would leave every later delta failing to reduce against a
    /// baseline nothing repairs, and each of those failures appends its own frameless entry rather than
    /// collapsing onto a frame-carrying one, so the queue would grow for as long as the pane stays off
    /// screen.
    ///
    /// `absorbedTransition` is excluded too: `mayCollapse`'s `carriesFullFrame` branch lets a screen-shaped
    /// output absorb a barrier pending ahead of it regardless of reason, so an output whose own reason is
    /// coalescible can still carry a transition (ownership, attachment, session metadata, runtime state,
    /// termination) folded in from what it collapsed. That transition drains as a barrier would — on
    /// arrival — rather than waiting for the hold to end, because its consumer's refresh only fires when
    /// this output actually applies (see `TerminalRemoteStateReductionOutput.notificationNames`), and an
    /// off-screen pane's title, ownership, and ended state must keep up with the session exactly as they do
    /// when the transition never got absorbed in the first place.
    private static func defersDrain(for output: TerminalRemoteStateReductionOutput, whileHoldingScreenUpdates holds: Bool) -> Bool {
        holds && output.isCoalescibleOnApply && !output.requestsResync && !output.absorbedTransition
    }

    /// The collapse rule a held pane adds: while holding, the queue's tail is at most ONE screen-only
    /// entry, whichever of the two carries a frame.
    ///
    /// `mayCollapse` alone would let the held tail grow one entry per input/output cycle, because a
    /// frameless `input` (coalescible by reason, never carrying a render update) cannot collapse onto a
    /// frame-carrying entry and appends instead, and the frame that follows it then replaces only that
    /// input. A session driven by a remote owner alternates exactly that way, so an off-screen pane would
    /// accumulate a materialized full frame per cycle and, on redisplay, apply every stale one of them.
    /// Here the fold is safe in both directions precisely because neither entry is going to be applied
    /// until the pane comes back: nothing is lost by folding them, as long as the survivor leaves with
    /// the newest frame either of them had (`inheritingEffects` adopts it).
    ///
    /// Both entries must be ones the hold actually defers: an output that requests a resync applies on
    /// arrival and stays a barrier, which is what bounds the queue when the delta chain breaks.
    private static func mayCollapseWhileHolding(_ output: TerminalRemoteStateReductionOutput, onto pending: TerminalRemoteStateReductionOutput)
        -> Bool
    { defersDrain(for: output, whileHoldingScreenUpdates: true) && defersDrain(for: pending, whileHoldingScreenUpdates: true) }

    func submit(_ output: TerminalRemoteStateReductionOutput) {
        lock.lock()
        // Collapsing is a cascade, not a single step: after absorbing the queue's last entry, keep
        // walking backwards absorbing whatever is still legal, so a full frame in the middle of a burst
        // does not stop at the first barrier it clears. Without this a burst like
        // `state_change(FULL) / runtime_state(frameless) / resize(FULL)` would leave two applies — the
        // `resize` absorbs only the `runtime_state` barrier ahead of it — instead of collapsing to one.
        var output = output
        while let pending = queued.last,
            Self.mayCollapse(output, onto: pending) || (holdsScreenUpdates && Self.mayCollapseWhileHolding(output, onto: pending))
        {
            output = output.inheritingEffects(ofCoalesced: pending)
            queued.removeLast()
        }
        queued.append(output)
        // The slot is claimed only when this submission actually schedules a drain: a held submission
        // that claimed it would leave the queue with no drain in flight and the slot saying otherwise,
        // so nothing would ever wake it again.
        let needsDrain = !isDrainScheduled && !Self.defersDrain(for: output, whileHoldingScreenUpdates: holdsScreenUpdates)
        if needsDrain { isDrainScheduled = true }
        lock.unlock()
        guard needsDrain else { return }
        Task { @MainActor [weak self] in self?.drain() }
    }

    /// Applies whatever was held as soon as the pane stops holding. A drain already in flight picks the
    /// queue up on its own, so this only schedules one when the slot is free.
    func setHoldsScreenUpdates(_ holds: Bool) {
        lock.lock()
        holdsScreenUpdates = holds
        let needsDrain = !holds && !isDrainScheduled && !queued.isEmpty
        if needsDrain { isDrainScheduled = true }
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
        var segment = queued
        // A held pane's newest entry stays queued when it is nothing but a newer picture of the screen;
        // everything ahead of it still applies, in order. Leaving it behind is what makes the hold hold:
        // a drain that took it would apply it, reschedule itself, and be handed the next collapsed frame
        // by the session's next flush, applying screen updates at output cadence for a pane nobody can
        // see. What stays behind is one entry, because every screen-only submission collapses onto it.
        if holdsScreenUpdates, let newest = segment.last, Self.defersDrain(for: newest, whileHoldingScreenUpdates: true) {
            segment.removeLast()
            queued = [newest]
        } else {
            queued.removeAll(keepingCapacity: true)
        }
        // The drain slot is released only on an empty take, so a submission that lands while a segment
        // is being applied is picked up by the drain this one schedules rather than by a second one.
        if segment.isEmpty { isDrainScheduled = false }
        return segment
    }
}
