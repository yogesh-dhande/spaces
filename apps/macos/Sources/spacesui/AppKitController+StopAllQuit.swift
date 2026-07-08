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
        let rawTerminatedSessionIDs: [String]
        let rawTerminationFailures: [StopAllQuitSessionTerminationFailure]
        let remainingSessionIDs: [String]
        let preparationError: Error?

        var succeeded: Bool { preparationError == nil && stopFailures.isEmpty && rawTerminationFailures.isEmpty && remainingSessionIDs.isEmpty }
    }

    enum StopAllQuitCleanupFailureChoice: Equatable, Sendable {
        case forceQuit
        case cancelQuit
    }

    struct BrowserSessionWindowTracking: Equatable, Sendable {
        let targetURL: String
        let windowID: Int
    }

    nonisolated static func stopAllQuitWorkspaceSelection(
        runningWorkspaces: [WorkspaceRecord], liveSessions: [TerminalServiceSessionSummary],
        workspaceForLiveSession: (String) throws -> WorkspaceRecord?
    ) throws -> StopAllQuitWorkspaceSelection {
        var workspaceIDs: [String] = []
        var seenWorkspaceIDs = Set<String>()
        var associatedLiveSessionIDs = Set<String>()

        func appendWorkspaceID(_ workspaceID: String) {
            guard !seenWorkspaceIDs.contains(workspaceID) else { return }
            seenWorkspaceIDs.insert(workspaceID)
            workspaceIDs.append(workspaceID)
        }

        for workspace in runningWorkspaces
        where workspace.deviceID == SpacesDeviceRecord.localDeviceID && !workspace.isArchived && workspace.isRunning {
            appendWorkspaceID(workspace.id)
        }

        for session in liveSessions {
            guard let workspace = try workspaceForLiveSession(session.id) else { continue }
            associatedLiveSessionIDs.insert(session.id)
            guard workspace.deviceID == SpacesDeviceRecord.localDeviceID else { continue }
            appendWorkspaceID(workspace.id)
        }

        return StopAllQuitWorkspaceSelection(workspaceIDs: workspaceIDs, associatedLiveSessionIDs: associatedLiveSessionIDs)
    }

    nonisolated static func performStopAllQuitCleanup(
        liveSessions: [TerminalServiceSessionSummary], runningWorkspaces: () throws -> [WorkspaceRecord],
        workspaceForLiveSession: (String) throws -> WorkspaceRecord?, stopWorkspace: (String) throws -> Void,
        terminateSession: (String) throws -> Void, listLiveSessions: () throws -> [TerminalServiceSessionSummary],
        browserSessionTargetURLs: (String) throws -> [String], closeBrowserSessions: (String, [String]) -> Void
    ) -> StopAllQuitCleanupResult {
        let originalLiveSessionIDs = Set(liveSessions.map(\.id))
        let selection: StopAllQuitWorkspaceSelection
        do {
            selection = try stopAllQuitWorkspaceSelection(
                runningWorkspaces: try runningWorkspaces(), liveSessions: liveSessions, workspaceForLiveSession: workspaceForLiveSession)
        } catch {
            return StopAllQuitCleanupResult(
                workspaceIDs: [], stoppedWorkspaceIDs: [], associatedLiveSessionIDs: [], browserSessionTargetURLsByWorkspaceID: [:], stopFailures: [],
                rawTerminatedSessionIDs: [], rawTerminationFailures: [], remainingSessionIDs: uniqueSessionIDs(liveSessions.map(\.id)),
                preparationError: error)
        }

        var browserSessionTargetURLsByWorkspaceID: [String: [String]] = [:]
        do {
            for workspaceID in selection.workspaceIDs {
                browserSessionTargetURLsByWorkspaceID[workspaceID] = try browserSessionTargetURLs(workspaceID)
            }
        } catch {
            return StopAllQuitCleanupResult(
                workspaceIDs: selection.workspaceIDs, stoppedWorkspaceIDs: [], associatedLiveSessionIDs: selection.associatedLiveSessionIDs,
                browserSessionTargetURLsByWorkspaceID: browserSessionTargetURLsByWorkspaceID, stopFailures: [], rawTerminatedSessionIDs: [],
                rawTerminationFailures: [], remainingSessionIDs: uniqueSessionIDs(liveSessions.map(\.id)), preparationError: error)
        }

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
        let unownedRemainingSessionIDs = uniqueSessionIDs(
            liveAfterWorkspaceStop.filter { originalLiveSessionIDs.contains($0.id) && !selection.associatedLiveSessionIDs.contains($0.id) }.map(\.id))
        var rawTerminatedSessionIDs: [String] = []
        var rawTerminationFailures: [StopAllQuitSessionTerminationFailure] = []
        for sessionID in unownedRemainingSessionIDs {
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
            rawTerminatedSessionIDs: rawTerminatedSessionIDs, rawTerminationFailures: rawTerminationFailures,
            remainingSessionIDs: remainingSessionIDs, preparationError: nil)
    }

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
        result: StopAllQuitCleanupResult, choice: StopAllQuitCleanupFailureChoice, terminateSession: (String) throws -> Void,
        closeBrowserSessions: (String, [String]) -> Void
    ) -> NSApplication.TerminateReply {
        switch choice {
        case .forceQuit:
            return forceStopAllQuitAfterCleanupFailure(result: result, terminateSession: terminateSession, closeBrowserSessions: closeBrowserSessions)
                ? .terminateNow : .terminateCancel
        case .cancelQuit: return .terminateCancel
        }
    }

    nonisolated static func runningLocalWorkspacesForStopAllQuit(store: SQLiteStore) throws -> [WorkspaceRecord] {
        var workspaces: [WorkspaceRecord] = []
        for project in try store.projects() { workspaces.append(contentsOf: try store.workspaces(projectID: project.id, includeArchived: false)) }
        return workspaces
    }

    nonisolated static func closeLocalBrowserSessionWindowsSynchronously(workspaceID: String, configuredBrowserSessionTargetURLs: [String]) {
        let store = ClientBrowserWindowIDStore()
        let chrome = ChromeAdapter()
        closeLocalBrowserSessionWindowsSynchronously(
            workspaceID: workspaceID, configuredBrowserSessionTargetURLs: configuredBrowserSessionTargetURLs,
            trackedWindowIDs: {
                try store.windowIDs(workspaceID: workspaceID).map { BrowserSessionWindowTracking(targetURL: $0.targetURL, windowID: $0.windowID) }
            }, chromeIsRunning: { chrome.isRunning() },
            closeMatchingTabsInWindow: { windowID, urlPrefix, excludedURLPrefixes in
                try chrome.closeMatchingTabsInWindow(windowID: windowID, urlPrefix: urlPrefix, excludingURLPrefixes: excludedURLPrefixes)
            }, clearTrackedWindowIDs: { try store.clearAll(workspaceID: workspaceID) })
    }

    nonisolated static func closeLocalBrowserSessionWindowsSynchronously(
        workspaceID: String, configuredBrowserSessionTargetURLs: [String], trackedWindowIDs: () throws -> [BrowserSessionWindowTracking],
        chromeIsRunning: () -> Bool, closeMatchingTabsInWindow: (Int, String, [String]) throws -> Bool, clearTrackedWindowIDs: () throws -> Void
    ) {
        guard let tracked = try? trackedWindowIDs(), !tracked.isEmpty else { return }
        // This check avoids launching Chrome just to clean up tabs that disappeared when the user quit Chrome.
        if chromeIsRunning() {
            let teardownTargetURLs = browserSessionTeardownTargetURLs(
                configuredTargetURLs: configuredBrowserSessionTargetURLs, trackedTargetURLs: tracked.map(\.targetURL))
            for entry in tracked {
                // The URL guard keeps a stale reused Chrome window id from closing an unrelated user tab.
                _ = try? closeMatchingTabsInWindow(
                    entry.windowID, entry.targetURL, browserSessionSiblingTargetURLs(targetURL: entry.targetURL, targetURLs: teardownTargetURLs))
            }
        }
        try? clearTrackedWindowIDs()
    }

    func performStopAllQuitCleanup(liveSessions: [TerminalServiceSessionSummary]) -> StopAllQuitCleanupResult {
        do {
            let store = try SQLiteStore(path: try DatabaseLocator.defaultPath())
            let orchestrator = WorkspaceOrchestrator(store: store)
            return Self.performStopAllQuitCleanup(
                liveSessions: liveSessions, runningWorkspaces: { try Self.runningLocalWorkspacesForStopAllQuit(store: store) },
                workspaceForLiveSession: { sessionID in
                    guard let workspaceID = try store.workspaceIDForTerminalSession(sessionID) else { return nil }
                    return try store.workspace(id: workspaceID)
                }, stopWorkspace: { workspaceID in _ = try orchestrator.stopWorkspace(workspaceID: workspaceID) },
                terminateSession: { sessionID in try TerminalService.terminateSession(id: sessionID) },
                listLiveSessions: TerminalService.listSessions,
                browserSessionTargetURLs: { workspaceID in
                    try Self.configuredBrowserSessionTargetURLsForStopAllQuit(workspaceID: workspaceID, orchestrator: orchestrator)
                },
                closeBrowserSessions: { workspaceID, configuredBrowserSessionTargetURLs in
                    Self.closeLocalBrowserSessionWindowsSynchronously(
                        workspaceID: workspaceID, configuredBrowserSessionTargetURLs: configuredBrowserSessionTargetURLs)
                })
        } catch {
            return StopAllQuitCleanupResult(
                workspaceIDs: [], stoppedWorkspaceIDs: [], associatedLiveSessionIDs: [], browserSessionTargetURLsByWorkspaceID: [:], stopFailures: [],
                rawTerminatedSessionIDs: [], rawTerminationFailures: [], remainingSessionIDs: Self.uniqueSessionIDs(liveSessions.map(\.id)),
                preparationError: error)
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
            result: result, choice: choice, terminateSession: { sessionID in try TerminalService.terminateSession(id: sessionID) },
            closeBrowserSessions: { workspaceID, configuredBrowserSessionTargetURLs in
                Self.closeLocalBrowserSessionWindowsSynchronously(
                    workspaceID: workspaceID, configuredBrowserSessionTargetURLs: configuredBrowserSessionTargetURLs)
            })
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
