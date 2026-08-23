import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    public func workspaceIDForTerminalSession(_ sessionID: String) throws -> String? { try store.workspaceIDForTerminalSession(sessionID) }

    /// Whether a workspace terminal row names a session launched through the coding-agent path. Before
    /// the agent's first hook signal there is no agent row to render or address, so an explicit Stop still
    /// arrives as a workspace-terminal request and must select teardown from the persisted launch kind.
    public func workspaceTerminalSessionIsSpawnedAgent(workspaceID: String, sessionID: String) -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID),
            let launchConfiguration = terminalSessionLaunchConfiguration(sessionID: sessionID)
        else { return false }
        return launchConfiguration.workspaceID == workspaceID && launchConfiguration.kind == .agent
    }

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
    /// `.agent` kind (`agent spawn`)
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

    /// Destroys an automation-attributed terminal while its workspace lifecycle gate is already held by
    /// workspace/project teardown. This deliberately performs the same terminal-window, agent-row, and
    /// subscriber cleanup as the public stop paths without trying to claim the gate a second time.
    /// Automation deletion supplies only sessions stamped with its run id; callers must therefore never
    /// use this as a general terminal-stop shortcut.
    func terminateAutomationTerminalSessionDuringWorkspaceTeardown(sessionID: String) throws {
        guard let sessionID = normalizedTerminalSessionID(sessionID) else { return }
        terminateBuiltInTerminalSession(sessionID)
        try removeAutomationTerminalSessionRuntimeTargetDuringWorkspaceTeardown(sessionID: sessionID)
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

    /// Stops an ad hoc built-in terminal session whose owning pane the user just closed, but only when
    /// the terminal is sitting at a bare prompt with nothing left holding it. Returns whether the session
    /// was terminated; `false` means it was kept and stays recoverable in the sidebar.
    ///
    /// Three things have to be true, in this order:
    ///  1. the session has no configured owner, so `agent spawn` sessions and configured process
    ///     terminals are refused outright (closing their panes only ever detaches);
    ///  2. no live owner-mode attachment remains. The closing client detaches before asking, so an owner
    ///     attachment still standing means ownership transferred to another local pane or another device
    ///     already owns it, and that owner keeps the session;
    ///  3. its foreground is a bare shell AND that shell is holding no child process, both read fresh from
    ///     the OS at this instant rather than from the ~1s-old sample on persisted runtime state: a command
    ///     started just before the close must never be killed by a decision made against a foreground that
    ///     predates it. The child check is what separates an idle prompt from a shell holding work it is
    ///     not in the foreground of (a background or stopped job, a `wait`), which reports the same
    ///     executable and argv as an idle prompt, and it survives an uninspectable foreground: a shell pid
    ///     that resolved but could not be inspected (a zombie process-group leader in the instant before
    ///     the shell reaps it) is treated as bare-equivalent only once the child check has cleared it,
    ///     never on the strength of the missing reading alone. A session with no reading at all (no live
    ///     core here, or a dead pid) is bare: there is no process left to protect, and a fresh-open close
    ///     race resolves toward stopping rather than leaking a shell.
    ///
    /// There is deliberately no sweep behind this: a session closed while a program ran stays alive after
    /// that program exits, so the user can reopen it and see why. Closing it at the prompt is the only
    /// termination trigger.
    @discardableResult public func stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(workspaceID: String, sessionID: String) throws -> Bool {
        // During an exec-in-place handoff the session terminator no-ops and live sessions are carried into
        // the successor daemon, so deleting this session's product rows here would orphan a live terminal.
        // A quiet `false` here, rather than the `throw WorkspaceError.daemonHandoffInProgress` the sibling
        // handoff gates use, is deliberate: this call is driven by a routine pane close, not an explicit
        // user action on the handoff-sensitive operation itself, so it should not surface an error, and the
        // next explicit close against the successor daemon succeeds normally.
        guard !daemonHandoffInProgress() else { return false }
        return try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard let sessionID = normalizedTerminalSessionID(sessionID) else { return false }
            let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
            guard !builtInTerminalSessionHasConfiguredOwner(ownership) else { return false }
            guard !builtInTerminalSessionHasLiveOwnerAttachment(sessionID: sessionID) else { return false }
            guard let launchConfiguration = terminalSessionLaunchConfiguration(sessionID: sessionID) else { return false }
            if let reading = builtInTerminalForegroundProcessSampler(sessionID) {
                guard !reading.shellHasChildProcesses else { return false }
                if let process = reading.process {
                    guard
                        TerminalBareShellForeground.isBareShell(
                            executableName: process.executableName, argv: process.argv, launchShell: launchConfiguration.shell)
                    else { return false }
                }
            }
            return try stopAdHocBuiltInTerminalSessionUnlocked(workspaceID: workspaceID, sessionID: sessionID)
        }
    }

    /// Whether some client still holds the session's owner attachment, judged by the same lease rule the
    /// daemon applies everywhere (`liveAttachments`), so a remote viewer whose lease lapsed without ever
    /// sending a detach does not count.
    ///
    /// A live core hosted in this process is asked first, through `builtInTerminalLiveOwnerAttachmentProber`:
    /// its in-memory snapshot is the attachment authority and is always at least as current as the durable
    /// mirror (this core is the only writer of its own attachment rows), so when a live core answers, that
    /// answer wins. This matters specifically because the closing client's own detach is applied to that
    /// snapshot before its durable mirror commits, so a durable read taken right after can still see the
    /// just-detached owner. The durable read below remains the fallback for a session with no live core in
    /// this process (e.g. it already ended).
    ///
    /// Fails closed: a session whose paths or attachment snapshot cannot be read is presumed owned. This
    /// answer gates a termination, and the two mistakes are not symmetric: a wrongful stop destroys a
    /// terminal the user cannot get back, while a session wrongly kept costs one more close.
    func builtInTerminalSessionHasLiveOwnerAttachment(sessionID: String) -> Bool {
        if let liveAnswer = builtInTerminalLiveOwnerAttachmentProber(sessionID) { return liveAnswer }
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return true }
        guard let liveAttachments = try? TerminalSessionPersistence.liveAttachments(paths: paths, now: currentDate()) else { return true }
        return liveAttachments.contains { $0.mode == .owner }
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
    /// generated name the session was launched under — the only way back from a rename. The resulting
    /// name must remain unique among the workspace's focusable runtime rows.
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
            let launchConfiguration = terminalSessionLaunchConfiguration(sessionID: sessionID)
            // Read, validate, and update the window rows under one immediate transaction. Like an agent
            // rename, two terminal renames cannot both validate against the old names and then commit the
            // same candidate.
            try store.withTransaction {
                let matchingWindows = try store.windows(workspaceID: workspaceID).filter {
                    $0.roleValue == .terminal && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
                }
                if let resultingName = title.isEmpty ? launchConfiguration?.title : title {
                    try validateAvailableWorkspaceFocusName(
                        workspaceID: workspaceID, name: resultingName, excludingWindowIDs: Set(matchingWindows.map(\.id)))
                }
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
            }
            // The terminal-session catalog shares the profile database through its own serialized
            // connection, so write it after the store transaction releases its SQLite write lock.
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
        let visibleNames = try workspaceFocusableWindowNames(workspaceID: workspaceID)
        let reservedLaunchNames = try reservedAdHocTerminalLaunchNames(workspaceID: workspaceID, excludingWindowIDs: [])
        let usedNames = Set((visibleNames + reservedLaunchNames).map(normalizedFocusName))
        var suffix = 1
        while usedNames.contains(normalizedFocusName("shell-\(suffix)")) { suffix += 1 }
        return "shell-\(suffix)"
    }

    /// An ad-hoc terminal's launch name remains its clear-rename destination while a user title is
    /// displayed, so no other row may claim it in the meantime. The terminal window supplies the
    /// authoritative workspace/session relationship; the persisted shell launch supplies the reserved
    /// name. Callers exclude a session's own window while validating its clear operation.
    func reservedAdHocTerminalLaunchNames(workspaceID: String, excludingWindowIDs: Set<String>) throws -> [String] {
        try adHocTerminalNamePairs(workspaceID: workspaceID, excludingWindowIDs: excludingWindowIDs).map { $0.launchName }
    }

    /// Names a full-workspace uniqueness check must reserve for each ad-hoc terminal. An unrenamed
    /// terminal contributes its one name once; a renamed terminal contributes its visible user title and
    /// its distinct launch title, which remains the destination of a later clear. A terminal claimed by
    /// a coding agent shows no row of its own: the agent row is that window's one visible row, so a
    /// terminal name equal to the claiming agent's label is that single row's name, not a second holder,
    /// and is dropped here. The claimed terminal's names stay reserved against every other row.
    func adHocTerminalFocusNames(workspaceID: String, claimingAgentNormalizedLabelBySessionID: [String: String]) throws -> [String] {
        try adHocTerminalNamePairs(workspaceID: workspaceID, excludingWindowIDs: []).flatMap { pair -> [String] in
            let names =
                normalizedFocusName(pair.effectiveName) == normalizedFocusName(pair.launchName)
                ? [pair.effectiveName] : [pair.effectiveName, pair.launchName]
            guard let claimingLabel = claimingAgentNormalizedLabelBySessionID[pair.sessionID] else { return names }
            return names.filter { normalizedFocusName($0) != claimingLabel }
        }
    }

    private func adHocTerminalNamePairs(workspaceID: String, excludingWindowIDs: Set<String>) throws
        -> [(sessionID: String, effectiveName: String, launchName: String)]
    {
        var seenSessionIDs = Set<String>()
        return try store.windows(workspaceID: workspaceID).compactMap { window in
            guard !excludingWindowIDs.contains(window.id), window.roleValue == .terminal, terminalHost(for: window.app) == .spaces,
                let sessionID = terminalSessionID(for: window), let launchConfiguration = terminalSessionLaunchConfiguration(sessionID: sessionID),
                launchConfiguration.workspaceID == workspaceID, launchConfiguration.kind == .shell, !seenSessionIDs.contains(sessionID),
                let launchName = sanitizedFocusName(launchConfiguration.title)
            else { return nil }
            seenSessionIDs.insert(sessionID)
            let effectiveName =
                sanitizedFocusName(TerminalSessionTitle.name(userTitle: launchConfiguration.userTitle, launchTitle: launchConfiguration.title))
                ?? launchName
            return (sessionID, effectiveName, launchName)
        }
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

    /// Runs `command` through an interactive login shell (`-l -i -c`), the single shell form every
    /// command Spaces launches into a terminal goes through — workspace processes, ad-hoc
    /// `terminal create` sessions, and spawned coding agents.
    ///
    /// `-l` alone sources only the profile files (`~/.zshenv`, `~/.zprofile`). The PATH entries and
    /// version-manager shims that put a user's tools on PATH — `~/.local/bin`, nvm/fnm/asdf/volta —
    /// live in `~/.zshrc`, which a shell reads only when it is interactive. Without `-i`, `claude`
    /// (installed to `~/.local/bin`), an fnm-managed `codex`, or `nvm use 24 && npm run dev` fails
    /// with `command not found` even though the same command works typed into a Spaces terminal —
    /// whose shell is a bare `exec <shell> -l` on a PTY, and therefore interactive.
    func interactiveLoginShellCommand(_ command: String, shellPath: String? = nil) -> String {
        "exec \(shellQuoted(shellPath ?? terminalLoginShellPath())) -l -i -c \(shellQuoted(command))"
    }

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
    func terminalLaunchEnvironment(base: [String: String], includeInheritedPath: Bool = true, includeProfileEnvironment: Bool = true) -> [String:
        String]
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

    /// - Parameter openIntent: What the client should do with the window and the layout when the pane
    ///   opens. Stated at every call site rather than defaulted, because its focus half is the difference
    ///   between a launch a user is waiting to type into and one a script triggered behind their back.
    func launchSpacesTerminalSession(
        title: String, workingDirectory: String, command: String?, showMode: TerminalAttachmentMode, openIntent: TerminalPaneOpenIntent,
        backend: TerminalSessionBackendKind = .ghosttyEmbedded, readinessPolicy: BuiltInTerminalReadinessPolicy = .stableChildPID,
        sessionID: String? = nil, lifetimePolicy: TerminalSessionLifetimePolicy = .persistent, workspaceID: String, kind: TerminalSessionKind = .shell
    ) throws -> SpacesTerminalSessionHandle {
        let sessionID = sessionID ?? UUID().uuidString
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: backend, lifetimePolicy: lifetimePolicy, title: title, workingDirectory: workingDirectory,
            shell: terminalShellPathOverride() ?? "/bin/zsh", command: command, createdAt: TerminalSessionTimestamp.fractionalString(from: Date()),
            workspaceID: workspaceID, kind: kind)

        builtInTerminalWindowOpener(sessionID, showMode, openIntent)
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
            builtInTerminalWindowCloser(sessionID, .teardown)
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
        let runtimeEnv = terminalLaunchEnvironment(
            base: env, includeInheritedPath: includeInheritedPath, includeProfileEnvironment: includeProfileEnvironment)
        return commandPrefixedWithShellEnvironment(interactiveLoginShellCommand(command, shellPath: shellPath), env: runtimeEnv)
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
        // Registry before any durable read: a pending entry is cleared only after its row commits, so in
        // this order a miss means the rows are durably readable below or the session is genuinely gone.
        // The reverse order could miss on both sides of a commit-then-clear and misread a live
        // just-created session as vanished.
        //
        // This branch also deliberately ignores the durable runtime row. On a relaunch of the same
        // session id, the previous run's row can still read .exited or .failed while the new run's
        // replacement writes are queued behind its launch write, so that row is the old run's leftover,
        // not a verdict on this launch; trusting it would let liveness probes tear down a live relaunch.
        if let pending = TerminalSessionPendingLaunchRegistry.shared.pendingLaunchConfiguration(sessionID: sessionID) {
            guard let createdAt = TerminalSessionTimestamp.date(from: pending.createdAt) else { return false }
            let age = now.timeIntervalSince(createdAt)
            return age >= -5 && age < 60
        }
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
        // An automation session is never a workspace's configured coding agent.
        case .shell, .process, .automation: return false
        case nil: return ((try? store.agentWindows(workspaceID: workspaceID)) ?? []).contains { builtInTerminalSessionID(for: $0) == sessionID }
        }
    }

    /// Whether the session currently has any active attachment (owner or viewer).
    ///
    /// A live core hosted in this process is asked first, through `builtInTerminalLiveActiveAttachmentProber`:
    /// its in-memory snapshot is the attachment authority and is always at least as current as the durable
    /// mirror (this core is the only writer of its own attachment rows), so when a live core answers, that
    /// answer wins. This matters specifically because a just-applied attach can be visible to the live core
    /// before its durable mirror commits: a just-applied attach whose mirror is still queued behind a
    /// contended SQLite lock still counts here, and a just-applied detach stops counting immediately. The
    /// durable read below remains the fallback for a session with no live core in this process.
    ///
    /// This gates tracked-window pruning in `builtInTrackedWindowIsStillLive`, where the two mistakes are
    /// not symmetric: wrongly pruning drops a live window's tracked row, while wrongly keeping it costs one
    /// more refresh cycle.
    func builtInSessionHasActiveAttachments(sessionID: String) -> Bool {
        if let liveAnswer = builtInTerminalLiveActiveAttachmentProber(sessionID) { return liveAnswer }
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

    func terminateBuiltInTerminalSession(_ sessionID: String?, closeDisposition: TerminalPaneCloseDisposition = .teardown) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else { return }
        builtInTerminalWindowCloser(sessionID, closeDisposition)
        builtInTerminalSessionTerminator(sessionID)
    }

    /// The live configured-process sessions whose panes a restart should hold for their replacements,
    /// captured before the stop deletes the rows that name them. Keyed by the process each row belongs
    /// to, which is the only thing that survives a full restart: the stop deletes the process rows and
    /// the launch mints fresh row, window, and session ids, so nothing else pairs an old session with the
    /// one that takes its place.
    /// An orchestrator whose opener reaches no client captures nothing, so it can never ask for a hold it
    /// could not release. That single check is what keeps the hold and the replacement's open wired
    /// together; see `deliversTerminalWindowOpens`.
    func replacedTerminalSessionReservations(workspaceID: String) throws -> ReplacedTerminalSessionReservations {
        guard deliversTerminalWindowOpens else { return ReplacedTerminalSessionReservations(sessionIDsByProcessKey: [:]) }
        var sessionIDsByProcessKey: [String: String] = [:]
        for process in try store.runningProcesses(workspaceID: workspaceID) where isManagedTerminalApp(process.terminalApp) {
            guard let sessionID = normalizedTerminalSessionID(process.terminalTrackingID) else { continue }
            sessionIDsByProcessKey[runningProcessMatchKey(name: process.templateName)] = sessionID
        }
        return ReplacedTerminalSessionReservations(sessionIDsByProcessKey: sessionIDsByProcessKey)
    }

    /// The session a single-process restart's replacement takes over from.
    ///
    /// Deliberately not gated on `deliversTerminalWindowOpens`, unlike the workspace restart's
    /// reservations above. Every start and restart of a configured process is served by the Device API,
    /// whose orchestrator has no opener to any client, so gating here made the ordinary case — starting a
    /// process whose previous run exited, while its ended pane is open — a plain teardown that closed the
    /// pane out from under the reader. This path can hold safely without an opener because the pairing
    /// reaches the client another way: the process keeps its row across the restart and only the session
    /// it names changes, so the refreshed overview tells the client which pane to point at the
    /// replacement. A launch that never happens still releases the hold from `restartProcessInTerminal`'s
    /// own teardown close, which is the one thing no client can infer.
    func replacedTerminalSessionID(for process: RunningProcessRecord) -> String? { normalizedTerminalSessionID(process.terminalTrackingID) }

    /// Releases every pane this restart is still holding: held by the stop, and never claimed by a
    /// replacement. Only emitted holds are released, so a stop that failed before sending them cannot
    /// close a pane whose session is still running.
    func releaseUnclaimedReplacedTerminalSessions(_ reservations: ReplacedTerminalSessionReservations) {
        for sessionID in reservations.unclaimedHeldSessionIDs { builtInTerminalWindowCloser(sessionID, .teardown) }
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
    /// `spaces terminal create` always resolves a workspace before launching. Returns nil
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

    /// Reads every row an ownership lookup consults, in the project-then-workspace order the lookup
    /// resolves its first match in. A caller that resolves several sessions builds this once.
    func builtInTerminalOwnershipIndex() throws -> BuiltInTerminalOwnershipIndex {
        let workspaceIDs = try store.projects().flatMap { project in try store.workspaces(projectID: project.id).map(\.id) }
        return BuiltInTerminalOwnershipIndex(
            workspaceIDs: workspaceIDs, runningProcessesByWorkspace: try store.runningProcessesByWorkspace(),
            agentWindowsByWorkspace: try store.agentWindowsByWorkspace(), windowsByWorkspace: try store.windowsByWorkspace())
    }

    func builtInTerminalSessionOwnership(sessionID: String) throws -> BuiltInTerminalSessionOwnership {
        builtInTerminalSessionOwnership(sessionID: sessionID, index: try builtInTerminalOwnershipIndex())
    }

    func builtInTerminalSessionOwnership(sessionID: String, index: BuiltInTerminalOwnershipIndex) -> BuiltInTerminalSessionOwnership {
        var owningProcess: RunningProcessRecord?
        var owningAgent: AgentWindowRecord?
        var terminalWindowWorkspaceID: String?
        for workspaceID in index.workspaceIDs {
            if owningProcess == nil {
                owningProcess = index.runningProcesses(workspaceID: workspaceID).first { builtInTerminalSessionID(for: $0) == sessionID }
            }
            if owningAgent == nil {
                owningAgent = index.agentWindows(workspaceID: workspaceID).first { builtInTerminalSessionID(for: $0) == sessionID }
            }
            if terminalWindowWorkspaceID == nil,
                index.windows(workspaceID: workspaceID).contains(where: {
                    $0.roleValue == .terminal && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
                })
            {
                terminalWindowWorkspaceID = workspaceID
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
        // An automation session is never a workspace's configured owner.
        case .shell, .automation: return false
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

    func terminateBuiltInTerminalSession(for process: RunningProcessRecord, closeDisposition: TerminalPaneCloseDisposition = .teardown) {
        terminateBuiltInTerminalSession(builtInTerminalSessionID(for: process), closeDisposition: closeDisposition)
    }

    func matchesTrackedTerminalWindow(_ window: WindowRecord, process: RunningProcessRecord) -> Bool {
        guard window.roleValue == .terminal, window.app == process.terminalApp else { return false }
        if window.id == process.id { return true }
        if let terminalID = process.terminalTrackingID, !terminalID.isEmpty, window.terminalTrackingID == terminalID { return true }
        return false
    }
}
