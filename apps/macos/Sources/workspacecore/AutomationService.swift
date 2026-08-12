import Foundation
import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Daemon-side scheduler and executor for scheduled automations. One instance owns the whole automation
/// lifecycle: firing cron automations on their persisted schedule, catching up (or skipping) runs missed
/// while the daemon was down, executing a run — a `script`-kind run in a workspace-less command session, or
/// an `agent`-kind run as a coding agent spawned into a workspace and seeded with a prompt — watching it to
/// completion, enforcing concurrency and timeout policies, sweeping and finalizing the coding-agent
/// sessions a run spawned, and pruning old run history.
///
/// No run state lives only in memory: an `agent`-kind run has two phases, both derived from
/// `promptDeliveredAt` — NULL means it is detecting the agent and sending the prompt, set means it is
/// awaiting the agent's `done` signal or its session end — so a daemon restart resumes the correct phase
/// from the store through the same `pollRunningRun` path rather than a parallel recovery path.
///
/// All firing (cron, manual, missed catch-up) funnels through one concurrency gate so every path applies
/// the same allow/skip/queue rules. Execution is poll-based: `tick()` advances the schedule, polls running
/// runs for completion or timeout, and promotes a queued run when its automation goes idle. The daemon
/// drives `tick()` from a periodic timer; tests drive it directly with a controllable clock, so no path
/// depends on background tasks.
///
/// Confined to a private serial queue, NOT the daemon main actor: in the daemon the executor's call graph
/// enters the terminal launcher/terminator closures, which hop the terminal engine actor via
/// `TerminalEngineActor.runSynchronously` — and that engine work itself hops synchronously onto the main
/// actor for NSView/Ghostty work. A main-actor caller blocking on this service would therefore deadlock
/// behind that engine→main hop (the one-way rule). Every public entry point hops onto the serial queue,
/// which also serializes overlapping timer fires; callers are transport/Device-API threads and the daemon
/// timer via a detached task, never the main actor. Internal code must call the private `…Locked` helpers,
/// never back through the queue-hopping public surface, or it would re-enter `queue.sync` and deadlock.
public final class AutomationService: @unchecked Sendable {
    /// Serial queue every public entry point confines its work to. Serializes concurrent transport callers
    /// and overlapping timer-driven `tick()`s, and keeps the whole service off the main actor.
    private let queue = DispatchQueue(label: "spaces.automation-service")
    private let store: SQLiteStore
    private let orchestrator: WorkspaceOrchestrator
    /// Prepended to the automation command's PATH so `spaces` resolves to the running daemon's sibling CLI.
    private let binaryDirectory: String
    /// Supplies the device's current time zone on demand (rather than a value captured once), so a tick can
    /// notice a zone change. Cron `nextFireDate` is computed in whatever zone this returns at that moment.
    private let timeZone: @Sendable () -> TimeZone
    private let now: () -> Date
    /// Grace between the SIGTERM sent to a timed-out/canceled run's command process group and the SIGKILL
    /// that follows if it has not exited. Production uses 10s; tests shrink it to exercise escalation fast.
    private let terminationGrace: TimeInterval
    /// Newest runs kept per automation; older terminal runs are pruned with their artifacts.
    private let retentionLimit: Int
    /// Read at the top of every queue-confined tick, not just at the daemon's timer callback. The timer-side
    /// handoff gate races: a tick that passed it can sit unscheduled while the handoff's `waitUntilIdle()`
    /// drains an empty queue, then run against quiesced cores and misread preserved sessions as dead.
    /// Re-checking INSIDE the confinement queue closes that window — any tick admitted after the handoff
    /// flag is set no-ops. The daemon injects the same liveness flag its timer gate reads.
    private let ticksSuspended: @Sendable () -> Bool
    private let logError: (String) -> Void

    /// Command processes signaled during a timeout/cancel teardown, awaiting SIGKILL escalation. Keyed by
    /// run id so escalation continues on later ticks even after the run row reached its terminal status.
    private struct PendingKill {
        let automationID: String
        let childPID: Int32
        /// The command's process group id captured at SIGTERM time, when the child was its own group leader
        /// and that group was not the daemon's own; nil otherwise. Escalation signals THIS stored group
        /// rather than recomputing `getpgid(childPID)` at the deadline: once the shell group leader exits,
        /// `getpgid` would fail (or, after pid reuse, name the wrong group), so a descendant that ignored
        /// SIGTERM would never receive SIGKILL. Tracking the group keeps the kill outstanding — and reaches
        /// the survivor — after the leader is gone.
        let processGroupID: Int32?
        let sigkillDeadline: Date
    }
    private var pendingKills: [String: PendingKill] = [:]

    public init(
        store: SQLiteStore, orchestrator: WorkspaceOrchestrator, binaryDirectory: String, timeZone: @escaping @Sendable () -> TimeZone = { .current },
        now: @escaping () -> Date = Date.init, terminationGrace: TimeInterval = 10, retentionLimit: Int = 100,
        ticksSuspended: @escaping @Sendable () -> Bool = { false }, logError: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.orchestrator = orchestrator
        self.binaryDirectory = binaryDirectory
        self.timeZone = timeZone
        self.now = now
        self.terminationGrace = terminationGrace
        self.retentionLimit = retentionLimit
        self.ticksSuspended = ticksSuspended
        self.logError = logError
    }

    /// Drains any in-flight operation: awaits a no-op block appended to the confinement queue. Because that
    /// queue is serial, the continuation resumes only after every previously started operation has completed.
    /// Used by the daemon to drain a possibly in-flight `tick()` before quiescing cores for an exec handoff.
    /// Async, and must never be called as a sync block from the main actor: the service's executor hops the
    /// terminal engine actor (and thus main), so a main-actor sync wait would deadlock (the one-way rule).
    public func waitUntilIdle() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }

    /// Drains the confinement queue and immediately completes every termination escalation already armed by
    /// a timeout or cancel. An exec handoff preserves child processes but replaces this service, so letting
    /// the in-memory pending table cross that boundary would permanently lose its promised SIGKILL.
    public func completePendingTerminationsForHandoff() async {
        await withCheckedContinuation { continuation in
            queue.async {
                for pending in self.pendingKills.values where self.pendingKillIsOutstanding(pending) { self.escalateToSIGKILL(pending) }
                self.pendingKills.removeAll()
                continuation.resume()
            }
        }
    }

    // MARK: - Scheduling entry points

    /// Establishes a newly created or re-enabled cron automation's next fire time from now, with no
    /// backfill of occurrences that fell before this moment. Throws when the anchor cannot be persisted, so
    /// the create/update command surface reports the failure instead of returning an automation that
    /// silently never fires; scheduler-side callers wrap it and log rather than propagate.
    public func computeInitialNextFireTime(automationID: String) throws {
        try queue.sync { try computeInitialNextFireTimeLocked(automationID: automationID) }
    }

    private func computeInitialNextFireTimeLocked(automationID: String) throws {
        guard let automation = try store.automation(id: automationID), automation.enabled, let schedule = automation.parsedCronSchedule else {
            return
        }
        let zone = timeZone()
        guard let nextFireTime = schedule.nextFireDate(after: now(), timeZone: zone) else {
            throw AutomationValidationError("Cron schedule has no future occurrence.")
        }
        try store.setAutomationNextFireTime(id: automationID, nextFireTime: nextFireTime, anchorTimeZoneIdentifier: zone.identifier)
    }

    /// One scheduler + executor step: poll running runs for completion/timeout, fire due cron automations,
    /// advance escalations, and promote a queued run whose automation is now idle. Idempotent per minute:
    /// a cron automation fires once when its `nextFireTime` elapses because firing recomputes it forward.
    ///
    /// Invariant: `pollRunningRuns` runs BEFORE `fireDueCronAutomations`, so a run whose command exited
    /// between ticks is finalized before the concurrency gate judges overlap this tick. Otherwise a due fire
    /// under the `skip` policy would read the just-exited run as still `.running`, consume the cron anchor,
    /// and record a skipped occurrence against work that is no longer running — so `skip` only ever skips
    /// against genuinely still-running work.
    public func tick() {
        queue.sync {
            // Checked inside the queue so a tick scheduled before a handoff began — but run after its
            // drain — cannot poll quiesced cores (see `ticksSuspended`).
            guard !ticksSuspended() else { return }
            recomputeCronAnchorsIfTimeZoneChanged()
            pollRunningRuns()
            fireDueCronAutomations()
            processPendingKills()
            promoteQueuedRuns()
        }
    }

    /// Recomputes every enabled cron automation's next fire time from now when the device's current zone
    /// differs from the zone persisted beside that anchor. Anchors are absolute instants, so a zone change
    /// would otherwise keep firing daily/weekly schedules at the old zone's wall-clock time.
    private func recomputeCronAnchorsIfTimeZoneChanged() {
        let zone = timeZone()
        do {
            for automation in try store.enabledCronAutomations() where automation.anchorTimeZoneIdentifier.map({ $0 != zone.identifier }) == true {
                // Scheduler-side: one automation's anchor failing must not wedge the recompute for the rest,
                // so each is isolated and logged rather than propagated (the command surface propagates).
                do { try computeInitialNextFireTimeLocked(automationID: automation.id) } catch {
                    logError("automation_next_fire_time_error id=\(automation.id) error=\(error)")
                }
            }
        } catch { logError("automation_timezone_recompute_error error=\(error)") }
    }

    /// Daemon-start reconciliation: for each enabled cron automation whose persisted `nextFireTime` already
    /// elapsed while the daemon was down, apply the missed-run policy exactly once (one catch-up run, or one
    /// skipped row), then recompute the next fire time from now. Automations with no elapsed anchor (freshly
    /// created, or whose next time is still in the future) are left untouched.
    public func reconcileMissedRunsOnStart() { queue.sync { reconcileMissedRunsOnStartLocked() } }

    private func reconcileMissedRunsOnStartLocked() {
        // Reconcile stale `running` run rows left by the previous daemon lifetime BEFORE firing any catch-up.
        // A run whose command finished (or died with the daemon) while the daemon was down is still `running`
        // in the store; the catch-up routes through the same concurrency gate, which would read that stale row
        // as an active run and skip/queue the catch-up — permanently losing a `runOnce` catch-up under the
        // `skip` policy once the cron anchor is advanced below. `recoverStaleSessions` (daemon startup) has
        // already flipped a crashed daemon's sessions to a non-interactive state, so this poll observes the
        // completion and finalizes the row. A genuinely-still-running session (adopted across a graceful
        // handoff, whose service pid is alive) stays `running` and correctly keeps blocking the catch-up.
        pollRunningRuns()
        let currentTime = now()
        let currentZone = timeZone()
        do {
            for automation in try store.enabledCronAutomations() {
                guard let schedule = automation.parsedCronSchedule else { continue }
                let dueTime: Date?
                if let identifier = automation.anchorTimeZoneIdentifier, identifier != currentZone.identifier {
                    guard let anchorZone = TimeZone(identifier: identifier) else {
                        throw AutomationValidationError("Invalid persisted automation time zone '\(identifier)'.")
                    }
                    dueTime = automation.nextFireTime.flatMap { Self.reinterpretWallClockOccurrence($0, from: anchorZone, to: currentZone) }
                } else {
                    // A NULL zone is a v14 anchor. Its absolute due time retains the historical behavior for
                    // that one upgrade, then the atomic claim below stamps every row with the current zone.
                    dueTime = automation.nextFireTime
                }
                // Claim the next occurrence before launching a catch-up, matching ordinary cron firing's
                // at-most-once order. The zone and instant land in one UPDATE, so a restart can never see one
                // half of the anchor context without the other.
                try store.setAutomationNextFireTime(
                    id: automation.id, nextFireTime: schedule.nextFireDate(after: currentTime, timeZone: currentZone),
                    anchorTimeZoneIdentifier: currentZone.identifier)
                if let dueTime, dueTime <= currentTime {
                    switch automation.missedRunPolicy {
                    case .runOnce: _ = fire(automation: automation, trigger: .missedCatchUp)
                    case .skip: _ = try recordSkippedRun(automation: automation, trigger: .missedCatchUp, reason: .missed)
                    }
                }
            }
        } catch { logError("automation_missed_run_reconcile_error error=\(error)") }
    }

    /// Maps an occurrence's local date and clock components from the zone that produced its persisted
    /// absolute instant into another zone. This preserves the logical cron occurrence across an offline
    /// device move instead of comparing the old zone's instant to the new zone's wall clock.
    private static func reinterpretWallClockOccurrence(_ occurrence: Date, from sourceZone: TimeZone, to destinationZone: TimeZone) -> Date? {
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = sourceZone
        let components = sourceCalendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: occurrence)
        var destinationCalendar = Calendar(identifier: .gregorian)
        destinationCalendar.timeZone = destinationZone
        return destinationCalendar.date(from: components)
    }

    /// Manual trigger entry point (tests today, Device API later). Fires through the same concurrency gate
    /// as cron. Returns the resulting run row (started, queued, or a skipped record), or nil when the
    /// automation is missing.
    @discardableResult public func triggerManually(automationID: String) -> AutomationRun? {
        queue.sync {
            do {
                guard let automation = try store.automation(id: automationID) else { return nil }
                return fire(automation: automation, trigger: .manual)
            } catch {
                logError("automation_manual_trigger_error id=\(automationID) error=\(error)")
                return nil
            }
        }
    }

    // MARK: - Command surface

    /// The single daemon-side implementation of every automation command. Both transports — the profile
    /// service socket and the Device API — call these on the one live `AutomationService` instance, so
    /// scheduling, execution, and validation never fork between local and remote callers. Validation and
    /// next-fire-time recomputation live here (not per transport) so both boundaries behave identically.

    /// Creates a new automation from a validated draft. On an enabled cron automation the initial next fire
    /// time is computed from now (no backfill). Returns the persisted automation, including any computed
    /// next fire time.
    public func createAutomation(_ draft: AutomationDraft) throws -> Automation { try queue.sync { try createAutomationLocked(draft) } }

    private func createAutomationLocked(_ draft: AutomationDraft) throws -> Automation {
        let validated = try draft.validated()
        let timestamp = now()
        let automation = Automation(
            id: UUID().uuidString, name: validated.name, enabled: validated.enabled, triggerKind: validated.triggerKind,
            cronExpression: validated.cronExpression, kind: validated.kind, script: validated.script, agentCommand: validated.agentCommand,
            agentPrompt: validated.agentPrompt, workspaceID: validated.workspaceID, workingDirectory: validated.workingDirectory,
            timeoutSeconds: validated.timeoutSeconds, concurrencyPolicy: validated.concurrencyPolicy, missedRunPolicy: validated.missedRunPolicy,
            nextFireTime: nil, createdAt: timestamp, updatedAt: timestamp)
        // The row and its cron anchor must land atomically: a failure between the two writes would otherwise
        // persist an enabled cron automation with a NULL anchor (one that never fires) while surfacing an
        // error the caller would retry into a duplicate.
        try store.withTransaction {
            try store.upsertAutomation(automation)
            try applyNextFireTime(automationID: automation.id, enabled: validated.enabled, triggerKind: validated.triggerKind)
        }
        return try requireAutomation(id: automation.id)
    }

    /// Applies a validated draft to an existing automation (including enabling/disabling it), preserving its
    /// id and creation time. Its next fire time is recomputed from now for an enabled cron automation and
    /// cleared otherwise, so disabling or switching to manual removes a stale schedule anchor. Throws when
    /// the automation does not exist.
    public func updateAutomation(id: String, draft: AutomationDraft) throws -> Automation {
        try queue.sync { try updateAutomationLocked(id: id, draft: draft) }
    }

    private func updateAutomationLocked(id: String, draft: AutomationDraft) throws -> Automation {
        let existing = try requireAutomation(id: id)
        let validated = try draft.validated()
        // The poll path dispatches on the automation's current kind, so switching Script↔Agent while a run is
        // queued or running would misclassify that in-flight run. Reject only the kind change; every other
        // edit stays allowed even mid-run.
        if validated.kind != existing.kind, try !store.activeAutomationRuns(automationID: id).isEmpty {
            throw AutomationValidationError("Automation type can't be changed while a run is queued or running.")
        }
        let automation = Automation(
            id: existing.id, name: validated.name, enabled: validated.enabled, triggerKind: validated.triggerKind,
            cronExpression: validated.cronExpression, kind: validated.kind, script: validated.script, agentCommand: validated.agentCommand,
            agentPrompt: validated.agentPrompt, workspaceID: validated.workspaceID, workingDirectory: validated.workingDirectory,
            timeoutSeconds: validated.timeoutSeconds, concurrencyPolicy: validated.concurrencyPolicy, missedRunPolicy: validated.missedRunPolicy,
            nextFireTime: nil, createdAt: existing.createdAt, updatedAt: now())
        // The row and its recomputed cron anchor must land atomically: a failure between the two writes would
        // otherwise leave an enabled cron automation with a NULL anchor (one that never fires) while surfacing
        // an error to the caller.
        try store.withTransaction {
            try store.upsertAutomation(automation)
            try applyNextFireTime(automationID: automation.id, enabled: validated.enabled, triggerKind: validated.triggerKind)
        }
        return try requireAutomation(id: automation.id)
    }

    public func listAutomations() throws -> [Automation] { try queue.sync { try store.automations() } }

    /// Runs for one automation (newest first) when `automationID` is given, or across every automation
    /// otherwise. Includes live (queued/running) runs, which sort to the top by their recent creation time.
    public func listAutomationRuns(automationID: String?) throws -> [AutomationRun] {
        try queue.sync {
            if let automationID { return try store.automationRuns(automationID: automationID) }
            return try store.allAutomationRuns()
        }
    }

    /// Manually fires an automation through the shared concurrency gate. Throws when the automation is
    /// missing so the boundary surfaces a clear error instead of a silent no-op.
    public func triggerAutomation(id: String) throws -> AutomationRun {
        try queue.sync {
            let automation = try requireAutomation(id: id)
            guard let run = fire(automation: automation, trigger: .manual) else {
                throw AutomationValidationError("Failed to start a run for automation \(id).")
            }
            return run
        }
    }

    /// Cancels a run, returning its resulting terminal row. A terminal run is returned unchanged
    /// (idempotent). Throws when the run does not exist or its teardown/finalization fails, so the transport
    /// surfaces the failure instead of reporting success over a still-running row.
    public func cancelAutomationRun(runID: String) throws -> AutomationRun { try queue.sync { try cancelAutomationRunLocked(runID: runID) } }

    private func cancelAutomationRunLocked(runID: String) throws -> AutomationRun {
        let run = try requireAutomationRun(id: runID)
        guard !run.status.isTerminal else { return run }
        // `cancelRunThrowing` returns the finalized `canceled` row built from what it persisted, so the result
        // is accurate even when finalizing this run made it immediately prunable and removed it from the store
        // — a re-fetch would then throw "run not found" despite a successful cancel. The nil branch is only the
        // already-terminal/missing race the guard above already excludes on this single-actor path.
        guard let canceled = try cancelRunThrowing(runID: runID) else { return run }
        return canceled
    }

    /// Ends every still-live coding-agent session attributed to a TERMINAL run, then prunes the automation's
    /// retention and returns the run's final state. This reaps the agent sessions a finished run left
    /// running — an `agent`-kind run whose agent signalled `done` (succeeded) deliberately leaves its
    /// session open, and this is how a client stops it on demand. The run's status, exit code, and
    /// timestamps are left untouched: end-agents cleans up lingering sessions, it does not re-finalize the
    /// run. A non-terminal (queued/running) run is rejected
    /// loudly — a live run is stopped with cancel, not end-agents. Each live attributed session is torn down
    /// through the exact seam cancel's agent teardown uses: the agent-kill flow (which finalizes the agent
    /// row and notifies subscribers), falling back to a plain session termination for a not-yet-signalled
    /// `.agent` session with no row.
    public func endAttributedAgents(runID: String) throws -> AutomationRun { try queue.sync { try endAttributedAgentsLocked(runID: runID) } }

    private func endAttributedAgentsLocked(runID: String) throws -> AutomationRun {
        let run = try requireAutomationRun(id: runID)
        guard run.status.isTerminal else {
            throw AutomationValidationError("Cannot end agents for automation run \(runID): it is still \(run.status.rawValue). Cancel it instead.")
        }
        for sessionID in try store.terminalSessionIDs(automationRunID: run.id) where orchestrator.automationSessionIsLive(sessionID: sessionID) {
            if try !orchestrator.killAgentSession(terminalSessionID: sessionID) { orchestrator.automationTerminateSession(sessionID: sessionID) }
        }
        // A run beyond the retention cap can be retained solely because its attributed agent was live (the
        // no-kill guard in `pruneRetention`). Now that its sessions are ended, prune so it is removed here
        // rather than lingering over-cap until some later run happens to prune. This may delete `run` itself,
        // so return the local value — end-agents leaves the run row's status/exit/timestamps untouched, so it
        // is the run's accurate final state whether or not the row survived pruning.
        try pruneRetention(automationID: run.automationID)
        return run
    }

    /// Deletes an automation (cancelling any running run and cleaning up its artifacts and attributed
    /// sessions). Throws when the automation does not exist.
    public func deleteAutomationCommand(id: String) throws {
        try queue.sync {
            _ = try requireAutomation(id: id)
            try deleteAutomationLocked(id: id)
        }
    }

    private func requireAutomation(id: String) throws -> Automation {
        guard let automation = try store.automation(id: id) else { throw AutomationValidationError("Automation not found: \(id).") }
        return automation
    }

    private func requireAutomationRun(id: String) throws -> AutomationRun {
        guard let run = try store.automationRun(id: id) else { throw AutomationValidationError("Automation run not found: \(id).") }
        return run
    }

    /// Recomputes (enabled cron) or clears (disabled or manual) an automation's next fire time after a
    /// create/update. `computeInitialNextFireTime` sets the anchor from now for an enabled cron automation;
    /// every other case has no schedule, so the anchor is explicitly cleared to drop any stale value.
    private func applyNextFireTime(automationID: String, enabled: Bool, triggerKind: AutomationTriggerKind) throws {
        if enabled, triggerKind == .cron {
            try computeInitialNextFireTimeLocked(automationID: automationID)
        } else {
            try store.setAutomationNextFireTime(id: automationID, nextFireTime: nil, anchorTimeZoneIdentifier: nil)
        }
    }

    private func fireDueCronAutomations() {
        let currentTime = now()
        do {
            for automation in try store.enabledCronAutomations() {
                guard let schedule = automation.parsedCronSchedule, let nextFireTime = automation.nextFireTime, nextFireTime <= currentTime else {
                    continue
                }
                // At-most-once firing: the persisted anchor is the durable claim on this occurrence, advanced
                // BEFORE the launch. `fire` swallows its own errors and the two writes are independent, so if the
                // launch ran first an anchor-write failure (or a crash between the two) would leave a due anchor
                // that re-fires the same occurrence on every tick — under the `allow` policy, a fresh duplicate
                // launch every second. Advancing the anchor first means a failure or crash can only ever LOSE one
                // occurrence, never duplicate a launch (a duplicate agent/script launch is the worse failure).
                // Which automations fire this tick is still decided by each row's in-memory `nextFireTime` in the
                // guard above (the loop iterates a pre-fetched list), so the reorder does not change the selection.
                let zone = timeZone()
                try store.setAutomationNextFireTime(
                    id: automation.id, nextFireTime: schedule.nextFireDate(after: currentTime, timeZone: zone),
                    anchorTimeZoneIdentifier: zone.identifier)
                _ = fire(automation: automation, trigger: .cron)
            }
        } catch { logError("automation_fire_due_error error=\(error)") }
    }

    // MARK: - Concurrency gate

    /// The single fire chokepoint every trigger routes through, applying the automation's concurrency
    /// policy. Script-kind gating is against the automation's active (queued/running) run rows. Agent-kind
    /// gating additionally counts a live attributed session as a conflict: an agent session outlives its
    /// run row (a `done` agent's session stays open with the run already `succeeded`), so `skip`/`queue`
    /// must keep blocking while any attributed session of the automation is still live, not just while a
    /// run row is running.
    @discardableResult private func fire(automation: Automation, trigger: AutomationRunTrigger) -> AutomationRun? {
        do {
            let active = try store.activeAutomationRuns(automationID: automation.id)
            let running = active.contains { $0.status == .running }
            let queued = active.contains { $0.status == .queued }
            let blocking =
                try running || automationHasPendingTermination(automationID: automation.id)
                || (automation.kind == .agent && automationHasLiveAttributedSession(automationID: automation.id))
            switch automation.concurrencyPolicy {
            case .allow: return try startRun(automation: automation, trigger: trigger)
            case .skip:
                if !blocking && !queued { return try startRun(automation: automation, trigger: trigger) }
                return try recordSkippedRun(automation: automation, trigger: trigger, reason: .concurrency)
            case .queue:
                if !blocking && !queued { return try startRun(automation: automation, trigger: trigger) }
                if queued { return try recordSkippedRun(automation: automation, trigger: trigger, reason: .concurrency) }
                return try enqueueRun(automation: automation, trigger: trigger)
            }
        } catch {
            logError("automation_fire_error id=\(automation.id) error=\(error)")
            return nil
        }
    }

    /// Whether any terminal session attributed to any run of this automation is still live. Agent-kind
    /// concurrency gates on this (not just run-row status) because an agent session persists past its run's
    /// terminal status; the ended-only sweep and retention eventually reap the ended ones.
    private func automationHasLiveAttributedSession(automationID: String) throws -> Bool {
        for run in try store.automationRuns(automationID: automationID) {
            for sessionID in try store.terminalSessionIDs(automationRunID: run.id) where orchestrator.automationSessionIsLive(sessionID: sessionID) {
                return true
            }
        }
        return false
    }

    /// A script remains concurrency-active after its run row becomes terminal while SIGTERM grace is still
    /// in flight. Starting its replacement before the promised SIGKILL completes would overlap processes
    /// under the Skip/Queue policies even though the database no longer has a running row.
    private func automationHasPendingTermination(automationID: String) -> Bool {
        pendingKills.values.contains { $0.automationID == automationID && pendingKillIsOutstanding($0) }
    }

    private func recordSkippedRun(automation: Automation, trigger: AutomationRunTrigger, reason: AutomationRunSkipReason) throws -> AutomationRun {
        let currentTime = now()
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: automation.kind, status: .skipped, skipReason: reason, trigger: trigger,
            exitCode: nil, terminalSessionID: nil, startedAt: nil, endedAt: currentTime, createdAt: currentTime)
        try store.insertAutomationRun(run)
        try pruneRetention(automationID: automation.id)
        return run
    }

    private func enqueueRun(automation: Automation, trigger: AutomationRunTrigger) throws -> AutomationRun {
        let currentTime = now()
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: automation.kind, status: .queued, skipReason: nil, trigger: trigger,
            exitCode: nil, terminalSessionID: nil, startedAt: nil, endedAt: nil, createdAt: currentTime)
        try store.insertAutomationRun(run)
        return run
    }

    // MARK: - Executor

    /// Begins executing a run: insert (or promote an existing queued) row to `running`, sweep the ended
    /// coding-agent sessions of this automation's prior runs, then launch the workspace-less command
    /// session and record its terminal session id. A launch failure records the run `failed`.
    @discardableResult private func startRun(automation: Automation, trigger: AutomationRunTrigger, promoting existing: AutomationRun? = nil) throws
        -> AutomationRun
    {
        let currentTime = now()
        let runID = existing?.id ?? UUID().uuidString
        let run = AutomationRun(
            id: runID, automationID: automation.id, kind: automation.kind, status: .running, skipReason: nil, trigger: existing?.trigger ?? trigger,
            exitCode: nil, terminalSessionID: nil, startedAt: currentTime, endedAt: nil, createdAt: existing?.createdAt ?? currentTime)
        if existing == nil {
            try store.insertAutomationRun(run)
        } else {
            try store.updateAutomationRun(
                id: runID, status: .running, skipReason: nil, exitCode: nil, terminalSessionID: nil, startedAt: currentTime, endedAt: nil,
                promptDeliveredAt: nil)
        }

        sweepPriorRunSessions(automationID: automation.id, excludingRunID: runID)

        switch automation.kind {
        case .script: try launchScriptRun(automation: automation, runID: runID, startedAt: currentTime)
        case .agent: try launchAgentRun(automation: automation, runID: runID, startedAt: currentTime)
        }
        // The launch paths update the stored row with the session id (or a launch failure), so return the
        // persisted row rather than the pre-launch local value, which still reads `running` with no session.
        return try requireAutomationRun(id: runID)
    }

    /// Launches a script-kind run's workspace-less command session and records its terminal session id. A
    /// launch failure records the run `failed`.
    private func launchScriptRun(automation: Automation, runID: String, startedAt: Date) throws {
        let sessionID = UUID().uuidString
        // Set once the session is live; distinguishes a post-launch persist failure from a launch failure.
        var launchedSessionID: String?
        do {
            try AutomationPaths.ensureRunDirectory(runID: runID)
            let command = try wrappedCommand(automation: automation, runID: runID)
            _ = try orchestrator.launchAutomationSession(
                runID: runID, sessionID: sessionID, title: automation.name, workingDirectory: automation.workingDirectory, command: command,
                environment: [WorkspaceOrchestrator.automationRunIDEnvVar: runID])
            launchedSessionID = sessionID
            try store.updateAutomationRun(
                id: runID, status: .running, skipReason: nil, exitCode: nil, terminalSessionID: sessionID, startedAt: startedAt, endedAt: nil,
                promptDeliveredAt: nil)
        } catch {
            logError("automation_launch_error run=\(runID) error=\(error)")
            // Invariant: a run may never finalize while a session it launched is still live and unrecorded.
            // A persist failure leaves the launched session running with no run-row session id — an orphan that
            // runs alongside the automation's next fire (script concurrency gates on run rows only). Tear it down
            // best-effort: termination must not mask the original error, so the run still lands `.failed`.
            if let launchedSessionID { orchestrator.automationTerminateSession(sessionID: launchedSessionID) }
            try recordLaunchFailure(automationID: automation.id, runID: runID, startedAt: startedAt)
        }
    }

    /// Spawns an agent-kind run's coding agent into the automation's workspace, seeded (later) with its
    /// prompt. The spawned session IS the run's session — no wrapper terminal. The prompt is not sent here:
    /// `pollRunningAgentRun` waits for foreground detection first, then delivers it, so the tick never
    /// blocks. A missing workspace, an unsupported command, or a spawn error records the run `failed`
    /// through the same launch-failure path a script-launch error takes.
    private func launchAgentRun(automation: Automation, runID: String, startedAt: Date) throws {
        // Set once the session is spawned; distinguishes a post-launch persist failure from a spawn failure.
        var launchedSessionID: String?
        do {
            guard let workspaceID = automation.workspaceID, let command = automation.agentCommand else {
                throw AutomationValidationError("Agent automation is missing its workspace or command.")
            }
            // Same command gate the interactive `agent spawn` uses: the command must launch a supported
            // coding agent so foreground detection knows which kind to await.
            _ = try AgentSpawnCommandGate.resolveSpawnableAgent(command: command)
            try AutomationPaths.ensureRunDirectory(runID: runID)
            let session = try orchestrator.createWorkspaceAgentSession(
                workspaceID: workspaceID, command: command, title: automation.name, automationRunID: runID)
            launchedSessionID = session.id
            try store.updateAutomationRun(
                id: runID, status: .running, skipReason: nil, exitCode: nil, terminalSessionID: session.id, startedAt: startedAt, endedAt: nil,
                promptDeliveredAt: nil)
        } catch {
            logError("automation_agent_launch_error run=\(runID) error=\(error)")
            // Invariant: a run may never finalize while a session it launched is still live and unrecorded.
            // A persist failure leaves the spawned session running but unrecorded; its automationRunID stamp on the
            // session table keeps `automationHasLiveAttributedSession` true, permanently blocking future agent fires.
            // Mirror `teardownAgentRunSession`'s fallback: the kill is best-effort so the run still lands `.failed`.
            if let launchedSessionID, (try? orchestrator.killAgentSession(terminalSessionID: launchedSessionID)) != true {
                orchestrator.automationTerminateSession(sessionID: launchedSessionID)
            }
            try recordLaunchFailure(automationID: automation.id, runID: runID, startedAt: startedAt)
        }
    }

    /// Records a run `failed` after a launch error and prunes retention, the shared failure tail for both
    /// kinds' launch paths.
    private func recordLaunchFailure(automationID: String, runID: String, startedAt: Date) throws {
        try store.updateAutomationRun(
            id: runID, status: .failed, skipReason: nil, exitCode: nil, terminalSessionID: nil, startedAt: startedAt, endedAt: now(),
            promptDeliveredAt: nil)
        try pruneRetention(automationID: automationID)
    }

    /// Builds the shell command string the automation session runs. Prepends the daemon binary directory
    /// to PATH (so `spaces` resolves), runs the user's command in a subshell, then records the command's
    /// exit code into the run's sentinel file and re-exits with it. `SPACES_AUTOMATION_RUN_ID` is exported
    /// separately by the launch path's environment prefix. POSIX-sh compatible so it runs under any login
    /// shell. The user command runs in a `( … )` subshell, not a `{ … }` group, so that a command which
    /// calls `exit` ends only the subshell — the exit code is still captured rather than tearing the outer
    /// shell down before the sentinel is written.
    private func wrappedCommand(automation: Automation, runID: String) throws -> String {
        let sentinelPath = try AutomationPaths.exitCodePath(runID: runID).path
        let quotedBinDir = orchestrator.automationShellQuoted(binaryDirectory)
        let quotedSentinel = orchestrator.automationShellQuoted(sentinelPath)
        return """
            export PATH=\(quotedBinDir):"$PATH"
            ( \(automation.script)
            )
            __spaces_ec=$?
            printf '%s' "$__spaces_ec" > \(quotedSentinel) 2>/dev/null || true
            exit $__spaces_ec
            """
    }

    private func pollRunningRuns() {
        do {
            for run in try store.runningAutomationRuns() {
                guard let automation = try store.automation(id: run.automationID) else {
                    // The automation was deleted out from under a live run; treat the orphan as canceled.
                    try finishRun(run, status: .canceled, exitCode: nil)
                    continue
                }
                pollRunningRun(run, automation: automation)
            }
        } catch { logError("automation_poll_error error=\(error)") }
    }

    private func pollRunningRun(_ run: AutomationRun, automation: Automation) {
        // A `.running` row with no session id is always a stale crash leftover: queue confinement means a tick
        // can never observe the mid-`startRun` window where the row is briefly `.running` with a nil session id
        // (`startRun` inserts the row and records its launched session id within one queued operation, never
        // interleaved with a tick). So an observed nil-session `.running` row is a daemon that died between
        // inserting the row and persisting its session id; it would otherwise stay `.running` forever and block
        // skip/queue concurrency. Fail it (nil exit code) so the automation is unblocked.
        guard run.terminalSessionID != nil else {
            do { try finishRun(run, status: .failed, exitCode: nil) } catch { logError("automation_poll_run_error run=\(run.id) error=\(error)") }
            return
        }
        switch automation.kind {
        case .script: pollRunningScriptRun(run, automation: automation)
        case .agent: pollRunningAgentRun(run, automation: automation)
        }
    }

    private func pollRunningScriptRun(_ run: AutomationRun, automation: Automation) {
        do {
            guard let sessionID = run.terminalSessionID else { return }
            let runtimeState = try? terminalRuntimeState(sessionID: sessionID)
            let isInteractive = runtimeState?.state.isInteractive == true
            // Launch-persistence grace: just after a successful launch the runtime row can be absent/stale under
            // write-behind persistence (post-#224), so a nil runtime state within the launch-pending window is
            // the session still coming up, not completion.
            let launchPending = runtimeState == nil && orchestrator.automationSessionLaunchIsPending(sessionID: sessionID)
            // A completed script beats the timeout: the exit-code sentinel is authored by the wrapped command at
            // its own exit and written synchronously, while the exited runtime row is write-behind and can still
            // read interactive when the timeout tick lands. A present sentinel is therefore completion evidence
            // that outranks a stale interactive (or not-yet-landed) runtime row — it must never be killed and
            // recorded `.timedOut` after finishing within budget. Read once here so both the timeout guard below
            // (which it suppresses) and the completion branch (which it satisfies) see the same evidence.
            let exitCode = readExitCode(runID: run.id)

            // Timeout: the budget elapsed while the session is still live (interactive) OR still within the
            // launch-persistence grace (nil runtime + launch pending). Covering the pending case keeps a short
            // timeout from silently stretching toward the 60s pending window: a launch whose runtime row never
            // lands is torn down and recorded `.timedOut` on time rather than surviving to a later `.failed`
            // completion that skipped teardown. Suppressed by a present sentinel (completion won the race).
            if exitCode == nil, let timeoutSeconds = automation.timeoutSeconds, let startedAt = run.startedAt,
                now().timeIntervalSince(startedAt) >= TimeInterval(timeoutSeconds), isInteractive || launchPending
            {
                try teardownRunSessions(run, terminate: true)
                try finishRun(run, status: .timedOut, exitCode: nil)
                return
            }

            // Still launch-pending with no completion evidence: indeterminate, so wait for the next tick rather
            // than falsely failing a just-launched run. Only a nil state OUTSIDE the pending window is a vanished
            // session (bounded by the 60s pending window) that finalizes below.
            if exitCode == nil, launchPending { return }

            // Completion: a present sentinel, an ended (non-interactive) session, or a vanished runtime row.
            if exitCode != nil || runtimeState == nil || !isInteractive {
                // A nil runtime row past the grace with no sentinel is a session that vanished before its runtime
                // row landed — and the row may never land while the process is still live. Tear the session down
                // before finalizing so a live-but-unrecorded process is not orphaned (a run may never finalize
                // while a session it launched is still live). A sentinel or an exited runtime row means the
                // command already ended, so those paths need no teardown.
                if exitCode == nil, runtimeState == nil { try teardownRunSessions(run, terminate: true) }
                try finishRun(run, status: exitCode == 0 ? .succeeded : .failed, exitCode: exitCode)
            }
        } catch { logError("automation_poll_run_error run=\(run.id) error=\(error)") }
    }

    /// Detection deadline for an agent-kind run: how long to wait for the daemon's foreground classifier to
    /// identify the coding agent before failing the run. Matches the interactive `agent spawn` default (90s).
    private static let agentDetectionDeadline: TimeInterval = 90

    /// Drives an agent-kind run through its two phases, both derived from the run row so a restart resumes
    /// deterministically: `promptDeliveredAt == nil` is the detecting/sending phase, otherwise the run is
    /// awaiting the agent's `done` signal or its session end. The timeout budget applies to the agent
    /// session in either phase (torn down via the agent-kill flow).
    private func pollRunningAgentRun(_ run: AutomationRun, automation: Automation) {
        do {
            guard let sessionID = run.terminalSessionID else { return }
            let sessionLive = orchestrator.automationSessionIsLive(sessionID: sessionID)

            if let timeoutSeconds = automation.timeoutSeconds, let startedAt = run.startedAt,
                now().timeIntervalSince(startedAt) >= TimeInterval(timeoutSeconds), sessionLive
            {
                // An observed completion wins over the timeout: the timeout exists to reap hung agents, not
                // to reclassify finished work. A done agent's session deliberately stays live, so an agent
                // whose row already recorded `.done` before its deadline — but whose next tick lands after it
                // — is finished as `.succeeded` by the awaiting-phase handler below rather than killed and
                // recorded `.timedOut`.
                let agentDone = try store.agentWindowByTerminalSession(terminalSessionID: sessionID)?.status == .done
                if !agentDone {
                    try teardownAgentRunSession(run)
                    try finishRun(run, status: .timedOut, exitCode: nil)
                    return
                }
            }

            if run.promptDeliveredAt == nil {
                try pollAgentDetectionPhase(run, automation: automation, sessionID: sessionID, sessionLive: sessionLive)
            } else {
                try pollAgentAwaitingPhase(run, sessionID: sessionID, sessionLive: sessionLive)
            }
        } catch { logError("automation_poll_run_error run=\(run.id) error=\(error)") }
    }

    /// Detecting/sending phase (`promptDeliveredAt == nil`): wait for foreground detection, then deliver the
    /// seed prompt. A session that ends before delivery fails the run (the agent never received its work). A
    /// detection deadline miss also fails the run but leaves the session running for inspection (mirrors
    /// `spaces agent spawn`, which reports a detection timeout without killing the session).
    private func pollAgentDetectionPhase(_ run: AutomationRun, automation: Automation, sessionID: String, sessionLive: Bool) throws {
        guard sessionLive else {
            // Launch-persistence grace: just after a spawn the runtime row can be absent/stale under write-behind
            // persistence (post-#224), so `sessionLive` (which reads that row) reads false even though the session
            // is still coming up. Treat a not-yet-landed launch as still detecting — the next tick re-checks —
            // rather than failing the run. The detection deadline below remains the overall bound.
            if orchestrator.automationSessionLaunchIsPending(sessionID: sessionID) { return }
            try finishRun(run, status: .failed, exitCode: nil)
            return
        }
        if let startedAt = run.startedAt, now().timeIntervalSince(startedAt) >= Self.agentDetectionDeadline {
            logError("automation_agent_detection_timeout run=\(run.id) session=\(sessionID)")
            try finishRun(run, status: .failed, exitCode: nil)
            return
        }
        let runtimeState = try? terminalRuntimeState(sessionID: sessionID)
        guard runtimeState?.foregroundDetectedAgentKind != nil else { return }
        try deliverAgentPrompt(run, automation: automation, sessionID: sessionID)
    }

    /// Delivers the agent's seed prompt as one submit-send (`appendNewline: true`): the session host's send
    /// chokepoint writes the text and a separate, spaced Enter keystroke, which every supported agent TUI
    /// (Claude Code, Codex, OpenCode) reads as a real submit — a client-side follow-up CR write would land
    /// inline within the paste burst and is exactly what OpenCode leaves unsubmitted (issue #187). The
    /// prompt is sent verbatim (nothing stripped). `promptDeliveredAt` is persisted only after the write
    /// succeeds, so a restart or a failed write retries the whole send rather than resuming into a
    /// never-submitted prompt.
    private func deliverAgentPrompt(_ run: AutomationRun, automation: Automation, sessionID: String) throws {
        guard let prompt = automation.agentPrompt else { return }
        try orchestrator.writeAutomationSessionInput(sessionID: sessionID, input: .text(prompt), appendNewline: true)
        try store.updateAutomationRun(
            id: run.id, status: .running, skipReason: nil, exitCode: nil, terminalSessionID: sessionID, startedAt: run.startedAt, endedAt: nil,
            promptDeliveredAt: now())
    }

    /// Awaiting phase (`promptDeliveredAt != nil`): the run completes on the first of — the agent row
    /// signaling `done` (→ succeeded, the session is deliberately left open, never killed), or the session
    /// ending. On session end the status comes from the recorded exit status when the platform provides one:
    /// the embedded terminal backend records a `.failed` end state on a launch/crash failure (→ failed) but
    /// no numeric exit code for a normal exit. When no failure is recorded, a session that ended after a
    /// successful prompt delivery is treated as succeeded, since a deliberate close is the common case.
    private func pollAgentAwaitingPhase(_ run: AutomationRun, sessionID: String, sessionLive: Bool) throws {
        if let agent = try store.agentWindowByTerminalSession(terminalSessionID: sessionID), agent.status == .done {
            try finishRun(run, status: .succeeded, exitCode: nil)
            return
        }
        guard !sessionLive else { return }
        let recordedFailure = (try? terminalRuntimeState(sessionID: sessionID))?.state == .failed
        try finishRun(run, status: recordedFailure ? .failed : .succeeded, exitCode: nil)
    }

    /// Timeout/cancel teardown for an agent-kind run: kill the agent session through the agent-kill flow so
    /// its subscribers get their exited notice and the agent row is finalized. `killAgentSession` also
    /// handles a not-yet-signaled `.agent` session (no row yet) by terminating it directly; only if it
    /// recognizes neither do we fall back to a plain session termination. The killed session's transcript is
    /// not copied anywhere: the session itself survives, frozen and replayable, until the run is pruned.
    private func teardownAgentRunSession(_ run: AutomationRun) throws {
        guard let sessionID = run.terminalSessionID else { return }
        if try !orchestrator.killAgentSession(terminalSessionID: sessionID) { orchestrator.automationTerminateSession(sessionID: sessionID) }
    }

    /// Promotes each automation's single pending queued run to running once no run of that automation is
    /// still running.
    private func promoteQueuedRuns() {
        do {
            let queuedAutomationIDs = Set(try store.runningAutomationRuns().map(\.automationID))
            // Any automation that has a queued run but no running run is ready to promote. Enumerate
            // automations (cheap) rather than tracking a separate index.
            for automation in try store.automations() {
                guard !queuedAutomationIDs.contains(automation.id) else { continue }
                guard try !store.activeAutomationRuns(automationID: automation.id).contains(where: { $0.status == .running }) else { continue }
                guard let queued = try store.queuedAutomationRun(automationID: automation.id) else { continue }
                guard !automationHasPendingTermination(automationID: automation.id) else { continue }
                // An agent automation's session outlives its run row, so a queued run waits for every
                // attributed session to end (not just for the running run row to clear) before promoting.
                if automation.kind == .agent, try automationHasLiveAttributedSession(automationID: automation.id) { continue }
                _ = try startRun(automation: automation, trigger: queued.trigger, promoting: queued)
            }
        } catch { logError("automation_promote_error error=\(error)") }
    }

    // MARK: - Cancellation

    /// Cancels a run, recorded `canceled`. A script-kind run gets the same teardown as a timeout (terminate
    /// attributed sessions, signal the command process group); an agent-kind run is torn down
    /// through the agent-kill flow so its subscribers are notified and the agent row finalized. A run whose
    /// automation was deleted out from under it falls back to the plain-session teardown. A no-op for an
    /// already-terminal run. Teardown/finalization failures propagate so the command surface
    /// (`cancelAutomationRun`) surfaces them; resilient internal callers use the log-only `cancelRun`.
    @discardableResult private func cancelRunThrowing(runID: String) throws -> AutomationRun? {
        guard let run = try store.automationRun(id: runID), !run.status.isTerminal else { return nil }
        if try store.automation(id: run.automationID)?.kind == .agent {
            try teardownAgentRunSession(run)
        } else {
            try teardownRunSessions(run, terminate: true)
        }
        return try finishRun(run, status: .canceled, exitCode: nil)
    }

    /// Log-only wrapper around the cancel core for resilient scheduler-side callers — the delete path (which
    /// best-effort cancels every running run before tearing the automation down) — where one run's teardown
    /// failure must not abort the surrounding sweep. Command-surface cancels go through `cancelAutomationRun`.
    public func cancelRun(runID: String) { queue.sync { cancelRunLocked(runID: runID) } }

    private func cancelRunLocked(runID: String) {
        do { try cancelRunThrowing(runID: runID) } catch { logError("automation_cancel_error run=\(runID) error=\(error)") }
    }

    // MARK: - Run finalization + teardown

    /// Records a run's terminal status and prunes retention for its automation. Any SIGKILL escalation a
    /// timeout/cancel registered is tracked separately in `pendingKills` (keyed by run id) and continues
    /// on later ticks regardless of the now-terminal run status.
    @discardableResult private func finishRun(_ run: AutomationRun, status: AutomationRunStatus, exitCode: Int?) throws -> AutomationRun {
        let endedAt = now()
        try store.updateAutomationRun(
            id: run.id, status: status, skipReason: nil, exitCode: exitCode, terminalSessionID: run.terminalSessionID, startedAt: run.startedAt,
            endedAt: endedAt, promptDeliveredAt: run.promptDeliveredAt)
        try pruneRetention(automationID: run.automationID)
        // Return the finalized row constructed from exactly what was just persisted, NOT a re-fetch: finalizing
        // an old run can make it immediately prunable (enough newer terminal runs already exist), so its row
        // may no longer be in the store. This is the run's accurate final state (mirrors `endAttributedAgents`,
        // which returns its captured local value for the same pruning reason).
        return AutomationRun(
            id: run.id, automationID: run.automationID, kind: run.kind, status: status, skipReason: nil, trigger: run.trigger, exitCode: exitCode,
            terminalSessionID: run.terminalSessionID, startedAt: run.startedAt, endedAt: endedAt, createdAt: run.createdAt,
            promptDeliveredAt: run.promptDeliveredAt)
    }

    /// Teardown for a timeout/cancel: terminate + finalize the run's still-live coding-agent sessions, then
    /// signal the run's own command process group so the command stops. The command's process group gets
    /// SIGTERM now and SIGKILL after the grace via `processPendingKills`.
    private func teardownRunSessions(_ run: AutomationRun, terminate: Bool) throws {
        let ownSessionID = run.terminalSessionID
        let attributedSessionIDs = try store.terminalSessionIDs(automationRunID: run.id).filter { $0 != ownSessionID }
        for sessionID in attributedSessionIDs where orchestrator.automationSessionIsLive(sessionID: sessionID) {
            orchestrator.automationTerminateSession(sessionID: sessionID)
            try finalizeAttributedAgentRow(sessionID: sessionID)
        }

        guard terminate, let ownSessionID else { return }
        if let runtimeState = try? terminalRuntimeState(sessionID: ownSessionID), let childPID = runtimeState.childPID, childPID > 0 {
            // Preferred path: signal the command's own process group so the transcript keeps flowing until the
            // command exits (the session host stays up and drains output), with SIGKILL escalation tracked in
            // `pendingKills`. The group id is read ONCE, before SIGTERM: a leader that dies on the signal would
            // make a second getpgid fail, storing no group and dropping the escalation while a SIGTERM-ignoring
            // descendant survives. The signal and the pending kill must see the same group.
            let processGroupID = signalableProcessGroupID(childPID: childPID)
            signalProcessGroup(childPID: childPID, processGroupID: processGroupID, signal: SIGTERM)
            pendingKills[run.id] = PendingKill(
                automationID: run.automationID, childPID: childPID, processGroupID: processGroupID,
                sigkillDeadline: now().addingTimeInterval(terminationGrace))
        } else {
            // Fallback for the no-PID window: under write-behind persistence the runtime row (or its childPID)
            // can be absent while the session is genuinely live — a cancel, or a short timeout expiring while
            // the session is still starting. Terminating the whole session through the daemon's machinery kills
            // its process tree, so a run finalized canceled/timedOut can never leave its own session running.
            orchestrator.automationTerminateSession(sessionID: ownSessionID)
        }
    }

    /// Sweeps the prior runs of an automation when a new run starts: for each attributed coding-agent
    /// session whose terminal has ENDED (never a live one), finalize its agent row so no orchestration state
    /// (agent row, tracked window, workspace running flag) leaks from a session nothing will ever revive.
    ///
    /// The session itself is deliberately left in place, rows and directory both. Its run is still listed in
    /// the Runs tab and offers a read-only replay, so the session is the replay source and must survive until
    /// its run does; retention pruning and automation deletion are the only paths that remove it.
    private func sweepPriorRunSessions(automationID: String, excludingRunID: String) {
        do {
            for priorRun in try store.automationRuns(automationID: automationID) where priorRun.id != excludingRunID {
                let ownSessionID = priorRun.terminalSessionID
                for sessionID in try store.terminalSessionIDs(automationRunID: priorRun.id) where sessionID != ownSessionID {
                    guard !orchestrator.automationSessionIsLive(sessionID: sessionID) else { continue }
                    try finalizeAttributedAgentRow(sessionID: sessionID)
                }
            }
        } catch { logError("automation_sweep_error automation=\(automationID) error=\(error)") }
    }

    /// Finalizes the coding-agent orchestration row bound to an attributed terminal session through the
    /// single termination chokepoint (`finalizeAgentRow`), so its subscribers are told it exited before its
    /// row is removed.
    ///
    /// Invariant: an ended attributed session must leave no workspace tracking behind, row or no row. A
    /// spawned agent session persists workspace-side state (a tracked terminal window plus the workspace
    /// marked running) at spawn time, before the foreground reconciler registers its agent row. A session
    /// that ends inside that window has no `AgentWindowRecord`, so `finalizeAgentRow` cannot reach it; left
    /// alone, its tracked window and running flag would leak past the sweep. For that row-less case route
    /// through `terminateSpawnedAgentTerminalSession` — the existing `.agent` cleanup seam shared with
    /// `agent kill` that drops the tracked window and clears the workspace's running flag when no runtime
    /// indicators remain. Its terminate call is a harmless no-op here: the sweep only reaches ended sessions,
    /// and teardown has already terminated the live one.
    private func finalizeAttributedAgentRow(sessionID: String) throws {
        guard let agent = try store.agentWindowByTerminalSession(terminalSessionID: sessionID) else {
            _ = try orchestrator.terminateSpawnedAgentTerminalSession(sessionID: sessionID)
            return
        }
        try orchestrator.finalizeAgentRow(agent, reason: .destroyed(terminateTerminalSession: false))
    }

    // MARK: - Retention

    /// Prunes an automation's terminal runs beyond the newest `retentionLimit`, deleting each pruned run's
    /// artifacts, its attributed terminal-session directories/rows, and the run row itself. Live
    /// (queued/running) runs are never eligible.
    ///
    /// This is the product-side bound on how long a run's terminals stay replayable: a run's sessions are
    /// held against the daemon's session garbage collector by their `automation_run_id` stamp, so they live
    /// exactly as long as the run row unless the collector's global ended-session limits (age, disk budget)
    /// expire them first.
    ///
    /// A prunable run whose attributed agent session is STILL live is skipped and stays retained past the
    /// cap. `deleteRunArtifactsAndSessions` terminates any live session before removing its records, so
    /// pruning such a run would kill a running coding agent — violating the product guarantee that no
    /// automation kills a live coding agent on its own (a succeeded agent-kind run deliberately leaves its
    /// agent open). The skipped run is removed by a later prune once its session ends, or immediately when
    /// the user runs End agents; deletion of the whole automation stays terminating because it is
    /// user-initiated.
    private func pruneRetention(automationID: String) throws {
        for runID in try store.prunableAutomationRunIDs(automationID: automationID, keeping: retentionLimit) {
            if try runHasLiveAttributedSession(runID: runID) { continue }
            try deleteRunArtifactsAndSessions(runID: runID)
            try store.deleteAutomationRun(id: runID)
        }
    }

    /// Whether any terminal session attributed to a single run is still live.
    private func runHasLiveAttributedSession(runID: String) throws -> Bool {
        for sessionID in try store.terminalSessionIDs(automationRunID: runID) where orchestrator.automationSessionIsLive(sessionID: sessionID) {
            return true
        }
        return false
    }

    private func deleteRunArtifactsAndSessions(runID: String) throws {
        let sessionIDs = try store.terminalSessionIDs(automationRunID: runID)
        for sessionID in sessionIDs {
            // A live session must be terminated before its persistence is removed, so deleting a run's records
            // can never orphan a running process: a succeeded agent-kind run deliberately leaves its agent
            // session live, and dropping its rows/directories without ending it would leave that process running
            // but unreachable through the product.
            if orchestrator.automationSessionIsLive(sessionID: sessionID) { orchestrator.automationTerminateSession(sessionID: sessionID) }
            // Finalize the attributed agent row for BOTH the just-terminated live session and an already-ended
            // one: an agent session that ended before the foreground reconciler registered its row still holds
            // spawn-time workspace tracking (a tracked terminal window plus the workspace-running flag), which
            // `finalizeAttributedAgentRow`'s row-less fallback releases. Deleting the session rows/files without
            // it would leak that tracking permanently — no later sweep can reach the gone rows.
            try finalizeAttributedAgentRow(sessionID: sessionID)
            try store.deleteTerminalSession(sessionID: sessionID)
            if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                try? FileManager.default.removeItem(atPath: paths.rootDirectory)
                try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
                try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
            }
        }
        if let runDirectory = try? AutomationPaths.runDirectory(runID: runID) { try? FileManager.default.removeItem(at: runDirectory) }
    }

    // MARK: - Automation deletion

    /// Deletes an automation: cancels any running run through the cancel path, removes every run's artifacts
    /// and attributed sessions, then deletes the automation row (its run rows cascade away). Throws when the
    /// deletion cannot complete, so the command surface (`deleteAutomationCommand`) reports the failure
    /// instead of leaving the automation row — and its cron schedule — in place while reporting success. Each
    /// running run's cancel stays best-effort (the log-only `cancelRun`) so one stuck teardown does not abort
    /// the surrounding deletion.
    public func deleteAutomation(id: String) throws { try queue.sync { try deleteAutomationLocked(id: id) } }

    private func deleteAutomationLocked(id: String) throws {
        for run in try store.activeAutomationRuns(automationID: id) where run.status == .running { cancelRunLocked(runID: run.id) }
        for run in try store.automationRuns(automationID: id) { try deleteRunArtifactsAndSessions(runID: run.id) }
        try store.deleteAutomation(id: id)
    }

    // MARK: - Process control

    /// Reads a session's runtime state, or nil when none is persisted.
    private func terminalRuntimeState(sessionID: String) throws -> TerminalSessionRuntimeState? {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        return try? TerminalSessionPersistence.readRuntimeState(paths: paths)
    }

    private func readExitCode(runID: String) -> Int? {
        guard let path = try? AutomationPaths.exitCodePath(runID: runID).path, let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        return Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func processPendingKills() {
        let currentTime = now()
        for (runID, pending) in pendingKills {
            if !pendingKillIsOutstanding(pending) {
                pendingKills.removeValue(forKey: runID)
                continue
            }
            if currentTime >= pending.sigkillDeadline {
                escalateToSIGKILL(pending)
                pendingKills.removeValue(forKey: runID)
            }
        }
    }

    /// A pending kill stays outstanding while EITHER the group leader OR (when a group was captured) any
    /// process in that group is still alive. The group check is what keeps the escalation armed after the
    /// shell leader exits but a descendant that ignored SIGTERM is still running — otherwise the leader's
    /// death would drop the pending kill and leave the survivor running.
    private func pendingKillIsOutstanding(_ pending: PendingKill) -> Bool {
        if Self.isProcessAlive(pid: pending.childPID) { return true }
        guard let processGroupID = pending.processGroupID else { return false }
        return Self.isProcessGroupAlive(processGroupID: processGroupID)
    }

    /// SIGKILLs the captured process group (guarded against the daemon's own group) and the leader pid. The
    /// group id is the one captured at SIGTERM time and is never recomputed here: by escalation time the
    /// leader may be gone, so `getpgid(childPID)` could fail or name a reused pid's group.
    private func escalateToSIGKILL(_ pending: PendingKill) {
        if let processGroupID = pending.processGroupID, processGroupID != getpgrp() { kill(-processGroupID, SIGKILL) }
        kill(pending.childPID, SIGKILL)
    }

    /// Signals a command's process group (and the leader itself). `processGroupID` is the caller's
    /// already-captured `signalableProcessGroupID` — passed in rather than recomputed so the signaled group
    /// and the one stored for SIGKILL escalation can never diverge.
    private func signalProcessGroup(childPID: Int32, processGroupID: Int32?, signal signalNumber: Int32) {
        if let processGroupID { kill(-processGroupID, signalNumber) }
        kill(childPID, signalNumber)
    }

    /// The child's process group id when it is safe to signal as a group — the child is its own group leader
    /// and that group is not the daemon's own — matching `signalProcessGroup`'s guard; nil otherwise. Read
    /// once at SIGTERM time and stored so escalation never has to recompute it after the leader exits.
    private func signalableProcessGroupID(childPID: Int32) -> Int32? {
        let processGroupID = getpgid(childPID)
        guard processGroupID > 0, processGroupID == childPID, processGroupID != getpgrp() else { return nil }
        return processGroupID
    }

    private static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Whether any process remains in a process group. A group persists as long as one member is alive, even
    /// after its leader (the process whose pid equals the group id) has exited.
    private static func isProcessGroupAlive(processGroupID: Int32) -> Bool {
        guard processGroupID > 0 else { return false }
        if kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }
}
