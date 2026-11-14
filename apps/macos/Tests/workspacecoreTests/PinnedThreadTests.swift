import Foundation
import XCTest
import spacesdatabase
import spacesdevicecore
import spacesterminalcore

@testable import workspacecore

/// Pinned threads at the orchestrator level: a pin names a running agent row, outlives the agent as a
/// not-running pin, splits off when the row's conversation changes, and re-attaches on resume.
final class PinnedThreadTests: XCTestCase {
    private struct Fixture {
        let store: SQLiteStore
        let orchestrator: WorkspaceOrchestrator
        let workspace: WorkspaceRecord
        let launches: TerminalLaunchConfigurationCapture

        /// Starts a live agent whose row already holds `key`, the state a hook report or a restore leaves.
        @discardableResult func startAgent(command: String = "claude", key: String? = "conv-1") throws -> AgentWindowRecord {
            let session = try orchestrator.createWorkspaceAgentSession(
                workspaceID: workspace.id, command: command, title: nil, recordedLaunchCommand: command, resumedAgentSessionKey: key)
            // Without a conversation the launch writes no row; a keyless hook init is what creates one.
            if key == nil {
                try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: session.id, status: .idle)
            }
            return try XCTUnwrap(try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: session.id))
        }

        /// An agent the user typed into an ad-hoc shell (named `shell-1`): its row claims that shell terminal.
        @discardableResult func startShellBackedAgent(key: String = "conv-1") throws -> AgentWindowRecord {
            let session = try orchestrator.createWorkspaceTerminalSession(workspaceID: workspace.id, title: nil, command: nil)
            let row = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: session.id, sessionKey: .set(key), status: .idle)
            try store.setAgentSessionDetectedForeground(id: row.id, kind: "claude", launchCommand: "claude")
            return try XCTUnwrap(try store.agentWindow(id: row.id))
        }

        func pin(_ agent: AgentWindowRecord, as name: String) throws {
            try orchestrator.pinAgentSession(workspaceID: workspace.id, agentID: agent.id, name: name)
        }

        func pins() throws -> [PinnedThreadRecord] { try store.pinnedThreads(workspaceID: workspace.id) }

        func row(_ agent: AgentWindowRecord) throws -> AgentWindowRecord { try XCTUnwrap(try store.agentWindow(id: agent.id)) }

        /// Ends the agent's terminal the way a quit does: its runtime row reads exited.
        func endTerminal(of agent: AgentWindowRecord) throws {
            let sessionID = try XCTUnwrap(agent.terminalTrackingID)
            try PinnedThreadTests.writeRuntimeState(sessionID: sessionID, state: .exited)
        }
    }

    private func makeFixture() throws -> Fixture {
        let store = try makeTemporaryStore()
        let launches = TerminalLaunchConfigurationCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalSessionLauncher: { configuration in
                Self.persistLiveSession(configuration)
                launches.append(configuration)
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
        return Fixture(store: store, orchestrator: orchestrator, workspace: workspace, launches: launches)
    }

    /// Writes what the terminal service leaves for a launched session, with a runtime state owned by this
    /// process and a control socket, which is what makes the session read as live.
    private static func persistLiveSession(_ configuration: TerminalSessionLaunchConfiguration) {
        guard let paths = try? TerminalSessionPaths.forSession(id: configuration.sessionID) else { return }
        try? paths.ensureDirectories()
        try? TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
        try? writeRuntimeState(sessionID: configuration.sessionID, state: .running)
        FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
    }

    fileprivate static func writeRuntimeState(sessionID: String, state: TerminalSessionState) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: state, updatedAt: "2026-06-06T00:00:00Z"),
            paths: paths)
    }

    // MARK: - Pinning

    func testPinNamesTheRunningRowAndKeepsTheConversation() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()

        try f.pin(agent, as: "  Fix checkout ")

        let pin = try XCTUnwrap(try f.pins().first)
        XCTAssertEqual(pin.name, "Fix checkout")
        XCTAssertEqual(pin.agentSessionID, agent.id)
        XCTAssertEqual(pin.sessionKey, "conv-1")
        XCTAssertEqual(pin.launchCommand, "claude")
        XCTAssertEqual(pin.workingDirectory, f.workspace.dir)
        XCTAssertEqual(try f.row(agent).effectiveLabel, "Fix checkout")
    }

    func testPinIsRefusedWithoutAConversationOrForAOneShotRun() throws {
        let f = try makeFixture()
        let keyless = try f.startAgent(key: nil)
        let oneShot = try f.startAgent(command: #"claude -p "summarize""#, key: "conv-2")

        for (agent, reason) in [(keyless, SpacesDeviceAgentPinUnavailableReason.noConversation), (oneShot, .oneShotRun)] {
            XCTAssertThrowsError(try f.pin(agent, as: "Nope"), "\(reason)") { error in
                guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains(reason.message), message)
            }
        }
        XCTAssertTrue(try f.pins().isEmpty)
        XCTAssertNil(try f.row(keyless).userLabel)
    }

    func testPinIsRefusedForANameTheWorkspaceAlreadyUsesAndForAnAlreadyPinnedConversation() throws {
        let f = try makeFixture()
        let first = try f.startAgent(key: "conv-1")
        let second = try f.startAgent(key: "conv-2")
        try f.pin(first, as: "Reviewer")

        XCTAssertThrowsError(try f.pin(second, as: "reviewer"), "a running pin's name is taken")
        XCTAssertThrowsError(try f.pin(first, as: "Other"), "a conversation is pinned once")
        XCTAssertThrowsError(try f.pin(second, as: "   "), "a pin needs a name")
        XCTAssertEqual(try f.pins().map(\.name), ["Reviewer"])
    }

    func testPinningAnExitedAgentLeavesANotRunningPinAndTheRowItsDefaultName() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.store.updateAgentWindowStatus(id: agent.id, status: .exited, updatedAt: "2026-06-06T00:00:00Z")

        try f.pin(agent, as: "Fix checkout")

        let pin = try XCTUnwrap(try f.pins().first)
        XCTAssertNil(pin.agentSessionID)
        XCTAssertEqual(try f.row(agent).effectiveLabel, agent.label)
    }

    func testPinsAreListedOldestFirst() throws {
        let f = try makeFixture()
        let first = try f.startAgent(key: "conv-1")
        let second = try f.startAgent(key: "conv-2")
        try f.pin(second, as: "Second")
        try f.pin(first, as: "First")

        XCTAssertEqual(try f.pins().map(\.name), ["Second", "First"])
        XCTAssertEqual(try f.store.pinnedThreadsByWorkspace()[f.workspace.id]?.map(\.name), ["Second", "First"])
    }

    // MARK: - Unpin

    func testUnpinningARunningPinKeepsTheRowUnderTheName() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")
        let pin = try XCTUnwrap(try f.pins().first)

        try f.orchestrator.unpinThread(workspaceID: f.workspace.id, pinID: pin.id)

        XCTAssertTrue(try f.pins().isEmpty)
        XCTAssertEqual(try f.row(agent).effectiveLabel, "Fix checkout")
    }

    func testUnpinningANotRunningPinRemovesIt() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")
        try f.store.deleteAgentWindow(id: agent.id)
        let pin = try XCTUnwrap(try f.pins().first)

        try f.orchestrator.unpinThread(workspaceID: f.workspace.id, pinID: pin.id)

        XCTAssertTrue(try f.pins().isEmpty)
    }

    // MARK: - The pin stays on its conversation

    func testAClearedConversationSplitsTheRowOffAndLeavesTheNameOnTheNotRunningPin() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")

        let changed = try f.orchestrator.updateAgentWindowSessionKey(id: agent.id, sessionKey: .clear, eventSource: "test")

        XCTAssertTrue(changed)
        XCTAssertNil(try f.pins().first?.agentSessionID)
        XCTAssertEqual(try f.pins().first?.name, "Fix checkout")
        XCTAssertEqual(try f.row(agent).effectiveLabel, agent.label, "the split row is an ordinary row under its default name")
    }

    func testTheSplitRowIsNumberedWhenItsDefaultNameIsTaken() throws {
        let f = try makeFixture()
        let pinned = try f.startAgent(key: "conv-1")
        try f.pin(pinned, as: "Fix checkout")
        let other = try f.startAgent(key: "conv-2")
        XCTAssertEqual(other.label, pinned.label)

        try f.orchestrator.updateAgentWindowSessionKey(id: pinned.id, sessionKey: .clear, eventSource: "test")

        XCTAssertEqual(try f.row(pinned).effectiveLabel, "\(try XCTUnwrap(pinned.label))-2")
        XCTAssertEqual(try f.row(other).effectiveLabel, other.label)
    }

    func testAStatusSignalReportingADifferentConversationSplitsAndTheSameOneDoesNot() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        let sessionID = try XCTUnwrap(agent.terminalTrackingID)
        try f.pin(agent, as: "Fix checkout")

        try f.orchestrator.updateAgentWindowStatus(
            workspaceID: f.workspace.id, provider: .spaces, terminalTrackingID: sessionID, sessionKey: .set("conv-1"), status: .spinning)
        XCTAssertEqual(try f.pins().first?.agentSessionID, agent.id, "the same conversation keeps the pin attached")
        XCTAssertEqual(try f.row(agent).effectiveLabel, "Fix checkout")

        try f.orchestrator.updateAgentWindowStatus(
            workspaceID: f.workspace.id, provider: .spaces, terminalTrackingID: sessionID, sessionKey: .set("conv-2"), status: .idle)
        XCTAssertNil(try f.pins().first?.agentSessionID)
        XCTAssertEqual(try f.row(agent).sessionKey, "conv-2")
        XCTAssertEqual(try f.row(agent).effectiveLabel, agent.label)
    }

    func testAPendingConversationReportOnAStatusSignalSplits() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        let sessionID = try XCTUnwrap(agent.terminalTrackingID)
        try f.pin(agent, as: "Fix checkout")

        try f.orchestrator.updateAgentWindowStatus(
            workspaceID: f.workspace.id, provider: .spaces, terminalTrackingID: sessionID, sessionKey: .clear, status: .idle)

        XCTAssertNil(try f.pins().first?.agentSessionID)
        XCTAssertNil(try f.row(agent).sessionKey)
    }

    func testAnAgentExitingInALiveTerminalLeavesTheRowExitedAndThePinNotRunning() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")

        let exited = try f.orchestrator.recordAgentExitStatus(try f.row(agent))

        XCTAssertEqual(exited?.status, .exited)
        XCTAssertEqual(exited?.effectiveLabel, agent.label)
        XCTAssertNil(try f.pins().first?.agentSessionID)
    }

    func testStoppingAPinnedAgentLeavesTheNotRunningPinAndItsBrief() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")
        try f.store.setAgentSessionBrief(id: agent.id, brief: "Where I left off", updatedAt: "2026-06-06T00:00:01Z")

        try f.orchestrator.stopCodingAgent(workspaceID: f.workspace.id, agentID: agent.id)

        XCTAssertTrue(try f.store.agentWindows(workspaceID: f.workspace.id).isEmpty)
        let pin = try XCTUnwrap(try f.pins().first)
        XCTAssertNil(pin.agentSessionID)
        XCTAssertEqual(pin.brief, "Where I left off")
    }

    func testAnExitedAgentRowDeletedWithItsTerminalLeavesTheNotRunningPin() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")
        try f.endTerminal(of: agent)

        try f.orchestrator.handleAgentExit(try f.row(agent))

        XCTAssertNil(try f.store.agentWindow(id: agent.id))
        XCTAssertNil(try f.pins().first?.agentSessionID)
    }

    // MARK: - Resume

    func testResumingANotRunningPinLaunchesTheResumeCommandAndAttachesTheNewRow() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")
        try f.endTerminal(of: agent)
        try f.store.deleteAgentWindow(id: agent.id)
        let pin = try XCTUnwrap(try f.pins().first)

        let resumption = try f.orchestrator.resumePinnedThread(workspaceID: f.workspace.id, pinID: pin.id)

        let launched = try XCTUnwrap(f.launches.snapshot().last)
        XCTAssertEqual(launched.sessionID, resumption.sessionID)
        XCTAssertTrue(launched.command?.contains("claude --resume conv-1") == true, launched.command ?? "nil")
        XCTAssertEqual(launched.launchCommand, "claude", "the recorded command stays the one the pin captured")
        XCTAssertEqual(launched.workingDirectory, pin.workingDirectory)
        let row = try XCTUnwrap(try f.store.agentWindow(workspaceID: f.workspace.id, terminalTrackingID: resumption.sessionID))
        XCTAssertEqual(try f.pins().first?.agentSessionID, row.id)
        XCTAssertEqual(row.effectiveLabel, "Fix checkout")
    }

    func testResumingARunningPinAnswersWithItsTerminalAndLaunchesNothing() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")
        let pin = try XCTUnwrap(try f.pins().first)
        let launchesBefore = f.launches.snapshot().count

        let resumption = try f.orchestrator.resumePinnedThread(workspaceID: f.workspace.id, pinID: pin.id)

        XCTAssertEqual(resumption.sessionID, agent.terminalTrackingID)
        XCTAssertNil(resumption.launchedSession)
        XCTAssertEqual(f.launches.snapshot().count, launchesBefore)
    }

    func testResumeTakesTheNameBackFromADeadRowThatStillHoldsThePin() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")
        try f.endTerminal(of: agent)
        let pin = try XCTUnwrap(try f.pins().first)

        let resumption = try f.orchestrator.resumePinnedThread(workspaceID: f.workspace.id, pinID: pin.id)

        let resumed = try XCTUnwrap(try f.store.agentWindow(workspaceID: f.workspace.id, terminalTrackingID: resumption.sessionID))
        XCTAssertNotEqual(resumed.id, agent.id)
        XCTAssertEqual(try f.pins().first?.agentSessionID, resumed.id)
        XCTAssertEqual(resumed.effectiveLabel, "Fix checkout")
        XCTAssertNotEqual(try f.row(agent).effectiveLabel, "Fix checkout", "the dead row gave the name back")
    }

    func testAStandaloneRestoreOfAPinnedConversationReattachesThePin() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")
        try f.endTerminal(of: agent)
        try f.store.deleteAgentWindow(id: agent.id)

        let session = try f.orchestrator.createWorkspaceAgentSession(
            workspaceID: f.workspace.id, command: CodingAgent.resumeCommand(launchCommand: "claude", sessionKey: "conv-1"), title: "claude",
            recordedLaunchCommand: "claude", resumedAgentSessionKey: "conv-1")

        let row = try XCTUnwrap(try f.store.agentWindow(workspaceID: f.workspace.id, terminalTrackingID: session.id))
        XCTAssertEqual(try f.pins().first?.agentSessionID, row.id)
        XCTAssertEqual(row.effectiveLabel, "Fix checkout")
    }

    func testSkippingARestoreOfferKeepsThePinnedConversationsBriefOnly() throws {
        let f = try makeFixture()
        let pinned = try f.startAgent(key: "conv-1")
        let unpinned = try f.startAgent(key: "conv-2")
        try f.pin(pinned, as: "Fix checkout")
        try f.store.setAgentSessionBrief(id: pinned.id, brief: "pinned brief", updatedAt: "2026-06-06T00:00:01Z")
        try f.store.setAgentSessionBrief(id: unpinned.id, brief: "other brief", updatedAt: "2026-06-06T00:00:01Z")
        try f.store.deleteAgentWindow(id: pinned.id)
        try f.store.deleteAgentWindow(id: unpinned.id)
        try f.store.replaceRestorableSessions(
            generation: "gen-1", capturedAt: "2026-06-06T00:00:02Z",
            captures: ["conv-1", "conv-2"].map { key in
                RestorableSessionCapture(
                    sessionID: "gone-\(key)", workspaceID: f.workspace.id, agentKind: .claude, agentSessionKey: key, launchCommand: "claude",
                    workingDirectory: f.workspace.dir, title: key)
            })

        try f.store.discardRestorableSessions(generation: "gen-1")

        XCTAssertEqual(try f.pins().first?.brief, "pinned brief")
        let remaining = try f.store.queryRows(sql: "SELECT session_key FROM agent_conversation_briefs")
        XCTAssertEqual(remaining.map { $0[0] }, ["conv-1"])
    }

    // MARK: - Names

    func testNotRunningPinsReserveTheirNameAgainstRenamesAndNewRows() throws {
        let f = try makeFixture()
        let pinned = try f.startAgent(key: "conv-1")
        let other = try f.startAgent(key: "conv-2")
        try f.pin(pinned, as: "Fix checkout")
        try f.endTerminal(of: pinned)
        try f.store.deleteAgentWindow(id: pinned.id)

        XCTAssertThrowsError(try f.orchestrator.renameAgentSession(workspaceID: f.workspace.id, agentID: other.id, title: "fix checkout"))
        XCTAssertThrowsError(try f.orchestrator.pinAgentSession(workspaceID: f.workspace.id, agentID: other.id, name: "Fix Checkout"))
        XCTAssertEqual(try f.orchestrator.uniqueAgentFocusLabel(workspaceID: f.workspace.id, preferredLabel: "Fix checkout"), "Fix checkout-2")
        XCTAssertThrowsError(
            try f.orchestrator.validateAvailableWorkspaceFocusName(workspaceID: f.workspace.id, name: "Fix checkout", excludingWindowIDs: []))
    }

    func testRenamingAPinRenamesItsRowAndRefusesTakenOrEmptyNames() throws {
        let f = try makeFixture()
        let pinned = try f.startAgent(key: "conv-1")
        let other = try f.startAgent(key: "conv-2")
        try f.pin(pinned, as: "Fix checkout")
        let pin = try XCTUnwrap(try f.pins().first)

        try f.orchestrator.renameAgentSession(workspaceID: f.workspace.id, agentID: pinned.id, title: "Fix Checkout 500")
        XCTAssertEqual(try f.pins().first?.name, "Fix Checkout 500")
        XCTAssertEqual(try f.row(pinned).effectiveLabel, "Fix Checkout 500")

        let otherName = try XCTUnwrap(other.effectiveLabel)
        XCTAssertThrowsError(try f.orchestrator.renamePinnedThread(workspaceID: f.workspace.id, pinID: pin.id, name: otherName))
        XCTAssertThrowsError(try f.orchestrator.renamePinnedThread(workspaceID: f.workspace.id, pinID: pin.id, name: "  "))
        XCTAssertThrowsError(try f.orchestrator.renameAgentSession(workspaceID: f.workspace.id, agentID: pinned.id, title: "  "))
        XCTAssertEqual(try f.pins().first?.name, "Fix Checkout 500")
        XCTAssertEqual(try f.row(pinned).effectiveLabel, "Fix Checkout 500")
    }

    func testRenamingANotRunningPinChecksOtherRowsAndPinsButNotItself() throws {
        let f = try makeFixture()
        let first = try f.startAgent(key: "conv-1")
        let second = try f.startAgent(key: "conv-2")
        try f.pin(first, as: "First")
        try f.pin(second, as: "Second")
        for agent in [first, second] { try f.endTerminal(of: agent) }
        try f.store.deleteAgentWindow(id: first.id)
        try f.store.deleteAgentWindow(id: second.id)
        let pin = try XCTUnwrap(try f.pins().first { $0.name == "First" })

        XCTAssertThrowsError(try f.orchestrator.renamePinnedThread(workspaceID: f.workspace.id, pinID: pin.id, name: "second"))
        try f.orchestrator.renamePinnedThread(workspaceID: f.workspace.id, pinID: pin.id, name: "FIRST")

        XCTAssertEqual(try f.store.pinnedThread(id: pin.id)?.name, "FIRST")
    }

    func testANewDefaultTerminalSkipsTheNameANotRunningPinHolds() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "shell-1")
        try f.endTerminal(of: agent)
        try f.store.deleteAgentWindow(id: agent.id)

        let session = try f.orchestrator.createWorkspaceTerminalSession(workspaceID: f.workspace.id, title: nil, command: nil)

        XCTAssertEqual(session.launchConfiguration?.title, "shell-2")
        try f.orchestrator.validateWorkspaceFocusNames(workspaceID: f.workspace.id)
    }

    func testPinningAShellBackedAgentUnderItsTerminalsNamesIsRefused() throws {
        let f = try makeFixture()
        let agent = try f.startShellBackedAgent()
        let sessionID = try XCTUnwrap(agent.terminalTrackingID)
        try f.orchestrator.renameAdHocBuiltInTerminalSession(workspaceID: f.workspace.id, sessionID: sessionID, title: "my shell")

        for name in ["my shell", "shell-1"] {
            XCTAssertThrowsError(try f.pin(agent, as: name), name) { error in
                guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains("used by this agent's terminal"), message)
            }
        }
        XCTAssertTrue(try f.pins().isEmpty)
        XCTAssertNil(try f.row(agent).userLabel)

        try f.pin(agent, as: "Fix checkout")
        XCTAssertEqual(try f.pins().first?.name, "Fix checkout")
    }

    func testRenamingAnAttachedPinToItsBackingShellsNameIsRefused() throws {
        let f = try makeFixture()
        let agent = try f.startShellBackedAgent()
        try f.pin(agent, as: "Fix checkout")
        let pin = try XCTUnwrap(try f.pins().first)

        XCTAssertThrowsError(try f.orchestrator.renamePinnedThread(workspaceID: f.workspace.id, pinID: pin.id, name: "shell-1"))
        XCTAssertThrowsError(try f.orchestrator.renameAgentSession(workspaceID: f.workspace.id, agentID: agent.id, title: "SHELL-1"))

        XCTAssertEqual(try f.pins().first?.name, "Fix checkout")
        XCTAssertEqual(try f.row(agent).effectiveLabel, "Fix checkout")
    }

    // MARK: - Lifecycle and storage

    func testDeletingAWorkspaceDeletesItsPins() throws {
        let f = try makeFixture()
        let agent = try f.startAgent()
        try f.pin(agent, as: "Fix checkout")

        try f.store.deleteWorkspace(id: f.workspace.id)

        XCTAssertTrue(try f.store.pinnedThreadsByWorkspace().isEmpty)
    }

    func testAVersion27ProfileMigratesAndCanPin() throws {
        let f = try makeFixture()
        let path = try DatabaseLocator.defaultPath()
        let database = try SpacesSQLiteDatabase(path: path)
        try database.execute(sql: "DROP TABLE pinned_threads")
        try database.execute(sql: "UPDATE migration_state SET current_version = 27")

        let reopened = try SQLiteStore(path: path)

        XCTAssertEqual(try database.queryRow(sql: "SELECT current_version FROM migration_state")?.first, "\(DatabaseSchema.currentVersion)")
        let orchestrator = makeTestOrchestrator(
            store: reopened,
            builtInTerminalSessionLauncher: { configuration in
                Self.persistLiveSession(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
                    launchConfiguration: configuration)
            })
        let session = try orchestrator.createWorkspaceAgentSession(
            workspaceID: f.workspace.id, command: "claude", title: nil, recordedLaunchCommand: "claude", resumedAgentSessionKey: "conv-1")
        let agent = try XCTUnwrap(try reopened.agentWindow(workspaceID: f.workspace.id, terminalTrackingID: session.id))

        try orchestrator.pinAgentSession(workspaceID: f.workspace.id, agentID: agent.id, name: "Fix checkout")

        XCTAssertEqual(try reopened.pinnedThreads(workspaceID: f.workspace.id).map(\.name), ["Fix checkout"])
    }
}
