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
                // A live session that already has a row is normally left alone, but an ad-hoc detected
                // agent whose foreground genuinely reverted to its own plain shell is demoted back to a
                // plain terminal here — the one place a live session sheds its ad-hoc classification.
                if isAdHocDetectedForegroundAgent(existingRow), foregroundHasRevertedToPlainShell(session) {
                    try demoteAdHocDetectedForegroundAgent(existingRow)
                    didMutate = true
                }
                continue
            }
            if let detectedAgent = adHocDetectedForegroundAgent(from: session.runtimeState) {
                try insertAdHocDetectedAgent(detectedAgent: detectedAgent, workspace: workspace, sessionID: sessionID)
                didMutate = true
            }
        }
        if try reconcileExitedAdHocForegroundAgentRows(excludingLiveSessionIDs: liveSessionIDs) { didMutate = true }
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
        let resolvedLabel = try uniqueAgentFocusLabel(workspaceID: workspace.id, preferredLabel: detectedAgent.label)
        let record = AgentWindowRecord(
            id: adHocDetectedAgentID(sessionID: sessionID), workspaceID: workspace.id, provider: .spaces, label: resolvedLabel,
            runtimeTargetID: terminalWindow?.id, terminalTarget: terminalTarget, sessionKey: nil, claimedLauncherID: nil, claimedLauncherName: nil,
            status: .idle, createdAt: now, updatedAt: now)
        let nextAgentWindows = try store.agentWindows(workspaceID: workspace.id) + [record]
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: try store.workspaceProcesses(workspaceID: workspace.id),
            browserSessions: try store.workspaceBrowserSessions(workspaceID: workspace.id), agentWindows: nextAgentWindows)

        try store.upsertAgentWindow(record)
        _ = try updateAdHocAgentRuntimeTargetDetail(record, displayCommand: detectedAgent.displayCommand)
    }

    func adHocDetectedAgentID(sessionID: String) -> String { "terminal-agent-\(sessionID)" }

    /// True when `record` is an ad-hoc coding-agent row that foreground detection promoted from a plain
    /// terminal (id == `adHocDetectedAgentID(sessionID)`), as opposed to an explicitly spawned or
    /// configured-launcher agent. Only these are demoted back to plain terminals on agent exit.
    func isAdHocDetectedForegroundAgent(_ record: AgentWindowRecord) -> Bool {
        guard record.provider == .spaces, let sessionID = builtInAgentSessionID(for: record) else { return false }
        return record.id == adHocDetectedAgentID(sessionID: sessionID)
    }

    /// Reverts a foreground-detection promotion: removes the ad-hoc agent row and clears the agent-command
    /// detail it wrote onto the shared terminal window, WITHOUT terminating the terminal session or deleting
    /// its window — the shell is still live and must remain as a plain terminal. Used when the detected agent
    /// process exits but the terminal stays open, so the session stops being counted as a coding agent.
    func demoteAdHocDetectedForegroundAgent(_ record: AgentWindowRecord) throws {
        _ = try? updateAdHocAgentRuntimeTargetDetail(record, displayCommand: nil)
        try store.deleteAgentWindow(id: record.id)
    }

    @discardableResult func reconcileExitedAdHocForegroundAgentRows(excludingLiveSessionIDs liveSessionIDs: Set<String>) throws -> Bool {
        var didMutate = false
        for project in try store.projects() {
            for workspace in try store.workspaces(projectID: project.id, includeArchived: false) {
                for agent in try store.agentWindows(workspaceID: workspace.id) where agent.provider == .spaces {
                    guard let sessionID = builtInTerminalSessionID(for: agent), !liveSessionIDs.contains(sessionID) else { continue }
                    guard let launchConfiguration = terminalSessionLaunchConfiguration(sessionID: sessionID), launchConfiguration.kind == .shell
                    else { continue }
                    guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
                        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive
                    else { continue }
                    if agent.status != .done {
                        try store.updateAgentWindowStatus(id: agent.id, status: .done, updatedAt: nowISO8601())
                        didMutate = true
                    }
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
            try store.deleteAgentWindow(id: agent.id)
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
            try handleAgentExit(existingAgent, eventType: type.rawValue, eventSource: "remote_spaces_signal", environmentKeys: event.environmentKeys)
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

    func removeStaleAgentWindow(_ record: AgentWindowRecord) throws {
        terminateBuiltInTerminalSession(record.terminalTrackingID)
        try store.deleteAgentWindow(id: record.id)
        try removeAdHocTrackedWindowForAgent(
            workspaceID: record.workspaceID, provider: record.provider, terminalTrackingID: record.terminalTrackingID)
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
            if isAdHocDetectedForegroundAgent(existing) {
                // Foreground-detected agent's process ended but its shell terminal is still live: demote
                // to a plain terminal rather than keeping a phantom "exited" coding-agent row on the shell.
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
    /// implementation of `spaces agent kill` (`.agentKill`). A hook-signaled child (one with an agent
    /// row) is stopped through the coding-agent stop path *after* its subscribers are told it exited:
    /// stopping deletes the agent row, whose FK cascade removes the subscription edges, so the notice
    /// must be delivered or queued first (`childDidTransition`'s documented contract — queued rows
    /// have no FK and survive the deletion). A not-yet-signaled session goes through
    /// `terminateSpawnedAgentTerminalSession`, whose `.agent` launch-kind gate refuses ordinary shell
    /// and process terminals. Returns false when the id names neither, for the caller to surface
    /// loudly.
    public func killAgentSession(terminalSessionID: String, engine: AgentNotificationEngine) throws -> Bool {
        if let match = try resolveSpacesAgentSession(terminalSessionID: terminalSessionID) {
            try engine.childDidTransition(agent: match.record, transition: .exited)
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

    func stopCodingAgentRecord(_ record: AgentWindowRecord) throws {
        if let sessionID = record.terminalTrackingID, !sessionID.isEmpty { terminateBuiltInTerminalSession(sessionID) }
        appendAgentSessionEvent(
            agentSessionID: record.id, eventType: "stop", source: "orchestrator",
            message: agentSessionEventMessage(
                provider: record.provider, label: record.label, terminalTrackingID: record.terminalTrackingID, sessionKey: record.sessionKey),
            createdAt: nowISO8601())
        try store.deleteAgentWindow(id: record.id)
        try removeAdHocTrackedWindowForAgent(
            workspaceID: record.workspaceID, provider: record.provider, terminalTrackingID: record.terminalTrackingID)
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
        var launchEnv = terminalLaunchEnvironment(base: env, includeInheritedPath: false, includeProfileEnvironment: true)
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
                            id: agent.id, terminalSessionID: terminalSessionID, agent: detectedKind,
                            label: trimmedOrNilAgentField(agent.label), status: agent.status.rawValue,
                            note: trimmedOrNilAgentField(agent.note),
                            projectID: project.id, projectName: project.name, workspaceID: workspace.id, workspaceName: workspace.displayName,
                            workspaceDir: workspace.dir, branch: trimmedOrNilAgentField(workspace.branch), updatedAt: agent.updatedAt,
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
        try store.setAgentSessionNote(id: target.id, note: sanitized.isEmpty ? nil : sanitized, updatedAt: nowISO8601())
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
