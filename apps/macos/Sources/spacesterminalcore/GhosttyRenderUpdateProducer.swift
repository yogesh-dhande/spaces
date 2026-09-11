import Foundation

/// The one full-vs-delta render-update policy every session host runs, and the state that policy
/// needs: the stream's delta baseline, the pending subscriber-baseline-reset promise, and the
/// scroll-rect carry a self-contained export folds movement into.
///
/// Both hosts (the macOS embedded-Ghostty host and the Linux libghostty-vt headless core) drive the
/// same stream of reasons at the same subscribers, and a client applies whatever arrives identically
/// whichever daemon sent it, so the decision of when a frame must be self-contained belongs in one
/// place rather than in a near-copy per host. A host owns capture, revisions, and broadcasting; this
/// type owns nothing but the policy and the baseline bookkeeping it implies.
///
/// A frame goes out FULL only when a subscriber cannot be assumed to hold the picture the delta
/// would be based on:
/// - `.initial`, `.resize`, `.terminated`: the frame is a resync by definition, so it must stand alone.
/// - a `.selfContained` export: a one-shot read (a Device API `.state` request) has no stream baseline
///   to diff against and no subscriber to advance.
/// - a pending subscriber-baseline reset, except on `.scroll`: see `armSubscriberBaselineReset`.
/// - a delta this producer could not apply to its own baseline: see `makeUpdate`.
///
/// Everything else ships as a delta, including a frame identical to the baseline. An empty delta is a
/// valid, cheap update (see `GhosttyRenderUpdateFactory.makeUpdate`), and the selection and scrollbar
/// values it carries are current whether or not a cell moved.
public struct GhosttyRenderUpdateProducer: Sendable {
    /// Whether the export being built may ship a delta against the stream baseline, or must stand on
    /// its own. Only a broadcast to the state stream advances the baseline; a one-shot read must not,
    /// because nobody applied it.
    public enum ExportMode: Sendable, Equatable {
        case selfContained
        case streamDeltaAllowed
    }

    /// The frame the stream's subscribers are assumed to hold, and the base every delta is diffed
    /// against. Hosts read it to decide whether a broadcast would carry anything new.
    public private(set) var baseline: GhosttyRenderUpdateBaseline?
    private var pendingSubscriberBaselineReset = false
    private var scrollRectCarry = TerminalStreamScrollRectCarry()

    public init() {}

    /// Drops the stream baseline without promising the next broadcast a full frame. Used where the
    /// baseline stops describing anything a subscriber holds but the very next export is already
    /// self-contained by policy (an owner-epoch advance, whose frames a client rejects on epoch alone).
    public mutating func discardBaseline() { baseline = nil }

    /// Promises the next stream broadcast a full frame. Armed where a subscriber is left with no
    /// baseline it can apply a delta to: a subscriber whose `initial` carried no render update, a
    /// handoff adoption, a re-theme whose recolored screen must not arrive as a color-only delta from
    /// a stale baseline.
    ///
    /// `.scroll` is deliberately excluded from spending the promise: a scroll delta rewrites the
    /// viewport through scroll rects and a full frame would waste that, while a delta hands a
    /// baseline-less subscriber nothing to apply. The promise is kept by the next broadcast that
    /// actually emits a full frame.
    public mutating func armSubscriberBaselineReset() { pendingSubscriberBaselineReset = true }

    /// Drops the baseline and promises the next stream broadcast a full frame.
    public mutating func resetBaselineAndForceNextFull() {
        baseline = nil
        pendingSubscriberBaselineReset = true
    }

    /// Whether an export has drained scroll rects out of the terminal that no stream frame has carried
    /// yet (or has poisoned the carry by overflowing it). Read by a host that would otherwise publish
    /// nothing: the movement those rects describe reaches a mirror's drag-selection anchor only on a
    /// stream frame, and only `makeUpdate` drains the carry, so a suppressed frame strands it.
    public var hasPendingScrollCarry: Bool { !scrollRectCarry.rects.isEmpty || scrollRectCarry.overflowed }

    /// Folds scroll rects an export drained out of Ghostty but did not ship into the carry, so the
    /// next stream delta still reports how far content moved. See `TerminalStreamScrollRectCarry`.
    public mutating func foldScrollRects(_ rects: [GhosttyRenderScrollRectOperation], overflowed: Bool) {
        scrollRectCarry.fold(rects: rects, overflowed: overflowed)
    }

    /// The forced-full reason for a frame exported under `reason` and `exportMode`, or nil when the
    /// frame may ship as a delta. Exposed so a test can pin the whole table in one place.
    public func forcedFullReason(for reason: TerminalRemoteSessionStateReason?, exportMode: ExportMode) -> String? {
        let forcesFullForSubscriberBaseline = exportMode == .streamDeltaAllowed && pendingSubscriberBaselineReset && reason != .scroll
        if reason == .initial { return "initial_baseline" }
        if reason == .resize { return "resize_self_contained" }
        if reason == .terminated { return "explicit_resync" }
        if forcesFullForSubscriberBaseline { return "subscriber_baseline_reset" }
        if exportMode == .selfContained { return "self_contained_state_export" }
        return nil
    }

    /// Builds the update this export ships and advances the baseline to what it shipped.
    ///
    /// - Parameter reason: The broadcast's reason, or nil for a reason outside the enum (the macOS
    ///   host's debug hook drives this pipeline with raw wire strings). An unrecognized reason forces
    ///   nothing on its own.
    public mutating func makeUpdate(
        for frame: GhosttyRenderFrame, reason: TerminalRemoteSessionStateReason?,
        nativeScrollRects capturedScrollRects: [GhosttyRenderScrollRectOperation] = [],
        nativeScrollRectsOverflowed capturedScrollRectsOverflowed: Bool = false, exportMode: ExportMode
    ) -> GhosttyRenderUpdate {
        // Ghostty drains its pending scroll rects on every snapshot export, self-contained or not. A
        // `.selfContained` export always forces a full frame below, and a full frame never carries scroll
        // rects, so the rects this export drained would otherwise vanish: carry them for the next stream
        // export instead. A `.streamDeltaAllowed` export that itself ends up emitting a full frame
        // (baseline reset, delta-apply failure) is still correct to drain here: a client poisons its own
        // carry on any full frame it receives, so the rects this drain hands it are moot the moment the
        // full frame lands.
        let nativeScrollRects: [GhosttyRenderScrollRectOperation]
        let nativeScrollRectsOverflowed: Bool
        switch exportMode {
        case .selfContained:
            scrollRectCarry.fold(rects: capturedScrollRects, overflowed: capturedScrollRectsOverflowed)
            nativeScrollRects = []
            nativeScrollRectsOverflowed = false
        case .streamDeltaAllowed:
            (nativeScrollRects, nativeScrollRectsOverflowed) = scrollRectCarry.drain(
                mergingWith: capturedScrollRects, overflowed: capturedScrollRectsOverflowed)
        }

        let hasPendingSubscriberBaselineReset = exportMode == .streamDeltaAllowed && pendingSubscriberBaselineReset
        let forcedFullReason = forcedFullReason(for: reason, exportMode: exportMode)
        let update = GhosttyRenderUpdateFactory.makeUpdate(
            target: frame, baseline: baseline, forceFull: forcedFullReason != nil, forceFullReason: forcedFullReason ?? "",
            nativeScrollRects: nativeScrollRects, nativeScrollRectsOverflowed: nativeScrollRectsOverflowed)
        let advancesBaseline = exportMode == .streamDeltaAllowed
        // What actually goes out, which is `update` except where a delta that could not be applied
        // locally is replaced below. The pending-baseline promise is answered against this rather than
        // against `update`, so both readings agree with what the subscriber received.
        var emittedUpdate = update
        switch update.kind {
        case .full:
            if advancesBaseline, let fullFrame = update.fullFrame { baseline = GhosttyRenderUpdateBaseline(frame: fullFrame) }
        case .delta:
            // Applying the delta to this producer's own copy of the baseline is what makes the delta
            // trustworthy: the client runs exactly this applier, so a delta that fails here would fail
            // there too, and the subscriber would be stuck until a resync round trip. Emitting the full
            // frame instead keeps the stream self-healing without a second code path deciding when a
            // delta is "safe".
            if let appliedBaseline = try? GhosttyRenderUpdateApplier.apply(update, to: baseline) {
                baseline = appliedBaseline
            } else {
                emittedUpdate = GhosttyRenderUpdate.full(frame, fallbackReason: "delta_apply_failed")
                if advancesBaseline { baseline = GhosttyRenderUpdateBaseline(frame: frame) }
            }
        case .resyncRequired: if advancesBaseline { baseline = nil }
        }
        // Only a full frame keeps the promise: a delta hands a baseline-less subscriber nothing to
        // apply, so spending the promise on one would leave it with a frame it can only drop and a
        // resync round trip before the pane shows anything.
        if hasPendingSubscriberBaselineReset, emittedUpdate.kind == .full { pendingSubscriberBaselineReset = false }
        return emittedUpdate
    }
}
