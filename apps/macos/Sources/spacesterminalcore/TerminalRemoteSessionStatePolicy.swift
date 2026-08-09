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

    public mutating func reduce(
        incomingPayload: GhosttyRemoteSessionStatePayload, previousPayload: GhosttyRemoteSessionStatePayload?,
        shouldUseFrame: (GhosttyRenderFrame, GhosttyRemoteSessionStatePayload) -> Bool = { _, _ in true }, requestResyncOnApplyFailure: Bool = false
    ) -> TerminalRemoteStateReductionResult {
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
        // Every drop asks for a resync, the caller's veto above included: whichever way the frame was
        // lost, the client is left with a picture the session has already moved past and nothing on the
        // client ever rebuilds it on its own. The request is the only thing that makes the session
        // re-send a full frame; the caller paces it (see `RemoteGhosttySessionHost`'s once-per-second
        // throttle), so a run of vetoed frames costs one round trip, not one each.
        return TerminalRemoteStateReductionResult(
            payload: payload, storedPayload: storedPayload, decodedUpdate: resolved.decodedUpdate, frameToApply: frameToApply, dropReason: dropReason,
            didRequestResync: requestResyncOnApplyFailure && dropReason != nil)
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
