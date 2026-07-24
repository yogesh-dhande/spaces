import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// Behavior coverage for the commit-2 spawn/kill/subscribe orchestration surface: the `.agent`-kind
/// launch, default titling, cross-workspace agent resolution, and hook-signal readiness.
final class AgentSpawnOrchestrationTests: XCTestCase {
    private func makeAgentOrchestrator(
        store: SQLiteStore, launchCapture: TerminalLaunchConfigurationCapture, terminateCapture: TerminalTerminateCapture
    ) -> WorkspaceOrchestrator {
        makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) },
            builtInTerminalSessionLauncher: { configuration in
                launchCapture.append(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
                    launchConfiguration: configuration)
            })
    }

    func testCreateWorkspaceAgentSessionLaunchesAgentKindWithAgentTitle() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let launchCapture = TerminalLaunchConfigurationCapture()
        let orchestrator = makeAgentOrchestrator(store: store, launchCapture: launchCapture, terminateCapture: TerminalTerminateCapture())
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        let session = try orchestrator.createWorkspaceAgentSession(workspaceID: workspace.id, command: "codex --yolo", title: nil)

        let launchConfiguration = try XCTUnwrap(launchCapture.snapshot().first)
        XCTAssertEqual(launchConfiguration.sessionID, session.id)
        XCTAssertEqual(launchConfiguration.kind, .agent)
        // Default title is the matched coding agent's display name.
        XCTAssertEqual(launchConfiguration.title, "Codex")
        XCTAssertTrue(launchConfiguration.command?.contains("codex --yolo") == true)
        let terminalWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first)
        XCTAssertEqual(terminalWindow.terminalTrackingID, session.id)
        XCTAssertEqual(terminalWindow.name, "Codex")
    }

    func testCreateWorkspaceAgentSessionHonorsExplicitTitleAndRejectsBlankCommand() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let launchCapture = TerminalLaunchConfigurationCapture()
        let orchestrator = makeAgentOrchestrator(store: store, launchCapture: launchCapture, terminateCapture: TerminalTerminateCapture())
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        _ = try orchestrator.createWorkspaceAgentSession(workspaceID: workspace.id, command: "claude", title: "Reviewer")
        XCTAssertEqual(launchCapture.snapshot().first?.title, "Reviewer")

        XCTAssertThrowsError(try orchestrator.createWorkspaceAgentSession(workspaceID: workspace.id, command: "   ", title: nil))
    }

    func testTerminateSpawnedAgentTerminalSessionKillsPreSignalAgentKindSession() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeAgentOrchestrator(
            store: store, launchCapture: TerminalLaunchConfigurationCapture(), terminateCapture: terminateCapture)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        // A spawned agent session launches with `.agent` kind and has no agent row until it signals.
        let session = try orchestrator.createWorkspaceAgentSession(workspaceID: workspace.id, command: "claude", title: "Reviewer")
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try store.windows(workspaceID: workspace.id).filter { $0.terminalTrackingID == session.id }.isEmpty)
        // The real terminal service persists the launch configuration at launch; the capture fake
        // does not, so persist the `.agent`-kind config the kind gate reads.
        let paths = try TerminalSessionPaths.forSession(id: session.id)
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: session.id, title: "Reviewer", workingDirectory: projectDir.path, shell: "/bin/zsh", command: "claude",
                createdAt: "now", workspaceID: workspace.id, kind: .agent), paths: paths)

        let killed = try orchestrator.terminateSpawnedAgentTerminalSession(sessionID: session.id)

        // The `.agent` launch kind is exactly what qualifies here (unlike stopAdHocBuiltInTerminalSession,
        // which excludes it): the session is terminated and its tracked window torn down.
        XCTAssertTrue(killed)
        XCTAssertEqual(terminateCapture.sessionIDs, [session.id])
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).filter { $0.terminalTrackingID == session.id }.isEmpty)
    }

    func testTerminateSpawnedAgentTerminalSessionReturnsFalseForUnknownSession() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        XCTAssertFalse(try orchestrator.terminateSpawnedAgentTerminalSession(sessionID: "no-such-session"))
    }

    /// `agent kill`'s pre-signal terminate fallback must refuse a session that was not launched as a
    /// coding agent: a mistyped or wrong session id naming an ordinary shell or process terminal must
    /// come back as "no agent session", not silently destroy that terminal.
    func testTerminateSpawnedAgentTerminalSessionRefusesShellAndProcessKindSessions() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeAgentOrchestrator(
            store: store, launchCapture: TerminalLaunchConfigurationCapture(), terminateCapture: terminateCapture)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        for kind: TerminalSessionKind in [.shell, .process] {
            let sessionID = "kill-refuse-\(kind.rawValue)-\(UUID().uuidString)"
            try store.upsert(
                window: WindowRecord(
                    id: "window-\(sessionID)", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: kind.rawValue, detail: nil,
                    targetURL: nil, terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: sessionID, title: kind.rawValue, workingDirectory: projectDir.path, shell: "/bin/zsh", command: nil,
                    createdAt: "now", workspaceID: workspace.id, kind: kind), paths: paths)

            let killed = try orchestrator.terminateSpawnedAgentTerminalSession(sessionID: sessionID)

            XCTAssertFalse(killed, "a \(kind.rawValue)-kind session must be refused, not treated as a spawned agent")
            XCTAssertTrue(terminateCapture.sessionIDs.isEmpty, "a refused \(kind.rawValue)-kind session must not be terminated")
            XCTAssertFalse(
                try store.windows(workspaceID: workspace.id).filter { $0.terminalTrackingID == sessionID }.isEmpty,
                "a refused \(kind.rawValue)-kind session must keep its tracked window")
        }
    }

    func testResolveSpacesAgentSessionFindsRowAcrossWorkspacesAndNilForUnknown() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)
        let workspaceA = makeWorkspaceRecord(projectID: project.id, dir: projectDir + "/a")
        let workspaceB = makeWorkspaceRecord(projectID: project.id, dir: projectDir + "/b")
        try store.upsert(workspace: workspaceA)
        try store.upsert(workspace: workspaceB)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspaceB.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "child-session", status: .idle)

        let resolved = try XCTUnwrap(orchestrator.resolveSpacesAgentSession(terminalSessionID: "child-session"))
        XCTAssertEqual(resolved.workspaceID, workspaceB.id)
        XCTAssertEqual(resolved.record.id, agent.id)

        XCTAssertNil(try orchestrator.resolveSpacesAgentSession(terminalSessionID: "no-such-session"))
    }

    func testAgentWindowExistsReflectsSubscriptionTargetPresence() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir + "/ws")
        try store.upsert(workspace: workspace)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .idle)

        XCTAssertTrue(try store.agentWindowExists(id: agent.id))
        XCTAssertFalse(try store.agentWindowExists(id: "missing-agent"))
    }

    func testForegroundDetectedRowIsNotReadyUntilHookSignal() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: projectDir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir + "/ws")
        try store.upsert(workspace: workspace)
        // A foreground-detected agent row exists but has emitted no hook signal event.
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .idle, eventSource: "foreground_agent_signal")
        XCTAssertNil(try store.lastAgentSignalAt(agentSessionID: agent.id))

        // A `working` signal through the hook-signal source flips readiness on.
        _ = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .spinning, eventType: "working",
            eventSource: "spaces_agent_signal")
        XCTAssertNotNil(try store.lastAgentSignalAt(agentSessionID: agent.id))
    }
}
