import AppKit
import Foundation
import spacesclientcore
import spacesterminalcore
import systembridge
import workspacecore

extension AppKitController {
    struct StopAllQuitWorkspaceSelection {
        let workspaceIDs: [String]
        let associatedLiveSessionIDs: Set<String>
        /// The live sessions open in the home project, in the order they were listed. They are neither
        /// covered by a workspace Stop nor unowned, so they carry their own list.
        let homeSessionIDs: [String]
    }

    /// How Stop All and Quit tears one live terminal session down. Every live session resolves to exactly
    /// one of these; the cases are teardown paths, not a preference order.
    enum StopAllQuitSessionOwnership {
        /// A workspace Stop covers the session, so stopping that workspace ends it.
        case workspaceStop(WorkspaceRecord)
        /// The session is open in the home project, which has no workspace lifecycle, so it is stopped on
        /// its own through the daemon's per-session terminal stop.
        case homeTerminalStop
        /// No workspace owns the session, so nothing but a direct termination can end it.
        case unowned
    }

    struct StopAllQuitWorkspaceStopFailure {
        let workspaceID: String
        let error: Error
    }

    struct StopAllQuitSessionTerminationFailure {
        let sessionID: String
        let error: Error
    }

    struct StopAllQuitCleanupResult {
        let workspaceIDs: [String]
        let stoppedWorkspaceIDs: [String]
        let associatedLiveSessionIDs: Set<String>
        let browserSessionTargetURLsByWorkspaceID: [String: [String]]
        let stopFailures: [StopAllQuitWorkspaceStopFailure]
        let homeStoppedSessionIDs: [String]
        let homeStopFailures: [StopAllQuitSessionTerminationFailure]
        let rawTerminatedSessionIDs: [String]
        let rawTerminationFailures: [StopAllQuitSessionTerminationFailure]
        let remainingSessionIDs: [String]
        let preparationError: Error?
        /// The record the park wrote, when it wrote one. Carried so a quit that ends up not happening can
        /// drop that record by name.
        var parkedRestoreGeneration: String? = nil

        var succeeded: Bool {
            preparationError == nil && stopFailures.isEmpty && homeStopFailures.isEmpty && rawTerminationFailures.isEmpty
                && remainingSessionIDs.isEmpty
        }
    }

    enum StopAllQuitCleanupFailureChoice: Equatable, Sendable {
        case forceQuit
        case cancelQuit
    }

    nonisolated static func stopAllQuitWorkspaceSelection(
        runningWorkspaces: [WorkspaceRecord], liveSessions: [TerminalServiceSessionSummary],
        ownershipForLiveSession: (String) throws -> StopAllQuitSessionOwnership
    ) throws -> StopAllQuitWorkspaceSelection {
        var workspaceIDs: [String] = []
        var seenWorkspaceIDs = Set<String>()
        var associatedLiveSessionIDs = Set<String>()
        var homeSessionIDs: [String] = []

        func appendWorkspaceID(_ workspaceID: String) {
            guard !seenWorkspaceIDs.contains(workspaceID) else { return }
            seenWorkspaceIDs.insert(workspaceID)
            workspaceIDs.append(workspaceID)
        }

        for workspace in runningWorkspaces where workspace.isRunning { appendWorkspaceID(workspace.id) }

        for session in liveSessions {
            switch try ownershipForLiveSession(session.id) {
            case .workspaceStop(let workspace):
                associatedLiveSessionIDs.insert(session.id)
                appendWorkspaceID(workspace.id)
            case .homeTerminalStop: homeSessionIDs.append(session.id)
            case .unowned: continue
            }
        }

        return StopAllQuitWorkspaceSelection(
            workspaceIDs: workspaceIDs, associatedLiveSessionIDs: associatedLiveSessionIDs, homeSessionIDs: uniqueSessionIDs(homeSessionIDs))
    }

    /// `parkAgentSessionsForRestore` runs once, in the one window where the record is both complete and
    /// committed: after every step that can still abandon the quit (a preparation failure hands the user a
    /// Cancel Quit choice, and a record parked before it would offer agents that are still running back),
    /// and before the first stop, while the agent rows the record is read from are still live. It is the
    /// whole-app quit that is restorable (stopping one workspace, or one agent, is a deliberate end to that
    /// work), which is why the call sits here rather than inside the per-workspace stop.
    nonisolated static func performStopAllQuitCleanup(
        liveSessions: [TerminalServiceSessionSummary], parkAgentSessionsForRestore: () -> String?, runningWorkspaces: () throws -> [WorkspaceRecord],
        ownershipForLiveSession: (String) throws -> StopAllQuitSessionOwnership, stopWorkspace: (String) throws -> Void,
        stopHomeTerminalSession: (String) throws -> Void, terminateSession: (String) throws -> Void,
        listLiveSessions: () throws -> [TerminalServiceSessionSummary], browserSessionTargetURLs: (String) throws -> [String],
        closeBrowserSessions: (String, [String]) -> Void
    ) -> StopAllQuitCleanupResult {
        let originalLiveSessionIDs = Set(liveSessions.map(\.id))
        let selection: StopAllQuitWorkspaceSelection
        do {
            selection = try stopAllQuitWorkspaceSelection(
                runningWorkspaces: try runningWorkspaces(), liveSessions: liveSessions, ownershipForLiveSession: ownershipForLiveSession)
        } catch {
            return StopAllQuitCleanupResult(
                workspaceIDs: [], stoppedWorkspaceIDs: [], associatedLiveSessionIDs: [], browserSessionTargetURLsByWorkspaceID: [:], stopFailures: [],
                homeStoppedSessionIDs: [], homeStopFailures: [], rawTerminatedSessionIDs: [], rawTerminationFailures: [],
                remainingSessionIDs: uniqueSessionIDs(liveSessions.map(\.id)), preparationError: error)
        }

        var browserSessionTargetURLsByWorkspaceID: [String: [String]] = [:]
        do {
            for workspaceID in selection.workspaceIDs {
                browserSessionTargetURLsByWorkspaceID[workspaceID] = try browserSessionTargetURLs(workspaceID)
            }
        } catch {
            return StopAllQuitCleanupResult(
                workspaceIDs: selection.workspaceIDs, stoppedWorkspaceIDs: [], associatedLiveSessionIDs: selection.associatedLiveSessionIDs,
                browserSessionTargetURLsByWorkspaceID: browserSessionTargetURLsByWorkspaceID, stopFailures: [], homeStoppedSessionIDs: [],
                homeStopFailures: [], rawTerminatedSessionIDs: [], rawTerminationFailures: [],
                remainingSessionIDs: uniqueSessionIDs(liveSessions.map(\.id)), preparationError: error)
        }

        let parkedRestoreGeneration = parkAgentSessionsForRestore()
        var stoppedWorkspaceIDs: [String] = []
        var stopFailures: [StopAllQuitWorkspaceStopFailure] = []
        for workspaceID in selection.workspaceIDs {
            do {
                try stopWorkspace(workspaceID)
                stoppedWorkspaceIDs.append(workspaceID)
                closeBrowserSessions(workspaceID, browserSessionTargetURLsByWorkspaceID[workspaceID] ?? [])
            } catch { stopFailures.append(StopAllQuitWorkspaceStopFailure(workspaceID: workspaceID, error: error)) }
        }

        let liveAfterWorkspaceStop = (try? listLiveSessions()) ?? liveSessions
        // Both remaining passes read the same post-stop listing, so a session that ended on its own while
        // the workspaces were stopping is stopped by neither of them.
        let liveOriginalSessionIDs = uniqueSessionIDs(liveAfterWorkspaceStop.filter { originalLiveSessionIDs.contains($0.id) }.map(\.id))
        let homeSessionIDs = Set(selection.homeSessionIDs)
        var homeStoppedSessionIDs: [String] = []
        var homeStopFailures: [StopAllQuitSessionTerminationFailure] = []
        for sessionID in liveOriginalSessionIDs where homeSessionIDs.contains(sessionID) {
            do {
                try stopHomeTerminalSession(sessionID)
                homeStoppedSessionIDs.append(sessionID)
            } catch {
                // The daemon refuses `.terminalStop` for a session that has already ended (it answers
                // with `SpacesRuntimeError.invalidArgument`, "has already ended"), and a home shell can
                // exit on its own in the window between the post-workspace-stop listing above and this
                // pass reaching it. Re-check liveness rather than string-matching the error: a session
                // no longer listed is cleaned up either way. (This is never two home sessions sharing one
                // automation run taking each other down: the home project carries no automations, because
                // the daemon refuses `~` as an automation target in
                // `AutomationService.validateWorkspaceTarget` and refuses to adopt a project that already
                // has them, so no live or queued run can exist for it and nothing pairs sessions under a
                // cancellable run. See `WorkspaceOrchestrator+HomeProject.swift`.)
                let stillLive = (try? listLiveSessions())?.contains { $0.id == sessionID } ?? true
                if stillLive {
                    homeStopFailures.append(StopAllQuitSessionTerminationFailure(sessionID: sessionID, error: error))
                } else {
                    homeStoppedSessionIDs.append(sessionID)
                }
            }
        }

        var rawTerminatedSessionIDs: [String] = []
        var rawTerminationFailures: [StopAllQuitSessionTerminationFailure] = []
        for sessionID in liveOriginalSessionIDs where !selection.associatedLiveSessionIDs.contains(sessionID) && !homeSessionIDs.contains(sessionID) {
            do {
                try terminateSession(sessionID)
                rawTerminatedSessionIDs.append(sessionID)
            } catch { rawTerminationFailures.append(StopAllQuitSessionTerminationFailure(sessionID: sessionID, error: error)) }
        }

        let finalLiveSessions = (try? listLiveSessions()) ?? liveAfterWorkspaceStop
        let remainingSessionIDs = uniqueSessionIDs(finalLiveSessions.filter { originalLiveSessionIDs.contains($0.id) }.map(\.id))
        return StopAllQuitCleanupResult(
            workspaceIDs: selection.workspaceIDs, stoppedWorkspaceIDs: stoppedWorkspaceIDs,
            associatedLiveSessionIDs: selection.associatedLiveSessionIDs,
            browserSessionTargetURLsByWorkspaceID: browserSessionTargetURLsByWorkspaceID, stopFailures: stopFailures,
            homeStoppedSessionIDs: homeStoppedSessionIDs, homeStopFailures: homeStopFailures, rawTerminatedSessionIDs: rawTerminatedSessionIDs,
            rawTerminationFailures: rawTerminationFailures, remainingSessionIDs: remainingSessionIDs, preparationError: nil,
            parkedRestoreGeneration: parkedRestoreGeneration)
    }

    /// Asks the daemon to record this profile's live coding agents as restorable, so the next launch can
    /// offer them back. Best effort by design: the record is an offer, not part of the teardown, so a
    /// daemon that cannot answer must not stand between the user and the quit they asked for. Nothing is
    /// recorded then, and the quit proceeds.
    nonisolated static func parkAgentSessionsForStopAllQuit() -> String? {
        do { return try TerminalService.sendProfileCommand(.parkAgentSessionsForRestore).parkedRestoreGeneration } catch {
            fputs("spaces: could not record coding agents for restore before quitting: \(error)\n", stderr)
            return nil
        }
    }

    /// Reconciles the record `parkAgentSessionsForStopAllQuit` wrote against what is still running, for a
    /// quit that does not happen. The daemon keeps the rows whose sessions ended and drops the ones still
    /// live. Best effort for the same reason the park is: the app stays open either way, and a daemon that
    /// cannot answer leaves a record the user can still answer with Skip.
    nonisolated static func reconcileParkedAgentSessionsAfterStopAllQuit(generation: String) {
        do { _ = try TerminalService.sendProfileCommand(.reconcileParkedAgentSessions(generation: generation)) } catch {
            fputs("spaces: could not reconcile the parked coding agents after the quit was canceled: \(error)\n", stderr)
        }
    }

    /// Stop All runs in the app process, while active automation cancellation is serialized by the daemon's
    /// AutomationService. Route workspace stop through the profile socket so it enters that coordinator;
    /// constructing an app-local orchestrator would have no daemon-installed cancellation callback.
    nonisolated static func stopWorkspaceForStopAllQuit(
        workspaceID: String, sendProfileCommand: (TerminalServiceProfileCommand) throws -> TerminalServiceProfileCommandResponse
    ) throws {
        // Stop All names every workspace it stops, so the lifecycle payload's `cwd` is never consulted;
        // it carries the process directory only because the shared payload always requires one.
        _ = try sendProfileCommand(.workspaceStop(.init(cwd: FileManager.default.currentDirectoryPath, workspaceID: workspaceID)))
    }

    /// Ends one terminal open in the home project, through the profile socket for the same reason the
    /// workspace stop above goes through it: `.terminalStop` is the daemon's per-session teardown
    /// chokepoint, where automation cancellation is serialized and an agent's subscribers are told it
    /// exited before its row is deleted. Constructing an app-local orchestrator would reach neither.
    nonisolated static func stopHomeTerminalForStopAllQuit(
        sessionID: String, sendProfileCommand: (TerminalServiceProfileCommand) throws -> TerminalServiceProfileCommandResponse
    ) throws { _ = try sendProfileCommand(.terminalStop(sessionID: sessionID)) }

    nonisolated static func forceStopAllQuitAfterCleanupFailure(
        result: StopAllQuitCleanupResult, terminateSession: (String) throws -> Void, closeBrowserSessions: (String, [String]) -> Void
    ) -> Bool {
        var didFail = false
        for sessionID in result.remainingSessionIDs {
            do { try terminateSession(sessionID) } catch {
                fputs("spaces: failed to force-stop terminal session \(sessionID): \(error)\n", stderr)
                didFail = true
            }
        }
        for workspaceID in result.workspaceIDs {
            guard let targetURLs = result.browserSessionTargetURLsByWorkspaceID[workspaceID] else { continue }
            closeBrowserSessions(workspaceID, targetURLs)
        }
        return !didFail
    }

    nonisolated static func stopAllQuitFailureTerminateReply(
        result: StopAllQuitCleanupResult, choice: StopAllQuitCleanupFailureChoice, parkAgentSessionsForRestore: () -> String?,
        terminateSession: (String) throws -> Void, closeBrowserSessions: (String, [String]) -> Void, reconcileParkedAgentSessions: (String) -> Void
    ) -> NSApplication.TerminateReply {
        let reply: NSApplication.TerminateReply
        let parkedRestoreGeneration: String?
        switch choice {
        case .forceQuit:
            // Cleanup that fails before its own park (workspace inspection or browser-target preparation)
            // leaves nothing recorded, and a force quit from there terminates every remaining session, which
            // the daemon reads as a deliberate end. So the park happens here, immediately before the
            // termination, on the same terms as the one in the cleanup: last thing before the sessions go.
            parkedRestoreGeneration = result.parkedRestoreGeneration ?? parkAgentSessionsForRestore()
            reply =
                forceStopAllQuitAfterCleanupFailure(result: result, terminateSession: terminateSession, closeBrowserSessions: closeBrowserSessions)
                ? .terminateNow : .terminateCancel
        case .cancelQuit:
            // Nothing is parked here: the app stays open with its agents running, so there is nothing to
            // offer back and nothing a cleanup that never parked needs to record.
            parkedRestoreGeneration = result.parkedRestoreGeneration
            reply = .terminateCancel
        }
        // A quit that does not happen can still have stopped workspaces before it was cancelled, so the
        // record it parked is reconciled rather than dropped: an agent still running needs no offer (it
        // would come back as a second copy of itself), while an agent whose workspace did stop is gone, and
        // this record is the only way back to it.
        if reply == .terminateCancel, let generation = parkedRestoreGeneration { reconcileParkedAgentSessions(generation) }
        return reply
    }

    /// Every local workspace Stop All can stop, which leaves the home project's out: it has no stop, so
    /// the terminals open in it are torn down one session at a time instead (see
    /// `stopAllQuitSessionOwnership`).
    nonisolated static func runningLocalWorkspacesForStopAllQuit(store: SQLiteStore) throws -> [WorkspaceRecord] {
        var workspaces: [WorkspaceRecord] = []
        for project in try store.projects() where project.kind != .home { workspaces.append(contentsOf: try store.workspaces(projectID: project.id)) }
        return workspaces
    }

    /// Which teardown path a live session takes, read from the local daemon store.
    ///
    /// A session whose workspace belongs to the home project takes the per-session path rather than
    /// answering with its workspace, because the home project supports terminals and nothing else: its
    /// workspace has no lifecycle (`assertWorkspaceHasLifecycle` refuses Start, Stop, and Restart for it),
    /// so it is left out of the list above and no workspace Stop covers the terminals open in it. The
    /// per-session stop is the same teardown the sidebar's Stop on a terminal row and `spaces terminal
    /// stop` drive, so the session's window, agent, and subscriber rows go with it, the home workspace's
    /// running flag is reconciled once nothing is left tracked against it, and an automation that owns the
    /// session is cancelled rather than having its terminal pulled out from under it. A raw termination
    /// would end the process and leave every one of those rows behind, so the next launch would show a
    /// running `~` row whose terminal no longer exists.
    ///
    /// A session no workspace owns is unowned: there is no per-session stop to route it through, so the
    /// raw pass is the only thing that can end it.
    nonisolated static func stopAllQuitSessionOwnership(sessionID: String, store: SQLiteStore) throws -> StopAllQuitSessionOwnership {
        guard let workspaceID = try store.workspaceIDForTerminalSession(sessionID), let workspace = try store.workspace(id: workspaceID) else {
            return .unowned
        }
        guard try store.project(id: workspace.projectID)?.kind != .home else { return .homeTerminalStop }
        return .workspaceStop(workspace)
    }

    func performStopAllQuitCleanup(liveSessions: [TerminalServiceSessionSummary]) -> StopAllQuitCleanupResult {
        do {
            let store = try SQLiteStore(path: try DatabaseLocator.defaultPath())
            let orchestrator = WorkspaceOrchestrator(store: store)
            return Self.performStopAllQuitCleanup(
                liveSessions: liveSessions, parkAgentSessionsForRestore: Self.parkAgentSessionsForStopAllQuit,
                runningWorkspaces: { try Self.runningLocalWorkspacesForStopAllQuit(store: store) },
                ownershipForLiveSession: { sessionID in try Self.stopAllQuitSessionOwnership(sessionID: sessionID, store: store) },
                stopWorkspace: { workspaceID in
                    try Self.stopWorkspaceForStopAllQuit(workspaceID: workspaceID) { command in try TerminalService.sendProfileCommand(command) }
                },
                stopHomeTerminalSession: { sessionID in
                    try Self.stopHomeTerminalForStopAllQuit(sessionID: sessionID) { command in try TerminalService.sendProfileCommand(command) }
                }, terminateSession: { sessionID in try TerminalService.terminateSession(id: sessionID) },
                listLiveSessions: TerminalService.listSessions,
                browserSessionTargetURLs: { workspaceID in
                    try Self.configuredBrowserSessionTargetURLsForStopAllQuit(workspaceID: workspaceID, orchestrator: orchestrator)
                },
                closeBrowserSessions: { workspaceID, configuredBrowserSessionTargetURLs in
                    BrowserSessionCoordinator.closeLocalBrowserSessionWindowsSynchronously(
                        workspaceID: workspaceID, configuredBrowserSessionTargetURLs: configuredBrowserSessionTargetURLs)
                })
        } catch {
            return StopAllQuitCleanupResult(
                workspaceIDs: [], stoppedWorkspaceIDs: [], associatedLiveSessionIDs: [], browserSessionTargetURLsByWorkspaceID: [:], stopFailures: [],
                homeStoppedSessionIDs: [], homeStopFailures: [], rawTerminatedSessionIDs: [], rawTerminationFailures: [],
                remainingSessionIDs: Self.uniqueSessionIDs(liveSessions.map(\.id)), preparationError: error)
        }
    }

    func presentStopAllQuitCleanupFailureDialog(_ result: StopAllQuitCleanupResult) -> StopAllQuitCleanupFailureChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Stop All Workspaces"
        alert.informativeText = stopAllQuitCleanupFailureMessage(result)
        let forceButton = alert.addButton(withTitle: "Force Quit")
        forceButton.keyEquivalent = "\r"
        forceButton.keyEquivalentModifierMask = []
        let cancelButton = alert.addButton(withTitle: "Cancel Quit")
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        return alert.runModal() == .alertFirstButtonReturn ? .forceQuit : .cancelQuit
    }

    func handleStopAllQuitCleanupFailure(_ result: StopAllQuitCleanupResult) -> NSApplication.TerminateReply {
        let choice = presentStopAllQuitCleanupFailureDialog(result)
        let reply = Self.stopAllQuitFailureTerminateReply(
            result: result, choice: choice, parkAgentSessionsForRestore: Self.parkAgentSessionsForStopAllQuit,
            terminateSession: { sessionID in try TerminalService.terminateSession(id: sessionID) },
            closeBrowserSessions: { workspaceID, configuredBrowserSessionTargetURLs in
                BrowserSessionCoordinator.closeLocalBrowserSessionWindowsSynchronously(
                    workspaceID: workspaceID, configuredBrowserSessionTargetURLs: configuredBrowserSessionTargetURLs)
            }, reconcileParkedAgentSessions: Self.reconcileParkedAgentSessionsAfterStopAllQuit(generation:))
        if choice == .forceQuit, reply == .terminateCancel {
            showError(WorkspaceError.invalidArgument(message: "Unable to force-stop all terminal sessions before quitting."))
        }
        return reply
    }

    private func stopAllQuitCleanupFailureMessage(_ result: StopAllQuitCleanupResult) -> String {
        var parts: [String] = []
        if result.preparationError != nil { parts.append("Spaces could not inspect the local workspace runtime state.") }
        if !result.stopFailures.isEmpty {
            let count = result.stopFailures.count
            parts.append("\(count) local \(count == 1 ? "workspace" : "workspaces") could not be stopped cleanly.")
        }
        if !result.homeStopFailures.isEmpty {
            let count = result.homeStopFailures.count
            parts.append("\(count) terminal \(count == 1 ? "session" : "sessions") in the home project could not be stopped.")
        }
        if !result.remainingSessionIDs.isEmpty {
            let count = result.remainingSessionIDs.count
            parts.append("\(count) original terminal \(count == 1 ? "session is" : "sessions are") still running.")
        }
        if !result.rawTerminationFailures.isEmpty {
            let count = result.rawTerminationFailures.count
            parts.append("\(count) unowned terminal \(count == 1 ? "session" : "sessions") could not be stopped.")
        }
        parts.append("Force Quit stops the remaining terminal sessions and quits Spaces. Cancel Quit leaves Spaces open.")
        return parts.joined(separator: " ")
    }

    nonisolated private static func configuredBrowserSessionTargetURLsForStopAllQuit(workspaceID: String, orchestrator: WorkspaceOrchestrator) throws
        -> [String]
    { try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspaceID).compactMap(\.url) }

    nonisolated private static func uniqueSessionIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            unique.append(id)
        }
        return unique
    }
}
