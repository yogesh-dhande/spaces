import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// The restore loop end to end at the record level: an agent is captured, relaunched the way Restore
/// relaunches it, and captured again once it reports a newer conversation.
final class RestorableSessionRestoreLoopTests: XCTestCase {

    /// A restored agent records the command it was originally started with, not the resume command it
    /// runs, so restoring it a second time resumes its newest conversation with one selector. Recording the
    /// resume command instead would splice a second selector in ahead of the first.
    func testRestoringTwiceResumesTheNewestConversationWithOneSelector() throws {
        let store = try makeTemporaryStore()
        let launchCapture = TerminalLaunchConfigurationCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalSessionLauncher: { configuration in
                launchCapture.append(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
                    launchConfiguration: configuration)
            })
        let projectDir = try makeTempDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // The agent the user started, live and reporting its first conversation.
        let spawned = try orchestrator.createWorkspaceAgentSession(workspaceID: workspace.id, command: "codex --yolo", title: nil)
        let spawnedConfiguration = try XCTUnwrap(launchCapture.snapshot().last)
        try persistLaunchedSession(spawnedConfiguration, state: .running)
        try seedAgentRow(store: store, workspaceID: workspace.id, terminalSessionID: spawned.id, sessionKey: "conversation-1")

        XCTAssertEqual(try store.captureLiveAgentSessionsForRestore(generation: "gen-1", capturedAt: "2026-09-11T00:00:00Z"), 1)
        let firstOffer = try XCTUnwrap(try store.restorableSessions().first)
        XCTAssertEqual(firstOffer.launchCommand, "codex --yolo")
        let firstResume = CodingAgent.resumeCommand(launchCommand: firstOffer.launchCommand, sessionKey: firstOffer.agentSessionKey)
        XCTAssertEqual(firstResume, "codex resume conversation-1 --yolo")

        // Restore: the relaunch runs the resume command and records the captured one. The original agent
        // has ended, which is why it is being offered back at all.
        try persistLaunchedSession(spawnedConfiguration, state: .exited)
        let restored = try orchestrator.createWorkspaceAgentSession(
            workspaceID: firstOffer.workspaceID, command: firstResume, title: firstOffer.title, recordedLaunchCommand: firstOffer.launchCommand)
        let restoredConfiguration = try XCTUnwrap(launchCapture.snapshot().last)
        XCTAssertTrue(restoredConfiguration.command?.contains(firstResume) == true, "the relaunch runs the resume command")
        XCTAssertEqual(restoredConfiguration.launchCommand, "codex --yolo", "the relaunch records the command the agent was started with")
        try store.clearRestorableSessions(generation: firstOffer.generation)

        // The restored agent reports its own conversation and its work is cut short again.
        try persistLaunchedSession(restoredConfiguration, state: .running)
        try seedAgentRow(store: store, workspaceID: workspace.id, terminalSessionID: restored.id, sessionKey: "conversation-2")

        XCTAssertEqual(try store.captureLiveAgentSessionsForRestore(generation: "gen-2", capturedAt: "2026-09-11T00:10:00Z"), 1)
        let secondOffer = try XCTUnwrap(try store.restorableSessions().first)
        XCTAssertEqual(secondOffer.sessionID, restored.id)
        let secondResume = CodingAgent.resumeCommand(launchCommand: secondOffer.launchCommand, sessionKey: secondOffer.agentSessionKey)
        XCTAssertEqual(secondResume, "codex resume conversation-2 --yolo")
    }

    /// The same loop for an agent the user typed into a terminal: it is captured off its runtime row's
    /// foreground sample, comes back as an agent session of its own in the directory it was working in, and
    /// is restorable again from there, off its own session row this time.
    func testATypedAgentIsRestoredIntoItsWorkingDirectoryAndIsRestorableAgain() throws {
        let store = try makeTemporaryStore()
        let launchCapture = TerminalLaunchConfigurationCapture()
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalSessionLauncher: { Self.summary(for: $0, capture: launchCapture) })
        let projectDir = try makeTempDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let agentDirectory = URL(fileURLWithPath: workspace.dir).appendingPathComponent("services/api", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

        // A terminal the user opened, with `claude` typed into it and `cd`-ed into a subdirectory: its core
        // samples the running agent onto the runtime row, and the classification pass copies that sample
        // onto the agent row alongside the conversation the hooks reported.
        let shell = try orchestrator.createWorkspaceTerminalSession(workspaceID: workspace.id, title: nil, command: nil)
        let shellConfiguration = try XCTUnwrap(launchCapture.snapshot().last)
        try persistLaunchedSession(
            shellConfiguration, state: .running, workingDirectory: agentDirectory.path, foregroundAgentKind: .claude,
            foregroundCommand: #"claude --model opus 'fix the build'"#)
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-\(shell.id)", workspaceID: workspace.id, provider: .spaces, label: "claude",
                terminalTarget: TerminalTargetRecord(trackingID: shell.id), sessionKey: "conversation-1", status: .spinning,
                detectedAgentKind: TerminalDetectedAgentKind.claude.rawValue, launchCommand: #"claude --model opus 'fix the build'"#,
                createdAt: "2026-09-11T00:00:00Z", updatedAt: "2026-09-11T00:00:00Z"))

        XCTAssertEqual(try store.captureLiveAgentSessionsForRestore(generation: "gen-1", capturedAt: "2026-09-11T00:00:00Z"), 1)
        let offer = try XCTUnwrap(try store.restorableSessions().first)
        XCTAssertEqual(offer.sessionID, shell.id)
        XCTAssertEqual(offer.workingDirectory, agentDirectory.path)
        let resume = CodingAgent.resumeCommand(launchCommand: offer.launchCommand, sessionKey: offer.agentSessionKey)
        XCTAssertEqual(resume, "claude --resume conversation-1 --model opus", "the resumed conversation already holds the prompt")

        // Restore relaunches it as an agent session in the recorded directory, with no run attribution.
        try persistLaunchedSession(shellConfiguration, state: .exited, workingDirectory: agentDirectory.path)
        let restored = try orchestrator.createWorkspaceAgentSession(
            workspaceID: offer.workspaceID, command: resume, title: offer.title, recordedLaunchCommand: offer.launchCommand,
            workingDirectory: offer.workingDirectory)
        let restoredConfiguration = try XCTUnwrap(launchCapture.snapshot().last)
        XCTAssertEqual(restoredConfiguration.kind, .agent)
        XCTAssertEqual(restoredConfiguration.workingDirectory, agentDirectory.path)
        XCTAssertNil(restoredConfiguration.automationRunID)
        XCTAssertEqual(restoredConfiguration.launchCommand, #"claude --model opus 'fix the build'"#)
        try store.clearRestorableSessions(generation: offer.generation)

        // The restored agent is an ordinary agent session from here, captured off its own session row.
        try persistLaunchedSession(restoredConfiguration, state: .running, workingDirectory: agentDirectory.path)
        try seedAgentRow(store: store, workspaceID: workspace.id, terminalSessionID: restored.id, sessionKey: "conversation-2")

        XCTAssertEqual(try store.captureLiveAgentSessionsForRestore(generation: "gen-2", capturedAt: "2026-09-11T00:10:00Z"), 1)
        let secondOffer = try XCTUnwrap(try store.restorableSessions().first)
        XCTAssertEqual(secondOffer.sessionID, restored.id)
        XCTAssertEqual(secondOffer.workingDirectory, agentDirectory.path)
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: secondOffer.launchCommand, sessionKey: secondOffer.agentSessionKey),
            "claude --resume conversation-2 --model opus")
    }

    /// A recorded directory that is gone fails that row's relaunch, which is what puts the agent on the
    /// restore answer's list of agents that could not come back. Starting it somewhere else would look like
    /// a success and act on the wrong tree.
    func testRestoringIntoADirectoryThatIsGoneFailsThatRelaunch() throws {
        let store = try makeTemporaryStore()
        let launchCapture = TerminalLaunchConfigurationCapture()
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalSessionLauncher: { Self.summary(for: $0, capture: launchCapture) })
        let projectDir = try makeTempDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        XCTAssertThrowsError(
            try orchestrator.createWorkspaceAgentSession(
                workspaceID: workspace.id, command: "claude --resume abc", title: "Claude", workingDirectory: workspace.dir + "/deleted-worktree")
        ) { error in XCTAssertTrue("\(error)".contains("Working directory"), "\(error)") }
        XCTAssertTrue(launchCapture.snapshot().isEmpty, "nothing is launched when the directory is gone")
    }

    // MARK: - Fixtures

    private static func summary(for configuration: TerminalSessionLaunchConfiguration, capture: TerminalLaunchConfigurationCapture)
        -> TerminalServiceSessionSummary
    {
        capture.append(configuration)
        return TerminalServiceSessionSummary(
            id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory, backend: configuration.backend,
            lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
            controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
            launchConfiguration: configuration)
    }

    /// Writes the session rows the terminal service writes for a launched session, so the capture queries
    /// read exactly what a real launch leaves behind.
    private func persistLaunchedSession(
        _ configuration: TerminalSessionLaunchConfiguration, state: TerminalSessionState, workingDirectory: String? = nil,
        foregroundAgentKind: TerminalDetectedAgentKind? = nil, foregroundCommand: String? = nil
    ) throws {
        let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: configuration.sessionID, servicePID: 123, childPID: 456, state: state, updatedAt: "2026-09-11T00:00:01Z",
                workingDirectory: workingDirectory, foregroundDetectedAgentKind: foregroundAgentKind, foregroundCommand: foregroundCommand),
            paths: paths)
    }

    /// The row an agent's hook signal writes, carrying the conversation id a restore resumes.
    private func seedAgentRow(store: SQLiteStore, workspaceID: String, terminalSessionID: String, sessionKey: String) throws {
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspaceID, provider: .spaces, label: sessionKey,
                terminalTarget: TerminalTargetRecord(trackingID: terminalSessionID), sessionKey: sessionKey, status: .idle,
                detectedAgentKind: TerminalDetectedAgentKind.codex.rawValue, createdAt: "2026-09-11T00:00:00Z", updatedAt: "2026-09-11T00:00:00Z"))
    }
}
