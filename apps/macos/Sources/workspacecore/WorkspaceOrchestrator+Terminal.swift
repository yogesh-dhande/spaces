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

    /// Terminates a spawned coding-agent terminal session by id and tears down its tracked window and
    /// agent rows — the not-yet-signaled fallback inside `killAgentSession`, which both the local
    /// `.agentKill` command and the remote `killAgentSession` Device API command route through when the
    /// session has no agent row for `stopCodingAgent` to target. Only a session launched with the
    /// `.agent` kind (`agent spawn`, an agent launcher)
    /// qualifies: `agent kill` addresses coding agents, and without the kind gate a mistyped or wrong
    /// session id naming an ordinary shell or process terminal would silently destroy it. Returns
    /// false for a non-agent or untracked session, which the caller surfaces as a loud error rather
    /// than a silent no-op.
    @discardableResult public func terminateSpawnedAgentTerminalSession(sessionID: String) throws -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID) else { return false }
        let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
        guard ownership.launchKind == .agent else { return false }
        guard
            let workspaceID = ownership.processWorkspaceID ?? ownership.agentWorkspaceID ?? ownership.terminalWindowWorkspaceID
                ?? ownership.launchWorkspaceID
        else { return false }
        return try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            let matchingWindowIDs = try store.windows(workspaceID: workspaceID).filter {
                $0.roleValue == .terminal && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
            }.map(\.id)
            terminateBuiltInTerminalSession(sessionID)
            for windowID in matchingWindowIDs { try store.deleteWindow(id: windowID) }
            try deleteAgentRows(forBuiltInTerminalSession: sessionID, workspaceID: workspaceID)
            try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
            return true
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
            $0.roleValue == .terminal && terminalHost(for: $0.app) == .spaces && $0.terminalTrackingID == sessionID
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
            $0.roleValue == .terminal && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
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
    ///
    /// An empty (or whitespace-only) title clears the rename instead of setting one, restoring the
    /// generated name the session was launched under — the only way back from a rename.
    @discardableResult public func renameAdHocBuiltInTerminalSession(workspaceID: String, sessionID: String, title: String) throws -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
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
                $0.roleValue == .terminal && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
            }
            let launchConfiguration = terminalSessionLaunchConfiguration(sessionID: sessionID)
            // The window record names its row only once the session is gone, so a rename writes it to
            // outlive the session and clearing one puts back the launch-generated name the record was
            // created with. With no session record left there is no name to restore, so it stands.
            if let windowName = title.isEmpty ? launchConfiguration?.title : title {
                for window in matchingWindows {
                    try store.upsert(
                        window: WindowRecord(
                            id: window.id, workspaceID: window.workspaceID, app: window.app, name: windowName, detail: window.detail,
                            targetURL: window.targetURL, terminalTrackingID: window.terminalTrackingID, role: window.role,
                            orderIndex: window.orderIndex, lastSeenAt: nowISO8601()))
                }
            }
            if launchConfiguration != nil {
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try TerminalSessionPersistence.writeUserTitle(title, sessionID: sessionID, paths: paths)
            }
            return true
        }
    }

    /// Finalizes the agent rows bound to a built-in terminal session that is being destroyed and tears
    /// down that terminal's own watch state. Every caller terminates the terminal named by `sessionID`
    /// immediately before calling this — a user-closed ad-hoc shell (`stopAdHocBuiltInTerminalSession`), a
    /// removed ad-hoc terminal (`removeAdHocBuiltInTerminalSession`), or the not-yet-signaled `agent kill`
    /// fallback (`terminateSpawnedAgentTerminalSession`) — so each matching row is destroyed through the
    /// finalization chokepoint (terminal already gone, so no re-termination): its subscribers are told it
    /// `exited` before the row is deleted, and the terminal's own inbound queue and outgoing watch edges
    /// are torn down. A final `subscriberDidExit` runs even when no agent row matched, because the
    /// destroyed terminal may have been a SUBSCRIBER of other agents without owning an agent row of its own.
    @discardableResult func deleteAgentRows(forBuiltInTerminalSession sessionID: String, workspaceID: String) throws -> Int {
        let matchingAgents = try store.agentWindows(workspaceID: workspaceID).filter { builtInTerminalSessionID(for: $0) == sessionID }
        for agent in matchingAgents { try finalizeAgentRow(agent, reason: .destroyed(terminateTerminalSession: false)) }
        try makeAgentNotificationEngine().subscriberDidExit(subscriberTerminalSessionID: sessionID)
        return matchingAgents.count
    }

    func generatedAdHocTerminalWindowName(workspaceID: String) throws -> String {
        let usedNames = Set(try workspaceFocusableWindowNames(workspaceID: workspaceID).map(normalizedFocusName))
        var suffix = 1
        while usedNames.contains(normalizedFocusName("shell-\(suffix)")) { suffix += 1 }
        return "shell-\(suffix)"
    }

    func terminalTargetID(process: RunningProcessRecord) -> String? {
        if let sessionID = process.terminalTrackingID, !sessionID.isEmpty { return sessionID }
        return process.terminalTrackingKey
    }

    func terminalTargetID(record: AgentWindowRecord) -> String? {
        if let sessionID = record.terminalTrackingID, !sessionID.isEmpty { return sessionID }
        return record.terminalTrackingKey
    }

    func terminalTargetID(window: WindowRecord) -> String? {
        if let sessionID = window.terminalTrackingID, !sessionID.isEmpty { return sessionID }
        return window.terminalTrackingKey
    }

    func terminalHost(for appName: String?) -> TerminalHost? {
        guard let appName else { return nil }
        return appName == TerminalHost.spaces.appName ? .spaces : nil
    }

    func isManagedTerminalApp(_ appName: String?) -> Bool { terminalHost(for: appName) != nil }

    /// Requests focus for a Spaces-managed terminal by session id. Focus is delegated to the
    /// client over IPC (the daemon has no window server), so this only routes the request and
    /// reports whether a session identity was available.
    func focusManagedTerminal(terminalApp: String?, providerIdentity: TerminalTrackingIdentity?, requestID: String? = nil)
        -> ManagedTerminalFocusResult
    {
        guard terminalHost(for: terminalApp) == .spaces else { return .unavailable }
        guard case .session(let sessionID)? = providerIdentity else { return .unavailable }
        let startedAt = currentDate()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        builtInTerminalWindowFocuser(sessionID, requestID)
        logTerminalPerfMetric(
            "built_in_terminal_focus_route", target: "session=\(sessionID)", detail: "stage=session_request\(requestDetail)",
            elapsedMS: elapsedMS(since: startedAt), success: true)
        return .sessionRequest
    }

    func shellSingleQuoted(_ raw: String) -> String { "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'" }

    func interactiveShellCommand(cwd _: String) -> String { "exec \(shellSingleQuoted(terminalLoginShellPath())) -l" }

    /// Builds the environment a Spaces terminal session launches with.
    ///
    /// `SPACES_DB_PATH` is FORWARDED from this daemon's own environment, never synthesized from the resolved
    /// profile. Both real profiles are discoverable from a binary's own location with no environment at all —
    /// the installed daemon under launchd falls through to `~/.spaces`, and a repo-built or deployed binary
    /// derives its development profile from where it sits on disk — so an unbound terminal is the CORRECT
    /// state for both: every `spaces` binary invoked inside one resolves the profile it belongs to. The only
    /// profile that cannot be discovered that way is an ephemeral throwaway root (tests, E2E harnesses), and
    /// that is exactly the case where the daemon itself was started with the variable and so forwards it.
    ///
    /// Synthesizing it instead exported a `SPACES_DB_PATH` into every workspace terminal, including the
    /// installed daemon's own. Anything run inside — notably an agent hook, which fires on every tool call —
    /// inherited it, and a `spaces` invocation that autostarts a daemon hands it the whole parent
    /// environment. A daemon serving `~/.spaces` then resolved itself through the explicit-path branch,
    /// was classified as a development profile, and assigned and persisted a development-range Device API
    /// port, orphaning every paired client. Profile identity belongs to the binary's location, not to an
    /// inherited binding, which is why `SPACES_DB_PATH` is refused outright inside a live profile root.
    ///
    /// Accepted consequence: in a development-profile terminal, a globally-configured agent hook still runs
    /// the INSTALLED `spaces` binary, which resolves the installed profile, so its agent signal is a silent
    /// no-op for a workspace id that profile has never heard of. Agent-lifecycle reporting from
    /// development-profile terminals is explicitly not supported.
    ///
    /// The rule has exactly one exception, and it is not a second rule: a process BOUND to the installed
    /// profile (`spacese2e --installed-profile`) states which profile it serves on its own command line, so
    /// the overrides in its environment describe a profile it is not serving and forwarding them would export
    /// a `SPACES_DB_PATH` into an installed-profile terminal — the failure above, reached from the other
    /// side. `SpacesProfile.environmentServingThisProfile` is that exception, shared with every other place this
    /// codebase launches a process, so "a bound process hands no override to what it launches" has one
    /// definition rather than one per launch site. Every profile a build owns still forwards exactly what its
    /// own environment carries.
    func terminalLaunchEnvironment(base: [String: String], includeInheritedPath: Bool = true, includeProfileEnvironment: Bool = true) throws
        -> [String: String]
    {
        var env = base
        if includeInheritedPath, let path = Shell.currentProcessEnvironment()["PATH"], !path.isEmpty { env["PATH"] = path }
        if includeProfileEnvironment {
            let forwardable = try SpacesProfile.current().environmentServingThisProfile()
            for key in [DatabaseLocator.databasePathEnvironmentVariable, "SPACES_RUNTIME_DIR", "SPACES_E2E_EVENTS_LOG", "DEBUG"] {
                if let value = forwardable[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { env[key] = value }
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
        sessionID: String? = nil, lifetimePolicy: TerminalSessionLifetimePolicy = .persistent, workspaceID: String, kind: TerminalSessionKind = .shell
    ) throws -> SpacesTerminalSessionHandle {
        let sessionID = sessionID ?? UUID().uuidString
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: backend, lifetimePolicy: lifetimePolicy, title: title, workingDirectory: workingDirectory,
            shell: terminalShellPathOverride() ?? "/bin/zsh", command: command, createdAt: nowISO8601(), workspaceID: workspaceID, kind: kind)

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
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let refreshedRuntimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return SpacesTerminalSessionHandle(
            sessionID: sessionID, childPID: (refreshedRuntimeState?.childPID ?? sessionSummary.childPID).map(Int.init),
            outputPath: sessionSummary.outputPath)
    }

    func spacesTerminalCommand(
        template: ProcessTemplate, env: [String: String], shellPath: String? = nil, includeInheritedPath: Bool = true,
        includeProfileEnvironment: Bool = true, commandPrelude: String? = nil
    ) throws -> String {
        let command = commandWithPrelude(try processLaunchCommand(template: template), prelude: commandPrelude)
        let runtimeEnv = try terminalLaunchEnvironment(
            base: env, includeInheritedPath: includeInheritedPath, includeProfileEnvironment: includeProfileEnvironment)
        let resolvedShellPath = shellPath ?? terminalLoginShellPath()
        // Run managed processes through an interactive login shell (`-l -i -c`), matching the ad-hoc
        // terminal experience. `-l` alone sources only the profile files; the version-manager shims
        // developers rely on (nvm, asdf, volta) live in `~/.bashrc`/`~/.zshrc`, which is guarded to
        // interactive shells. Without `-i`, a command like `nvm use 24 && npm run dev` fails with
        // `nvm: command not found` even though the same command works when typed into a terminal.
        return commandPrefixedWithShellEnvironment("exec \(shellQuoted(resolvedShellPath)) -l -i -c \(shellQuoted(command))", env: runtimeEnv)
    }

    func logTerminalPerfMetric(_ metric: String, target: String, detail: String = "", elapsedMS: Int, success: Bool) {
        TerminalPerformance.logMetric(metric, target: target, elapsedMS: elapsedMS, success: success, detail: detail)
    }

    func managedTrackedTerminalWindowIsStillLive(window: WindowRecord) -> Bool {
        guard window.roleValue == .terminal, let host = terminalHost(for: window.app) else { return false }
        guard host == .spaces else { return false }
        return builtInTrackedWindowIsStillLive(window: window)
    }

    func builtInTrackedWindowIsStillLive(window: WindowRecord) -> Bool {
        guard window.roleValue == .terminal, terminalHost(for: window.app) == .spaces else { return false }
        guard let sessionID = window.terminalTrackingID, !sessionID.isEmpty else { return false }
        if builtInSessionBelongsToRunningProcess(sessionID: sessionID, workspaceID: window.workspaceID) {
            return builtInSessionIsStillLive(sessionID: sessionID) || builtInSessionLaunchIsPending(sessionID: sessionID)
        }
        if builtInSessionBelongsToConfiguredAgent(sessionID: sessionID, workspaceID: window.workspaceID) {
            return builtInSessionIsStillLive(sessionID: sessionID) || builtInSessionLaunchIsPending(sessionID: sessionID)
        }
        if builtInSessionIsStillLive(sessionID: sessionID) && builtInSessionHasActiveAttachments(sessionID: sessionID) { return true }
        return builtInSessionLaunchIsPendingBeforeOwnerAttachment(sessionID: sessionID)
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
            let createdAt = TerminalSessionTimestamp.date(from: launchConfiguration.createdAt)
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
        let sessionID = record.terminalTrackingID
        guard let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func builtInSessionBelongsToRunningProcess(sessionID: String, workspaceID: String) -> Bool {
        ((try? store.runningProcesses(workspaceID: workspaceID)) ?? []).contains { $0.terminalTrackingID == sessionID }
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

    func resolvedBuiltInSessionRuntimePID(for process: RunningProcessRecord) -> Int? {
        resolvedBuiltInSessionRuntimeState(for: process)?.childPID.map(Int.init)
    }

    func resolvedBuiltInSessionRuntimeState(for process: RunningProcessRecord) -> TerminalSessionRuntimeState? {
        guard terminalHost(for: process.terminalApp) == .spaces else { return nil }
        guard let sessionID = process.terminalTrackingID, !sessionID.isEmpty else { return nil }
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return nil }
        return try? TerminalSessionPersistence.readRuntimeState(paths: paths)
    }

    func terminateBuiltInTerminalSession(_ sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else { return }
        builtInTerminalWindowCloser(sessionID)
        builtInTerminalSessionTerminator(sessionID)
    }

    func liveAdHocBuiltInTerminalSessionIDs(workspaceID: String) throws -> [String] {
        guard let workspace = try store.workspace(id: workspaceID) else { return [] }
        let liveSessions: [TerminalSessionCatalogEntry]
        do { liveSessions = try TerminalSessionCatalog.listLiveSessions() } catch {
            // This sweep is only for untracked shells; tracked process and agent sessions
            // have already been handled, so catalog errors must not leave stop half-applied.
            if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
                Self.writeStandardError("spaces: unable to enumerate ad-hoc terminal sessions during workspace stop: \(error.localizedDescription)\n")
            }
            return []
        }
        var sessionIDs: [String] = []
        var seen = Set<String>()
        for session in liveSessions where session.launchConfiguration.backend == .ghosttyEmbedded {
            let sessionID = session.sessionID
            let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
            guard !builtInTerminalSessionHasConfiguredOwner(ownership) else { continue }
            let ownedWorkspaceID = ownership.terminalWindowWorkspaceID ?? ownership.launchWorkspaceID
            guard ownedWorkspaceID == workspaceID || (ownedWorkspaceID == nil && terminalSession(sessionID: sessionID, belongsTo: workspace)) else {
                continue
            }
            if seen.insert(sessionID).inserted { sessionIDs.append(sessionID) }
        }
        return sessionIDs
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
        return normalizedTerminalSessionID(process.terminalTrackingID)
    }

    func builtInTerminalSessionID(for agent: AgentWindowRecord) -> String? {
        guard agent.provider == .spaces else { return nil }
        return normalizedTerminalSessionID(agent.terminalTrackingID)
    }

    func terminalSessionID(for window: WindowRecord) -> String? { normalizedTerminalSessionID(window.terminalTrackingID) }

    func normalizedTerminalSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Resolves the workspace owning a built-in terminal session: the workspace behind its
    /// running-process/agent/terminal-window row if it has one, else the workspace stamped
    /// on its own launch configuration — which every session now carries, since
    /// `spaces terminal command` always resolves a workspace before launching. Returns nil
    /// only when the session's launch configuration itself can't be read (deleted/pruned).
    func workspaceForBuiltInTerminalSession(sessionID: String, ownership existingOwnership: BuiltInTerminalSessionOwnership? = nil) throws
        -> WorkspaceRecord?
    {
        let ownership = try existingOwnership ?? builtInTerminalSessionOwnership(sessionID: sessionID)
        guard
            let workspaceID = ownership.processWorkspaceID ?? ownership.agentWorkspaceID ?? ownership.terminalWindowWorkspaceID
                ?? ownership.launchWorkspaceID
        else { return nil }
        return try store.workspace(id: workspaceID)
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
                    $0.roleValue == .terminal && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
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

    func matchesTrackedTerminalWindow(_ window: WindowRecord, process: RunningProcessRecord) -> Bool {
        guard window.roleValue == .terminal, window.app == process.terminalApp else { return false }
        if window.id == process.id { return true }
        if let terminalID = process.terminalTrackingID, !terminalID.isEmpty, window.terminalTrackingID == terminalID { return true }
        return false
    }
}
