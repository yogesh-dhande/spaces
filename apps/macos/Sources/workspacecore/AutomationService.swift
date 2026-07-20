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
/// depends on background tasks. Runs on the daemon main actor.
@MainActor public final class AutomationService {
    private let store: SQLiteStore
    private let orchestrator: WorkspaceOrchestrator
    /// Prepended to the automation command's PATH so `spaces` resolves to the running daemon's sibling CLI.
    private let binaryDirectory: String
    private let timeZone: TimeZone
    private let now: () -> Date
    /// Grace between the SIGTERM sent to a timed-out/canceled run's command process group and the SIGKILL
    /// that follows if it has not exited. Production uses 10s; tests shrink it to exercise escalation fast.
    private let terminationGrace: TimeInterval
    /// Newest runs kept per automation; older terminal runs are pruned with their artifacts.
    private let retentionLimit: Int
    private let logError: (String) -> Void

    /// Command processes signaled during a timeout/cancel teardown, awaiting SIGKILL escalation. Keyed by
    /// run id so escalation continues on later ticks even after the run row reached its terminal status.
    private struct PendingKill {
        let childPID: Int32
        let sigkillDeadline: Date
    }
    private var pendingKills: [String: PendingKill] = [:]

    public init(
        store: SQLiteStore, orchestrator: WorkspaceOrchestrator, binaryDirectory: String, timeZone: TimeZone = .current,
        now: @escaping () -> Date = Date.init, terminationGrace: TimeInterval = 10, retentionLimit: Int = 100,
        logError: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.orchestrator = orchestrator
        self.binaryDirectory = binaryDirectory
        self.timeZone = timeZone
        self.now = now
        self.terminationGrace = terminationGrace
        self.retentionLimit = retentionLimit
        self.logError = logError
    }

    // MARK: - Scheduling entry points

    /// Establishes a newly created or re-enabled cron automation's next fire time from now, with no
    /// backfill of occurrences that fell before this moment.
    public func computeInitialNextFireTime(automationID: String) {
        do {
            guard let automation = try store.automation(id: automationID), automation.enabled, let schedule = automation.parsedCronSchedule else {
                return
            }
            try store.setAutomationNextFireTime(id: automationID, nextFireTime: schedule.nextFireDate(after: now(), timeZone: timeZone))
        } catch { logError("automation_next_fire_time_error id=\(automationID) error=\(error)") }
    }

    /// One scheduler + executor step: fire due cron automations, advance escalations, poll running runs for
    /// completion/timeout, and promote a queued run whose automation is now idle. Idempotent per minute:
    /// a cron automation fires once when its `nextFireTime` elapses because firing recomputes it forward.
    public func tick() {
        fireDueCronAutomations()
        processPendingKills()
        pollRunningRuns()
        promoteQueuedRuns()
    }

    /// Daemon-start reconciliation: for each enabled cron automation whose persisted `nextFireTime` already
    /// elapsed while the daemon was down, apply the missed-run policy exactly once (one catch-up run, or one
    /// skipped row), then recompute the next fire time from now. Automations with no elapsed anchor (freshly
    /// created, or whose next time is still in the future) are left untouched.
    public func reconcileMissedRunsOnStart() {
        let currentTime = now()
        do {
            for automation in try store.enabledCronAutomations() {
                guard let schedule = automation.parsedCronSchedule else { continue }
                if let nextFireTime = automation.nextFireTime, nextFireTime <= currentTime {
                    switch automation.missedRunPolicy {
                    case .runOnce: _ = fire(automation: automation, trigger: .missedCatchUp)
                    case .skip: _ = try recordSkippedRun(automation: automation, trigger: .missedCatchUp, reason: .missed)
                    }
                }
                try store.setAutomationNextFireTime(id: automation.id, nextFireTime: schedule.nextFireDate(after: currentTime, timeZone: timeZone))
            }
        } catch { logError("automation_missed_run_reconcile_error error=\(error)") }
    }

    /// Manual trigger entry point (tests today, Device API later). Fires through the same concurrency gate
    /// as cron. Returns the resulting run row (started, queued, or a skipped record), or nil when the
    /// automation is missing.
    @discardableResult public func triggerManually(automationID: String) -> AutomationRun? {
        do {
            guard let automation = try store.automation(id: automationID) else { return nil }
            return fire(automation: automation, trigger: .manual)
        } catch {
            logError("automation_manual_trigger_error id=\(automationID) error=\(error)")
            return nil
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
    public func createAutomation(_ draft: AutomationDraft) throws -> Automation {
        let validated = try draft.validated()
        let timestamp = now()
        let automation = Automation(
            id: UUID().uuidString, name: validated.name, enabled: validated.enabled, triggerKind: validated.triggerKind,
            cronExpression: validated.cronExpression, kind: validated.kind, script: validated.script, agentCommand: validated.agentCommand,
            agentPrompt: validated.agentPrompt, workspaceID: validated.workspaceID, workingDirectory: validated.workingDirectory,
            timeoutSeconds: validated.timeoutSeconds, concurrencyPolicy: validated.concurrencyPolicy, missedRunPolicy: validated.missedRunPolicy,
            nextFireTime: nil, createdAt: timestamp, updatedAt: timestamp)
        try store.upsertAutomation(automation)
        try applyNextFireTime(automationID: automation.id, enabled: validated.enabled, triggerKind: validated.triggerKind)
        return try requireAutomation(id: automation.id)
    }

    /// Applies a validated draft to an existing automation (including enabling/disabling it), preserving its
    /// id and creation time. Its next fire time is recomputed from now for an enabled cron automation and
    /// cleared otherwise, so disabling or switching to manual removes a stale schedule anchor. Throws when
    /// the automation does not exist.
    public func updateAutomation(id: String, draft: AutomationDraft) throws -> Automation {
        let existing = try requireAutomation(id: id)
        let validated = try draft.validated()
        let automation = Automation(
            id: existing.id, name: validated.name, enabled: validated.enabled, triggerKind: validated.triggerKind,
            cronExpression: validated.cronExpression, kind: validated.kind, script: validated.script, agentCommand: validated.agentCommand,
            agentPrompt: validated.agentPrompt, workspaceID: validated.workspaceID, workingDirectory: validated.workingDirectory,
            timeoutSeconds: validated.timeoutSeconds, concurrencyPolicy: validated.concurrencyPolicy, missedRunPolicy: validated.missedRunPolicy,
            nextFireTime: nil, createdAt: existing.createdAt, updatedAt: now())
        try store.upsertAutomation(automation)
        try applyNextFireTime(automationID: automation.id, enabled: validated.enabled, triggerKind: validated.triggerKind)
        return try requireAutomation(id: automation.id)
    }

    public func listAutomations() throws -> [Automation] { try store.automations() }

    /// Runs for one automation (newest first) when `automationID` is given, or across every automation
    /// otherwise. Includes live (queued/running) runs, which sort to the top by their recent creation time.
    public func listAutomationRuns(automationID: String?) throws -> [AutomationRun] {
        if let automationID { return try store.automationRuns(automationID: automationID) }
        return try store.allAutomationRuns()
    }

    /// Manually fires an automation through the shared concurrency gate. Throws when the automation is
    /// missing so the boundary surfaces a clear error instead of a silent no-op.
    public func triggerAutomation(id: String) throws -> AutomationRun {
        let automation = try requireAutomation(id: id)
        guard let run = fire(automation: automation, trigger: .manual) else {
            throw AutomationValidationError("Failed to start a run for automation \(id).")
        }
        return run
    }

    /// Cancels a run, returning its resulting row. A terminal run is returned unchanged (idempotent).
    /// Throws when the run does not exist.
    public func cancelAutomationRun(runID: String) throws -> AutomationRun {
        let run = try requireAutomationRun(id: runID)
        guard !run.status.isTerminal else { return run }
        cancelRun(runID: runID)
        return try requireAutomationRun(id: runID)
    }

    /// Ends every still-live coding-agent session attributed to a TERMINAL run, returning the run row
    /// unchanged. This reaps the agent sessions a finished run left running — an `agent`-kind run whose agent
    /// signalled `done` (succeeded) deliberately leaves its session open, and this is how a client stops it
    /// on demand. The run's status, exit code, and timestamps are left untouched: end-agents cleans up
    /// lingering sessions, it does not re-finalize the run. A non-terminal (queued/running) run is rejected
    /// loudly — a live run is stopped with cancel, not end-agents. Each live attributed session is torn down
    /// through the exact seams cancel's agent teardown uses: capture the transcript, then the agent-kill flow
    /// (which finalizes the agent row and notifies subscribers), falling back to a plain session termination
    /// for a not-yet-signalled `.agent` session with no row.
    public func endAttributedAgents(runID: String) throws -> AutomationRun {
        let run = try requireAutomationRun(id: runID)
        guard run.status.isTerminal else {
            throw AutomationValidationError("Cannot end agents for automation run \(runID): it is still \(run.status.rawValue). Cancel it instead.")
        }
        for sessionID in try store.terminalSessionIDs(automationRunID: run.id) where orchestrator.automationSessionIsLive(sessionID: sessionID) {
            try captureAttributedTranscript(runID: run.id, sessionID: sessionID)
            if try !orchestrator.killAgentSession(terminalSessionID: sessionID) { orchestrator.automationTerminateSession(sessionID: sessionID) }
        }
        return try requireAutomationRun(id: runID)
    }

    /// Deletes an automation (cancelling any running run and cleaning up its artifacts and attributed
    /// sessions). Throws when the automation does not exist.
    public func deleteAutomationCommand(id: String) throws {
        _ = try requireAutomation(id: id)
        deleteAutomation(id: id)
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
            computeInitialNextFireTime(automationID: automationID)
        } else {
            try store.setAutomationNextFireTime(id: automationID, nextFireTime: nil)
        }
    }

    private func fireDueCronAutomations() {
        let currentTime = now()
        do {
            for automation in try store.enabledCronAutomations() {
                guard let schedule = automation.parsedCronSchedule, let nextFireTime = automation.nextFireTime, nextFireTime <= currentTime else {
                    continue
                }
                _ = fire(automation: automation, trigger: .cron)
                try store.setAutomationNextFireTime(id: automation.id, nextFireTime: schedule.nextFireDate(after: currentTime, timeZone: timeZone))
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
            let blocking = try running || (automation.kind == .agent && automationHasLiveAttributedSession(automationID: automation.id))
            switch automation.concurrencyPolicy {
            case .allow:
                return try startRun(automation: automation, trigger: trigger)
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

    private func recordSkippedRun(automation: Automation, trigger: AutomationRunTrigger, reason: AutomationRunSkipReason) throws -> AutomationRun {
        let currentTime = now()
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, status: .skipped, skipReason: reason, trigger: trigger, exitCode: nil,
            terminalSessionID: nil, startedAt: nil, endedAt: currentTime, createdAt: currentTime)
        try store.insertAutomationRun(run)
        try pruneRetention(automationID: automation.id)
        return run
    }

    private func enqueueRun(automation: Automation, trigger: AutomationRunTrigger) throws -> AutomationRun {
        let currentTime = now()
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, status: .queued, skipReason: nil, trigger: trigger, exitCode: nil,
            terminalSessionID: nil, startedAt: nil, endedAt: nil, createdAt: currentTime)
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
            id: runID, automationID: automation.id, status: .running, skipReason: nil, trigger: existing?.trigger ?? trigger, exitCode: nil,
            terminalSessionID: nil, startedAt: currentTime, endedAt: nil, createdAt: existing?.createdAt ?? currentTime)
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
        return run
    }

    /// Launches a script-kind run's workspace-less command session and records its terminal session id. A
    /// launch failure records the run `failed`.
    private func launchScriptRun(automation: Automation, runID: String, startedAt: Date) throws {
        let sessionID = UUID().uuidString
        do {
            try AutomationPaths.ensureRunDirectory(runID: runID)
            let command = try wrappedCommand(automation: automation, runID: runID)
            _ = try orchestrator.launchAutomationSession(
                runID: runID, sessionID: sessionID, title: automation.name, workingDirectory: automation.workingDirectory, command: command,
                environment: [WorkspaceOrchestrator.automationRunIDEnvVar: runID])
            try store.updateAutomationRun(
                id: runID, status: .running, skipReason: nil, exitCode: nil, terminalSessionID: sessionID, startedAt: startedAt, endedAt: nil,
                promptDeliveredAt: nil)
        } catch {
            logError("automation_launch_error run=\(runID) error=\(error)")
            try recordLaunchFailure(automationID: automation.id, runID: runID, startedAt: startedAt)
        }
    }

    /// Spawns an agent-kind run's coding agent into the automation's workspace, seeded (later) with its
    /// prompt. The spawned session IS the run's session — no wrapper terminal. The prompt is not sent here:
    /// `pollRunningAgentRun` waits for foreground detection first, then delivers it, so the tick never
    /// blocks. A missing workspace, an unsupported command, or a spawn error records the run `failed`
    /// through the same launch-failure path a script-launch error takes.
    private func launchAgentRun(automation: Automation, runID: String, startedAt: Date) throws {
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
            try store.updateAutomationRun(
                id: runID, status: .running, skipReason: nil, exitCode: nil, terminalSessionID: session.id, startedAt: startedAt, endedAt: nil,
                promptDeliveredAt: nil)
        } catch {
            logError("automation_agent_launch_error run=\(runID) error=\(error)")
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
        switch automation.kind {
        case .script: pollRunningScriptRun(run, automation: automation)
        case .agent: pollRunningAgentRun(run, automation: automation)
        }
    }

    private func pollRunningScriptRun(_ run: AutomationRun, automation: Automation) {
        do {
            guard let sessionID = run.terminalSessionID else { return }
            let runtimeState = try? terminalRuntimeState(sessionID: sessionID)

            // Timeout: elapsed budget exceeded while the command session is still live.
            if let timeoutSeconds = automation.timeoutSeconds, let startedAt = run.startedAt,
                now().timeIntervalSince(startedAt) >= TimeInterval(timeoutSeconds), let runtimeState, runtimeState.state.isInteractive
            {
                try teardownRunSessions(run, terminate: true)
                try finishRun(run, status: .timedOut, exitCode: nil)
                return
            }

            // Completion: the command session ended, so read the recorded exit code and finalize.
            if runtimeState == nil || runtimeState?.state.isInteractive == false {
                let exitCode = readExitCode(runID: run.id)
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
    /// session in either phase (capture-then-kill via the agent-kill flow).
    private func pollRunningAgentRun(_ run: AutomationRun, automation: Automation) {
        do {
            guard let sessionID = run.terminalSessionID else { return }
            let sessionLive = orchestrator.automationSessionIsLive(sessionID: sessionID)

            if let timeoutSeconds = automation.timeoutSeconds, let startedAt = run.startedAt,
                now().timeIntervalSince(startedAt) >= TimeInterval(timeoutSeconds), sessionLive
            {
                try teardownAgentRunSession(run)
                try finishRun(run, status: .timedOut, exitCode: nil)
                return
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

    /// Delivers the agent's seed prompt as TWO independent writes — the prompt text, then a separate CR
    /// (byte 13). This is the provider-neutral submit: a single write with a trailing CR is exactly what
    /// OpenCode leaves unsubmitted (issue #187), so the CR is always its own write. The prompt is sent
    /// verbatim (nothing stripped). `promptDeliveredAt` is persisted only after the CR write succeeds, so a
    /// restart or a partial write retries the whole send rather than resuming into a never-submitted prompt.
    private func deliverAgentPrompt(_ run: AutomationRun, automation: Automation, sessionID: String) throws {
        guard let prompt = automation.agentPrompt else { return }
        try orchestrator.writeAutomationSessionInput(sessionID: sessionID, input: .text(prompt))
        try orchestrator.writeAutomationSessionInput(sessionID: sessionID, input: .bytes(Data([0x0D])))
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

    /// Timeout/cancel teardown for an agent-kind run: capture the agent session's transcript, then kill it
    /// through the agent-kill flow so its subscribers get their exited notice and the agent row is finalized.
    /// `killAgentSession` also handles a not-yet-signaled `.agent` session (no row yet) by terminating it
    /// directly; only if it recognizes neither do we fall back to a plain session termination.
    private func teardownAgentRunSession(_ run: AutomationRun) throws {
        guard let sessionID = run.terminalSessionID else { return }
        if orchestrator.automationSessionIsLive(sessionID: sessionID) { try captureAttributedTranscript(runID: run.id, sessionID: sessionID) }
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
                // An agent automation's session outlives its run row, so a queued run waits for every
                // attributed session to end (not just for the running run row to clear) before promoting.
                if automation.kind == .agent, try automationHasLiveAttributedSession(automationID: automation.id) { continue }
                _ = try startRun(automation: automation, trigger: queued.trigger, promoting: queued)
            }
        } catch { logError("automation_promote_error error=\(error)") }
    }

    // MARK: - Cancellation

    /// Cancels a run, recorded `canceled`. A script-kind run gets the same teardown as a timeout (capture +
    /// terminate attributed sessions, signal the command process group); an agent-kind run is torn down
    /// through the agent-kill flow so its subscribers are notified and the agent row finalized. A run whose
    /// automation was deleted out from under it falls back to the plain-session teardown. A no-op for an
    /// already-terminal run.
    public func cancelRun(runID: String) {
        do {
            guard let run = try store.automationRun(id: runID), !run.status.isTerminal else { return }
            if try store.automation(id: run.automationID)?.kind == .agent {
                try teardownAgentRunSession(run)
            } else {
                try teardownRunSessions(run, terminate: true)
            }
            try finishRun(run, status: .canceled, exitCode: nil)
        } catch { logError("automation_cancel_error run=\(runID) error=\(error)") }
    }

    // MARK: - Run finalization + teardown

    /// Records a run's terminal status and prunes retention for its automation. Any SIGKILL escalation a
    /// timeout/cancel registered is tracked separately in `pendingKills` (keyed by run id) and continues
    /// on later ticks regardless of the now-terminal run status.
    private func finishRun(_ run: AutomationRun, status: AutomationRunStatus, exitCode: Int?) throws {
        try store.updateAutomationRun(
            id: run.id, status: status, skipReason: nil, exitCode: exitCode, terminalSessionID: run.terminalSessionID, startedAt: run.startedAt,
            endedAt: now(), promptDeliveredAt: run.promptDeliveredAt)
        try pruneRetention(automationID: run.automationID)
    }

    /// Teardown for a timeout/cancel: capture + terminate + finalize the run's still-live coding-agent
    /// sessions, then signal the run's own command process group so the command stops. The command's
    /// process group gets SIGTERM now and SIGKILL after the grace via `processPendingKills`.
    private func teardownRunSessions(_ run: AutomationRun, terminate: Bool) throws {
        let ownSessionID = run.terminalSessionID
        let attributedSessionIDs = try store.terminalSessionIDs(automationRunID: run.id).filter { $0 != ownSessionID }
        for sessionID in attributedSessionIDs where orchestrator.automationSessionIsLive(sessionID: sessionID) {
            try captureAttributedTranscript(runID: run.id, sessionID: sessionID)
            orchestrator.automationTerminateSession(sessionID: sessionID)
            try finalizeAttributedAgentRow(sessionID: sessionID)
        }

        guard terminate, let ownSessionID else { return }
        if let runtimeState = try? terminalRuntimeState(sessionID: ownSessionID), let childPID = runtimeState.childPID, childPID > 0 {
            signalProcessGroup(childPID: childPID, signal: SIGTERM)
            pendingKills[run.id] = PendingKill(childPID: childPID, sigkillDeadline: now().addingTimeInterval(terminationGrace))
        }
    }

    /// Sweeps the prior runs of an automation when a new run starts: for each attributed coding-agent
    /// session whose terminal has ENDED (never a live one), capture its transcript if not already captured,
    /// finalize its agent row, and remove the ended session from the product.
    private func sweepPriorRunSessions(automationID: String, excludingRunID: String) {
        do {
            for priorRun in try store.automationRuns(automationID: automationID) where priorRun.id != excludingRunID {
                let ownSessionID = priorRun.terminalSessionID
                for sessionID in try store.terminalSessionIDs(automationRunID: priorRun.id) where sessionID != ownSessionID {
                    guard !orchestrator.automationSessionIsLive(sessionID: sessionID) else { continue }
                    try captureAttributedTranscript(runID: priorRun.id, sessionID: sessionID)
                    try finalizeAttributedAgentRow(sessionID: sessionID)
                    try removeEndedSession(sessionID: sessionID)
                }
            }
        } catch { logError("automation_sweep_error automation=\(automationID) error=\(error)") }
    }

    /// Copies a coding-agent session's `output.log` into the run's artifacts directory as
    /// `agent-<sessionID>.log`, unless it was already captured. Missing output is not an error.
    private func captureAttributedTranscript(runID: String, sessionID: String) throws {
        let destination = try AutomationPaths.attributedSessionLogPath(runID: runID, sessionID: sessionID)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let sourcePath = try TerminalSessionPaths.forSession(id: sessionID).outputPath
        guard FileManager.default.fileExists(atPath: sourcePath) else { return }
        try AutomationPaths.ensureRunDirectory(runID: runID)
        try FileManager.default.copyItem(atPath: sourcePath, toPath: destination.path)
    }

    /// Finalizes the coding-agent orchestration row bound to an attributed terminal session through the
    /// single termination chokepoint (`finalizeAgentRow`), so its subscribers are told it exited before its
    /// row is removed. A session with no agent row (e.g. a plain automation command) is left untouched.
    private func finalizeAttributedAgentRow(sessionID: String) throws {
        guard let agent = try store.agentWindowByTerminalSession(terminalSessionID: sessionID) else { return }
        try orchestrator.finalizeAgentRow(agent, reason: .destroyed(terminateTerminalSession: false))
    }

    /// Removes an ended attributed session from the product: its terminal-session row and its session
    /// directory. Only ever called for sessions confirmed ended by the sweep.
    private func removeEndedSession(sessionID: String) throws {
        try store.deleteTerminalSession(sessionID: sessionID)
        if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
            try? FileManager.default.removeItem(atPath: paths.rootDirectory)
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
            try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
        }
    }

    // MARK: - Retention

    /// Prunes an automation's terminal runs beyond the newest `retentionLimit`, deleting each pruned run's
    /// artifacts, its attributed terminal-session directories/rows, and the run row itself. Live
    /// (queued/running) runs are never eligible.
    private func pruneRetention(automationID: String) throws {
        for runID in try store.prunableAutomationRunIDs(automationID: automationID, keeping: retentionLimit) {
            try deleteRunArtifactsAndSessions(runID: runID)
            try store.deleteAutomationRun(id: runID)
        }
    }

    private func deleteRunArtifactsAndSessions(runID: String) throws {
        for sessionID in try store.terminalSessionIDs(automationRunID: runID) {
            try store.deleteTerminalSession(sessionID: sessionID)
            if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                try? FileManager.default.removeItem(atPath: paths.rootDirectory)
                try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
                try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
            }
        }
        if let runDirectory = try? AutomationPaths.runDirectory(runID: runID) {
            try? FileManager.default.removeItem(at: runDirectory)
        }
    }

    // MARK: - Automation deletion

    /// Deletes an automation: cancels any running run through the cancel path, removes every run's artifacts
    /// and attributed sessions, then deletes the automation row (its run rows cascade away).
    public func deleteAutomation(id: String) {
        do {
            for run in try store.activeAutomationRuns(automationID: id) where run.status == .running { cancelRun(runID: run.id) }
            for run in try store.automationRuns(automationID: id) { try deleteRunArtifactsAndSessions(runID: run.id) }
            try store.deleteAutomation(id: id)
        } catch { logError("automation_delete_error id=\(id) error=\(error)") }
    }

    // MARK: - Process control

    /// Reads a session's runtime state, or nil when none is persisted.
    private func terminalRuntimeState(sessionID: String) throws -> TerminalSessionRuntimeState? {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        return try? TerminalSessionPersistence.readRuntimeState(paths: paths)
    }

    private func readExitCode(runID: String) -> Int? {
        guard let path = try? AutomationPaths.exitCodePath(runID: runID).path,
            let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        return Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func processPendingKills() {
        let currentTime = now()
        for (runID, pending) in pendingKills {
            if !Self.isProcessAlive(pid: pending.childPID) {
                pendingKills.removeValue(forKey: runID)
                continue
            }
            if currentTime >= pending.sigkillDeadline {
                signalProcessGroup(childPID: pending.childPID, signal: SIGKILL)
                pendingKills.removeValue(forKey: runID)
            }
        }
    }

    /// Signals a command's process group (and the leader itself). Only signals the group when the child is
    /// its own group leader and that group is not the daemon's own — the same guard the PTY driver uses, so
    /// a session whose child did not become a group leader never sends a signal to the daemon's group.
    private func signalProcessGroup(childPID: Int32, signal signalNumber: Int32) {
        let processGroupID = getpgid(childPID)
        if processGroupID > 0, processGroupID == childPID, processGroupID != getpgrp() { kill(-processGroupID, signalNumber) }
        kill(childPID, signalNumber)
    }

    private static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
