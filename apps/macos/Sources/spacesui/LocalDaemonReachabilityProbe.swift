import Foundation
import spacesterminalcore

/// Liveness probe for this Mac's own daemon, run once per reachability-watchdog tick while the local
/// sidebar section still claims to be loaded.
///
/// Every other device reports its own death: a paired remote's overview stream drops and the
/// disconnect callback marks that section offline. The local device has no stream. Its section
/// reaches `.offline` only through a sidebar snapshot, and snapshots are driven by
/// `IPCNotification.databaseDidChange` — a signal a dead daemon can no longer emit. So a local daemon
/// that dies while the app is idle leaves the section claiming `.loaded` indefinitely, and the
/// watchdog's local recovery branch (which only runs for a section that is *not* loaded) can never
/// engage. This probe is the only evidence available for a device with nothing to disconnect.
///
/// It reports a change of verdict, never the standing one. The caller reloads on the
/// loaded→unreachable transition only: the reload is what decides what the section becomes, so it
/// installs the offline section and the watchdog's not-loaded branch owns every retry from there,
/// and a probe that was wrong costs exactly one reload rather than one per tick.
///
/// That suppression is scoped to one epoch of the section's claim, not to the app session. It holds
/// only while the reload the report asked for has not yet re-derived the section — repeated failures
/// in that window must coalesce into the one reload. A local snapshot that leaves the section loaded
/// ends the epoch and re-arms detection (`noteLocalSectionLoadedFromSnapshot`), because such a
/// snapshot is itself first-hand evidence the daemon answered. Without that, a daemon the reload
/// restarted and that then died again would be reported by nothing: the section would claim `.loaded`
/// while every probe of the corpse was swallowed as "already known", and the reload is the only thing
/// that restarts it.
@MainActor final class LocalDaemonReachabilityProbe {
    /// One liveness attempt: `nil` when the daemon answered, otherwise why it did not. Blocking on a
    /// socket round-trip, so the probe always runs it off the main actor.
    typealias LivenessAttempt = @Sendable () -> (any Error)?

    enum Outcome {
        /// The verdict is unchanged, or an earlier attempt is still outstanding.
        case noChange
        /// The daemon stopped answering.
        case lostContact(error: any Error)
        /// The daemon answers again.
        case regainedContact
    }

    private let attempt: LivenessAttempt
    /// One attempt at a time. A wedged daemon answers nothing until the socket read times out, which
    /// can outlast a watchdog tick; without this, a run of ticks would stack probes on it.
    private var isProbing = false
    /// Seeded as answering: the watchdog is only armed after background services start, which follows
    /// a local snapshot the daemon had to answer for the section to be `.loaded` at all — the same
    /// evidence every later loaded snapshot carries (see `noteLocalSectionLoadedFromSnapshot`).
    private var daemonAnsweredLastAttempt = true

    init(attempt: @escaping LivenessAttempt = LocalDaemonReachabilityProbe.pingLocalDaemon) { self.attempt = attempt }

    /// A local sidebar snapshot left this Mac's section `.loaded`. The daemon had to answer that
    /// snapshot for the section to be loaded, so this is the verdict the probe would otherwise have to
    /// spend a tick discovering: record it, which closes the suppression window an outage report opened
    /// and lets the next failure be reported as a fresh loss of contact.
    func noteLocalSectionLoadedFromSnapshot() { daemonAnsweredLastAttempt = true }

    func run() async -> Outcome {
        guard !isProbing else { return .noChange }
        isProbing = true
        let attempt = attempt
        let failure = await Task.detached(priority: .utility) { attempt() }.value
        isProbing = false
        if let failure {
            guard daemonAnsweredLastAttempt else { return .noChange }
            daemonAnsweredLastAttempt = false
            return .lostContact(error: failure)
        }
        guard !daemonAnsweredLastAttempt else { return .noChange }
        daemonAnsweredLastAttempt = true
        return .regainedContact
    }

    /// The daemon's own liveness ping over its unix socket.
    ///
    /// Deliberately not the local-device bootstrap or the sidebar snapshot that wraps it: both route
    /// through `TerminalService.ensureRunning`, which *starts* spacesd when it is down, so either as a
    /// probe would resurrect the daemon it is meant to observe and could never report it gone. `.ping`
    /// starts nothing. It is answered inline on the daemon's accept queue from a lock-guarded snapshot
    /// (`DaemonLivenessState.pingResponse`), never reaching its main actor or serial work queue, and
    /// its socket timeout bounds the wait on a daemon that is alive but wedged.
    ///
    /// Any failure counts as "did not answer", including the `.shuttingDown` reply of a daemon
    /// mid-handoff to an updated image: the section's state is derived from a daemon that is about to
    /// be replaced, and the reload this triggers waits the handoff out through `ensureRunning` and
    /// re-derives it. The probe only decides that the section must be re-derived; the snapshot decides
    /// what it becomes.
    static let pingLocalDaemon: LivenessAttempt = {
        do {
            try TerminalService.ping()
            return nil
        } catch { return error }
    }
}
