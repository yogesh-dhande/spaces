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
        if let snapshot { if GhosttyTerminalSnapshotGrid.containsVisibleContent(snapshot) { return true } }
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

    public init(
        payload: GhosttyRemoteSessionStatePayload, storedPayload: GhosttyRemoteSessionStatePayload, decodedUpdate: GhosttyRenderUpdate?,
        frameToApply: GhosttyRenderFrame?, dropReason: String?, didRequestResync: Bool
    ) {
        self.payload = payload
        self.storedPayload = storedPayload
        self.decodedUpdate = decodedUpdate
        self.frameToApply = frameToApply
        self.dropReason = dropReason
        self.didRequestResync = didRequestResync
    }
}

public struct TerminalRemoteStateReducer: Sendable {
    private var renderUpdateBaseline: GhosttyRenderUpdateBaseline?

    public init(renderUpdateBaseline: GhosttyRenderUpdateBaseline? = nil) { self.renderUpdateBaseline = renderUpdateBaseline }

    public mutating func resetRenderUpdateBaseline() { renderUpdateBaseline = nil }

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
        if isOutOfBand, let staleReduction = staleOutOfBandReduction(incomingPayload: incomingPayload, previousPayload: previousPayload) {
            return staleReduction
        }
        let resolved = payloadByResolvingRenderUpdate(incomingPayload)
        var payload = resolved.payload
        var dropReason = resolved.dropReason
        var frameToApply: GhosttyRenderFrame?
        // `resolved.frame` is the materialized full frame, the same value a
        // `payload.decodedRenderUpdate?.fullFrame` read on the resolved payload returns, handed back
        // directly so callers do not have to go through the payload for it.
        if let frame = resolved.frame {
            if shouldUseFrame(frame, payload) {
                frameToApply = frame
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
        // throttle), so a run of vetoed frames costs one round trip, not one each. The one drop that does
        // NOT ask is the stale out-of-band refusal above, which returns before this: it discards a frame
        // the client is already past rather than losing one it needed, so nothing is owed.
        return TerminalRemoteStateReductionResult(
            payload: payload, storedPayload: storedPayload, decodedUpdate: resolved.decodedUpdate, frameToApply: frameToApply, dropReason: dropReason,
            didRequestResync: requestResyncOnApplyFailure && dropReason != nil)
    }

    /// The reduction a stale out-of-band payload gets: nothing moves.
    ///
    /// A direct `.state` read answers with the screen and metadata as they were when the session was
    /// asked, and it re-enters here beside a stream that never stopped. Ordering it by arrival cannot
    /// work — a newer stream payload may already be queued ahead of it — so it is ordered here, at the
    /// head of the queue, against the state this reducer has actually reduced.
    ///
    /// A carried full frame is stale when it belongs to an older owner epoch (epochs only advance, so a
    /// lower one describes a session generation that has been handed off) or when it sits at or below the
    /// baseline's revision in the same epoch (the daemon advances revisions monotonically per session and
    /// never lets two different screens share one, so equal means identical content). Anything else is
    /// applied — a strictly newer revision matters because a `.state` export flushes pending output into
    /// the session's surface without broadcasting, making that response the only carrier of the screen it
    /// describes.
    ///
    /// A frameless response is ordered by `emittedAt` instead, because nothing else it carries is
    /// reliably ordered: attachment-only updates and Linux payloads reuse the prior revisions
    /// (`DeviceTerminalSessionStateModel.apply` documents the same finding and orders on the same field).
    /// One daemon stamps every payload for a session, so the comparison is against a single clock; a
    /// backwards step of that wall clock is the known caveat, and its cost is one dropped metadata
    /// refresh that the next payload supersedes.
    ///
    /// The drop deliberately does NOT request a resync, unlike every other drop in `reduce` (see the note
    /// there): those lose a frame the client needed, while this one refuses a frame the client is already
    /// past. The baseline is intact and newer, so nothing is owed.
    private func staleOutOfBandReduction(incomingPayload: GhosttyRemoteSessionStatePayload, previousPayload: GhosttyRemoteSessionStatePayload?)
        -> TerminalRemoteStateReductionResult?
    {
        // With nothing reduced yet there is nothing to be stale against, and nothing to keep instead.
        guard let previousPayload else { return nil }
        // A response reporting the session is no longer interactive is never refused. It is the session's
        // final word rather than one screen update among many, and ordering it away would leave the pane
        // believing a dead session is live — the opposite of the regression this guard prevents.
        guard incomingPayload.runtimeState?.state.isInteractive != false else { return nil }
        let isStale: Bool
        if incomingPayload.hasRenderUpdate {
            guard let baseline = renderUpdateBaseline, let frame = incomingPayload.decodedRenderUpdate?.fullFrame else { return nil }
            isStale = Self.isStale(frame: frame, against: baseline)
        } else {
            isStale = Self.isStaleMetadata(incomingPayload, against: previousPayload)
        }
        guard isStale else { return nil }
        return TerminalRemoteStateReductionResult(
            payload: incomingPayload, storedPayload: previousPayload, decodedUpdate: nil, frameToApply: nil, dropReason: "stale_out_of_band_state",
            didRequestResync: false)
    }

    private static func isStale(frame: GhosttyRenderFrame, against baseline: GhosttyRenderUpdateBaseline) -> Bool {
        if frame.ownerEpoch != baseline.ownerEpoch { return frame.ownerEpoch < baseline.ownerEpoch }
        // An unrevisioned frame on either side cannot be ordered, so it is left to apply as it did before
        // this guard existed.
        guard let frameRevision = frame.sessionRevision, let baselineRevision = baseline.sessionRevision else { return false }
        return frameRevision <= baselineRevision
    }

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
            let frame = GhosttyRenderFrame(sessionRevision: baseline.sessionRevision, ownerEpoch: baseline.ownerEpoch, snapshot: baseline.snapshot)
            // The stored payload carries the materialized full frame as a value, not as a re-encoded
            // blob: the reads the client makes of it next (renderSnapshot, renderOwnerEpoch, the render
            // state key) all want the frame, and nothing on this path wants bytes. The payload still
            // yields the identical blob if it is ever serialized (see `GhosttyRenderUpdateBody`).
            //
            // Storing the *materialized* frame rather than the incoming delta is what lets the next
            // payload's merge carry a complete screen forward, and what makes a resync request recover:
            // the chain's state lives in this reducer's baseline and in the stored payload's full frame,
            // both advanced exactly once per payload, in arrival order.
            return (payload.replacingRenderUpdate(materialized: .full(frame)), decodedUpdate, frame, nil)
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
