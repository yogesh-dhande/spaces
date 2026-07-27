import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    @discardableResult public func reconcileTerminalForegroundAgentClassifications() throws -> Bool {
        let liveSessions = try TerminalSessionCatalog.listLiveSessions()
        let liveSessionIDs = Set(liveSessions.map(\.sessionID))
        var didMutate = false
        for session in liveSessions where session.launchConfiguration.backend == .ghosttyEmbedded {
            let sessionID = session.sessionID
            let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
            if builtInTerminalSessionHasConfiguredOwner(ownership) { continue }
            guard let workspace = try workspaceForBuiltInTerminalSession(sessionID: sessionID, ownership: ownership) else { continue }
            if let existingRow = try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID) {
                // A row already finalized (its exit delivered — `.exited`, or an exit event recorded on a
                // previous pass) is skipped so it is never re-entered and its subscribers never get a
                // duplicate exited notice — the outer gate mirrored by the chokepoint's own idempotency
                // gate. A live turn-complete `.done` row is deliberately NOT skipped: it is not finalized,
                // and if its foreground has genuinely reverted to a plain shell the agent quit after its
                // turn, so the block below finalizes it (with the exited notice) rather than leaving a
                // stale coding-agent row on the shell.
                if try agentRowIsFinalized(existingRow) { continue }
                // A live session that already has a live-agent row is normally left alone, but an ad-hoc
                // detected agent whose foreground genuinely reverted to its own plain shell sheds its
                // ad-hoc classification here — the one place a live session does so — through the
                // finalization chokepoint. With the terminal still live, `handleAgentExit` demotes a
                // never-signaled detection row (pure detection state, no subscribers) and records `.exited`
                // on a signaled one (carrying lifecycle history and possibly subscribers), and the
                // chokepoint notifies the subscribers and tears down the reverted terminal's own watch
                // state either way.
                if isAdHocDetectedForegroundAgent(existingRow), foregroundHasRevertedToPlainShell(session) {
                    try finalizeAgentRow(existingRow, reason: .exited(eventType: "exit", eventSource: "foreground_reconciler", environmentKeys: nil))
                    didMutate = true
                }
                continue
            }
            if let detectedAgent = adHocDetectedForegroundAgent(from: session.runtimeState) {
                try insertAdHocDetectedAgent(detectedAgent: detectedAgent, workspace: workspace, sessionID: sessionID)
                didMutate = true
            }
        }
        if try reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs: liveSessionIDs) { didMutate = true }
        return didMutate
    }

    /// True only when a live session's foreground process is confirmed to be its own configured
    /// interactive shell (no program running in it at all), as opposed to `foregroundDetectedAgentKind`
    /// merely being nil. That nil case is ambiguous on its own: it also covers a foreground sample that
    /// hasn't landed yet (`foregroundExecutableName` nil, e.g. right after a reconnect) and an
    /// unclassified but still-running program (`python3 agent.py`) — neither of those is the detected
    /// agent process exiting, and demoting on either would drop a still-active coding-agent row. Only a
    /// foreground executable name that matches the session's own launch-configured shell basename is
    /// unambiguous evidence the terminal is back at a bare prompt.
    func foregroundHasRevertedToPlainShell(_ session: TerminalSessionCatalogEntry) -> Bool {
        guard session.runtimeState.foregroundDetectedAgentKind == nil,
            let executableName = session.runtimeState.foregroundExecutableName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !executableName.isEmpty
        else { return false }
        let shellBasename = URL(fileURLWithPath: session.launchConfiguration.shell).lastPathComponent
        return executableName == shellBasename
    }

    func adHocDetectedForegroundAgent(from runtimeState: TerminalSessionRuntimeState) -> (label: String, displayCommand: String?)? {
        guard let kind = runtimeState.foregroundDetectedAgentKind else { return nil }
        let label = runtimeState.foregroundDisplayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayCommand = runtimeState.foregroundDisplayCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label.flatMap { $0.isEmpty ? nil : $0 } ?? kind.displayLabel, displayCommand.flatMap { $0.isEmpty ? nil : $0 })
    }

    func insertAdHocDetectedAgent(detectedAgent: (label: String, displayCommand: String?), workspace: WorkspaceRecord, sessionID: String) throws {
        let terminalWindow = try store.windows(workspaceID: workspace.id).first { window in
            window.roleValue == .terminal && terminalHost(for: window.app) == .spaces && terminalSessionID(for: window) == sessionID
        }
        let terminalTarget = TerminalTargetRecord(runtimeTargetID: terminalWindow?.id, trackingID: sessionID)
        let now = nowISO8601()
        let agentID = adHocDetectedAgentID(sessionID: sessionID)
        // Exclude this row's own deterministic id from both the label scan and the validation snapshot.
        // Overlapping reconcile passes (TerminalForegroundAgentReconciler and ProcessExitMonitorService, both
        // detached) can each observe no existing row and both call this for the same session; the row id is
        // deterministic, so the later pass's upsert must never treat the earlier pass's already-inserted row
        // — carrying the SAME detected label — as a name conflict with itself and rename it "-2".
        let resolvedLabel = try uniqueAgentFocusLabel(workspaceID: workspace.id, preferredLabel: detectedAgent.label, excludingAgentWindowID: agentID)
        // Detection only ever creates or refreshes the label/command/runtime-target binding; it never owns
        // lifecycle state. Two overlapping reconciler passes (TerminalForegroundAgentReconciler and
        // ProcessExitMonitorService) can both observe no existing row and both reach this call for the same
        // deterministic id, and a hook signal can commit newer status/session-key state between this pass's
        // reads and its upsert. So the record carries only fresh initial lifecycle values, and preserving
        // any already-committed status, session key, claimed launcher fields, and lifecycle timestamps is enforced
        // in SQL by `upsertDetectedAgentWindow`'s ON CONFLICT clause rather than by re-reading and carrying
        // the snapshot forward here — closing the read-modify-upsert race. On first insert (no conflict)
        // these initial values are the ones written.
        let record = AgentWindowRecord(
            id: agentID, workspaceID: workspace.id, provider: .spaces, label: resolvedLabel, runtimeTargetID: terminalWindow?.id,
            terminalTarget: terminalTarget, sessionKey: nil, claimedLauncherID: nil, claimedLauncherName: nil, status: .idle, createdAt: now,
            updatedAt: now)
        let nextAgentWindows = try store.agentWindows(workspaceID: workspace.id).filter { $0.id != agentID } + [record]
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: try store.workspaceProcesses(workspaceID: workspace.id),
            browserSessions: try store.workspaceBrowserSessions(workspaceID: workspace.id), agentWindows: nextAgentWindows)

        try store.upsertDetectedAgentWindow(record)
        _ = try updateAdHocAgentRuntimeTargetDetail(record, displayCommand: detectedAgent.displayCommand)
    }

    func adHocDetectedAgentID(sessionID: String) -> String { "terminal-agent-\(sessionID)" }

    /// True when `record` is an ad-hoc coding-agent row that foreground detection promoted from a plain
    /// terminal (id == `adHocDetectedAgentID(sessionID)`), as opposed to an explicitly spawned or
    /// configured-launcher agent. This is pure id-provenance: it stays true even after hook signals land
    /// on the row, because a signal updates the detection row in place and preserves its id. Provenance
    /// alone is NOT sufficient to demote — that additionally requires no hook evidence
    /// (`agentRowHasRecordedHookSignal`), since a signaled detection row must exit through the
    /// `.exited`/notify path rather than a silent delete.
    func isAdHocDetectedForegroundAgent(_ record: AgentWindowRecord) -> Bool {
        guard record.provider == .spaces, let sessionID = builtInAgentSessionID(for: record) else { return false }
        return record.id == adHocDetectedAgentID(sessionID: sessionID)
    }

    /// Whether this agent row has ever recorded a real hook lifecycle signal (`spaces_agent_signal`), as
    /// opposed to being pure foreground-detection state. This is the gate on demoting an ad-hoc
    /// detection-created row back to a plain terminal: foreground detection creates the row BEFORE the
    /// agent's first hook fires (always for hookless codex/opencode, whose first signal is `working`; a
    /// race for claude), and later `init`/status signals update that same row in place, preserving its
    /// detection id — so `isAdHocDetectedForegroundAgent` cannot distinguish a never-signaled row (safe to
    /// silently demote and delete) from one that has since gained lifecycle history and possibly
    /// subscribers. Deleting a signaled row silently would drop the `exited` notice its subscribers are
    /// owed and lose the restart-reuse flush cue, so a signaled row must instead take the signaled-agent
    /// exit path (record `.exited`, notify subscribers). Foreground-detection events are a different
    /// source and are deliberately excluded by `lastAgentSignalAt`.
    func agentRowHasRecordedHookSignal(_ record: AgentWindowRecord) throws -> Bool { try store.lastAgentSignalAt(agentSessionID: record.id) != nil }

    /// Whether this agent row is already finalized — its exit has been delivered — so a termination path
    /// must neither re-notify its subscribers nor re-run its exit disposition. Finalized means either the
    /// `.exited` status (a kept live-terminal exit) OR a recorded `exit` event
    /// (`agentSessionHasRecordedExitEvent`). The recorded-event half is load-bearing: a configured
    /// launcher's exit is finalized to `.done` (`handleAgentExit`), and `.done` is ALSO the resting state
    /// a live launcher returns to after every completed turn, so status alone cannot tell an
    /// already-notified launcher exit from a live agent between turns. Keying on the persisted exit event
    /// instead means the most common kill scenario — an orchestrator killing a child that is sitting
    /// `.done` after finishing — is correctly seen as NOT finalized and still delivers exactly one exited
    /// notice, while a launcher whose exit was already delivered is never re-notified. Both halves are
    /// scoped to the row's CURRENT life across the restart-reuse reset (a fresh agent's `init` on the same
    /// terminal reuses the row id): the status half because that reset moves `.exited` back to `.idle`, and
    /// the event half because `agentSessionHasRecordedExitEvent` discounts an `exit` event once a later
    /// `init` event lands — so a reincarnated live agent is finalizable again and its kill/sweep delivers a
    /// fresh exited notice. The single finalized-fact predicate shared by the chokepoint's idempotency gate
    /// and both reconciler gates.
    func agentRowIsFinalized(_ record: AgentWindowRecord) throws -> Bool {
        if record.status == .exited { return true }
        return try store.agentSessionHasRecordedExitEvent(agentSessionID: record.id)
    }

    /// Reverts a foreground-detection promotion: removes the ad-hoc agent row and clears the agent-command
    /// detail it wrote onto the shared terminal window, WITHOUT terminating the terminal session or deleting
    /// its window — the shell is still live and must remain as a plain terminal. Used when the detected agent
    /// process exits but the terminal stays open, so the session stops being counted as a coding agent.
    func demoteAdHocDetectedForegroundAgent(_ record: AgentWindowRecord) throws {
        _ = try? updateAdHocAgentRuntimeTargetDetail(record, displayCommand: nil)
        try store.deleteAgentWindow(id: record.id)
    }

    /// Finalizes coding-agent rows whose backing built-in terminal session has ended without any exit
    /// signal — the state codex and opencode (which provide no session-end hook) and a SIGKILL'd claude
    /// leave behind. It covers both session provenances that back a Spaces agent row:
    ///  - explicitly spawned/configured `.agent`-launch-kind sessions (`agent spawn`, a launcher), and
    ///  - ad-hoc foreground-detected agents running in a `.shell`-launch-kind terminal the user closed.
    ///
    /// Such a row would otherwise stay `spinning`/`waiting` forever and its subscribers would never learn
    /// the child exited. For each such row this runs the real exit flow the hook-signaled `.exit` case
    /// uses: render/enqueue the `exited` notice to subscribers BEFORE `handleAgentExit` deletes the row —
    /// deletion cascades the subscription edges away, and the pending row (no FK) is what carries the
    /// notice past that — then reuse `handleAgentExit` for the delete-vs-`.done` decision, then tear down
    /// the dead terminal's own standing as a subscriber (its inbound queue and any outgoing watch edges —
    /// see `AgentNotificationEngine.subscriberDidExit`), since an exited terminal can never be a delivery
    /// target again.
    ///
    /// The `.shell` case was previously a separate sweep that silently wrote `.done` on the dead row (a
    /// path predating the `.exited` status): that raised a spurious "finished" alert for an agent that was
    /// actually terminated with its shell, delivered no exited notice, and leaked the closed terminal's
    /// watch edges. Unifying it here makes a dead ad-hoc `.shell` row take the identical exit flow — a
    /// dead non-launcher session is deleted by `handleAgentExit`, so it disappears from listings and a
    /// remote overview diffs the row's disappearance as `exited`, matching the local `.exited` notice.
    ///
    /// Only rows not yet finalized are swept (`agentRowIsFinalized`): a row already deleted (spawned/ad-hoc)
    /// or held `.exited`, and a configured launcher held `.done` that already recorded its `exit` event, is
    /// never re-processed and its subscribers never get a duplicate exited notice. A live launcher sitting
    /// `.done` between turns has no exit event yet, so it is not treated as finalized — but the liveness
    /// check below leaves it untouched while its session is alive; only once its terminal has ended does
    /// this sweep finalize it and deliver the notice.
    @discardableResult func reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs liveSessionIDs: Set<String>) throws -> Bool {
        var didMutate = false
        for project in try store.projects() {
            for workspace in try store.workspaces(projectID: project.id, includeArchived: false) {
                for agent in try store.agentWindows(workspaceID: workspace.id) where agent.provider == .spaces {
                    // Skip only rows already finalized (their exit delivered — `.exited`, or an exit event
                    // recorded on a previous pass). A live turn-complete `.done` row is NOT finalized: a
                    // hookless codex/opencode agent that completed a turn and then had its terminal closed
                    // sits `.done` with no exit event, and this sweep must finalize it (delivering the
                    // exited notice) rather than leaving it stale forever. A still-live `.done` row is
                    // filtered by the liveness and runtime-state checks below.
                    if try agentRowIsFinalized(agent) { continue }
                    guard let sessionID = builtInTerminalSessionID(for: agent), !liveSessionIDs.contains(sessionID) else { continue }
                    // A `.shell`-launch-kind row is only ever an ad-hoc foreground-detected agent, which
                    // `handleAgentExit` deletes once its shell is gone; `.agent` is a spawned/launcher
                    // session. Any other launch kind is not a coding agent and is left alone.
                    guard let launchConfiguration = terminalSessionLaunchConfiguration(sessionID: sessionID),
                        launchConfiguration.kind == .agent || launchConfiguration.kind == .shell
                    else { continue }
                    // Finalize only on unambiguous evidence the session ended: a present runtime state that
                    // is non-interactive. A missing runtime-state file is ambiguous (e.g. a just-launched
                    // session before its first write) and is left for a later sweep.
                    guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
                        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive
                    else { continue }
                    try finalizeAgentRow(agent, reason: .exited(eventType: "exit", eventSource: "foreground_reconciler", environmentKeys: nil))
                    didMutate = true
                }
            }
        }
        return didMutate
    }

    @discardableResult func updateAdHocAgentRuntimeTargetDetail(_ agent: AgentWindowRecord, displayCommand: String?) throws -> Bool {
        let targetID = try store.agentSessionRuntimeTargetID(id: agent.id) ?? agent.runtimeTargetID
        guard let targetID else { return false }
        guard let window = try store.windows(workspaceID: agent.workspaceID).first(where: { $0.id == targetID }) else { return false }
        let nextDetail = adHocAgentRuntimeDetail(label: agent.label, displayCommand: displayCommand)
        guard window.detail != nextDetail else { return false }
        try store.upsert(
            window: WindowRecord(
                id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: nextDetail, targetURL: window.targetURL,
                terminalTrackingID: window.terminalTrackingID, role: window.role, orderIndex: window.orderIndex, lastSeenAt: nowISO8601()))
        return true
    }

    func adHocAgentRuntimeDetail(label: String?, displayCommand: String?) -> String? {
        guard let command = displayCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
        let normalizedCommand = command.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedLabel = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard normalizedCommand != normalizedLabel else { return nil }
        return command
    }

    func preservesForegroundAgentCommandDetail(_ window: WindowRecord) -> Bool {
        guard window.roleValue == .terminal, terminalHost(for: window.app) == .spaces, let sessionID = terminalSessionID(for: window) else {
            return false
        }
        guard terminalSessionLaunchConfiguration(sessionID: sessionID)?.kind == .shell else { return false }
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), runtimeState.foregroundDetectedAgentKind != nil
        else { return false }
        return ((try? store.agentWindows(workspaceID: window.workspaceID)) ?? []).contains { builtInTerminalSessionID(for: $0) == sessionID }
    }

    func fallbackAgentFocusName(_ record: AgentWindowRecord) throws -> String? {
        let trackedWindow = try matchedTrackedWindowForAgent(
            workspaceID: record.workspaceID, provider: record.provider, terminalTrackingID: record.terminalTrackingID)
        if let title = sanitizedFocusName(trackedWindow?.name) { return sanitizedFocusName("Coding Agent \(title)") ?? title }
        if let detail = sanitizedFocusName(trackedWindow?.detail) { return sanitizedFocusName("Coding Agent \(detail)") ?? detail }
        return sanitizedFocusName("Coding Agent")
    }

    func uniqueAgentFocusLabel(
        workspaceID: String, preferredLabel: String?, excludingAgentWindowID: String? = nil, claimedLauncherName: String? = nil
    ) throws -> String? {
        guard let baseLabel = sanitizedFocusName(preferredLabel) else { return nil }
        // Configured coding-agent slots reserve their exact names even before a live agent
        // reports in. Ad-hoc agents that choose the same label get suffixed so the Run tab
        // and harness focus keep a stable one-name-to-one-row mapping.
        let usedNames = Set(
            try focusableWorkspaceTargets(workspaceID: workspaceID).filter { entry in
                guard case .agent(let record) = entry.target, let excludingAgentWindowID else { return true }
                return record.id != excludingAgentWindowID
            }.map(\.name).map(normalizedFocusName))
        let existingAgentNames = try store.agentWindows(workspaceID: workspaceID).filter { $0.id != excludingAgentWindowID }.compactMap(\.label)
            .compactMap(sanitizedFocusName).map(normalizedFocusName)
        let reservedLauncherNames = Set(
            try store.workspaceAgentLaunchers(workspaceID: workspaceID).map { try requiredConfiguredFocusName($0.name, kind: "Coding agent") }.filter
            { launcherName in
                guard let claimedLauncherName else { return true }
                return normalizedFocusName(launcherName) != normalizedFocusName(claimedLauncherName)
            }.map(normalizedFocusName))
        var blockedNames = usedNames
        blockedNames.formUnion(existingAgentNames)
        blockedNames.formUnion(reservedLauncherNames)
        if !blockedNames.contains(normalizedFocusName(baseLabel)) { return baseLabel }
        var suffix = 2
        while blockedNames.contains(normalizedFocusName("\(baseLabel)-\(suffix)")) { suffix += 1 }
        return "\(baseLabel)-\(suffix)"
    }

    func trackedTerminalWindowsForAgents(workspaceID: String, agentWindows: [AgentWindowRecord]) throws -> [WindowRecord] {
        guard !agentWindows.isEmpty else { return [] }
        let trackedAgentTerminalKeys = Set(agentWindows.compactMap(\.terminalTrackingKey))
        guard !trackedAgentTerminalKeys.isEmpty else { return [] }
        // Auto-launched coding agents register their own tracked terminal rows before the
        // workspace launch finishes. Preserve those rows when replacing the workspace
        // window snapshot so stop/restart can still close the actual agent terminals.
        return try store.windows(workspaceID: workspaceID).filter { window in
            guard window.roleValue == .terminal else { return false }
            if let trackingKey = window.terminalTrackingKey, trackedAgentTerminalKeys.contains(trackingKey) { return true }
            return false
        }
    }

    func normalizeAgentLauncherIDs(previous: [AgentLauncher], updated: [AgentLauncher]) -> [AgentLauncher] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let previousNames = previous.map { normalizedFocusName($0.name) }
        let previousCommands = previous.map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nameCounts = Dictionary(previousNames.map { ($0, 1) }, uniquingKeysWith: +)
        let commandCounts = Dictionary(previousCommands.map { ($0, 1) }, uniquingKeysWith: +)
        var usedIDs = Set<String>()

        return updated.map { launcher in
            if previousByID[launcher.id] != nil {
                usedIDs.insert(launcher.id)
                return launcher
            }

            let normalizedName = normalizedFocusName(launcher.name)
            if nameCounts[normalizedName] == 1,
                let match = previous.first(where: { normalizedFocusName($0.name) == normalizedName && !usedIDs.contains($0.id) })
            {
                usedIDs.insert(match.id)
                return AgentLauncher(id: match.id, name: launcher.name, command: launcher.command)
            }

            let trimmedCommand = launcher.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if commandCounts[trimmedCommand] == 1,
                let match = previous.first(where: {
                    $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedCommand && !usedIDs.contains($0.id)
                })
            {
                usedIDs.insert(match.id)
                return AgentLauncher(id: match.id, name: launcher.name, command: launcher.command)
            }

            return launcher
        }
    }

    @discardableResult func pruneOrphanedAgentWindows(workspaceID: String, agents: [AgentWindowRecord], prunedTerminalTrackingKeys: Set<String>)
        throws -> Int
    {
        guard !prunedTerminalTrackingKeys.isEmpty else { return 0 }
        let runningProcessTrackingKeys = Set(try store.runningProcesses(workspaceID: workspaceID).compactMap(\.terminalTrackingKey))
        var pruned = 0
        for agent in agents where agent.provider == .spaces {
            guard let trackingKey = agent.terminalTrackingKey else { continue }
            // Agent rows for ad-hoc terminals depend on the tracked terminal row for liveness.
            // Once that terminal disappears, the agent row should disappear too unless a managed
            // workspace process still owns the same terminal identity.
            guard prunedTerminalTrackingKeys.contains(trackingKey) else { continue }
            if runningProcessTrackingKeys.contains(trackingKey) { continue }
            if try spacesAgentRecordIsConfiguredLauncher(workspaceID: workspaceID, record: agent) { continue }
            // The backing terminal is already gone (its tracking key was pruned), so destroy the row
            // through the chokepoint without terminating anything: it still owes the child's subscribers an
            // exited notice and must tear down the orphaned terminal's own watch state.
            try finalizeAgentRow(agent, reason: .destroyed(terminateTerminalSession: false))
            pruned += 1
        }
        return pruned
    }

    // MARK: - Agent Windows

    public func agentWindows(workspaceID: String) throws -> [AgentWindowRecord] { try store.agentWindows(workspaceID: workspaceID) }

    /// Locates the Spaces coding-agent session bound to a terminal tracking id, scanning every
    /// workspace. Orchestration commands (`agent kill`) address agents by terminal session id without
    /// knowing the owning workspace, so this resolves the `(workspaceID, record)` pair for the caller.
    /// Returns `nil` when no Spaces agent row is bound to that terminal session yet — agent rows only
    /// appear on the first hook signal, so a just-spawned agent has none.
    public func resolveSpacesAgentSession(terminalSessionID: String) throws -> (workspaceID: String, record: AgentWindowRecord)? {
        for (workspaceID, agents) in try store.agentWindowsByWorkspace() {
            if let record = agents.first(where: { $0.provider == .spaces && $0.terminalTrackingID == terminalSessionID }) {
                return (workspaceID, record)
            }
        }
        return nil
    }

    /// Validates that subscribing `subscriberTerminalSessionID` to the agent row `agentSessionID` is a
    /// legal watch edge before it is persisted: the agent must exist, must not run in the subscriber's
    /// own terminal (a self-edge), and must not close a cycle in the subscription graph. The graph's
    /// nodes are terminal session ids; each edge points subscriber → the watched agent's terminal. A
    /// cycle would let injected notifications chase each other around a loop, so this walks existing
    /// edges outward from the target's terminal (following each terminal's own subscriptions) and errors
    /// if the walk reaches the subscriber. Deterministic and total: the walk visits each terminal once.
    public func validateAgentSubscription(subscriberTerminalSessionID: String, agentSessionID: String) throws {
        guard let target = try store.agentWindow(id: agentSessionID) else {
            throw WorkspaceError.invalidArgument(message: "No agent session \(agentSessionID) to subscribe to.")
        }
        // The subscribe contract requires hook evidence: a watch edge is only legal against a hook-signaled
        // agent. A never-signaled ad-hoc foreground-detection row is pure detection state that the reconciler
        // may silently demote (deleting it with no exited notice), so a watcher attached to it would be owed
        // a notice that never comes. Reject it and tell the caller to retry after the agent signals; this
        // also keeps the silent demote provably unwatchable.
        if isAdHocDetectedForegroundAgent(target), try !agentRowHasRecordedHookSignal(target) {
            throw WorkspaceError.invalidArgument(
                message: "Agent session \(agentSessionID) has not emitted its first hook signal yet; retry the subscribe after it starts working.")
        }
        guard let targetTerminalSessionID = target.terminalTrackingID else { return }
        if targetTerminalSessionID == subscriberTerminalSessionID {
            throw WorkspaceError.invalidArgument(message: "A terminal cannot subscribe to a coding agent running in itself.")
        }
        var visited: Set<String> = []
        var frontier = [targetTerminalSessionID]
        while let terminal = frontier.popLast() {
            guard visited.insert(terminal).inserted else { continue }
            for edge in try store.agentSubscriptions(subscriberTerminalSessionID: terminal) {
                guard let nextTerminal = try store.agentWindow(id: edge.agentSessionID)?.terminalTrackingID else { continue }
                if nextTerminal == subscriberTerminalSessionID {
                    throw WorkspaceError.invalidArgument(message: "Subscribing would create a notification cycle between these terminals.")
                }
                frontier.append(nextTerminal)
            }
        }
    }

    /// Records a same-device watch edge addressed by the child's *terminal session id* — the id a CLI or
    /// device caller holds — rather than the agent row id. A device-qualified subscribe naming this
    /// machine (`--device` resolving to the local device) is normalized onto this path so it is validated
    /// like a plain local watch instead of taking the cross-device path that skips cycle detection. The
    /// child's terminal session id is resolved to its agent row (as `killAgentSession` does), the edge is
    /// checked for a self-edge or any cycle (`validateAgentSubscription`), and only then persisted.
    /// Throws when no agent session is bound to that terminal yet.
    public func subscribeAgentWatch(subscriberTerminalSessionID: String, childTerminalSessionID: String) throws {
        guard let match = try resolveSpacesAgentSession(terminalSessionID: childTerminalSessionID) else {
            throw WorkspaceError.invalidArgument(message: "No agent session for terminal \(childTerminalSessionID).")
        }
        try validateAgentSubscription(subscriberTerminalSessionID: subscriberTerminalSessionID, agentSessionID: match.record.id)
        try store.insertAgentSubscription(
            subscriberTerminalSessionID: subscriberTerminalSessionID, agentSessionID: match.record.id, createdAt: nowISO8601())
    }

    /// Removes the same-device watch edge addressed by the child's *terminal session id*. Resolves the
    /// agent row bound to that terminal and deletes the subscriber's edge to it. When no agent row is
    /// bound to the child terminal this is a quiet success: a local edge FK-cascades away with its agent
    /// row, so there is nothing left to delete.
    public func unsubscribeAgentWatch(subscriberTerminalSessionID: String, childTerminalSessionID: String) throws {
        guard let match = try resolveSpacesAgentSession(terminalSessionID: childTerminalSessionID) else { return }
        try store.deleteAgentSubscription(subscriberTerminalSessionID: subscriberTerminalSessionID, agentSessionID: match.record.id)
    }

    @discardableResult public func recordRemoteAgentSignal(_ event: TerminalServiceAgentSignalEvent) throws -> Bool {
        guard let type = RemoteAgentSignalType(rawValue: event.type), let provider = AgentProvider(rawValue: event.provider) else { return false }
        guard let workspaceID = try remoteAgentSignalWorkspaceID(event) else { return false }
        let terminalTrackingID = sanitizedFocusName(event.terminalTrackingID) ?? sanitizedFocusName(event.sessionID)
        let existingAgent = try matchingAgentWindow(workspaceID: workspaceID, terminalTrackingID: terminalTrackingID)
        let signalLabel = sanitizedFocusName(event.label) ?? sanitizedFocusName(existingAgent?.label)
        let canRecordSignal = existingAgent != nil || type == .`init` || (type.establishesAgentFromEvidence && signalLabel != nil)
        guard canRecordSignal else { return true }

        switch type {
        case .`init`:
            try registerAgentWindow(
                workspaceID: workspaceID, provider: provider, label: signalLabel, terminalTrackingID: terminalTrackingID,
                status: existingAgent?.status ?? .idle, eventType: type.rawValue, eventSource: "remote_spaces_signal",
                environmentKeys: event.environmentKeys)
        case .working, .blocked, .done:
            try updateAgentWindowStatus(
                workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, label: signalLabel, status: type.status,
                eventType: type.rawValue, eventSource: "remote_spaces_signal", environmentKeys: event.environmentKeys)
        case .exit:
            guard let existingAgent else { return true }
            try finalizeAgentRow(
                existingAgent, reason: .exited(eventType: type.rawValue, eventSource: "remote_spaces_signal", environmentKeys: event.environmentKeys))
        }
        return true
    }

    func remoteAgentSignalWorkspaceID(_ event: TerminalServiceAgentSignalEvent) throws -> String? {
        if let workspaceID = sanitizedFocusName(event.workspaceID), try store.workspace(id: workspaceID) != nil { return workspaceID }
        if let workspacePath = sanitizedFocusName(event.workspacePath), let workspace = try store.workspace(dir: workspacePath) {
            return workspace.id
        }
        let candidateSessionIDs = Set([event.terminalTrackingID, event.sessionID].compactMap { normalizedTerminalSessionID($0) })
        guard !candidateSessionIDs.isEmpty else { return nil }
        for project in try store.projects() {
            for workspace in try store.workspaces(projectID: project.id, includeArchived: false) {
                if try store.agentWindows(workspaceID: workspace.id).contains(where: { agent in
                    guard let sessionID = builtInTerminalSessionID(for: agent) else { return false }
                    return candidateSessionIDs.contains(sessionID)
                }) {
                    return workspace.id
                }
            }
        }
        return nil
    }

    func matchingAgentWindow(workspaceID: String, terminalTrackingID: String?, sessionKey: String? = nil) throws -> AgentWindowRecord? {
        let allAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        return terminalTrackingID.flatMap { sessionID in allAgentWindows.first(where: { $0.terminalTrackingID == sessionID }) }
            ?? allAgentWindows.first(where: { $0.sessionKey == sessionKey && sessionKey != nil })
    }

    func agentTerminalTargetID(terminalTrackingID: String?) -> String? {
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return "terminal:\(sessionID)" }
        return nil
    }

    func matchedTrackedWindowForAgent(workspaceID: String, provider: AgentProvider, terminalTrackingID: String?) throws -> WindowRecord? {
        let windows = try store.windows(workspaceID: workspaceID)
        if provider == .spaces, let terminalTrackingID, !terminalTrackingID.isEmpty,
            let trackedWindow = windows.first(where: {
                $0.roleValue == .terminal && $0.app == TerminalHost.spaces.appName && $0.terminalTrackingID == terminalTrackingID
            })
        {
            return trackedWindow
        }
        if let targetID = agentTerminalTargetID(terminalTrackingID: terminalTrackingID),
            let trackedWindow = windows.first(where: { $0.roleValue == .terminal && $0.terminalTrackingKey == targetID })
        {
            return trackedWindow
        }
        return nil
    }

    /// Reconciles an agent with its already-tracked terminal row, if one exists. It does NOT
    /// mint a new window: a Spaces agent's tracked terminal row is created by the store when the
    /// agent record is upserted (`ensureRuntimeTargetForAgentWindow`). Creating it eagerly here
    /// would make the agent's own not-yet-claimed window collide with its focus label and force a
    /// spurious "-2" suffix, so when no row matches yet this returns nil and lets upsert create it.
    func ensureTrackedWindowExistsForAgent(workspaceID: String, provider: AgentProvider, label: String?, terminalTrackingID: String?) throws
        -> WindowRecord?
    {
        _ = label
        guard
            let trackedWindow = try matchedTrackedWindowForAgent(workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID)
        else { return nil }
        let resolvedSessionID = terminalTrackingID ?? trackedWindow.terminalTrackingID
        guard resolvedSessionID != trackedWindow.terminalTrackingID else { return trackedWindow }
        let updated = WindowRecord(
            id: trackedWindow.id, workspaceID: trackedWindow.workspaceID, app: trackedWindow.app, name: trackedWindow.name,
            detail: trackedWindow.detail, targetURL: trackedWindow.targetURL, terminalTrackingID: resolvedSessionID, role: trackedWindow.role,
            orderIndex: trackedWindow.orderIndex, lastSeenAt: nowISO8601())
        try store.upsert(window: updated)
        return updated
    }

    /// Evicts a stale agent slot whose backing session is gone, when a relaunch reuses its launcher
    /// identity. Destroys the row through the chokepoint (terminating any lingering terminal), so the stale
    /// child's subscribers are told it exited and the terminal's own watch state is torn down before the
    /// fresh session takes over.
    func removeStaleAgentWindow(_ record: AgentWindowRecord) throws {
        try finalizeAgentRow(record, reason: .destroyed(terminateTerminalSession: true))
    }

    func removeAdHocTrackedWindowForAgent(workspaceID: String, provider: AgentProvider, terminalTrackingID: String?) throws {
        guard
            let trackedWindow = try matchedTrackedWindowForAgent(workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID)
        else { return }
        let processUsesWindow = try store.runningProcesses(workspaceID: workspaceID).contains { process in
            process.terminalTrackingKey == trackedWindow.terminalTrackingKey
        }
        if !processUsesWindow { try store.deleteWindow(id: trackedWindow.id) }
    }

    func agentSessionEventMessage(
        provider: AgentProvider, label: String?, terminalTrackingID: String?, sessionKey: String?, environmentKeys: [String]? = nil
    ) -> String {
        func normalizedValue(_ value: String?) -> String {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return "<nil>" }
            return value
        }

        let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelValue = (normalizedLabel?.isEmpty == false ? normalizedLabel : nil) ?? "<nil>"
        let trackingValue = normalizedValue(terminalTrackingID)
        let sessionKeyValue = normalizedValue(sessionKey)
        let envKeysValue = environmentKeys.map { $0.isEmpty ? "<none>" : $0.joined(separator: ",") } ?? "<nil>"
        return
            "provider=\(provider.rawValue) label=\(labelValue) tracking_id=\(trackingValue) session_key=\(sessionKeyValue) env_keys=\(envKeysValue)"
    }

    func appendAgentSessionEvent(agentSessionID: String, eventType: String, source: String, message: String?, createdAt: String) {
        try? store.appendAgentSessionEvent(
            agentSessionID: agentSessionID, eventType: eventType, source: source, message: message, createdAt: createdAt)
    }

    func spacesAgentRecordIsConfiguredLauncher(workspaceID: String, record: AgentWindowRecord) throws -> Bool {
        guard record.provider == .spaces else { return false }
        let launchers = try store.workspaceAgentLaunchers(workspaceID: workspaceID)
        if let claimedLauncherID = sanitizedFocusName(record.claimedLauncherID) {
            if launchers.contains(where: { $0.id == claimedLauncherID }) { return true }
        }
        if let claimedLauncherName = sanitizedFocusName(record.claimedLauncherName) {
            return launchers.contains { normalizedFocusName($0.name) == normalizedFocusName(claimedLauncherName) }
        }
        return false
    }

    @discardableResult public func registerAgentWindow(
        workspaceID: String, provider: AgentProvider, label: String? = nil, terminalTrackingID: String? = nil, sessionKey: String? = nil,
        status: AgentWindowStatus = .idle, claimedLauncherID: String? = nil, claimedLauncherName: String? = nil, eventType: String = "register",
        eventSource: String = "orchestrator", environmentKeys: [String]? = nil
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        let existingAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        let trackedWindow = try ensureTrackedWindowExistsForAgent(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID)
        // The `init` signal re-registers a terminal's agent row and preserves its current status so a
        // reconnect never disturbs a live agent. But an `init` on a terminal whose previous agent
        // `.exited` means a fresh agent is reusing that terminal, so its status resets to `.idle` rather
        // than staying `.exited`. This is the single chokepoint for that restart-reuse reset, shared by
        // the daemon and remote signal init paths (both pass the preserved `existing.status`).
        let resolvedStatus: AgentWindowStatus = status == .exited ? .idle : status
        if let existing = try matchingAgentWindow(workspaceID: workspaceID, terminalTrackingID: terminalTrackingID, sessionKey: sessionKey) {
            let resolvedClaimedLauncherName = claimedLauncherName ?? existing.claimedLauncherName
            let resolvedLabel = try uniqueAgentFocusLabel(
                workspaceID: workspaceID, preferredLabel: label ?? existing.label, excludingAgentWindowID: existing.id,
                claimedLauncherName: resolvedClaimedLauncherName)
            let updated = AgentWindowRecord(
                id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: resolvedLabel,
                runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                terminalTarget: TerminalTargetRecord(
                    runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id, trackingID: terminalTrackingID ?? existing.terminalTrackingID),
                sessionKey: sessionKey ?? existing.sessionKey, claimedLauncherID: claimedLauncherID ?? existing.claimedLauncherID,
                claimedLauncherName: resolvedClaimedLauncherName, status: resolvedStatus, note: existing.note, createdAt: existing.createdAt,
                updatedAt: now)
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
                browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID),
                agentWindows: existingAgentWindows.map { $0.id == existing.id ? updated : $0 })
            try store.upsertAgentWindow(updated)
            appendAgentSessionEvent(
                agentSessionID: updated.id, eventType: eventType, source: eventSource,
                message: agentSessionEventMessage(
                    provider: updated.provider, label: updated.label, terminalTrackingID: updated.terminalTrackingID, sessionKey: updated.sessionKey,
                    environmentKeys: environmentKeys), createdAt: now)
            return updated
        }
        let resolvedLabel = try uniqueAgentFocusLabel(workspaceID: workspaceID, preferredLabel: label, claimedLauncherName: claimedLauncherName)
        let record = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspaceID, provider: provider, label: resolvedLabel, runtimeTargetID: trackedWindow?.id,
            terminalTarget: TerminalTargetRecord(runtimeTargetID: trackedWindow?.id, trackingID: terminalTrackingID), sessionKey: sessionKey,
            claimedLauncherID: claimedLauncherID, claimedLauncherName: claimedLauncherName, status: resolvedStatus, createdAt: now, updatedAt: now)
        try validateWorkspaceFocusNames(
            workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
            browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID), agentWindows: existingAgentWindows + [record])
        try store.upsertAgentWindow(record)
        appendAgentSessionEvent(
            agentSessionID: record.id, eventType: eventType, source: eventSource,
            message: agentSessionEventMessage(
                provider: record.provider, label: record.label, terminalTrackingID: record.terminalTrackingID, sessionKey: record.sessionKey,
                environmentKeys: environmentKeys), createdAt: now)
        return record
    }

    @discardableResult public func updateAgentWindowStatus(
        workspaceID: String, provider: AgentProvider, terminalTrackingID: String? = nil, sessionKey: String? = nil, label: String? = nil,
        status: AgentWindowStatus, claimedLauncherName: String? = nil, eventType: String? = nil, eventSource: String = "orchestrator",
        environmentKeys: [String]? = nil
    ) throws -> AgentWindowRecord {
        let existing = try matchingAgentWindow(workspaceID: workspaceID, terminalTrackingID: terminalTrackingID, sessionKey: sessionKey)
        // Per-tool hooks make an active agent signal `working` on every tool call. A signal that would
        // keep the row spinning is a pure no-op: no `agent_session_events` row (the event log records
        // state transitions, not tool calls) and no row rewrite — `updated_at` deliberately stays the
        // time the agent *entered* working, so it reads as the transition time, not tool-call recency.
        if let existing, status == .spinning, existing.status == .spinning { return existing }
        let now = nowISO8601()
        let allAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        let trackedWindow = try ensureTrackedWindowExistsForAgent(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID)
        if let existing {
            let resolvedClaimedLauncherName = claimedLauncherName ?? existing.claimedLauncherName
            let resolvedLabel = try uniqueAgentFocusLabel(
                workspaceID: workspaceID, preferredLabel: label ?? existing.label, excludingAgentWindowID: existing.id,
                claimedLauncherName: resolvedClaimedLauncherName)
            let updated = AgentWindowRecord(
                id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: resolvedLabel,
                runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                terminalTarget: TerminalTargetRecord(
                    runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id, trackingID: terminalTrackingID ?? existing.terminalTrackingID),
                sessionKey: sessionKey ?? existing.sessionKey, claimedLauncherID: existing.claimedLauncherID,
                claimedLauncherName: resolvedClaimedLauncherName, status: status, note: existing.note, createdAt: existing.createdAt, updatedAt: now)
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
                browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID),
                agentWindows: allAgentWindows.map { $0.id == existing.id ? updated : $0 })
            try store.upsertAgentWindow(updated)
            appendAgentSessionEvent(
                agentSessionID: updated.id, eventType: eventType ?? status.rawValue, source: eventSource,
                message: agentSessionEventMessage(
                    provider: updated.provider, label: updated.label, terminalTrackingID: updated.terminalTrackingID, sessionKey: updated.sessionKey,
                    environmentKeys: environmentKeys), createdAt: now)
            return updated
        }
        return try registerAgentWindow(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID, sessionKey: sessionKey,
            status: status, claimedLauncherName: claimedLauncherName, eventType: eventType ?? status.rawValue, eventSource: eventSource,
            environmentKeys: environmentKeys)
    }

    @discardableResult public func handleAgentExit(
        _ existing: AgentWindowRecord, eventType: String = "exit", eventSource: String = "orchestrator", environmentKeys: [String]? = nil
    ) throws -> AgentWindowRecord? {
        if try spacesAgentRecordIsConfiguredLauncher(workspaceID: existing.workspaceID, record: existing) {
            return try recordAgentExitStatus(
                existing, status: .done, eventType: eventType, eventSource: eventSource, environmentKeys: environmentKeys)
        }
        let sessionBackedSpacesAgent = builtInAgentSessionID(for: existing) != nil
        let existingSessionIsLive = sessionBackedSpacesAgent && builtInAgentSessionIsStillLive(existing)
        if existingSessionIsLive {
            if isAdHocDetectedForegroundAgent(existing), try !agentRowHasRecordedHookSignal(existing) {
                // Foreground-detected agent's process ended but its shell terminal is still live, and the
                // row never recorded a hook signal — pure detection state with no lifecycle history or
                // subscribers, so demote to a plain terminal rather than keeping a phantom "exited"
                // coding-agent row on the shell. A detection row that HAS signaled is deliberately NOT
                // claimed here: it falls through to the live-terminal `.exited` branch below so its
                // subscribers get the exited notice and a restart can reuse the row.
                try demoteAdHocDetectedForegroundAgent(existing)
                return nil
            }
            // The agent process ended but its terminal session is still open, so keep the row and mark it
            // `exited` (not `idle`): the terminal stays addressable and a restart reuses it, while remote
            // watchers see a real exit transition instead of a status change they treat as "not started".
            return try recordAgentExitStatus(
                existing, status: .exited, eventType: eventType, eventSource: eventSource, environmentKeys: environmentKeys)
        }
        appendAgentSessionEvent(
            agentSessionID: existing.id, eventType: eventType, source: eventSource,
            message: agentSessionEventMessage(
                provider: existing.provider, label: existing.label, terminalTrackingID: existing.terminalTrackingID, sessionKey: existing.sessionKey,
                environmentKeys: environmentKeys), createdAt: nowISO8601())
        terminateBuiltInTerminalSession(existing.terminalTrackingID)
        // Drop the row's inbound watch edges explicitly before the delete: the FK is `ON DELETE RESTRICT`,
        // so the delete would otherwise fail. `finalizeAgentRow` notified those subscribers `exited` first.
        try store.deleteAgentSubscriptions(agentSessionID: existing.id)
        try store.deleteAgentWindow(id: existing.id)
        try removeAdHocTrackedWindowForAgent(
            workspaceID: existing.workspaceID, provider: existing.provider, terminalTrackingID: existing.terminalTrackingID)
        return nil
    }

    func recordAgentExitStatus(
        _ existing: AgentWindowRecord, status: AgentWindowStatus, eventType: String, eventSource: String, environmentKeys: [String]?
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        let terminalTarget: TerminalTargetRecord? =
            if existing.terminalTarget != nil || existing.terminalTrackingID != nil {
                TerminalTargetRecord(runtimeTargetID: existing.runtimeTargetID, trackingID: existing.terminalTrackingID)
            } else { nil }
        let updated = AgentWindowRecord(
            id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: existing.label,
            runtimeTargetID: existing.runtimeTargetID, terminalTarget: terminalTarget, sessionKey: existing.sessionKey,
            claimedLauncherID: existing.claimedLauncherID, claimedLauncherName: existing.claimedLauncherName, status: status, note: existing.note,
            createdAt: existing.createdAt, updatedAt: now)
        try store.upsertAgentWindow(updated)
        appendAgentSessionEvent(
            agentSessionID: updated.id, eventType: eventType, source: eventSource,
            message: agentSessionEventMessage(
                provider: updated.provider, label: updated.label, terminalTrackingID: updated.terminalTrackingID, sessionKey: updated.sessionKey,
                environmentKeys: environmentKeys), createdAt: now)
        return updated
    }

    public func stopCodingAgent(workspaceID: String, agentID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard let record = try store.agentWindows(workspaceID: workspaceID).first(where: { $0.id == agentID }) else { return }
            try stopCodingAgentRecord(record)
            try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
        }
    }

    /// Terminates a coding-agent session addressed by its terminal session id — the shared local
    /// implementation of `spaces agent kill` (`.agentKill`). Both branches route through a stop chokepoint
    /// that already owns the notify-before-delete + subscriber-teardown flow, so the kill path adds no
    /// notification of its own and never double-notifies:
    ///  - A hook-signaled child (one with an agent row) stops through `stopCodingAgent` →
    ///    `stopCodingAgentRecord`, which tells the child's subscribers it exited before deleting the row
    ///    (whose FK cascade would otherwise drop the subscription edges silently) and tears down the
    ///    stopped terminal's own inbound queue and outgoing watch edges.
    ///  - A not-yet-signaled `.agent` session (no agent row) goes through
    ///    `terminateSpawnedAgentTerminalSession` → `deleteAgentRows`, which destroys the terminal and runs
    ///    `subscriberDidExit` for it even though no agent row existed — the killed terminal may itself have
    ///    been a SUBSCRIBER of other agents (subscribing does not require a live agent row), so its own
    ///    outgoing watch edges and inbound queue must still be torn down. Its `.agent` launch-kind gate
    ///    refuses ordinary shell and process terminals.
    /// Returns false when the id names neither, for the caller to surface loudly.
    public func killAgentSession(terminalSessionID: String) throws -> Bool {
        if let match = try resolveSpacesAgentSession(terminalSessionID: terminalSessionID) {
            try stopCodingAgent(workspaceID: match.workspaceID, agentID: match.record.id)
            return true
        }
        return try terminateSpawnedAgentTerminalSession(sessionID: terminalSessionID)
    }

    @discardableResult public func restartCodingAgent(workspaceID: String, agentID: String) throws -> AgentWindowRecord {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
            guard let record = try store.agentWindows(workspaceID: workspaceID).first(where: { $0.id == agentID }) else {
                throw WorkspaceError.invalidArgument(message: "Coding agent is not running.")
            }
            let launcher = try restartableCodingAgentLauncher(record)
            try stopCodingAgentRecord(record)
            return try launchAgentLauncher(workspaceID: workspaceID, launcherID: launcher.id)
        }
    }

    /// How an agent-row termination should be finalized, chosen by the caller and interpreted by
    /// `finalizeAgentRow`.
    public enum AgentTerminationReason: Sendable {
        /// A hard stop/destroy driven by an operator action or by the backing terminal going away: the row
        /// is unconditionally deleted and its inbound watch edges dropped. `terminateTerminalSession` kills
        /// the backing built-in terminal when the caller has not already done so.
        case destroyed(terminateTerminalSession: Bool)
        /// A lifecycle exit reported by a hook signal, a remote signal, or a device-runtime reconciler. The
        /// delete-vs-keep decision is delegated to `handleAgentExit` (configured launcher → `.done`; a
        /// never-signaled ad-hoc detection row on a live terminal → silent demote/delete; any other row on
        /// a live terminal → `.exited`; a row whose terminal has ended → delete).
        case exited(eventType: String, eventSource: String, environmentKeys: [String]?)
    }

    /// The single finalization chokepoint every agent-row termination routes through — sidebar / Device
    /// API stop, restart, `agent kill`, workspace stop, terminal teardown, stale-slot relaunch, orphan
    /// prune, and every hook / remote-signal / reconciler exit. Owning it in one place is what guarantees
    /// a watched child's subscribers are always told it exited before the row goes away and that the
    /// terminated terminal's own watch state is always torn down. In order it:
    ///  1. gates on the finalized fact for idempotency (`agentRowIsFinalized` — status `.exited`, or a
    ///     recorded `exit` event) — an already-finalized row is never re-notified (a `.destroyed` reason
    ///     still deletes it and tears down watch state; an `.exited` reason is a no-op), so a repeated
    ///     reconcile pass over an already-exited row delivers no duplicate notice. Keying on the recorded
    ///     exit event, not `.done` status, is what lets killing a live agent that is merely resting `.done`
    ///     between turns still deliver its one exited notice;
    ///  2. renders/enqueues the `exited` notice to the row's subscribers (`childDidTransition`) while its
    ///     inbound edges still exist — a no-op when it has no subscribers;
    ///  3. applies the disposition: `.exited` defers to `handleAgentExit` (keep `.done`/`.exited`, demote,
    ///     or delete — the delete branch drops the inbound edges explicitly), while `.destroyed`
    ///     unconditionally drops the inbound edges and deletes the row (terminating the terminal first when
    ///     asked);
    ///  4. tears down the terminated terminal's OWN standing as a subscriber — its inbound queue and every
    ///     outgoing local/remote watch edge (`subscriberDidExit`) — since it can never be a delivery target
    ///     again under this session id.
    /// Because `agent_subscriptions.agent_session_id` is `ON DELETE RESTRICT`, the inbound edges must be
    /// dropped explicitly here; a delete that bypasses this chokepoint leaves them in place and fails
    /// loudly. The never-signaled ad-hoc demote is a documented variant of the same door: it notifies
    /// nothing (a never-signaled row has no subscribers — `childDidTransition` is a no-op, and per the
    /// subscribe contract no watcher can even attach) and does NOT drop inbound edges, so a leftover edge
    /// on such a row makes the delete throw under RESTRICT — the enforcement working. The engine is built
    /// inside via `makeAgentNotificationEngine`; with no submitter installed (non-daemon callers, tests
    /// without subscribers) delivery is simply never attempted because the row has no subscribers.
    @discardableResult public func finalizeAgentRow(_ record: AgentWindowRecord, reason: AgentTerminationReason) throws -> AgentWindowRecord? {
        let engine = makeAgentNotificationEngine()
        let alreadyFinalized = try agentRowIsFinalized(record)
        switch reason {
        case .destroyed(let terminateTerminalSession):
            // Destroys delete the row and (usually) terminate the backing terminal. During a daemon
            // handoff the terminal side becomes a silent no-op (`terminateBuiltInTerminalSession` defers to
            // the successor daemon), so proceeding would delete rows for a terminal that survives the
            // handoff. Veto at the chokepoint so every destroy path — workspace stop, agent kill, stale-slot
            // eviction — either does both or neither. `.exited` stays admitted: it records an observed exit
            // and performs no terminal-side work that a handoff could split.
            guard !daemonHandoffInProgress() else { throw WorkspaceError.daemonHandoffInProgress }
            if !alreadyFinalized { try engine.childDidTransition(agent: record, transition: .exited) }
            if terminateTerminalSession, let sessionID = record.terminalTrackingID, !sessionID.isEmpty { terminateBuiltInTerminalSession(sessionID) }
            try store.deleteAgentSubscriptions(agentSessionID: record.id)
            try store.deleteAgentWindow(id: record.id)
            try removeAdHocTrackedWindowForAgent(
                workspaceID: record.workspaceID, provider: record.provider, terminalTrackingID: record.terminalTrackingID)
            if let sessionID = record.terminalTrackingID, !sessionID.isEmpty { try engine.subscriberDidExit(subscriberTerminalSessionID: sessionID) }
            return nil
        case .exited(let eventType, let eventSource, let environmentKeys):
            if alreadyFinalized { return record }
            try engine.childDidTransition(agent: record, transition: .exited)
            let result = try handleAgentExit(record, eventType: eventType, eventSource: eventSource, environmentKeys: environmentKeys)
            if let sessionID = record.terminalTrackingID, !sessionID.isEmpty { try engine.subscriberDidExit(subscriberTerminalSessionID: sessionID) }
            return result
        }
    }

    /// Terminates a coding-agent record through the finalization chokepoint. A stop is a hard destroy: it
    /// terminates the backing terminal and deletes the row (even a configured launcher's) unconditionally.
    /// Shared by the macOS sidebar / Device API stop (`stopCodingAgent`), restart (`restartCodingAgent`,
    /// which stops the old child here before relaunching a fresh session/row), and `agent kill`'s
    /// hook-signaled branch (`killAgentSession`).
    func stopCodingAgentRecord(_ record: AgentWindowRecord) throws {
        try finalizeAgentRow(record, reason: .destroyed(terminateTerminalSession: true))
    }

    func restartableCodingAgentLauncher(_ record: AgentWindowRecord) throws -> AgentLauncher {
        let launchers = try store.workspaceAgentLaunchers(workspaceID: record.workspaceID)
        if let claimedLauncherID = record.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines), !claimedLauncherID.isEmpty {
            guard let launcher = launchers.first(where: { $0.id == claimedLauncherID }) else {
                throw WorkspaceError.invalidArgument(message: "Configured coding agent not found.")
            }
            return launcher
        }
        if let claimedLauncherName = record.claimedLauncherName?.trimmingCharacters(in: .whitespacesAndNewlines), !claimedLauncherName.isEmpty {
            guard let launcher = launchers.first(where: { normalizedFocusName($0.name) == normalizedFocusName(claimedLauncherName) }) else {
                throw WorkspaceError.invalidArgument(message: "Configured coding agent not found.")
            }
            return launcher
        }
        if let label = record.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
            let launcher = launchers.first(where: { normalizedFocusName($0.name) == normalizedFocusName(label) })
        {
            return launcher
        }
        throw WorkspaceError.invalidArgument(message: "Unconfigured live coding agents cannot be restarted from Spaces.")
    }

    @discardableResult public func launchAgentLauncher(workspaceID: String, name: String, background: Bool = false) throws -> AgentWindowRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Coding agent name is required.") }
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        guard let launcher = settings?.agentLaunchers.first(where: { normalizedFocusName($0.name) == normalizedFocusName(trimmedName) }) else {
            throw WorkspaceError.invalidArgument(message: "Configured coding agent not found.")
        }
        return try launchAgentLauncher(launcher, project: project, workspace: workspace, background: background)
    }

    @discardableResult public func launchAgentLauncher(workspaceID: String, launcherID: String, background: Bool = false) throws -> AgentWindowRecord
    {
        let trimmedID = launcherID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw WorkspaceError.invalidArgument(message: "Coding agent ID is required.") }
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        guard let launcher = settings?.agentLaunchers.first(where: { $0.id == trimmedID }) else {
            throw WorkspaceError.invalidArgument(message: "Configured coding agent not found.")
        }
        return try launchAgentLauncher(launcher, project: project, workspace: workspace, background: background)
    }

    @discardableResult func launchAgentLauncher(_ launcher: AgentLauncher, project: ProjectRecord, workspace: WorkspaceRecord, background: Bool)
        throws -> AgentWindowRecord
    {
        let workspaceID = workspace.id
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        if let existing = try store.agentWindows(workspaceID: workspaceID).first(where: {
            if $0.claimedLauncherID == launcher.id { return true }
            guard $0.claimedLauncherID == nil else { return false }
            return normalizedFocusName($0.label ?? $0.claimedLauncherName ?? "") == normalizedFocusName(launcher.name)
        }) {
            if existing.provider == .spaces, !builtInAgentSessionIsStillLive(existing) {
                try removeStaleAgentWindow(existing)
            } else {
                if try focusAgentWindowRecord(existing, requestID: nil) {
                    try markWorkspaceRunningIfNeeded(workspace)
                    return existing
                }
                // A failed focus attempt is not enough evidence to destroy the reserved row.
                // Only evict the existing record when its terminal session is actually gone;
                // otherwise keep the current slot and treat launch as an idempotent no-op.
                if existing.provider == .spaces, builtInAgentSessionIsStillLive(existing) {
                    try markWorkspaceRunningIfNeeded(workspace)
                    return existing
                }
                try removeStaleAgentWindow(existing)
            }
        }

        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) }, runtimeManifest: runtimeManifest
        )
        var launchEnv = try terminalLaunchEnvironment(base: env, includeInheritedPath: false, includeProfileEnvironment: true)
        _ = background
        let agentSessionID = UUID().uuidString
        launchEnv[Self.terminalTrackingIDEnvVar] = agentSessionID
        let shellPath = terminalShellPathOverride()
        let sessionCommand = commandPrefixedWithShellEnvironment(
            wrappedAgentLauncherCommand(
                name: launcher.name, command: applyEnvVars(launcher.command, env: env), shellPath: shellPath, commandPrelude: nil), env: launchEnv)
        let session = try launchSpacesTerminalSession(
            title: launcher.name, workingDirectory: workspace.dir, command: sessionCommand, showMode: .owner, backend: .ghosttyEmbedded,
            readinessPolicy: .sessionReady, sessionID: agentSessionID, workspaceID: workspace.id, kind: .agent)
        let record = try registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: launcher.name, terminalTrackingID: session.sessionID, status: .idle,
            claimedLauncherID: launcher.id, claimedLauncherName: launcher.name)
        try markWorkspaceRunningIfNeeded(workspace)
        return record
    }

    func wrappedAgentLauncherCommand(name: String, command: String, shellPath: String?, commandPrelude: String? = nil) -> String {
        let escapedName = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\''")
        let wrappedCommand = commandWithPrelude("printf '\\033]0;\(escapedName)\\007'; \(command)", prelude: commandPrelude)
        let resolvedShell: String
        if let trimmedShell = shellPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedShell.isEmpty {
            resolvedShell = trimmedShell
        } else {
            resolvedShell = defaultInteractiveShellPath()
        }
        return "exec \(shellQuoted(resolvedShell)) -ilc \(shellQuoted(wrappedCommand))"
    }

    func focusAgentWindowRecord(_ record: AgentWindowRecord, requestID: String?) throws -> Bool {
        let terminalApp = record.provider == .spaces ? TerminalHost.spaces.appName : nil
        let focusResult = focusManagedTerminal(terminalApp: terminalApp, providerIdentity: record.terminalFocusIdentity, requestID: requestID)
        switch focusResult {
        case .sessionRequest: return true
        case .unavailable: return false
        }
    }

    // MARK: - Orchestration rows (shared by the profile command surface and the Device API)

    /// Trims an optional string to nil when empty, matching the daemon's `normalizedProfileArgument`
    /// normalization so the shared orchestration rows carry exactly the values the profile surface did.
    private func trimmedOrNilAgentField(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The coding agent's detected kind (claude/codex/opencode) for a terminal session — the `agent:`
    /// field of an orchestration row — read only from the session's persisted foreground runtime state,
    /// never the `.agent` launch title. This is the machine-readable identity remote notification
    /// rendering uses as the `(<kind>)` parenthetical; keeping it off the launch title is what prevents a
    /// "Reviewer (Reviewer)" duplication and preserves the claude/codex/opencode identity in listings.
    /// Nil until a kind is detected, which renders honestly as "coding agent" downstream.
    func agentRuntimeKind(terminalSessionID: String) -> String? {
        guard let paths = try? TerminalSessionPaths.forSession(id: terminalSessionID),
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        else { return nil }
        return runtimeState.foregroundDetectedAgentKind?.displayLabel
    }

    /// Builds the orchestration view of coding-agent sessions shared by the local `agent list`/`status`
    /// profile command and the Device API `listAgentSessions` handler, so both surfaces report identical
    /// rows. `workspaceID` narrows to one workspace; `sessionID` narrows to the agent bound to that
    /// terminal tracking id (single-agent `status` and readiness polling). `lastSignalAt` is the
    /// readiness marker: nil until the agent's hooks emit their first lifecycle signal.
    public func agentSessionRows(workspaceID: String? = nil, sessionID: String? = nil) throws -> [TerminalServiceAgentSessionRow] {
        var rows: [TerminalServiceAgentSessionRow] = []
        for project in try store.projects() {
            for workspace in try store.workspaces(projectID: project.id, includeArchived: true) {
                if let workspaceID, workspace.id != workspaceID { continue }
                for agent in try store.agentWindows(workspaceID: workspace.id) where agent.provider == .spaces {
                    let terminalSessionID = trimmedOrNilAgentField(agent.terminalTrackingID)
                    if let sessionID, terminalSessionID != sessionID { continue }
                    // `agent:` carries the detected kind (claude/codex/opencode), never the launch title;
                    // `label:` carries the row's stored label — the workspace-unique visible name, which
                    // signals keep fresh and collisions uniquify ("Reviewer 2"), so two children never
                    // report the same label. Collapsing kind and label made remote rendering emit
                    // "Reviewer (Reviewer)" and dropped the kind from listings.
                    let detectedKind = terminalSessionID.flatMap { agentRuntimeKind(terminalSessionID: $0) }
                    rows.append(
                        TerminalServiceAgentSessionRow(
                            id: agent.id, terminalSessionID: terminalSessionID, agent: detectedKind, label: trimmedOrNilAgentField(agent.label),
                            status: agent.status.rawValue, note: trimmedOrNilAgentField(agent.note), projectID: project.id, projectName: project.name,
                            workspaceID: workspace.id, workspaceName: workspace.displayName, workspaceDir: workspace.dir,
                            branch: trimmedOrNilAgentField(workspace.branch), updatedAt: agent.updatedAt,
                            lastSignalAt: try store.lastAgentSignalAt(agentSessionID: agent.id)))
                }
            }
        }
        return rows
    }

    /// Sets (or clears, with an empty note) a coding-agent session's explicit note, addressed by its
    /// terminal session id, and returns the updated row. Shared by the profile `agentAnnotate` command
    /// and the Device API `annotateAgentSession` handler so both sanitize identically. Errors loudly
    /// when no agent row is bound to the session yet (annotation requires a hook-signaled agent).
    @discardableResult public func annotateAgentSession(terminalSessionID: String, note: String) throws -> TerminalServiceAgentSessionRow {
        guard let target = try agentSessionRows(sessionID: terminalSessionID).first else {
            throw WorkspaceError.invalidArgument(
                message: "No agent session for terminal \(terminalSessionID). Annotate requires an active coding-agent session (hook-signaled).")
        }
        let sanitized = Self.sanitizedAgentNote(note)
        try store.setAgentSessionNote(id: target.id, note: sanitized.isEmpty ? nil : sanitized)
        guard let updated = try agentSessionRows(sessionID: terminalSessionID).first else {
            throw WorkspaceError.invalidArgument(message: "No agent session for terminal \(terminalSessionID).")
        }
        return updated
    }

    /// Notes are single-line, bounded, plain text: control characters (including any embedded newlines)
    /// are removed so an annotation can never inject terminal control sequences or break the one-line
    /// injection format, then the result is trimmed and capped.
    public static func sanitizedAgentNote(_ note: String) -> String {
        let stripped = String(note.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return String(stripped.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }

}
