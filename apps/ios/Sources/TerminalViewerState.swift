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
