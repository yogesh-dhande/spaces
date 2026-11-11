import Foundation
import spacesterminalcore

/// What a lost-shell resume produced: the session the pane's terminal row now names.
public struct LostShellResumption: Sendable, Equatable {
    public let sessionID: String
    public let replacedSessionID: String
    public let workspaceID: String
}

extension WorkspaceOrchestrator {
    /// Replaces a shell that was lost without an exit with a fresh shell in the same workspace, working
    /// directory and terminal row, with the lost shell's output above it.
    ///
    /// A shell is lost when stale recovery marked it `.failed` (its process died with the host or the
    /// daemon, so it never recorded an exit) while a plain terminal row still names it. That needs no flag
    /// of its own: the only other writer of `.failed`, a launch that never started, deletes its row; a
    /// shell the user ended is `.exited`; a configured process or agent is not `.shell`. A session on the
    /// pending restore record is refused so the restore offer keeps its seat. Once the offer is answered
    /// the shell that hosted that agent is an ordinary lost shell.
    ///
    /// The new session gets a fresh id and the row is repointed at it, because the old session's directory
    /// holds the transcript being carried over and a core would truncate it. The seed is read before the
    /// repoint so retention, which releases a session nothing references, cannot purge it first.
    ///
    /// Two clients asking at once launch one shell: the lifecycle gate serializes them, and the second
    /// finds the replacement the first recorded in the lost session's directory and returns it.
    ///
    /// A missing working directory fails the call before anything starts; no other directory is
    /// substituted.
    @discardableResult public func resumeLostShell(sessionID: String) throws -> LostShellResumption {
        let oldPaths = try TerminalSessionPaths.forSession(id: sessionID)
        guard let oldLaunch = try? TerminalSessionPersistence.readLaunchConfiguration(paths: oldPaths) else {
            throw WorkspaceError.sessionNotResumable(message: "Terminal session \(sessionID) was not found.")
        }
        guard oldLaunch.kind == .shell, let workspaceID = oldLaunch.workspaceID else {
            throw WorkspaceError.sessionNotResumable(message: "Terminal session \(sessionID) is not a shell.")
        }
        return try withWorkspaceLifecycleLockWaiting(workspaceID: workspaceID) {
            let (project, workspace) = try resolveWorkspace(id: workspaceID)

            if let replacementID = try currentReplacement(of: sessionID, workspaceID: workspaceID) {
                return LostShellResumption(sessionID: replacementID, replacedSessionID: sessionID, workspaceID: workspaceID)
            }

            guard let oldState = try? TerminalSessionPersistence.readRuntimeState(paths: oldPaths), oldState.state == .failed else {
                throw WorkspaceError.sessionNotResumable(message: "Terminal session \(sessionID) did not end unexpectedly.")
            }
            guard
                let window = try store.windowsReferencingTerminalSession(terminalSessionID: sessionID).first(where: {
                    $0.workspaceID == workspaceID && $0.roleValue == .terminal
                })
            else { throw WorkspaceError.sessionNotResumable(message: "Terminal session \(sessionID) is no longer a terminal of its workspace.") }
            guard try !store.holdsRestorableSession(sessionID: sessionID) else {
                throw WorkspaceError.restorePending(message: "Terminal session \(sessionID) is held by a pending restore.")
            }

            let workingDirectory = oldState.workingDirectory ?? oldLaunch.workingDirectory
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw WorkspaceError.workingDirectoryMissing(path: workingDirectory)
            }

            let seed = try lostShellSeed(oldPaths: oldPaths, oldState: oldState)
            // The launch title is the generated `shell-N`, and a rename lives apart from it as the session's
            // user title (with the row's name following it), so clearing a rename later still falls back to
            // `shell-N`. Launching under the row's current name would bake a rename into the launch title.
            let session = try launchWorkspaceCommandSession(
                project: project, workspace: workspace, title: oldLaunch.title, shellCommand: interactiveShellCommand(cwd: workingDirectory),
                kind: .shell, defaultTitle: oldLaunch.title, workingDirectory: workingDirectory, replacing: window, transcriptSeed: seed,
                userTitle: oldLaunch.userTitle)
            // Best effort: without the record a repeat request is refused as not lost, and the client
            // reaches the replacement through the terminal row it now names.
            try? session.id.write(toFile: oldPaths.replacementSessionPath, atomically: true, encoding: .utf8)
            return LostShellResumption(sessionID: session.id, replacedSessionID: sessionID, workspaceID: workspaceID)
        }
    }

    /// The session now standing in for `sessionID`, following the chain when a replacement was itself
    /// replaced, provided a terminal row of the workspace still names it.
    private func currentReplacement(of sessionID: String, workspaceID: String) throws -> String? {
        var current = sessionID
        while let next = try? String(contentsOfFile: TerminalSessionPaths.forSession(id: current).replacementSessionPath, encoding: .utf8),
            !next.isEmpty
        { current = next }
        guard current != sessionID else { return nil }
        let rows = try store.windowsReferencingTerminalSession(terminalSessionID: current)
        return rows.contains { $0.workspaceID == workspaceID && $0.roleValue == .terminal } ? current : nil
    }

    private func lostShellSeed(oldPaths: TerminalSessionPaths, oldState: TerminalSessionRuntimeState) throws -> TerminalTranscriptSeed {
        guard let modifiedAt = try? FileManager.default.attributesOfItem(atPath: oldPaths.outputPath)[.modificationDate] as? Date else {
            throw WorkspaceError.sessionNotResumable(message: "Terminal session \(oldState.sessionID) has no transcript to carry over.")
        }
        let cause = TerminalLostShellSeparator.cause(lastOutputAt: modifiedAt, hostBootedAt: HostBootTime.current(), platform: .current)
        let columns = oldState.columns ?? 80
        let rows = oldState.rows ?? 24
        let bytes = try TerminalLostShellSeed.build(
            transcriptPath: oldPaths.outputPath, columns: columns, rows: rows,
            separator: TerminalLostShellSeparator.text(cause: cause, lastOutputAt: modifiedAt))
        return TerminalTranscriptSeed(bytes: bytes, columns: columns, rows: rows)
    }
}
