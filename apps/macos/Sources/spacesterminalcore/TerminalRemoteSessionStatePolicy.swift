import Foundation

/// Every `reason` a session core stamps on a broadcast remote-state payload. Subscribers
/// route on these, so a core must never broadcast a reason that is not declared here.
public enum TerminalRemoteSessionStateReason {
    public static let initial = "initial"
    public static let attachmentState = "attachment_state"
    public static let sessionMetadata = "session_metadata"
    public static let input = "input"
    public static let inputOutput = "input_output"
    public static let output = "output"
    public static let stateChange = "state_change"
    public static let scroll = "scroll"
    public static let clearScreen = "clear_screen"
    /// The shared selection changed (set or cleared), by any viewer or by the daemon auto-clearing
    /// a garbage-pinned selection. Selection is host-anchored, not owner-gated, so this reason
    /// carries no owner-specific gating of its own.
    public static let selection = "selection"
    public static let runtimeState = "runtime_state"
    public static let resize = "resize"
    public static let terminated = "terminated"
    /// A program copied to the clipboard (OSC 52). Carries `clipboardWrite` and nothing else the
    /// client acts on; see `TerminalClipboardWritePayload`.
    public static let clipboardWrite = "clipboard_write"
}

public enum TerminalRemoteSessionStatePolicy {
    public static func activeOwnerClientID(in snapshot: TerminalSessionAttachmentSnapshot?) -> String? {
        snapshot?.attachments.first { $0.mode == .owner && $0.detachedAt == nil }?.clientID
    }

    public static func activeOwnerClient(in snapshot: TerminalSessionAttachmentSnapshot?) -> TerminalClient? {
        guard let ownerID = activeOwnerClientID(in: snapshot) else { return nil }
        return snapshot?.clients.first { $0.id == ownerID }
    }

    public static func activeOwnerClientKind(in snapshot: TerminalSessionAttachmentSnapshot?) -> TerminalClientKind? {
        activeOwnerClient(in: snapshot)?.kind
    }

    public static func shouldIncludeScreenState(reason: String, ownerKind: TerminalClientKind? = nil) -> Bool {
        switch reason {
        case TerminalRemoteSessionStateReason.initial, TerminalRemoteSessionStateReason.attachmentState:
            return ownerKind == .localWindow || ownerKind == .remoteViewer
        case TerminalRemoteSessionStateReason.resize: return ownerKind == .localWindow || ownerKind == .remoteViewer
        case TerminalRemoteSessionStateReason.output: return ownerKind == .localWindow || ownerKind == .remoteViewer
        case TerminalRemoteSessionStateReason.stateChange: return ownerKind == .localWindow || ownerKind == .remoteViewer
        case TerminalRemoteSessionStateReason.scroll: return true
        case TerminalRemoteSessionStateReason.clearScreen: return true
        case TerminalRemoteSessionStateReason.selection: return true
        case TerminalRemoteSessionStateReason.terminated: return true
        case TerminalRemoteSessionStateReason.input: return false
        case TerminalRemoteSessionStateReason.inputOutput: return ownerKind == .localWindow
        // A clipboard write announces no screen change: the output turn that carried the OSC 52
        // already broadcast the frame. Exporting one here would put a second frame on the delta
        // chain for a payload the mirror does not render.
        case TerminalRemoteSessionStateReason.clipboardWrite: return false
        default: return false
        }
    }

    public static func hasVisibleScreenContent(snapshot: GhosttyTerminalSnapshot?, snapshotText: String?) -> Bool {
        if let snapshot {
            // A selection is user-visible state of its own, independent of the grid it sits on: a
            // selection-only frame must stay renderable so viewers paint (and later un-paint) the
            // highlight even on an otherwise blank screen.
            if snapshot.selection != nil { return true }
            if GhosttyTerminalSnapshotGrid.containsVisibleContent(snapshot) { return true }
        }
        guard let snapshotText else { return false }
        return snapshotText.contains(where: { !$0.isWhitespace && !$0.isNewline })
    }

    public static func hasUsableOwnerBootstrapState(
        _ payload: GhosttyRemoteSessionStatePayload?, viewportColumns: Int? = nil, viewportRows: Int? = nil
    ) -> Bool {
        guard let snapshot = payload?.renderSnapshot else { return false }
        if let viewportColumns, snapshot.columns != viewportColumns { return false }
        if let viewportRows, snapshot.rows != viewportRows { return false }
        return true
    }
}

public struct TerminalRemoteStateReductionResult: Sendable {
    public let payload: GhosttyRemoteSessionStatePayload
    public let storedPayload: GhosttyRemoteSessionStatePayload
    public let decodedUpdate: GhosttyRenderUpdate?
    public let frameToApply: GhosttyRenderFrame?
    public let dropReason: String?
    public let didRequestResync: Bool
    /// True when the reduction moved nothing at all: an out-of-band payload the reducer refused whole
    /// (`staleOutOfBandReduction`), whose `storedPayload` is therefore the previous payload untouched.
    ///
    /// `payload` still carries the refused input — its attachment snapshot, its render snapshot, its
    /// metadata — because the metrics and traces describe the payload that arrived. A consumer must
    /// derive no client state from it while this is set: the payload was captured before whatever
    /// superseded it, so its attachment snapshot names the ownership of a session generation that has
    /// been handed off, and its render snapshot describes a screen the client is already past.
    ///
    /// A partial refusal (`supersededScreen`, where only the render update is refused and the payload's
    /// metadata is ordered on its own terms and genuinely merges) is NOT this: the flag stays false
    /// there, and the payload's remaining state applies as it always did.
    public let isRefusedOutOfBandPayload: Bool

    public init(
        payload: GhosttyRemoteSessionStatePayload, storedPayload: GhosttyRemoteSessionStatePayload, decodedUpdate: GhosttyRenderUpdate?,
        frameToApply: GhosttyRenderFrame?, dropReason: String?, didRequestResync: Bool, isRefusedOutOfBandPayload: Bool = false
    ) {
        self.payload = payload
        self.storedPayload = storedPayload
        self.decodedUpdate = decodedUpdate
        self.frameToApply = frameToApply
        self.dropReason = dropReason
        self.didRequestResync = didRequestResync
        self.isRefusedOutOfBandPayload = isRefusedOutOfBandPayload
    }
}

public struct TerminalRemoteStateReducer: Sendable {
    private var renderUpdateBaseline: GhosttyRenderUpdateBaseline?
    /// Where the last frame this reducer actually handed back sits in the session's order.
    ///
    /// Deliberately not the same thing as `renderUpdateBaseline`. The baseline advances for every frame
    /// that decodes and applies, including one the caller then vetoes (`shouldUseFrame`) — it has to, since
    /// it is what the session's next delta is computed against. The caller never received that frame, so
    /// ordering an out-of-band response against the baseline would refuse the resync the veto itself asked
    /// for, which is the only thing that can repair the pane. This moves only when a frame is genuinely
    /// handed over, so it answers the question the staleness check actually asks: is this response older
    /// than what the client is holding?
    private var retainedFrameOrdering: (sessionRevision: UInt64?, ownerEpoch: UInt64)?

    public init(renderUpdateBaseline: GhosttyRenderUpdateBaseline? = nil) { self.renderUpdateBaseline = renderUpdateBaseline }

    /// - Parameter isOutOfBand: True for a payload that did not arrive on the session's stream — the
    ///   response to a direct `.state` read. Such a payload was captured at request time and can reach
    ///   this reducer after the stream has already carried the session past it, so it must prove it is not
    ///   stale before it is allowed to move the chain (see `staleOutOfBandReduction`). Nothing on the wire
    ///   marks one: a fetch response is stamped `initial`, the same reason a fresh subscriber's unicast
    ///   initial carries, so provenance is passed in by the caller that made the request.
    public mutating func reduce(
        incomingPayload: GhosttyRemoteSessionStatePayload, previousPayload: GhosttyRemoteSessionStatePayload?,
        shouldUseFrame: (GhosttyRenderFrame, GhosttyRemoteSessionStatePayload) -> Bool = { _, _ in true }, requestResyncOnApplyFailure: Bool = false,
        isOutOfBand: Bool = false
    ) -> TerminalRemoteStateReductionResult {
        var incomingPayload = incomingPayload
        var supersededFrameDropReason: String?
        // An out-of-band payload is ordered against what this reducer has actually reduced, in two steps:
        // its frame first, then — for a payload left with none, whether it never carried one or its frame
        // was just refused — its metadata. Splitting it that way is what keeps a response's title, working
        // directory, ownership and runtime state from being thrown away with a screen the client is
        // already showing: screen revisions only advance with screen content, and a quiet terminal changes
        // metadata without painting anything.
        if isOutOfBand, let previousPayload, Self.isOutOfBandPayloadOrderable(incomingPayload, against: previousPayload) {
            switch outOfBandFrameDisposition(of: incomingPayload) {
            case .supersededSession:
                // An older owner epoch invalidates the whole payload, not just its screen: the attachment
                // snapshot it carries names the owner from before a handoff, and merging that would revert
                // ownership on top of refusing the frame.
                return staleOutOfBandReduction(
                    payload: incomingPayload, storedPayload: previousPayload, dropReason: Self.staleOutOfBandStateDropReason)
            case .supersededScreen:
                incomingPayload = incomingPayload.replacingRenderUpdate(nil)
                supersededFrameDropReason = Self.staleOutOfBandFrameDropReason
            case .usable: break
            }
            if !incomingPayload.hasRenderUpdate, Self.isStaleMetadata(incomingPayload, against: previousPayload) {
                return staleOutOfBandReduction(
                    payload: incomingPayload, storedPayload: previousPayload, dropReason: Self.staleOutOfBandStateDropReason)
            }
        }
        let resolved = payloadByResolvingRenderUpdate(incomingPayload)
        var payload = resolved.payload
        var dropReason = resolved.dropReason ?? supersededFrameDropReason
        var frameToApply: GhosttyRenderFrame?
        // `resolved.frame` is the materialized full frame, the same value a
        // `payload.decodedRenderUpdate?.fullFrame` read on the resolved payload returns, handed back
        // directly so callers do not have to go through the payload for it.
        if let frame = resolved.frame {
            if shouldUseFrame(frame, payload) {
                frameToApply = frame
                retainedFrameOrdering = (frame.sessionRevision, frame.ownerEpoch)
            } else {
                payload = payload.replacingRenderUpdate(nil)
                dropReason = dropReason ?? "stale_resize_grid"
            }
        } else if incomingPayload.hasRenderUpdate {
            dropReason = dropReason ?? "decode_failed"
        }
        let storedPayload = previousPayload?.merged(with: payload) ?? payload
        // Every drop reaching here asks for a resync, the caller's veto above included: whichever way the
        // frame was lost, the client is left with a picture the session has already moved past and nothing
        // on the client ever rebuilds it on its own. The request is the only thing that makes the session
        // re-send a full frame; the caller paces it (see `RemoteGhosttySessionHost`'s once-per-second
        // throttle), so a run of vetoed frames costs one round trip, not one each. The exception is the
        // superseded out-of-band frame handled above: it refuses a screen the client is already past
        // rather than losing one it needed, so the retained frame is still current and nothing is owed.
        return TerminalRemoteStateReductionResult(
            payload: payload, storedPayload: storedPayload, decodedUpdate: resolved.decodedUpdate, frameToApply: frameToApply, dropReason: dropReason,
            didRequestResync: requestResyncOnApplyFailure && dropReason != nil && dropReason != Self.staleOutOfBandFrameDropReason)
    }

    /// Whether an out-of-band payload is subject to the ordering below at all.
    ///
    /// A response reporting the session is no longer interactive is normally exempt: it is the session's
    /// final word rather than one screen update among many, and ordering it away would leave the pane
    /// believing a dead session is live. But a `.state` read capturing one run's exit can be delayed
    /// across a relaunch and arrive after the stream has already reported the NEW run live, and applying
    /// that would mark a running session dead and disable its input until some later event. So the
    /// exemption is withheld from a response that is provably answering for a superseded run.
    ///
    /// "Provably" needs both a run discriminator and a direction. The discriminator is the child PID,
    /// which is the part of `TerminalSessionRuntimeState.runIdentity` that distinguishes one launch from
    /// another — the rest of that identity is the exit timestamp, which necessarily differs between a run's
    /// live and ended payloads and so cannot separate runs from exits. The direction is `emittedAt`: a
    /// different child PID alone says the payloads describe different runs, not which is older, and a
    /// response for a genuinely NEWER run must still land. What this cannot catch: a payload carrying no
    /// runtime state, or two runs the daemon reports under the same child PID (a PID reused after wrap),
    /// where the exemption stands as before.
    private static func isOutOfBandPayloadOrderable(
        _ payload: GhosttyRemoteSessionStatePayload, against previousPayload: GhosttyRemoteSessionStatePayload
    ) -> Bool {
        guard payload.runtimeState?.state.isInteractive == false else { return true }
        guard let childPID = payload.runtimeState?.childPID, let previousChildPID = previousPayload.runtimeState?.childPID,
            childPID != previousChildPID
        else { return false }
        return isStaleMetadata(payload, against: previousPayload)
    }

    /// Where an out-of-band payload's own full frame sits relative to what the client is holding.
    ///
    /// A direct `.state` read answers with the screen and metadata as they were when the session was
    /// asked, and it re-enters beside a stream that never stopped. Ordering it by arrival cannot work — a
    /// newer stream payload may already be queued ahead of it — so it is ordered here, at the head of the
    /// queue, against the state this reducer has actually reduced.
    ///
    /// The frame is superseded when it belongs to an older owner epoch (epochs only advance, so a lower
    /// one describes a session generation that has been handed off) or when it sits at or below the
    /// revision of the last frame the client RETAINED in the same epoch (the daemon advances revisions
    /// monotonically per session and never lets two different screens share one, so equal means identical
    /// content). The comparison is against `retainedFrameOrdering` rather than the delta baseline for the
    /// reason recorded there: a vetoed frame advances the baseline without ever reaching the client, and
    /// the resync that veto asks for carries exactly that frame and revision back. Anything else is
    /// usable — a strictly newer revision matters because a `.state` export flushes pending output into
    /// the session's surface without broadcasting, making that response the only carrier of the screen it
    /// describes.
    private enum OutOfBandFrameDisposition {
        /// Nothing to refuse: no orderable frame, no chain to protect, or a frame that is genuinely newer.
        case usable
        /// The client already holds this screen. Only the render update is refused; the payload's metadata
        /// is ordered separately (see `isStaleMetadata`).
        case supersededScreen
        /// The payload describes a session generation that has been handed off, so none of it applies.
        case supersededSession
    }

    private func outOfBandFrameDisposition(of payload: GhosttyRemoteSessionStatePayload) -> OutOfBandFrameDisposition {
        guard payload.hasRenderUpdate else { return .usable }
        guard let retained = retainedFrameOrdering, let frame = payload.decodedRenderUpdate?.fullFrame else { return .usable }
        if frame.ownerEpoch != retained.ownerEpoch { return frame.ownerEpoch < retained.ownerEpoch ? .supersededSession : .usable }
        // An unrevisioned frame on either side cannot be ordered, so it is left to apply as it did before
        // this guard existed.
        guard let frameRevision = frame.sessionRevision, let retainedRevision = retained.sessionRevision else { return .usable }
        if frameRevision > retainedRevision { return .usable }
        // A broken chain (a delta that could not apply nils the baseline) makes the EQUAL-revision response
        // useful again: its content is byte-identical to what the pane already shows, so nothing repaints
        // backwards, and it re-heads the chain the deltas that follow need. That is the only concession —
        // a strictly older frame is refused whether or not the chain is broken, since applying one would
        // both regress the pane and, because the caller retires an armed resync on any applied frame,
        // silently cancel the resync the breakage asked for.
        if frameRevision == retainedRevision, renderUpdateBaseline == nil { return .usable }
        return .supersededScreen
    }

    /// The reduction an out-of-band payload gets when nothing about it may move the client's state.
    ///
    /// Deliberately does NOT request a resync, unlike every other drop in `reduce` (see the note there):
    /// those lose state the client needed, while this refuses state the client is already past.
    private func staleOutOfBandReduction(
        payload: GhosttyRemoteSessionStatePayload, storedPayload: GhosttyRemoteSessionStatePayload, dropReason: String
    ) -> TerminalRemoteStateReductionResult {
        TerminalRemoteStateReductionResult(
            payload: payload, storedPayload: storedPayload, decodedUpdate: nil, frameToApply: nil, dropReason: dropReason, didRequestResync: false,
            isRefusedOutOfBandPayload: true)
    }

    /// The whole payload was refused: its screen belonged to a superseded session generation, or it
    /// carries no usable screen and its metadata is older than what has already been reduced.
    private static let staleOutOfBandStateDropReason = "stale_out_of_band_state"
    /// Only the render update was refused; the payload's metadata was still considered on its own terms.
    private static let staleOutOfBandFrameDropReason = "stale_out_of_band_frame"

    /// Orders a payload carrying no usable screen by `emittedAt`, because nothing else it carries is
    /// reliably ordered: attachment-only updates and Linux payloads reuse the prior revisions
    /// (`DeviceTerminalSessionStateModel.apply` documents the same finding and orders on the same field).
    /// One daemon stamps every payload for a session, so the comparison is against a single clock; a
    /// backwards step of that wall clock is the known caveat, and its cost is one dropped metadata refresh
    /// that the next payload supersedes.
    private static func isStaleMetadata(_ payload: GhosttyRemoteSessionStatePayload, against previousPayload: GhosttyRemoteSessionStatePayload)
        -> Bool
    {
        guard let emittedAt = GhosttyRemoteSessionStateTimestamp.date(from: payload.emittedAt),
            let previousEmittedAt = GhosttyRemoteSessionStateTimestamp.date(from: previousPayload.emittedAt)
        else { return false }
        // Strictly older only. `emittedAt` has millisecond resolution, so a tie is as likely to mean "the
        // session answered in the same instant it broadcast" as "this is a repeat" — and the model's own
        // ordering guard (`DeviceTerminalSessionStateModel.apply`) keeps ties for the same reason.
        return emittedAt < previousEmittedAt
    }

    private mutating func payloadByResolvingRenderUpdate(_ payload: GhosttyRemoteSessionStatePayload) -> (
        payload: GhosttyRemoteSessionStatePayload, decodedUpdate: GhosttyRenderUpdate?, frame: GhosttyRenderFrame?, dropReason: String?
    ) {
        guard payload.hasRenderUpdate else { return (payload, nil, nil, nil) }
        guard let decodedUpdate = payload.decodedRenderUpdate else {
            return (payload.replacingRenderUpdate(nil), nil, nil, "render_update_decode_failed")
        }
        do {
            let baseline = try GhosttyRenderUpdateApplier.apply(decodedUpdate, to: renderUpdateBaseline)
            renderUpdateBaseline = baseline
            // A delta continuation carries the exact rects that produced this baseline from the previous
            // one, so a mirror view can trust them for its scroll-rect carry. Any other kind (a full frame,
            // which replaces the whole grid rather than diffing it) has no such rects, so `overflowed` is
            // forced true: that is the mirror's poison signal, not a report of a real ring-buffer overflow.
            let scrollRects: [GhosttyRenderScrollRectOperation]
            let scrollRectsOverflowed: Bool
            switch decodedUpdate.kind {
            case .delta:
                scrollRects = decodedUpdate.delta?.scrollRects ?? []
                scrollRectsOverflowed = decodedUpdate.delta?.scrollRectsOverflowed ?? true
            case .full, .resyncRequired:
                scrollRects = []
                scrollRectsOverflowed = true
            }
            let frame = GhosttyRenderFrame(
                sessionRevision: baseline.sessionRevision, ownerEpoch: baseline.ownerEpoch, snapshot: baseline.snapshot, scrollRects: scrollRects,
                scrollRectsOverflowed: scrollRectsOverflowed)
            // The stored payload carries the materialized full frame as a value, not as a re-encoded
            // blob: the reads the client makes of it next (renderSnapshot, renderOwnerEpoch, the render
            // state key) all want the frame, and nothing on this path wants bytes. The payload still
            // yields the identical blob if it is ever serialized (see `GhosttyRenderUpdateBody`).
            //
            // Storing the *materialized* frame rather than the incoming delta is what lets the next
            // payload's merge carry a complete screen forward, and what makes a resync request recover:
            // the chain's state lives in this reducer's baseline and in the stored payload's full frame,
            // both advanced exactly once per payload, in arrival order.
            //
            // The stored frame deliberately does NOT carry this delta's scroll rects: a stored payload
            // is what replays after a reconnect or a listener re-registration, and a replay repaint must
            // poison a mirror's scroll-rect carry (the frames between the store and the replay are
            // unknowable). The wire codec enforces the same thing structurally — a full frame encodes no
            // rect fields, so the blob this payload yields round-trips to exactly this poisoned value.
            // Only `frameToApply`, consumed once by the live apply that produced it, keeps the rects.
            let storedFrame = GhosttyRenderFrame(sessionRevision: baseline.sessionRevision, ownerEpoch: baseline.ownerEpoch, snapshot: baseline.snapshot)
            return (payload.replacingRenderUpdate(materialized: .full(storedFrame)), decodedUpdate, frame, nil)
        } catch {
            renderUpdateBaseline = nil
            return (payload.replacingRenderUpdate(nil), decodedUpdate, nil, Self.renderUpdateDropReason(for: error))
        }
    }

    public static func renderUpdateDropReason(for error: Error) -> String {
        switch error as? GhosttyRenderUpdateApplyError {
        case .missingBaseline: "missing_baseline"
        case .versionMismatch: "version_mismatch"
        case .missingFullFrame: "missing_full_frame"
        case .missingDelta: "missing_delta"
        case .resyncRequired: "resync_required"
        case .baseRevisionMismatch: "base_revision_mismatch"
        case .ownerEpochMismatch: "owner_epoch_mismatch"
        case .dimensionMismatch: "dimension_mismatch"
        case .invalidOperation: "invalid_operation"
        case nil: "render_update_apply_failed"
        }
    }
}
