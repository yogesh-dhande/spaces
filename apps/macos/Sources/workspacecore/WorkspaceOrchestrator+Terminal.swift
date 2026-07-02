import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    public func workspaceIDForTerminalSession(_ sessionID: String) throws -> String? { try store.workspaceIDForTerminalSession(sessionID) }

    @discardableResult public func stopBuiltInTerminalSessionClosedByUser(sessionID: String) throws -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID) else { return false }
        let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
        guard !builtInTerminalSessionHasConfiguredOwner(ownership) else { return false }
        guard let workspace = try workspaceForBuiltInTerminalSession(sessionID: sessionID, ownership: ownership) else { return false }
        return try stopAdHocBuiltInTerminalSession(workspaceID: workspace.id, sessionID: sessionID)
    }

    @discardableResult public func stopAdHocBuiltInTerminalSession(sessionID: String) throws -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID), let workspace = try workspaceForBuiltInTerminalSession(sessionID: sessionID)
        else { return false }
        return try stopAdHocBuiltInTerminalSession(workspaceID: workspace.id, sessionID: sessionID)
    }

    @discardableResult public func stopAdHocBuiltInTerminalSession(workspaceID: String, sessionID: String) throws -> Bool {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            try stopAdHocBuiltInTerminalSessionUnlocked(workspaceID: workspaceID, sessionID: sessionID)
        }
    }

    @discardableResult public func removeAdHocBuiltInTerminalSession(sessionID: String) throws -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID) else { return false }
        let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
        guard !builtInTerminalSessionHasConfiguredOwner(ownership) else { return false }
        let workspaceID: String?
        if let terminalWindowWorkspaceID = ownership.terminalWindowWorkspaceID {
            workspaceID = terminalWindowWorkspaceID
        } else {
            workspaceID = ownership.launchWorkspaceID
        }
        guard let workspaceID else { return false }
        let matchingWindowIDs = try store.windows(workspaceID: workspaceID).filter {
            $0.role == "terminal" && terminalHost(for: $0.app) == .spaces && ($0.terminalNativeID ?? $0.terminalTrackingID) == sessionID
        }.map(\.id)
        guard !matchingWindowIDs.isEmpty else { return false }
        for windowID in matchingWindowIDs { try store.deleteWindow(id: windowID) }
        try deleteAgentRows(forBuiltInTerminalSession: sessionID, workspaceID: workspaceID)
        try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
        return true
    }

    func stopAdHocBuiltInTerminalSessionUnlocked(workspaceID: String, sessionID: String) throws -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID), let workspace = try store.workspace(id: workspaceID) else { return false }
        let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
        guard !builtInTerminalSessionHasConfiguredOwner(ownership) else { return false }
        if let terminalWindowWorkspaceID = ownership.terminalWindowWorkspaceID {
            guard terminalWindowWorkspaceID == workspaceID else { return false }
        } else if let launchWorkspaceID = ownership.launchWorkspaceID {
            guard launchWorkspaceID == workspaceID else { return false }
        } else {
            guard terminalSession(sessionID: sessionID, belongsTo: workspace) else { return false }
        }
        let matchingWindowIDs = try store.windows(workspaceID: workspaceID).filter {
            $0.role == "terminal" && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
        }.map(\.id)
        terminateBuiltInTerminalSession(sessionID)
        for windowID in matchingWindowIDs { try store.deleteWindow(id: windowID) }
        try deleteAgentRows(forBuiltInTerminalSession: sessionID, workspaceID: workspaceID)
        try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
        return true
    }

    /// Renames an ad-hoc built-in terminal session: persists the user title on the daemon's
    /// terminal-session record and updates the `name` of the session's runtime-target rows so
    /// both the workspace terminal row and the session summary reflect the rename. Returns
    /// false when no ad-hoc session in the workspace matches.
    @discardableResult public func renameAdHocBuiltInTerminalSession(workspaceID: String, sessionID: String, title: String) throws -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkspaceError.invalidArgument(message: "Terminal session title must not be empty.") }
        // The lifecycle lock keeps the rename from re-upserting a window row that a concurrent
        // stop just deleted.
        return try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard let sessionID = normalizedTerminalSessionID(sessionID), let workspace = try store.workspace(id: workspaceID) else { return false }
            let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
            guard !builtInTerminalSessionHasConfiguredOwner(ownership) else { return false }
            if let terminalWindowWorkspaceID = ownership.terminalWindowWorkspaceID {
                guard terminalWindowWorkspaceID == workspaceID else { return false }
            } else if let launchWorkspaceID = ownership.launchWorkspaceID {
                guard launchWorkspaceID == workspaceID else { return false }
            } else {
                guard terminalSession(sessionID: sessionID, belongsTo: workspace) else { return false }
            }
            let matchingWindows = try store.windows(workspaceID: workspaceID).filter {
                $0.role == "terminal" && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
            }
            for window in matchingWindows {
                try store.upsert(
                    window: WindowRecord(
                        id: window.id, workspaceID: window.workspaceID, app: window.app, name: title, detail: window.detail,
                        targetURL: window.targetURL, windowID: window.windowID, terminalTrackingID: window.terminalTrackingID,
                        terminalNativeID: window.terminalNativeID, role: window.role, orderIndex: window.orderIndex, lastSeenAt: nowISO8601()))
            }
            if terminalSessionLaunchConfiguration(sessionID: sessionID) != nil {
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try TerminalSessionPersistence.writeUserTitle(title, sessionID: sessionID, paths: paths)
            }
            return true
        }
    }

    @discardableResult func deleteAgentRows(forBuiltInTerminalSession sessionID: String, workspaceID: String) throws -> Int {
        let matchingAgents = try store.agentWindows(workspaceID: workspaceID).filter { builtInTerminalSessionID(for: $0) == sessionID }
        for agent in matchingAgents { try store.deleteAgentWindow(id: agent.id) }
        return matchingAgents.count
    }

    func generatedAdHocTerminalWindowName(workspaceID: String) throws -> String {
        let usedNames = Set(try workspaceFocusableWindowNames(workspaceID: workspaceID).map(normalizedFocusName))
        var suffix = 1
        while usedNames.contains(normalizedFocusName("shell-\(suffix)")) { suffix += 1 }
        return "shell-\(suffix)"
    }

    func terminalTargetID(process: RunningProcessRecord) -> String? {
        if let sessionID = process.terminalNativeID, !sessionID.isEmpty { return sessionID }
        return process.terminalTrackingKey
    }

    func terminalTargetID(record: AgentWindowRecord) -> String? {
        if let sessionID = record.terminalNativeID, !sessionID.isEmpty { return sessionID }
        return record.terminalTrackingKey
    }

    func terminalTargetID(window: WindowRecord) -> String? {
        if let sessionID = window.terminalNativeID, !sessionID.isEmpty { return sessionID }
        return window.terminalTrackingKey
    }

    func terminalHost(for appName: String?) -> TerminalHost? {
        guard let appName else { return nil }
        return appName == TerminalHost.spaces.appName ? .spaces : nil
    }

    func isManagedTerminalApp(_ appName: String?) -> Bool { terminalHost(for: appName) != nil }

    func resolvedFocusIdentity(for window: WindowRecord, workspaceID: String) -> TerminalTrackingIdentity? {
        if let terminalHost = terminalHost(for: window.app), terminalHost == .spaces, let focusIdentity = window.terminalFocusIdentity {
            return focusIdentity
        }
        if let sessionID = window.terminalTrackingID, !sessionID.isEmpty { return .session(sessionID) }
        guard window.role == "terminal" else { return nil }
        if let windowID = window.windowID {
            if let processIdentity = try? store.runningProcesses(workspaceID: workspaceID).first(where: {
                $0.windowID == windowID && $0.terminalApp == window.app && $0.terminalFocusIdentity != nil
            })?.terminalFocusIdentity {
                return processIdentity
            }
            if let agentIdentity = try? store.agentWindows(workspaceID: workspaceID).first(where: {
                $0.provider == .spaces && window.app == TerminalHost.spaces.appName && (($0.yabaiWindowID ?? $0.windowID) == windowID)
                    && $0.terminalFocusIdentity != nil
            })?.terminalFocusIdentity {
                return agentIdentity
            }
            return .window(windowID)
        }
        return nil
    }

    func focusManagedTerminal(terminalApp: String?, providerIdentity: TerminalTrackingIdentity?, windowID: Int?, requestID: String? = nil)
        -> ManagedTerminalFocusResult
    {
        guard terminalHost(for: terminalApp) == .spaces else { return .unavailable }
        let startedAt = currentDate()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        if case .session(let sessionID)? = providerIdentity {
            builtInTerminalWindowFocuser(sessionID, requestID)
            guard requestID == nil else {
                logTerminalPerfMetric(
                    "built_in_terminal_focus_route", target: "session=\(sessionID)", detail: "stage=session_request\(requestDetail)",
                    elapsedMS: elapsedMS(since: startedAt), success: true)
                return .sessionRequest
            }
            if let capturedWindowID = try? captureSummonedBuiltInTerminalWindowID(appName: TerminalHost.spaces.appName) {
                if capturedWindowID != windowID {
                    logTerminalPerfMetric(
                        "built_in_terminal_focus_route", target: "session=\(sessionID)",
                        detail: "stage=rebound_session window=\(capturedWindowID)\(requestDetail)", elapsedMS: elapsedMS(since: startedAt),
                        success: true)
                    return .reboundSession(windowID: capturedWindowID)
                }
                logTerminalPerfMetric(
                    "built_in_terminal_focus_route", target: "session=\(sessionID)",
                    detail: "stage=existing_window window=\(capturedWindowID)\(requestDetail)", elapsedMS: elapsedMS(since: startedAt), success: true)
                return .existingWindow
            }
            if windowID != nil {
                logTerminalPerfMetric(
                    "built_in_terminal_focus_route", target: "session=\(sessionID)", detail: "stage=reopened_session window=nil\(requestDetail)",
                    elapsedMS: elapsedMS(since: startedAt), success: true)
                return .reopenedSession(windowID: nil)
            }
            logTerminalPerfMetric(
                "built_in_terminal_focus_route", target: "session=\(sessionID)", detail: "stage=session_request\(requestDetail)",
                elapsedMS: elapsedMS(since: startedAt), success: true)
            return .sessionRequest
        }
        if let windowID, (try? yabai.focusWindow(id: windowID)) ?? false {
            logTerminalPerfMetric(
                "built_in_terminal_focus_route", target: "window=\(windowID)", detail: "stage=existing_window\(requestDetail)",
                elapsedMS: elapsedMS(since: startedAt), success: true)
            return .existingWindow
        }
        return .unavailable
    }

    func pulseTerminalWindowIfNeeded(windowID: Int) {
        guard (try? windowFocusPulseEnabledProvider()) ?? SettingsKey.defaultWindowFocusPulseEnabled else { return }
        let color = (try? windowFocusPulseColorProvider()) ?? SettingsKey.windowFocusPulseColor(from: nil)
        terminalFocusPulseController.pulse(windowID: windowID, color: color, yabai: yabai)
    }

    func shellSingleQuoted(_ raw: String) -> String { "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'" }

    func interactiveShellCommand(cwd _: String) -> String { "exec \(shellSingleQuoted(terminalLoginShellPath())) -l" }

    func terminalLaunchEnvironment(base: [String: String], includeInheritedPath: Bool = true, includeProfileEnvironment: Bool = true)
        -> [String: String]
    {
        var env = base
        if includeInheritedPath, let path = Shell.currentProcessEnvironment()["PATH"], !path.isEmpty { env["PATH"] = path }
        if includeProfileEnvironment {
            for key in [DatabaseLocator.databasePathEnvironmentVariable, "SPACES_RUNTIME_DIR", "SPACES_E2E_EVENTS_LOG", "DEBUG"] {
                if let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    env[key] = value
                }
            }
        }
        env[Self.terminalTrackingIDEnvVar] = env[Self.terminalTrackingIDEnvVar] ?? UUID().uuidString
        return env
    }

    func terminalShellPathOverride() -> String? { terminalLoginShellPath() }

    func terminalLoginShellPath() -> String {
        let shellPath = Shell.resolvedLoginShellExecutablePath(environment: Shell.currentProcessEnvironment())?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return shellPath.flatMap { $0.isEmpty ? nil : $0 } ?? defaultInteractiveShellPath()
    }

    func defaultInteractiveShellPath() -> String {
        #if os(Linux)
            "/bin/bash"
        #else
            "/bin/zsh"
        #endif
    }

    func launchSpacesTerminalSession(
        title: String, workingDirectory: String, command: String?, showMode: TerminalAttachmentMode,
        backend: TerminalSessionBackendKind = .ghosttyEmbedded, readinessPolicy: BuiltInTerminalReadinessPolicy = .stableChildPID,
        sessionID: String? = nil, lifetimePolicy: TerminalSessionLifetimePolicy = .persistent, workspaceID: String? = nil,
        kind: TerminalSessionKind = .shell
    ) throws -> SpacesTerminalSessionHandle {
        let sessionID = sessionID ?? UUID().uuidString
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: backend, lifetimePolicy: lifetimePolicy, title: title, workingDirectory: workingDirectory,
            shell: terminalShellPathOverride() ?? "/bin/zsh", command: command, createdAt: nowISO8601(), workspaceID: workspaceID, kind: kind)

        let snapshot = bestEffortYabaiWindowSnapshot()
        builtInTerminalWindowOpener(sessionID, showMode)
        let waitStartedAt = currentDate()
        let sessionSummary: TerminalServiceSessionSummary
        do {
            sessionSummary = try builtInTerminalSessionLauncher(launchConfiguration)
            logTerminalPerfMetric(
                "terminal_session_wait_ready", target: "session=\(sessionID)",
                detail:
                    "policy=\(readinessPolicy.rawValue) state=\(sessionSummary.state.rawValue) child_pid=\(sessionSummary.childPID.map(String.init) ?? "-")",
                elapsedMS: elapsedMS(since: waitStartedAt), success: true)
        } catch {
            logTerminalPerfMetric(
                "terminal_session_wait_ready", target: "session=\(sessionID)", detail: "policy=\(readinessPolicy.rawValue)",
                elapsedMS: elapsedMS(since: waitStartedAt), success: false)
            builtInTerminalWindowCloser(sessionID)
            throw error
        }
        let windowCaptureDeadline = Date().addingTimeInterval(2)
        var windowID = bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: TerminalHost.spaces.appName)
        while windowID == nil, Date() < windowCaptureDeadline {
            Thread.sleep(forTimeInterval: 0.05)
            windowID = bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: TerminalHost.spaces.appName)
        }
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let refreshedRuntimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return SpacesTerminalSessionHandle(
            sessionID: sessionID, childPID: (refreshedRuntimeState?.childPID ?? sessionSummary.childPID).map(Int.init), windowID: windowID,
            outputPath: sessionSummary.outputPath)
    }

    func spacesTerminalCommand(
        template: ProcessTemplate, env: [String: String], shellPath: String? = nil, includeInheritedPath: Bool = true,
        includeProfileEnvironment: Bool = true, commandPrelude: String? = nil
    ) throws -> String {
        let command = commandWithPrelude(try processLaunchCommand(template: template), prelude: commandPrelude)
        let runtimeEnv = terminalLaunchEnvironment(
            base: env, includeInheritedPath: includeInheritedPath, includeProfileEnvironment: includeProfileEnvironment)
        let resolvedShellPath = shellPath ?? terminalLoginShellPath()
        return commandPrefixedWithShellEnvironment("exec \(shellQuoted(resolvedShellPath)) -l -c \(shellQuoted(command))", env: runtimeEnv)
    }

    func logTerminalPerfMetric(_ metric: String, target: String, detail: String = "", elapsedMS: Int, success: Bool) {
        TerminalPerformance.logMetric(metric, target: target, elapsedMS: elapsedMS, success: success, detail: detail)
    }

    func managedTrackedTerminalWindowIsStillLive(window: WindowRecord) -> Bool {
        guard window.role == "terminal", let host = terminalHost(for: window.app) else { return false }
        guard host == .spaces else { return false }
        return builtInTrackedWindowIsStillLive(window: window)
    }

    func builtInTrackedWindowIsStillLive(window: WindowRecord) -> Bool {
        guard window.role == "terminal", terminalHost(for: window.app) == .spaces else { return false }
        guard let sessionID = window.terminalNativeID ?? window.terminalTrackingID, !sessionID.isEmpty else { return false }
        if builtInSessionBelongsToRunningProcess(sessionID: sessionID, workspaceID: window.workspaceID) {
            return builtInSessionIsStillLive(sessionID: sessionID)
                || builtInSessionLaunchIsPending(sessionID: sessionID)
        }
        if builtInSessionBelongsToConfiguredAgent(sessionID: sessionID, workspaceID: window.workspaceID) {
            return builtInSessionIsStillLive(sessionID: sessionID)
                || builtInSessionLaunchIsPending(sessionID: sessionID)
        }
        if builtInSessionIsStillLive(sessionID: sessionID)
            && builtInSessionHasActiveAttachments(sessionID: sessionID)
        {
            return true
        }
        return builtInSessionLaunchIsPendingBeforeOwnerAttachment(sessionID: sessionID)
    }

    func builtInTrackedWindowBelongsToAgent(_ window: WindowRecord) -> Bool {
        guard window.role == "terminal", terminalHost(for: window.app) == .spaces else { return false }
        guard let sessionID = window.terminalNativeID ?? window.terminalTrackingID, !sessionID.isEmpty else { return false }
        return builtInSessionBelongsToAgent(sessionID: sessionID, workspaceID: window.workspaceID)
    }

    func builtInSessionIsStillLive(sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return false }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else { return false }
        guard runtimeState.state.isInteractive else { return false }
        return isProcessAlive(pid: Int(runtimeState.servicePID))
    }

    func builtInSessionLaunchIsPending(sessionID: String, now: Date = Date()) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths),
            runtimeState.state != .starting && runtimeState.state != .running
        {
            return false
        }
        guard let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            let createdAt = ISO8601DateFormatter().date(from: launchConfiguration.createdAt)
        else { return false }
        let age = now.timeIntervalSince(createdAt)
        return age >= -5 && age < 60
    }

    func builtInSessionLaunchIsPendingBeforeOwnerAttachment(sessionID: String, now: Date = Date()) -> Bool {
        guard !builtInSessionHasRecordedOwnerAttachment(sessionID: sessionID) else { return false }
        return builtInSessionLaunchIsPending(sessionID: sessionID, now: now)
    }

    func builtInSessionHasRecordedOwnerAttachment(sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths) else { return false }
        return snapshot.attachments.contains { $0.mode == .owner }
    }

    func builtInAgentSessionIsStillLive(_ record: AgentWindowRecord) -> Bool {
        guard record.provider == .spaces else { return false }
        guard let sessionID = builtInAgentSessionID(for: record) else { return false }
        return builtInSessionIsStillLive(sessionID: sessionID)
    }

    func builtInAgentSessionID(for record: AgentWindowRecord) -> String? {
        guard record.provider == .spaces else { return nil }
        let sessionID = record.terminalNativeID ?? record.terminalTrackingID
        guard let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func builtInSessionBelongsToRunningProcess(sessionID: String, workspaceID: String) -> Bool {
        ((try? store.runningProcesses(workspaceID: workspaceID)) ?? []).contains { ($0.terminalNativeID ?? $0.terminalTrackingID) == sessionID }
    }

    func builtInSessionBelongsToAgent(sessionID: String, workspaceID: String) -> Bool {
        ((try? store.agentWindows(workspaceID: workspaceID)) ?? []).contains { ($0.terminalNativeID ?? $0.terminalTrackingID) == sessionID }
    }

    func builtInSessionBelongsToConfiguredAgent(sessionID: String, workspaceID: String) -> Bool {
        switch terminalSessionLaunchConfiguration(sessionID: sessionID)?.kind {
        case .agent: return true
        case .shell, .process: return false
        case nil: return ((try? store.agentWindows(workspaceID: workspaceID)) ?? []).contains { builtInTerminalSessionID(for: $0) == sessionID }
        }
    }

    func builtInSessionHasActiveAttachments(sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        return ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).isEmpty == false
    }

    func captureSummonedBuiltInTerminalWindowID(appName: String) throws -> Int? {
        if let focused = try? yabai.focusedWindow(), focused.app == appName { return focused.id }
        return try yabai.listWindows().filter { $0.app == appName }.sorted { $0.id > $1.id }.first?.id
    }

    func resolvedBuiltInSessionRuntimePID(for process: RunningProcessRecord) -> Int? {
        resolvedBuiltInSessionRuntimeState(for: process)?.childPID.map(Int.init)
    }

    func resolvedBuiltInSessionRuntimeState(for process: RunningProcessRecord) -> TerminalSessionRuntimeState? {
        guard terminalHost(for: process.terminalApp) == .spaces else { return nil }
        guard let sessionID = process.terminalNativeID ?? process.terminalTrackingID, !sessionID.isEmpty else { return nil }
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return nil }
        return try? TerminalSessionPersistence.readRuntimeState(paths: paths)
    }

    func terminateBuiltInTerminalSession(_ sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else { return }
        builtInTerminalWindowCloser(sessionID)
        builtInTerminalSessionTerminator(sessionID)
    }

    func terminateBuiltInTerminalSessionsForConfiguredProcesses(workspaceID: String) throws {
        for process in try store.runningProcesses(workspaceID: workspaceID) { terminateBuiltInTerminalSession(for: process) }
    }

    func waitForBuiltInTerminalSessionsToExit(_ sessionIDs: Set<String>, timeout: TimeInterval = 10.0) {
        guard !sessionIDs.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        var pending = sessionIDs
        while !pending.isEmpty, Date() < deadline {
            pending = pending.filter { builtInTerminalSessionIsInteractive($0) }
            if pending.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if ProcessInfo.processInfo.environment["DEBUG"] == "1", !pending.isEmpty {
            Self.writeStandardError("spaces: timed out waiting for terminal sessions to exit: \(pending.sorted().joined(separator: ","))\n")
        }
    }

    func builtInTerminalSessionIsInteractive(_ sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), runtimeState.state.isInteractive
        else { return false }
        return runtimeState.servicePID == getpid() || isProcessAlive(pid: Int(runtimeState.servicePID))
    }

    func builtInTerminalSessionID(for process: RunningProcessRecord) -> String? {
        guard terminalHost(for: process.terminalApp) == .spaces else { return nil }
        return normalizedTerminalSessionID(process.terminalNativeID ?? process.terminalTrackingID)
    }

    func builtInTerminalSessionID(for agent: AgentWindowRecord) -> String? {
        guard agent.provider == .spaces else { return nil }
        return normalizedTerminalSessionID(agent.terminalNativeID ?? agent.terminalTrackingID)
    }

    func terminalSessionID(for window: WindowRecord) -> String? {
        normalizedTerminalSessionID(window.terminalNativeID ?? window.terminalTrackingID)
    }

    func normalizedTerminalSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func workspaceForBuiltInTerminalSession(sessionID: String, ownership existingOwnership: BuiltInTerminalSessionOwnership? = nil) throws
        -> WorkspaceRecord?
    {
        let ownership = try existingOwnership ?? builtInTerminalSessionOwnership(sessionID: sessionID)
        if let workspaceID = ownership.processWorkspaceID ?? ownership.agentWorkspaceID ?? ownership.terminalWindowWorkspaceID
            ?? ownership.launchWorkspaceID
        {
            return try store.workspace(id: workspaceID)
        }
        guard let workingDirectory = terminalSessionWorkingDirectory(sessionID: sessionID) else { return nil }
        let workspaces = try store.projects().flatMap { project in try store.workspaces(projectID: project.id, includeArchived: false) }
        return workspaces.filter { isPath(workingDirectory, inside: $0.dir, allowEqual: true) }.max {
            normalizePath($0.dir).count < normalizePath($1.dir).count
        }
    }

    func terminalSession(sessionID: String, belongsTo workspace: WorkspaceRecord) -> Bool {
        guard let workingDirectory = terminalSessionWorkingDirectory(sessionID: sessionID) else { return false }
        return isPath(workingDirectory, inside: workspace.dir, allowEqual: true)
    }

    func terminalSessionWorkingDirectory(sessionID: String) -> String? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            launchConfiguration.backend == .ghosttyEmbedded
        else { return nil }
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return runtimeState?.workingDirectory ?? launchConfiguration.workingDirectory
    }

    func builtInTerminalSessionOwnership(sessionID: String) throws -> BuiltInTerminalSessionOwnership {
        let workspaces = try store.projects().flatMap { project in try store.workspaces(projectID: project.id, includeArchived: true) }
        var owningProcess: RunningProcessRecord?
        var owningAgent: AgentWindowRecord?
        var terminalWindowWorkspaceID: String?
        for workspace in workspaces {
            if owningProcess == nil {
                owningProcess = try store.runningProcesses(workspaceID: workspace.id).first { builtInTerminalSessionID(for: $0) == sessionID }
            }
            if owningAgent == nil {
                owningAgent = try store.agentWindows(workspaceID: workspace.id).first { builtInTerminalSessionID(for: $0) == sessionID }
            }
            if terminalWindowWorkspaceID == nil,
                try store.windows(workspaceID: workspace.id).contains(where: {
                    $0.role == "terminal" && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
                })
            {
                terminalWindowWorkspaceID = workspace.id
            }
            if owningProcess != nil, owningAgent != nil, terminalWindowWorkspaceID != nil { break }
        }
        let launchConfiguration = terminalSessionLaunchConfiguration(sessionID: sessionID)
        return BuiltInTerminalSessionOwnership(
            process: owningProcess, agent: owningAgent, terminalWindowWorkspaceID: terminalWindowWorkspaceID,
            launchWorkspaceID: launchConfiguration?.workspaceID, launchKind: launchConfiguration?.kind)
    }

    func builtInTerminalSessionHasConfiguredOwner(_ ownership: BuiltInTerminalSessionOwnership) -> Bool {
        if ownership.process != nil { return true }
        switch ownership.launchKind {
        case .process, .agent: return true
        case .shell: return false
        case nil: return false
        }
    }

    func terminalSessionLaunchConfiguration(sessionID: String) -> TerminalSessionLaunchConfiguration? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            launchConfiguration.backend == .ghosttyEmbedded
        else { return nil }
        return launchConfiguration
    }

    func terminateBuiltInTerminalSession(for process: RunningProcessRecord) {
        terminateBuiltInTerminalSession(builtInTerminalSessionID(for: process))
    }

    func clearStaleBuiltInTerminalWindowBinding(_ agent: AgentWindowRecord) throws {
        guard agent.provider == .spaces else { return }
        let clearedAgent = AgentWindowRecord(
            id: agent.id, workspaceID: agent.workspaceID, provider: agent.provider, label: agent.label, runtimeTargetID: agent.runtimeTargetID,
            terminalTarget: agent.terminalTrackingID.map {
                TerminalTargetRecord(runtimeTargetID: agent.runtimeTargetID, windowID: nil, trackingID: $0)
            }, sessionKey: agent.sessionKey, claimedLauncherID: agent.claimedLauncherID, claimedLauncherName: agent.claimedLauncherName,
            status: agent.status, createdAt: agent.createdAt, updatedAt: nowISO8601())
        try store.upsertAgentWindow(clearedAgent)
    }

    func persistBuiltInTerminalWindowBinding(_ agent: AgentWindowRecord, windowID: Int) throws {
        guard agent.provider == .spaces else { return }
        let reboundAgent = AgentWindowRecord(
            id: agent.id, workspaceID: agent.workspaceID, provider: agent.provider, label: agent.label, runtimeTargetID: agent.runtimeTargetID,
            terminalTarget: agent.terminalTrackingID.map {
                TerminalTargetRecord(runtimeTargetID: agent.runtimeTargetID, windowID: windowID, trackingID: $0)
            }, sessionKey: agent.sessionKey, claimedLauncherID: agent.claimedLauncherID, claimedLauncherName: agent.claimedLauncherName,
            status: agent.status, createdAt: agent.createdAt, updatedAt: nowISO8601())
        try store.upsertAgentWindow(reboundAgent)
    }

    func clearStaleBuiltInTerminalWindowBinding(_ window: WindowRecord) throws {
        let clearedWindow = WindowRecord(
            id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: window.detail, targetURL: window.targetURL,
            windowID: nil, terminalTrackingID: window.terminalTrackingID, terminalNativeID: window.terminalNativeID, role: window.role,
            orderIndex: window.orderIndex, lastSeenAt: nowISO8601())
        try store.upsert(window: clearedWindow)
    }

    func matchesTrackedTerminalWindow(_ window: WindowRecord, process: RunningProcessRecord) -> Bool {
        guard window.role == "terminal", window.app == process.terminalApp else { return false }
        if window.id == process.id { return true }
        if let terminalID = process.terminalNativeID, !terminalID.isEmpty, window.terminalNativeID == terminalID { return true }
        if let terminalID = process.terminalTrackingID, !terminalID.isEmpty, window.terminalTrackingID == terminalID { return true }
        if let windowID = process.windowID, window.windowID == windowID { return true }
        return false
    }
}
