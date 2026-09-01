import Foundation
import spacesterminalcore

// Authoritative state for `TerminalSessionPaneViewController`'s attach/ownership machinery: one enum
// per axis. The controller reads and writes these directly; the handful of flag-named properties it
// still exposes (`isClientAttached`, `preferredAttachmentMode`, `isTakeoverAttemptPending`, etc.) are
// computed views over the case below, kept only because external readers and many internal call
// sites still name them.
//
// These types do no I/O and touch no AppKit — modeled on `RemoteOverviewSubscriptionCoordinator`'s
// decision style — so the state machine is directly unit-testable.

/// A pane's client attachment: whether this pane's client has asked the daemon to attach, and at
/// what mode.
enum TerminalClientAttachmentLifecycle: Equatable {
    /// No attach is outstanding and none is confirmed.
    case detached
    /// An attach is queued or in flight, identified by `id` (the id a queued send checks
    /// immediately before going out, so a superseded attach is dropped rather than delivered, and
    /// `finishAttach` uses to ignore a stale completion).
    ///
    /// `requestedMode` is the mode this attach asked for. `priorMode` starts out equal to
    /// `requestedMode` (the pane presents as attached at that mode optimistically, before the send
    /// lands) but can move independently: a `refreshNow` racing this same attach can sync it from an
    /// authoritative snapshot describing an older, still-current confirmed attachment for this
    /// client — that snapshot cannot reflect an attach the daemon has not answered yet, so it updates
    /// only `priorMode`, leaving `requestedMode` untouched. `priorMode` is nil when no prior
    /// attachment is known (nothing to fall back to if this attach fails).
    case attaching(id: UUID, requestedMode: TerminalAttachmentMode, priorMode: TerminalAttachmentMode?)
    /// A confirmed attachment at `mode`, with no attach outstanding.
    case attached(mode: TerminalAttachmentMode)
}

/// Whether this pane wants its client to hold the session's owner attachment, and the mode
/// currently presented while that intent stands.
enum TerminalOwnershipIntent: Equatable {
    /// This pane wants to be the session's owner. `presentedMode` can still read `.viewer`:
    /// `refreshNow`'s lost-owner branch presents `.viewer` the moment a snapshot shows another
    /// client owns the session, but keeps seeking ownership while this client's own attach is still
    /// outstanding, since that snapshot cannot describe an attach the daemon has not answered yet. A
    /// pane can therefore be "seeking owner" while presented as a viewer for the span of that one
    /// outstanding attach.
    case seekingOwner(presentedMode: TerminalAttachmentMode)
    /// This pane is content presenting as `presentedMode` without seeking ownership.
    case contentWithViewer(presentedMode: TerminalAttachmentMode)

    var presentedMode: TerminalAttachmentMode {
        switch self {
        case .seekingOwner(let mode), .contentWithViewer(let mode): return mode
        }
    }
}

/// A pane's Ghostty session host resolution.
///
/// Resolution is lazy and write-once per pane: `.unresolved` -> `.resolving` -> `.resolved` is a
/// one-way path the controller never reverses (the host it creates outlives the pane).
enum TerminalGhosttyHostResolution: Equatable {
    /// No host has been created yet.
    case unresolved
    /// Host creation is in flight. `deferred` carries a reentrant owner-attach or final-render
    /// request that arrived while this resolution was already running (the session-host provider can
    /// synchronously trigger one) instead of losing it, replayed once resolution completes.
    case resolving(deferred: DeferredAttachment?)
    /// A host exists; resolution is finished.
    case resolved

    /// A host-attach request stashed while a resolution was in flight, replayed once it completes.
    enum DeferredAttachment: Equatable {
        case owner(requestID: String?, reason: String, requestWindowFocus: Bool)
        /// Unreachable today: the only window this case is populated in is the first host
        /// resolution's reentrancy guard (see `resolvedGhosttySessionHost`), and `ghosttyRendererHost`
        /// is always nil there, so `ensureGhosttyFinalRenderSurfaceAttached` — the only producer of
        /// this case — can never observe `hasGhosttyFinalRenderStateAvailable()` (which reads
        /// `ghosttyRendererHost`) as true inside that window. Kept because the case is otherwise a
        /// legitimate deferred-attachment shape and a future caller of
        /// `ensureGhosttyFinalRenderSurfaceAttached` during that window would need it.
        case finalRender(reason: String)
    }
}

/// A pane's outstanding takeover attempt, if any.
enum TerminalTakeoverAttemptState: Equatable {
    /// No takeover attempt is outstanding.
    case none
    /// A takeover attempt identified by `id` is queued behind other control sends on the pane's
    /// serial queue, not yet started.
    case queued(id: UUID)
    /// A takeover attempt identified by `id` has its control send in flight, started at `startedAt`.
    case inFlight(id: UUID, startedAt: Date)

    /// The attempt's id, if one is outstanding. Lets a completion path key off "is this still the
    /// current attempt" without needing a separate id flag.
    var id: UUID? {
        switch self {
        case .none: return nil
        case .queued(let id), .inFlight(let id, _): return id
        }
    }

    /// Whether a new takeover request may proceed given this attempt's state. Nothing blocks a first
    /// attempt (`.none`); a merely `.queued` attempt has stamped no start and is never stale, however
    /// long it has waited behind other sends, so it cannot be superseded; an `.inFlight` attempt can
    /// be superseded only once it has been sending for at least `timeout` — a fresh retry before then
    /// would duplicate the takeover on the wire.
    func allowsNewAttempt(now: Date, timeout: TimeInterval) -> Bool {
        switch self {
        case .none: return true
        case .queued: return false
        case .inFlight(_, let startedAt): return now.timeIntervalSince(startedAt) >= timeout
        }
    }
}
