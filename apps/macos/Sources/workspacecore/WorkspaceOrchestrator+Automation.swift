import Foundation
import spacesterminalcore

extension WorkspaceOrchestrator {
    /// Launches the workspace-less terminal session that carries a scheduled automation's command. The
    /// sibling of `launchWorkspaceCommandSession` for automations: the launch configuration carries
    /// `workspaceID = nil`, `kind = .automation`, and the owning `automationRunID`, so the daemon's normal
    /// terminal-service session machinery runs the command while attributing the session back to its run.
    /// The command runs through the user's login shell (`$SHELL -l -c`, applied by the session core's
    /// `execCommand`); `environment` entries are exported ahead of the command exactly as ad-hoc sessions
    /// export their workspace environment.
    @discardableResult func launchAutomationSession(
        runID: String, sessionID: String, title: String, workingDirectory: String, command: String, environment: [String: String]
    ) throws -> TerminalServiceSessionSummary {
        let shellPath = terminalShellPathOverride() ?? defaultInteractiveShellPath()
        let launchCommand = commandPrefixedWithShellEnvironment(command, env: environment)
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: title, workingDirectory: workingDirectory,
            shell: shellPath, command: launchCommand, createdAt: nowISO8601(), workspaceID: nil, kind: .automation, automationRunID: runID)
        return try builtInTerminalSessionLauncher(launchConfiguration)
    }

    /// The login shell path an automation command runs under. Exposed for the automation executor, which
    /// resolves the same login shell the ad-hoc terminal launch path uses.
    func automationLoginShellPath() -> String { terminalShellPathOverride() ?? defaultInteractiveShellPath() }

    /// Single-quotes a token for safe interpolation into an automation command string.
    func automationShellQuoted(_ token: String) -> String { shellSingleQuoted(token) }

    /// Whether a built-in terminal session is still live (control socket present, interactive runtime
    /// state, service PID alive). Exposed for the automation executor's attributed-session sweep.
    func automationSessionIsLive(sessionID: String) -> Bool { builtInSessionIsStillLive(sessionID: sessionID) }

    /// Terminates a built-in terminal session through the daemon's existing termination machinery.
    func automationTerminateSession(sessionID: String) { builtInTerminalSessionTerminator(sessionID) }
}
