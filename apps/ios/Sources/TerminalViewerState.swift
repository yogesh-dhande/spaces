import Foundation

// Shadow state enums for `TerminalViewerModel`, introduced alongside the existing stored booleans
// they describe. This is stage 2 of a 3-stage decomposition (stage 1 added characterization tests;
// stage 3 makes these enums authoritative and deletes the flags), modeled on
// `TerminalSessionPaneAttachState` (apps/macos/Sources/spacesterminalui). Nothing here is read by
// product code yet: `TerminalViewerModel` writes each enum next to the flag write it mirrors and
// asserts the two agree (DEBUG only) at the end of every method that mutates an absorbed flag.

/// Whether this viewer's lifecycle is running or has been stopped, and — once stopped — whether the
/// stop's detach has already been sent. Mirrors `isStopping` + `hasSentStopDetach`.
enum TerminalViewerRunState: Equatable {
    /// Neither `isStopping` nor `hasSentStopDetach` is set.
    case running
    /// `isStopping == true`. `detachSent` mirrors `hasSentStopDetach`: `beginStop()` sets both flags
    /// together (`.stopped(detachSent: true)`), but `handleAuthenticationFailure` sets only
    /// `isStopping` (`.stopped(detachSent: false)`) — an authentication failure tears the viewer down
    /// without going through `beginStop()`'s detach bookkeeping. `(isStopping: false, hasSentStopDetach:
    /// true)` is unreachable: `start()` clears both together when restarting a lifecycle that already
    /// sent its detach.
    case stopped(detachSent: Bool)
}

/// Whether a `connect()` attempt is outstanding. Mirrors `isConnecting`. Carries no associated
/// generation: `reconnectAttemptGeneration` stays a standalone staleness counter, read by async
/// continuations regardless of this state's current case.
enum TerminalViewerConnectionState: Equatable {
    case idle
    case connecting
}

/// One outstanding takeover attempt (manual or automatic), or none. Mirrors `isBusy` +
/// `isAwaitingTakeoverConfirmation`. All four combinations of the pair are reachable, so this is a
/// flat 4-case enum with one case per combination (no 3-case approximation): `takeOver()` sets both
/// flags together at attempt start (:907/:910) and clears `isBusy` in its own `defer`, but
/// `isAwaitingTakeoverConfirmation` is also cleared from independent recovery call sites while a
/// `takeOver()` may still be suspended awaiting its network response, which is what makes the two
/// mixed cases below reachable. `hasAttemptedAutomaticTakeover` stays a separate stored bool
/// (eligibility, not attempt state); `automaticTakeoverGeneration` stays standalone.
enum TerminalViewerTakeoverAttemptState: Equatable {
    /// `isBusy == false`, `isAwaitingTakeoverConfirmation == false`: no attempt outstanding.
    case none
    /// `isBusy == true`, `isAwaitingTakeoverConfirmation == true`: the normal in-flight attempt —
    /// `takeOver()` sets both together (:907/:910) and its request is still awaiting a response.
    case awaitingConfirmation
    /// `isBusy == false`, `isAwaitingTakeoverConfirmation == true`: a recovery handler
    /// (`recoverEndedStateIfLiveStreamIsMissing` :2089, `retryStartingStateIfLaunchIsNotReady` :2125,
    /// `recoverEndedStateAfterTerminalStopped` :2147) cleared `isBusy` unconditionally while a
    /// `takeOver()` call was suspended awaiting its own response, so `isAwaitingTakeoverConfirmation`
    /// is still `true`. Reachable from the stream-disconnect (`handleDisconnect` :2052-2053),
    /// connect-failure (`handleConnectError` :2072-2074), and failed-input (`routeInputSendRecovery`
    /// :1515) caller paths, none of which guards on `isBusy` before recovering.
    case confirmationPendingAfterRecoveryClearedBusy
    /// `isBusy == true`, `isAwaitingTakeoverConfirmation == false`: a fresh `takeOver()` began
    /// (passing its `guard !isBusy` at :901) during a recovery handler's own `await` window (e.g.
    /// `recoverEndedStateIfLiveStreamIsMissing`'s `refreshLatestState` await at :2098, where `isBusy`
    /// reads `false` because the recovery already cleared it), setting `isBusy = true` for the new
    /// attempt; the resuming recovery's terminated branch (:2112) then clears
    /// `isAwaitingTakeoverConfirmation` for its own attempt while the new attempt's `isBusy` still
    /// holds `true`.
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

/// Ownership-synchronization (resize handshake) progress. Mirrors
/// `isOwnershipSynchronizationScheduled` + `isSynchronizingOwnership`.
/// `needsOwnershipSynchronizationAfterCurrentRun` stays a standalone stored bool: it is not confined to
/// `.running` and can stay `true` into `.idle` when ownership is lost mid-run.
enum TerminalViewerOwnershipSyncState: Equatable {
    /// Neither flag is set.
    case idle
    /// `isOwnershipSynchronizationScheduled == true`, `isSynchronizingOwnership == false`: the debounce
    /// window before `runOwnershipSynchronization` starts its run.
    case scheduled
    /// Both flags are `true`: `runOwnershipSynchronization`'s run body. `scheduled` is not cleared until
    /// the run's own `defer`, alongside `synchronizing`, so both read `true` for the whole run.
    case running
}

/// Whether the scene is foregrounded, and whether a foreground-ownership evaluation is outstanding.
/// Mirrors `isSceneActive` + `isForegroundResumeEvaluationPending`. `foregroundResumeCycle` stays a
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
