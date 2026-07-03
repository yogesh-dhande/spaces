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
            if try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID) != nil { continue }
            if let detectedAgent = adHocDetectedForegroundAgent(from: session.runtimeState) {
                try insertAdHocDetectedAgent(detectedAgent: detectedAgent, workspace: workspace, sessionID: sessionID)
                didMutate = true
            }
        }
        if try reconcileExitedAdHocForegroundAgentRows(excludingLiveSessionIDs: liveSessionIDs) { didMutate = true }
        return didMutate
    }

    func adHocDetectedForegroundAgent(from runtimeState: TerminalSessionRuntimeState) -> (label: String, displayCommand: String?)? {
        guard let kind = runtimeState.foregroundDetectedAgentKind else { return nil }
        let label = runtimeState.foregroundDisplayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayCommand = runtimeState.foregroundDisplayCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label.flatMap { $0.isEmpty ? nil : $0 } ?? kind.displayLabel, displayCommand.flatMap { $0.isEmpty ? nil : $0 })
    }

    func insertAdHocDetectedAgent(detectedAgent: (label: String, displayCommand: String?), workspace: WorkspaceRecord, sessionID: String) throws {
        let terminalWindow = try store.windows(workspaceID: workspace.id).first { window in
            window.role == "terminal" && terminalHost(for: window.app) == .spaces && terminalSessionID(for: window) == sessionID
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
                terminalTrackingID: window.terminalTrackingID, terminalNativeID: window.terminalNativeID,
                role: window.role, orderIndex: window.orderIndex, lastSeenAt: nowISO8601()))
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
        guard window.role == "terminal", terminalHost(for: window.app) == .spaces, let sessionID = terminalSessionID(for: window) else {
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
            guard window.role == "terminal" else { return false }
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

    @discardableResult public func recordRemoteAgentSignal(_ event: TerminalServiceAgentSignalEvent) throws -> Bool {
        guard let type = RemoteAgentSignalType(rawValue: event.type), let provider = AgentProvider(rawValue: event.provider) else { return false }
        guard let workspaceID = try remoteAgentSignalWorkspaceID(event) else { return false }
        let terminalTrackingID = sanitizedFocusName(event.terminalTrackingID) ?? sanitizedFocusName(event.sessionID)
        let terminalNativeID = sanitizedFocusName(event.terminalNativeID) ?? terminalTrackingID
        let codexThreadID = sanitizedFocusName(event.codexThreadID)
        let existingAgent = try matchingAgentWindow(workspaceID: workspaceID, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID)
        let signalLabel = sanitizedFocusName(event.label) ?? sanitizedFocusName(existingAgent?.label)
        let canRecordSignal = existingAgent != nil || type == .`init` || (type.establishesAgentFromEvidence && signalLabel != nil)
        guard canRecordSignal else { return true }

        switch type {
        case .`init`:
            try registerAgentWindow(
                workspaceID: workspaceID, provider: provider, label: signalLabel, terminalTrackingID: terminalTrackingID,
                terminalNativeID: terminalNativeID, codexThreadID: codexThreadID, status: existingAgent?.status ?? .idle, eventType: type.rawValue,
                eventSource: "remote_spaces_signal", environmentKeys: event.environmentKeys)
        case .working, .blocked, .done:
            try updateAgentWindowStatus(
                workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID,
                terminalNativeID: terminalNativeID, label: signalLabel, status: type.status, eventType: type.rawValue,
                eventSource: "remote_spaces_signal", environmentKeys: event.environmentKeys)
        case .exit:
            guard let existingAgent else { return true }
            try handleAgentExit(
                existingAgent, terminalNativeID: terminalNativeID, eventType: type.rawValue, eventSource: "remote_spaces_signal",
                environmentKeys: event.environmentKeys)
        }
        return true
    }

    func remoteAgentSignalWorkspaceID(_ event: TerminalServiceAgentSignalEvent) throws -> String? {
        if let workspaceID = sanitizedFocusName(event.workspaceID), try store.workspace(id: workspaceID) != nil { return workspaceID }
        if let workspacePath = sanitizedFocusName(event.workspacePath), let workspace = try store.workspace(dir: workspacePath) {
            return workspace.id
        }
        let candidateSessionIDs = Set(
            [event.terminalNativeID, event.terminalTrackingID, event.sessionID].compactMap { normalizedTerminalSessionID($0) })
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

    func matchingAgentWindow(workspaceID: String, terminalTrackingID: String?, codexThreadID: String?) throws -> AgentWindowRecord? {
        let allAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        return terminalTrackingID.flatMap { sessionID in allAgentWindows.first(where: { $0.terminalTrackingID == sessionID }) }
            ?? allAgentWindows.first(where: { $0.codexThreadID == codexThreadID && codexThreadID != nil })
    }

    func agentTerminalTargetID(terminalTrackingID: String?) -> String? {
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return "terminal:\(sessionID)" }
        return nil
    }

    func matchedWorkspaceProcessForAgent(workspaceID: String, provider: AgentProvider, terminalTrackingID: String?) throws -> RunningProcessRecord? {
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        let targetID = agentTerminalTargetID(terminalTrackingID: terminalTrackingID)
        if let targetID, let matched = processes.first(where: { $0.terminalTrackingKey == targetID }) { return matched }
        return processes.first(where: { process in
            guard provider == .spaces, process.terminalApp == TerminalHost.spaces.appName else { return false }
            if let terminalTrackingID, !terminalTrackingID.isEmpty, process.terminalTrackingID == terminalTrackingID { return true }
            return false
        })
    }

    func matchedTrackedWindowForAgent(workspaceID: String, provider: AgentProvider, terminalTrackingID: String?) throws -> WindowRecord? {
        let windows = try store.windows(workspaceID: workspaceID)
        if provider == .spaces, let terminalTrackingID, !terminalTrackingID.isEmpty,
            let trackedWindow = windows.first(where: {
                $0.role == "terminal" && $0.app == TerminalHost.spaces.appName && $0.terminalTrackingID == terminalTrackingID
            })
        {
            return trackedWindow
        }
        if let targetID = agentTerminalTargetID(terminalTrackingID: terminalTrackingID),
            let trackedWindow = windows.first(where: { $0.role == "terminal" && $0.terminalTrackingKey == targetID })
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
    func ensureTrackedWindowExistsForAgent(
        workspaceID: String, provider: AgentProvider, label: String?, terminalTrackingID: String?, terminalNativeID: String?
    ) throws -> WindowRecord? {
        _ = label
        guard
            let trackedWindow = try matchedTrackedWindowForAgent(workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID)
        else { return nil }
        let resolvedSessionID = terminalTrackingID ?? trackedWindow.terminalTrackingID
        let resolvedNativeID = terminalNativeID ?? trackedWindow.terminalNativeID
        guard resolvedSessionID != trackedWindow.terminalTrackingID || resolvedNativeID != trackedWindow.terminalNativeID else {
            return trackedWindow
        }
        let updated = WindowRecord(
            id: trackedWindow.id, workspaceID: trackedWindow.workspaceID, app: trackedWindow.app, name: trackedWindow.name,
            detail: trackedWindow.detail, targetURL: trackedWindow.targetURL, terminalTrackingID: resolvedSessionID,
            terminalNativeID: resolvedNativeID, role: trackedWindow.role, orderIndex: trackedWindow.orderIndex, lastSeenAt: nowISO8601())
        try store.upsert(window: updated)
        return updated
    }

    func removeStaleAgentWindow(_ record: AgentWindowRecord) throws {
        terminateBuiltInTerminalSession(record.terminalNativeID ?? record.terminalTrackingID)
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
        provider: AgentProvider, label: String?, terminalTrackingID: String?, terminalNativeID: String?, codexThreadID: String?,
        environmentKeys: [String]? = nil
    ) -> String {
        func normalizedValue(_ value: String?) -> String {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return "<nil>" }
            return value
        }

        let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelValue = (normalizedLabel?.isEmpty == false ? normalizedLabel : nil) ?? "<nil>"
        let trackingValue = normalizedValue(terminalTrackingID)
        let nativeValue = normalizedValue(terminalNativeID)
        let threadValue = normalizedValue(codexThreadID)
        let envKeysValue = environmentKeys.map { $0.isEmpty ? "<none>" : $0.joined(separator: ",") } ?? "<nil>"
        return
            "provider=\(provider.rawValue) label=\(labelValue) tracking_id=\(trackingValue) native_id=\(nativeValue) codex_thread_id=\(threadValue) env_keys=\(envKeysValue)"
    }

    func appendAgentSessionEvent(agentSessionID: String, eventType: String, source: String, message: String?, createdAt: String) {
        let runtimeTargetID = try? store.agentSessionRuntimeTargetID(id: agentSessionID)
        try? store.appendAgentSessionEvent(
            agentSessionID: agentSessionID, eventType: eventType, source: source, message: message, runtimeTargetID: runtimeTargetID,
            createdAt: createdAt)
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
        workspaceID: String, provider: AgentProvider, label: String? = nil, terminalTrackingID: String? = nil, terminalNativeID: String? = nil,
        codexThreadID: String? = nil, status: AgentWindowStatus = .idle, claimedLauncherID: String? = nil, claimedLauncherName: String? = nil,
        eventType: String = "register", eventSource: String = "orchestrator", environmentKeys: [String]? = nil
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        let existingAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        let matchedProcess = try matchedWorkspaceProcessForAgent(workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID)
        let resolvedTerminalNativeID = matchedProcess?.terminalNativeID ?? terminalNativeID
        let trackedWindow = try ensureTrackedWindowExistsForAgent(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID,
            terminalNativeID: resolvedTerminalNativeID)
        let finalTerminalNativeID = trackedWindow?.terminalNativeID ?? resolvedTerminalNativeID
        if let existing = try matchingAgentWindow(workspaceID: workspaceID, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID) {
            let resolvedClaimedLauncherName = claimedLauncherName ?? existing.claimedLauncherName
            let resolvedLabel = try uniqueAgentFocusLabel(
                workspaceID: workspaceID, preferredLabel: label ?? existing.label, excludingAgentWindowID: existing.id,
                claimedLauncherName: resolvedClaimedLauncherName)
            let updated = AgentWindowRecord(
                id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: resolvedLabel,
                runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                terminalTarget: TerminalTargetRecord(
                    runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                    trackingID: terminalTrackingID ?? finalTerminalNativeID ?? existing.terminalTrackingID),
                sessionKey: codexThreadID ?? existing.codexThreadID, claimedLauncherID: claimedLauncherID ?? existing.claimedLauncherID,
                claimedLauncherName: resolvedClaimedLauncherName, status: status, createdAt: existing.createdAt, updatedAt: now)
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
                browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID),
                agentWindows: existingAgentWindows.map { $0.id == existing.id ? updated : $0 })
            try store.upsertAgentWindow(updated)
            appendAgentSessionEvent(
                agentSessionID: updated.id, eventType: eventType, source: eventSource,
                message: agentSessionEventMessage(
                    provider: updated.provider, label: updated.label, terminalTrackingID: updated.terminalTrackingID,
                    terminalNativeID: updated.terminalNativeID, codexThreadID: updated.codexThreadID, environmentKeys: environmentKeys),
                createdAt: now)
            return updated
        }
        let resolvedLabel = try uniqueAgentFocusLabel(workspaceID: workspaceID, preferredLabel: label, claimedLauncherName: claimedLauncherName)
        let record = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspaceID, provider: provider, label: resolvedLabel, runtimeTargetID: trackedWindow?.id,
            terminalTarget: TerminalTargetRecord(runtimeTargetID: trackedWindow?.id, trackingID: terminalTrackingID ?? finalTerminalNativeID),
            sessionKey: codexThreadID, claimedLauncherID: claimedLauncherID, claimedLauncherName: claimedLauncherName, status: status, createdAt: now,
            updatedAt: now)
        try validateWorkspaceFocusNames(
            workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
            browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID), agentWindows: existingAgentWindows + [record])
        try store.upsertAgentWindow(record)
        appendAgentSessionEvent(
            agentSessionID: record.id, eventType: eventType, source: eventSource,
            message: agentSessionEventMessage(
                provider: record.provider, label: record.label, terminalTrackingID: record.terminalTrackingID,
                terminalNativeID: record.terminalNativeID, codexThreadID: record.codexThreadID, environmentKeys: environmentKeys), createdAt: now)
        return record
    }

    @discardableResult public func updateAgentWindowStatus(
        workspaceID: String, provider: AgentProvider, terminalTrackingID: String? = nil, codexThreadID: String? = nil,
        terminalNativeID: String? = nil, label: String? = nil, status: AgentWindowStatus, claimedLauncherName: String? = nil,
        eventType: String? = nil, eventSource: String = "orchestrator", environmentKeys: [String]? = nil
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        let allAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        let matchedProcess = try matchedWorkspaceProcessForAgent(workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID)
        let resolvedTerminalNativeID = matchedProcess?.terminalNativeID ?? terminalNativeID
        let trackedWindow = try ensureTrackedWindowExistsForAgent(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID,
            terminalNativeID: resolvedTerminalNativeID)
        let finalTerminalNativeID = trackedWindow?.terminalNativeID ?? resolvedTerminalNativeID
        let existing = try matchingAgentWindow(workspaceID: workspaceID, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID)
        if let existing {
            let resolvedClaimedLauncherName = claimedLauncherName ?? existing.claimedLauncherName
            let resolvedLabel = try uniqueAgentFocusLabel(
                workspaceID: workspaceID, preferredLabel: label ?? existing.label, excludingAgentWindowID: existing.id,
                claimedLauncherName: resolvedClaimedLauncherName)
            let updated = AgentWindowRecord(
                id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: resolvedLabel,
                runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                terminalTarget: TerminalTargetRecord(
                    runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                    trackingID: terminalTrackingID ?? finalTerminalNativeID ?? existing.terminalTrackingID),
                sessionKey: codexThreadID ?? existing.codexThreadID, claimedLauncherID: existing.claimedLauncherID,
                claimedLauncherName: resolvedClaimedLauncherName, status: status, createdAt: existing.createdAt, updatedAt: now)
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
                browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID),
                agentWindows: allAgentWindows.map { $0.id == existing.id ? updated : $0 })
            try store.upsertAgentWindow(updated)
            appendAgentSessionEvent(
                agentSessionID: updated.id, eventType: eventType ?? status.rawValue, source: eventSource,
                message: agentSessionEventMessage(
                    provider: updated.provider, label: updated.label, terminalTrackingID: updated.terminalTrackingID,
                    terminalNativeID: updated.terminalNativeID, codexThreadID: updated.codexThreadID, environmentKeys: environmentKeys),
                createdAt: now)
            return updated
        }
        return try registerAgentWindow(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID,
            terminalNativeID: resolvedTerminalNativeID, codexThreadID: codexThreadID, status: status, claimedLauncherName: claimedLauncherName,
            eventType: eventType ?? status.rawValue, eventSource: eventSource, environmentKeys: environmentKeys)
    }

    @discardableResult public func handleAgentExit(
        _ existing: AgentWindowRecord, terminalNativeID: String? = nil, eventType: String = "exit", eventSource: String = "orchestrator",
        environmentKeys: [String]? = nil
    ) throws -> AgentWindowRecord? {
        if try spacesAgentRecordIsConfiguredLauncher(workspaceID: existing.workspaceID, record: existing) {
            return try recordAgentExitStatus(
                existing, status: .done, terminalNativeID: terminalNativeID, eventType: eventType, eventSource: eventSource,
                environmentKeys: environmentKeys)
        }
        let sessionBackedSpacesAgent = builtInAgentSessionID(for: existing) != nil
        let existingSessionIsLive = sessionBackedSpacesAgent && builtInAgentSessionIsStillLive(existing)
        if existingSessionIsLive {
            return try recordAgentExitStatus(
                existing, status: .idle, terminalNativeID: terminalNativeID, eventType: eventType, eventSource: eventSource,
                environmentKeys: environmentKeys)
        }
        appendAgentSessionEvent(
            agentSessionID: existing.id, eventType: eventType, source: eventSource,
            message: agentSessionEventMessage(
                provider: existing.provider, label: existing.label, terminalTrackingID: existing.terminalTrackingID,
                terminalNativeID: terminalNativeID ?? existing.terminalNativeID, codexThreadID: existing.codexThreadID,
                environmentKeys: environmentKeys), createdAt: nowISO8601())
        terminateBuiltInTerminalSession(existing.terminalNativeID ?? existing.terminalTrackingID)
        try store.deleteAgentWindow(id: existing.id)
        try removeAdHocTrackedWindowForAgent(
            workspaceID: existing.workspaceID, provider: existing.provider, terminalTrackingID: existing.terminalTrackingID)
        return nil
    }

    func recordAgentExitStatus(
        _ existing: AgentWindowRecord, status: AgentWindowStatus, terminalNativeID: String?, eventType: String, eventSource: String,
        environmentKeys: [String]?
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        let terminalTarget: TerminalTargetRecord? =
            if existing.terminalTarget != nil || existing.terminalTrackingID != nil {
                TerminalTargetRecord(runtimeTargetID: existing.runtimeTargetID, trackingID: existing.terminalTrackingID)
            } else { nil }
        let updated = AgentWindowRecord(
            id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: existing.label,
            runtimeTargetID: existing.runtimeTargetID, terminalTarget: terminalTarget, sessionKey: existing.sessionKey,
            claimedLauncherID: existing.claimedLauncherID, claimedLauncherName: existing.claimedLauncherName, status: status,
            createdAt: existing.createdAt, updatedAt: now)
        try store.upsertAgentWindow(updated)
        appendAgentSessionEvent(
            agentSessionID: updated.id, eventType: eventType, source: eventSource,
            message: agentSessionEventMessage(
                provider: updated.provider, label: updated.label, terminalTrackingID: updated.terminalTrackingID,
                terminalNativeID: terminalNativeID ?? updated.terminalNativeID, codexThreadID: updated.codexThreadID, environmentKeys: environmentKeys
            ), createdAt: now)
        return updated
    }

    public func stopCodingAgent(workspaceID: String, agentID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard let record = try store.agentWindows(workspaceID: workspaceID).first(where: { $0.id == agentID }) else { return }
            try stopCodingAgentRecord(record)
            try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
        }
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
        if let sessionID = record.terminalNativeID ?? record.terminalTrackingID, !sessionID.isEmpty { terminateBuiltInTerminalSession(sessionID) }
        appendAgentSessionEvent(
            agentSessionID: record.id, eventType: "stop", source: "orchestrator",
            message: agentSessionEventMessage(
                provider: record.provider, label: record.label, terminalTrackingID: record.terminalTrackingID,
                terminalNativeID: record.terminalNativeID, codexThreadID: record.codexThreadID), createdAt: nowISO8601())
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
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
            runtimeManifest: runtimePlan.manifest)
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
            workspaceID: workspace.id, provider: .spaces, label: launcher.name, terminalTrackingID: session.sessionID,
            terminalNativeID: session.sessionID, status: .idle, claimedLauncherID: launcher.id, claimedLauncherName: launcher.name)
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

}
