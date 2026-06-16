import Foundation

public enum TerminalRemoteSessionStateReason {
    public static let initial = "initial"
    public static let attachmentState = "attachment_state"
    public static let input = "input"
    public static let inputOutput = "input_output"
    public static let output = "output"
    public static let stateChange = "state_change"
    public static let scroll = "scroll"
    public static let clearScreen = "clear_screen"
    public static let runtimeState = "runtime_state"
    public static let resize = "resize"
    public static let terminated = "terminated"
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
        if let frame = payload.decodedRenderUpdate?.fullFrame {
            if shouldUseFrame(frame, payload) {
                frameToApply = frame
            } else {
                payload = payload.replacingRenderUpdate(nil)
                dropReason = dropReason ?? "stale_resize_grid"
            }
        } else if incomingPayload.renderUpdate != nil {
            dropReason = dropReason ?? "decode_failed"
        }
        let storedPayload = previousPayload?.merged(with: payload) ?? payload
        return TerminalRemoteStateReductionResult(
            payload: payload, storedPayload: storedPayload, decodedUpdate: resolved.decodedUpdate, frameToApply: frameToApply, dropReason: dropReason,
            didRequestResync: requestResyncOnApplyFailure && resolved.dropReason != nil)
    }

    private mutating func payloadByResolvingRenderUpdate(_ payload: GhosttyRemoteSessionStatePayload) -> (
        payload: GhosttyRemoteSessionStatePayload, decodedUpdate: GhosttyRenderUpdate?, dropReason: String?
    ) {
        guard payload.renderUpdate != nil else { return (payload, nil, nil) }
        guard let decodedUpdate = payload.decodedRenderUpdate else { return (payload.replacingRenderUpdate(nil), nil, "render_update_decode_failed") }
        do {
            let baseline = try GhosttyRenderUpdateApplier.apply(decodedUpdate, to: renderUpdateBaseline)
            renderUpdateBaseline = baseline
            let frame = GhosttyRenderFrame(sessionRevision: baseline.sessionRevision, ownerEpoch: baseline.ownerEpoch, snapshot: baseline.snapshot)
            let materializedUpdate = try? GhosttyRenderUpdateBinaryCodec.encode(.full(frame))
            return (payload.replacingRenderUpdate(materializedUpdate), decodedUpdate, nil)
        } catch {
            renderUpdateBaseline = nil
            return (payload.replacingRenderUpdate(nil), decodedUpdate, Self.renderUpdateDropReason(for: error))
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
