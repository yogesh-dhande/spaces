import Foundation
import spacesterminalcore

// Shadow state for `TerminalSessionPaneViewController`'s attach/ownership machinery: one enum per
// axis, tracked alongside the existing flags (see `debugAssertAttachStateEquivalence()` in the
// controller) rather than replacing them yet. Each case maps onto an exact flag combination the
// controller can reach; see the doc comment on each case for that mapping.
//
// These types do no I/O and touch no AppKit — modeled on `RemoteOverviewSubscriptionCoordinator`'s
// decision style — so the state machine is directly unit-testable once a later stage moves
// production decisions onto it.

/// Shadow of `isClientAttached` / `lastRequestedAttachmentMode` / `pendingAttach`.
enum TerminalClientAttachmentLifecycle: Equatable {
    /// `isClientAttached == false`, `lastRequestedAttachmentMode == nil`, `pendingAttach == nil`.
    case detached
    /// An attach is queued or in flight: `pendingAttach != nil`, requesting `requestedMode`
    /// (`pendingAttach.mode`).
    ///
    /// `priorMode` mirrors `lastRequestedAttachmentMode` for as long as this attach stays in flight.
    /// That flag is set optimistically to `requestedMode` the moment the attach is queued (so the pane
    /// presents as attached before the send lands), which is why `priorMode` starts out equal to
    /// `requestedMode` rather than some earlier confirmed mode. `refreshNow` can later overwrite
    /// `lastRequestedAttachmentMode` from an authoritative snapshot while this same attach is still
    /// outstanding (the snapshot cannot reflect an attach the daemon has not answered yet, but it can
    /// reflect an older, still-current confirmed attachment for this client) — that write updates only
    /// `priorMode` here, leaving `requestedMode` untouched, which is exactly the case this associated
    /// value exists to carry precisely.
    case attaching(requestedMode: TerminalAttachmentMode, priorMode: TerminalAttachmentMode?)
    /// `isClientAttached == true`, `lastRequestedAttachmentMode == mode`, `pendingAttach == nil`.
    case attached(mode: TerminalAttachmentMode)
}

/// Shadow of `ownerAttachmentRequested` / `preferredAttachmentMode`.
enum TerminalOwnershipIntent: Equatable {
    /// `ownerAttachmentRequested == true`. `presentedMode` mirrors `preferredAttachmentMode`, which
    /// can read `.viewer` here: `refreshNow`'s lost-owner branch flips `preferredAttachmentMode` to
    /// `.viewer` on a snapshot that shows another client owns the session, but leaves
    /// `ownerAttachmentRequested` set while this client's own attach is still outstanding, since that
    /// snapshot cannot describe an attach the daemon has not answered yet. A pane can therefore be
    /// "seeking owner" while presented as a viewer for the span of that one outstanding attach.
    case seekingOwner(presentedMode: TerminalAttachmentMode)
    /// `ownerAttachmentRequested == false`. `presentedMode` mirrors `preferredAttachmentMode`.
    case contentWithViewer(presentedMode: TerminalAttachmentMode)

    var presentedMode: TerminalAttachmentMode {
        switch self {
        case .seekingOwner(let mode), .contentWithViewer(let mode): return mode
        }
    }
}

/// Shadow of `clientGhosttySessionHost` / `isResolvingGhosttySessionHost` / `pendingGhosttyHostAttachment`.
///
/// Resolution is lazy and write-once per pane: `.unresolved` -> `.resolving` -> `.resolved` is a
/// one-way path the controller never reverses (the host it creates outlives the pane).
enum TerminalGhosttyHostResolution: Equatable {
    /// `clientGhosttySessionHost == nil`, `isResolvingGhosttySessionHost == false`.
    case unresolved
    /// `isResolvingGhosttySessionHost == true`. `deferred` mirrors `pendingGhosttyHostAttachment`: a
    /// reentrant owner-attach or final-render request that arrived while a resolution was already
    /// running (the session-host provider can synchronously trigger one) is stashed here instead of
    /// being lost, and replayed once resolution completes.
    case resolving(deferred: DeferredAttachment?)
    /// `clientGhosttySessionHost != nil`, `isResolvingGhosttySessionHost == false`,
    /// `pendingGhosttyHostAttachment == nil`.
    case resolved

    /// Mirrors the controller's private `PendingGhosttyHostAttachment` case-for-case. Duplicated here
    /// rather than shared because that type is `private` to the controller's file; this axis's shadow
    /// lives in its own file per the project's one-type-per-file convention.
    enum DeferredAttachment: Equatable {
        case owner(requestID: String?, reason: String, requestWindowFocus: Bool)
        case finalRender(reason: String)
    }
}

/// Shadow of `takeoverAttemptID` / `takeoverAttemptStartedAt`.
enum TerminalTakeoverAttemptState: Equatable {
    /// `takeoverAttemptID == nil`.
    case none
    /// `takeoverAttemptID == id`, `takeoverAttemptStartedAt == nil`: queued behind other control sends
    /// on the pane's serial queue, not yet started.
    case queued(id: UUID)
    /// `takeoverAttemptID == id`, `takeoverAttemptStartedAt == startedAt`: the takeover control send is
    /// in flight.
    case inFlight(id: UUID, startedAt: Date)

    /// Whether a new takeover request may proceed given this attempt's state. Mirrors
    /// `takeOverOwnership`'s retry guard exactly: nothing blocks a first attempt (`.none`); a merely
    /// `.queued` attempt has stamped no start and is never stale, however long it has waited behind
    /// other sends, so it cannot be superseded; an `.inFlight` attempt can be superseded only once it
    /// has been sending for at least `timeout` — a fresh retry before then would duplicate the takeover
    /// on the wire.
    func allowsNewAttempt(now: Date, timeout: TimeInterval) -> Bool {
        switch self {
        case .none: return true
        case .queued: return false
        case .inFlight(_, let startedAt): return now.timeIntervalSince(startedAt) >= timeout
        }
    }
}
