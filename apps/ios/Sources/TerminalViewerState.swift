import Foundation

// State enums for `TerminalViewerModel`, modeled on `TerminalSessionPaneAttachState`
// (apps/macos/Sources/spacesterminalui). Each enum is the sole stored backing for one facet of the
// viewer's lifecycle; `TerminalViewerModel` exposes the same flag names it always has (`isStopping`,
// `isConnecting`, `isBusy`, and so on) as computed properties deriving from these enums, so every
// reader keeps reading a named boolean while only one write site per transition owns the source of
// truth.

/// Whether this viewer's lifecycle is running or has been stopped, and — once stopped — whether the
/// stop's detach has already been sent. Exposed as `isStopping` + `hasSentStopDetach`.
enum TerminalViewerRunState: Equatable {
    case running
    /// `detachSent` is `true` when `beginStop()` ran the normal stop-and-detach path, and `false` when
    /// `handleAuthenticationFailure` tore the viewer down without going through `beginStop()`'s detach
    /// bookkeeping. `(isStopping: false, hasSentStopDetach: true)` is unreachable: `start()` returns to
    /// `.running` when restarting a lifecycle that already sent its detach.
    case stopped(detachSent: Bool)
}

/// Whether a `connect()` attempt is outstanding. Exposed as `isConnecting`. Carries no associated
/// generation: `reconnectAttemptGeneration` stays a standalone staleness counter, read by async
/// continuations regardless of this state's current case.
enum TerminalViewerConnectionState: Equatable {
    case idle
    case connecting
}

/// One outstanding takeover attempt (manual or automatic), or none. Exposed as `isBusy` +
/// `isAwaitingTakeoverConfirmation`. All four combinations of the pair are reachable, so this is a
/// flat 4-case enum with one case per combination (no 3-case approximation): `takeOver()` sets both
/// components together at attempt start and clears `isBusy` in its own `defer`, but
/// `isAwaitingTakeoverConfirmation` is also cleared from independent recovery call sites while a
/// `takeOver()` may still be suspended awaiting its network response, which is what makes the two
/// mixed cases below reachable. `hasAttemptedAutomaticTakeover` stays a separate stored bool
/// (eligibility, not attempt state); `automaticTakeoverGeneration` stays standalone.
enum TerminalViewerTakeoverAttemptState: Equatable {
    /// `isBusy == false`, `isAwaitingTakeoverConfirmation == false`: no attempt outstanding.
    case none
    /// `isBusy == true`, `isAwaitingTakeoverConfirmation == true`: the normal in-flight attempt —
    /// `takeOver()` sets both together at attempt start and its request is still awaiting a response.
    case awaitingConfirmation
    /// `isBusy == false`, `isAwaitingTakeoverConfirmation == true`: a recovery handler
    /// (`recoverEndedStateIfLiveStreamIsMissing`, `retryStartingStateIfLaunchIsNotReady`,
    /// `recoverEndedStateAfterTerminalStopped`) cleared `isBusy` unconditionally while a `takeOver()`
    /// call was suspended awaiting its own response, so `isAwaitingTakeoverConfirmation` is still
    /// `true`. Reachable from the stream-disconnect (`handleDisconnect`), connect-failure
    /// (`handleConnectError`), and failed-input (`routeInputSendRecovery`) caller paths, none of which
    /// guards on `isBusy` before recovering.
    case confirmationPendingAfterRecoveryClearedBusy
    /// `isBusy == true`, `isAwaitingTakeoverConfirmation == false`: a fresh `takeOver()` began (passing
    /// its `guard !isBusy`) during a recovery handler's own `await` window (e.g.
    /// `recoverEndedStateIfLiveStreamIsMissing`'s `refreshLatestState` await, where `isBusy` reads
    /// `false` because the recovery already cleared it), setting `isBusy = true` for the new attempt;
    /// the resuming recovery's terminated branch then clears `isAwaitingTakeoverConfirmation` for its
    /// own attempt while the new attempt's `isBusy` still holds `true`.
    case sendingAfterRecoveryClearedConfirmation
}

extension TerminalViewerTakeoverAttemptState {
    /// Derives the exact case from both flags. Every takeover-axis write site assigns
    /// `takeoverAttemptState` through this initializer immediately after updating `isBusy` and/or
    /// `isAwaitingTakeoverConfirmation`, so the 4-way mapping is written once instead of duplicated
    /// (approximating ternaries) at each of the ~15 call sites.
    init(isBusy: Bool, isAwaitingTakeoverConfirmation: Bool) {
        switch (isBusy, isAwaitingTakeoverConfirmation) {
        case (false, false): self = .none
        case (true, true): self = .awaitingConfirmation
        case (false, true): self = .confirmationPendingAfterRecoveryClearedBusy
        case (true, false): self = .sendingAfterRecoveryClearedConfirmation
        }
    }
}

/// Ownership-synchronization (resize handshake) progress. Exposed as
/// `isOwnershipSynchronizationScheduled` + `isSynchronizingOwnership`.
/// `needsOwnershipSynchronizationAfterCurrentRun` stays a standalone stored bool: it is not confined to
/// `.running` and can stay `true` into `.idle` when ownership is lost mid-run.
enum TerminalViewerOwnershipSyncState: Equatable {
    case idle
    /// The debounce window before `runOwnershipSynchronization` starts its run:
    /// `isOwnershipSynchronizationScheduled == true`, `isSynchronizingOwnership == false`.
    case scheduled
    /// `runOwnershipSynchronization`'s run body: both `isOwnershipSynchronizationScheduled` and
    /// `isSynchronizingOwnership` read `true`. `scheduled` is not cleared until the run's own `defer`,
    /// alongside `synchronizing`, so both read `true` for the whole run.
    case running
}

/// Whether the scene is foregrounded, and whether a foreground-ownership evaluation is outstanding.
/// Exposed as `isSceneActive` + `isForegroundResumeEvaluationPending`. `foregroundResumeCycle` stays a
/// standalone staleness counter, read by async continuations regardless of this state's current case.
enum TerminalViewerSceneState: Equatable {
    enum ResumeEvaluation: Equatable {
        /// No foreground-ownership evaluation outstanding.
        case none
        /// A foreground-ownership evaluation is outstanding for the current `foregroundResumeCycle`.
        case pending
    }
    case active(resume: ResumeEvaluation)
    case backgrounded(resume: ResumeEvaluation)
}

/// Which attachment this client holds, as the daemon records it, or what is known about it when the
/// daemon has not named one. Read by `isAttachmentEvidence` to decide whether a snapshot naming this
/// client is about the attachment it holds now.
///
/// The middle case is what keeps a snapshot from before an expiry authoritative for the window between
/// learning the attachment is gone and the re-attach being acknowledged: the identity that would have
/// caught it has been cleared by then, and treating "no identity" as "judge by client id alone" lets the
/// daemon's pre-expiry backlog re-arm the confirmation just in time for the expiry behind it to read as a
/// second loss.
enum TerminalViewerAttachmentIdentity: Equatable {
    /// Before this lifecycle's first attach, and after a teardown: this client has never held an
    /// attachment the daemon named, so a snapshot naming it is about an attachment it made and nothing
    /// else, which is all such a model can judge by.
    case unattached
    /// An attach is unresolved: the attachment this client held is known to be gone (or was given up)
    /// and the identity of its replacement is not known until the daemon acknowledges it. `replacing` is
    /// the identity of the attachment that went away, when the daemon ever named it, so a snapshot still
    /// carrying that one is recognizably about an attachment that is over.
    case unresolved(replacing: String?)
    /// The daemon acknowledged the attach but its answer carried no session state, so the attachment
    /// exists and this model cannot name it yet. The daemon loads the post-control state with `try?`
    /// (`SpacesDeviceAPIServer`), so an acknowledgement without one is an ordinary answer, not a failure.
    /// It counts as acknowledged — there is an attachment for a snapshot's silence to be about — while a
    /// snapshot naming this client by id alone is not evidence about it, exactly as in `unresolved`: the
    /// id is the same across every attachment this client ever made, so matching on it would admit the
    /// backlog the daemon exported for the attachment that just ended.
    ///
    /// Nothing rests here: the attach path answers it immediately with a `.state` read on the same command
    /// channel (`resolveAttachmentIdentityWithStateRead`), which is ordered after the attach on the daemon
    /// and names this client's `connectedAt`, so the state lasts one round trip. A read that throws hands
    /// recovery to the redial, whose own attach is acknowledged with state; a loss moves the identity on
    /// through `afterAttachmentDropped`; and a teardown resets it to `unattached`.
    case acknowledgedWithoutIdentity
    /// The daemon named this client's attachment in the acknowledgement of the attach that established
    /// it: the `connectedAt` its snapshots carry for this client id.
    case resolved(String)

    /// Whether the daemon has named this client's attachment, which is what makes a snapshot with no row
    /// for this client answerable: there is an attachment for it to be about.
    var isAcknowledged: Bool {
        switch self {
        case .resolved, .acknowledgedWithoutIdentity: true
        case .unattached, .unresolved: false
        }
    }

    /// The state this one moves to when the model learns the attachment it describes is gone, keeping
    /// whatever is known about the attachment being replaced: a second telling of the same loss knows no
    /// more than the first, so it never lowers a known identity to `nil`.
    var afterAttachmentDropped: Self {
        switch self {
        case .unattached: .unresolved(replacing: nil)
        case .unresolved: self
        // Acknowledged but never named, so there is no identity to carry into the window: a snapshot
        // about the attachment that ended is unrecognizable either way, and both states refuse one.
        case .acknowledgedWithoutIdentity: .unresolved(replacing: nil)
        case .resolved(let identity): .unresolved(replacing: identity)
        }
    }
}
