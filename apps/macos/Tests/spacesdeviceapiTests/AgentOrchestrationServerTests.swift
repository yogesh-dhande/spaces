#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest
    import workspacecore

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// Device API server coverage for the remote orchestration surface (`spawnAgentSession`,
    /// `listAgentSessions`, `annotateAgentSession`, `renameAgentSession`, `killAgentSession`): the remote
    /// spawn gate, the row shape carried over the wire, note sanitization, how a renamed row is named
    /// across overview builds, and the injected-killer routing for remote kill.
    final class AgentOrchestrationServerTests: XCTestCase {
        /// Editor's Start Agent dialog accepts a command rather than a preset coding-agent kind. The
        /// daemon therefore creates an ordinary workspace terminal and lets the foreground reconciler
        /// promote it if the command actually runs a supported coding agent. This keeps arbitrary
        /// commands useful while avoiding a client-side guess about what executable will run.
        func testStartWorkspaceCommandSessionAcceptsArbitraryCommandAndUsesInteractiveLoginShell() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace()
                let launches = TerminalLaunchRecorder()
                let (server, client, clientApp, token) = try startServerAndClient(
                    builtInTerminalSessionLauncher: { configuration in launches.launch(configuration) })
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .startWorkspaceCommandSession(.init(workspaceID: "workspace-1", command: "my-agent --review")),
                        authToken: token, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let configurations = launches.configurations()
                XCTAssertEqual(configurations.count, 1)
                let launch = try XCTUnwrap(configurations.first)
                XCTAssertEqual(launch.workspaceID, "workspace-1")
                XCTAssertEqual(launch.kind, .shell)
                XCTAssertTrue(launch.command?.contains("my-agent --review") == true)
                XCTAssertTrue(launch.command?.contains(" -l -i -c ") == true)
                XCTAssertEqual(response.sessionID, launch.sessionID)
            }
        }

        func testStartingWorkspaceCommandDoesNotBlockAnUnrelatedOverview() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace()
                let launches = TerminalLaunchRecorder()
                let launchArrived = DispatchSemaphore(value: 0)
                let releaseLaunch = DispatchSemaphore(value: 0)
                let (server, client, clientApp, token) = try startServerAndClient(
                    builtInTerminalSessionLauncher: { configuration in
                        launchArrived.signal()
                        releaseLaunch.wait()
                        return launches.launch(configuration)
                    })
                defer {
                    releaseLaunch.signal()
                    client.cancel()
                    server.stop()
                }

                let startFinished = expectation(description: "The blocked workspace command eventually returns.")
                DispatchQueue.global().async {
                    _ = try? client.send(
                        SpacesDeviceAPIRequest(
                            command: .startWorkspaceCommandSession(.init(workspaceID: "workspace-1", command: "my-agent --review")),
                            authToken: token, clientApp: clientApp))
                    startFinished.fulfill()
                }
                XCTAssertEqual(launchArrived.wait(timeout: .now() + 5), .success, "The terminal launcher must be reached.")

                let overviewClient = try SpacesDeviceAPIRequestClient(
                    resolver: SpacesDeviceEndpointResolver(
                        hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: server.certificateFingerprint),
                    timeoutSeconds: 2)
                let startedAt = Date()
                let overview = try overviewClient.request(
                    SpacesDeviceAPIRequest(command: .overview, authToken: token, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(overview.ok, overview.message)
                XCTAssertLessThan(elapsed, 1.5, "An overview must not wait behind a terminal launch.")
                releaseLaunch.signal()
                wait(for: [startFinished], timeout: 10)
            }
        }

        func testStartWorkspaceCommandSessionRejectsBlankCommandBeforeLaunching() throws {
            try withTemporaryProfile { _ in
                let launches = TerminalLaunchRecorder()
                let (server, client, clientApp, token) = try startServerAndClient(
                    builtInTerminalSessionLauncher: { configuration in launches.launch(configuration) })
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .startWorkspaceCommandSession(.init(workspaceID: "workspace-1", command: " \n\t ")),
                        authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertEqual(response.message, "command is required.")
                XCTAssertTrue(launches.configurations().isEmpty)
            }
        }

        func testSpawnAgentSessionRejectsUnsupportedCommandWithoutTouchingWorkspace() throws {
            try withTemporaryProfile { _ in
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                // "ls" is not a supported coding agent, so the same gate as the local spawn rejects it
                // before any session is created — no seeded workspace needed.
                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .spawnAgentSession(.init(workspaceID: "workspace-1", command: "ls -la")), authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertTrue(response.message.contains("supported coding agent"), response.message)
            }
        }

        func testListAgentSessionsCarriesNoteAndReadinessOverTheWire() throws {
            try withTemporaryProfile { _ in
                let agent = try seedAgentSession(
                    terminalSessionID: "agent-session", label: "Claude Code CLI", status: .waiting, note: "review auth",
                    signalAt: "2026-07-14T10:00:00Z")
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(command: .listAgentSessions(.init(sessionID: "agent-session")), authToken: token, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let row = try XCTUnwrap(response.agentSessions?.first)
                XCTAssertEqual(row.id, agent.id)
                XCTAssertEqual(row.terminalSessionID, "agent-session")
                XCTAssertEqual(row.status, "waiting")
                XCTAssertEqual(row.note, "review auth")
                XCTAssertEqual(row.lastSignalAt, "2026-07-14T10:00:00Z")
            }
        }

        func testAnnotateAgentSessionSanitizesNoteOverTheWire() throws {
            try withTemporaryProfile { _ in
                _ = try seedAgentSession(terminalSessionID: "agent-session", label: "Claude Code CLI", status: .idle, note: nil, signalAt: nil)
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .annotateAgentSession(.init(sessionID: "agent-session", note: "line one\nline two\u{07}")), authToken: token,
                        clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertEqual(response.agentSessions?.first?.note, "line oneline two")
                // The sanitized note is persisted, not just echoed.
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                XCTAssertEqual(try store.agentWindows(workspaceID: "workspace-1").first?.note, "line oneline two")
            }
        }

        /// A `killAgentSession` request invokes the injected killer (the daemon's notify-then-stop
        /// `killAgentSession` flow) with the child session id and, on a true return, reports success. The
        /// server does not re-implement the kill; the notify-before-delete ordering it depends on is
        /// covered at the orchestrator level by AgentNotificationEngineTests.
        func testKillAgentSessionInvokesKillerAndReportsSuccess() throws {
            try withTemporaryProfile { _ in
                let killer = AgentSessionKillerRecorder(result: true)
                let (server, client, clientApp, token) = try startServerAndClient(agentSessionKiller: { killer.record($0) })
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(command: .killAgentSession(.init(sessionID: "child-session")), authToken: token, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertTrue(response.message.contains("Killed agent session"), response.message)
                XCTAssertEqual(killer.sessionIDs(), ["child-session"])
            }
        }

        /// Before the first hook signal, a spawned agent still appears as a workspace terminal row. Its
        /// run may already be finished (the agent prompt completed) while its terminal remains live. Stop
        /// must proceed through agent teardown rather than treating the run's no-op cancellation as done.
        func testStopWorkspaceTerminalStopsLiveAgentAfterItsAutomationRunFinished() throws {
            try withTemporaryProfile { _ in
                let run = try seedPreSignalAgentTerminal(terminalSessionID: "automation-agent-session", runStatus: .succeeded)
                let killer = AgentSessionKillerRecorder(result: true)
                let canceller = AutomationRunCancelRecorder(result: run)
                let (server, client, clientApp, token) = try startServerAndClient(
                    agentSessionKiller: { killer.record($0) }, automationOperations: automationOperations(cancelRun: { canceller.record($0) }))
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .stopWorkspaceTerminal(.init(workspaceID: "workspace-1", sessionID: "automation-agent-session")), authToken: token,
                        clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertTrue(response.message.contains("Stopped workspace terminal"), response.message)
                XCTAssertEqual(killer.sessionIDs(), ["automation-agent-session"])
                XCTAssertEqual(canceller.runIDs(), [run.id])
            }
        }

        /// A configured process can be recognized as an agent after its hook arrives. Its launch kind is
        /// still `.process`, so terminal Stop must recognize the persisted agent row before it applies the
        /// pre-signal `.agent` launch-kind gate.
        func testStopWorkspaceTerminalStopsHookRegisteredConfiguredProcessAgent() throws {
            try withTemporaryProfile { _ in
                _ = try seedAgentSession(
                    terminalSessionID: "configured-process-agent-session", label: "Codex", status: .spinning, note: nil, signalAt: nil)
                let killer = AgentSessionKillerRecorder(result: true)
                let (server, client, clientApp, token) = try startServerAndClient(agentSessionKiller: { killer.record($0) })
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .stopWorkspaceTerminal(.init(workspaceID: "workspace-1", sessionID: "configured-process-agent-session")),
                        authToken: token, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertTrue(response.message.contains("Stopped workspace terminal"), response.message)
                XCTAssertEqual(killer.sessionIDs(), ["configured-process-agent-session"])
            }
        }

        /// The row may read `running` just before the service serializes cancellation, then complete before
        /// cancellation obtains queue ownership. A terminal result from cancellation means Stop still has to
        /// reach the live agent session rather than returning as though it canceled work.
        func testStopWorkspaceTerminalContinuesToAgentKillerWhenActiveRunCompletesBeforeCancellation() throws {
            try withTemporaryProfile { _ in
                let running = try seedPreSignalAgentTerminal(terminalSessionID: "automation-agent-session", runStatus: .running)
                let completed = AutomationRun(
                    id: running.id, automationID: running.automationID, kind: running.kind, status: .succeeded, skipReason: nil,
                    trigger: running.trigger, exitCode: nil, terminalSessionID: running.terminalSessionID, startedAt: running.startedAt,
                    endedAt: Date(), createdAt: running.createdAt, promptDeliveredAt: running.promptDeliveredAt)
                let killer = AgentSessionKillerRecorder(result: true)
                let canceller = AutomationRunCancelRecorder(result: completed)
                let (server, client, clientApp, token) = try startServerAndClient(
                    agentSessionKiller: { killer.record($0) }, automationOperations: automationOperations(cancelRun: { canceller.record($0) }))
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .stopWorkspaceTerminal(.init(workspaceID: "workspace-1", sessionID: "automation-agent-session")), authToken: token,
                        clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertTrue(response.message.contains("Stopped workspace terminal"), response.message)
                XCTAssertEqual(canceller.runIDs(), [running.id])
                XCTAssertEqual(killer.sessionIDs(), ["automation-agent-session"])
            }
        }

        /// A live automation command owns the Stop action itself. Cancelling the run records cancellation
        /// and returns without also terminating a session that the automation service is already stopping.
        func testStopWorkspaceTerminalCancelsActiveAutomationRunWithoutKillingItsSessionAgain() throws {
            try withTemporaryProfile { _ in
                let run = try seedPreSignalAgentTerminal(terminalSessionID: "automation-agent-session", runStatus: .running)
                let killer = AgentSessionKillerRecorder(result: true)
                let canceled = AutomationRun(
                    id: run.id, automationID: run.automationID, kind: run.kind, status: .canceled, skipReason: nil, trigger: run.trigger,
                    exitCode: nil, terminalSessionID: run.terminalSessionID, startedAt: run.startedAt, endedAt: Date(), createdAt: run.createdAt,
                    promptDeliveredAt: run.promptDeliveredAt)
                let canceller = AutomationRunCancelRecorder(result: canceled)
                let (server, client, clientApp, token) = try startServerAndClient(
                    agentSessionKiller: { killer.record($0) }, automationOperations: automationOperations(cancelRun: { canceller.record($0) }))
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .stopWorkspaceTerminal(.init(workspaceID: "workspace-1", sessionID: "automation-agent-session")), authToken: token,
                        clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertTrue(response.message.contains("Canceled automation run"), response.message)
                XCTAssertEqual(canceller.runIDs(), [run.id])
                XCTAssertTrue(killer.sessionIDs().isEmpty)
            }
        }

        /// A false return from the killer means the id names no agent session — the same loud
        /// invalidArgument the local `.agentKill` path raises.
        func testKillAgentSessionFailsLoudlyWhenKillerReportsNoSession() throws {
            try withTemporaryProfile { _ in
                let killer = AgentSessionKillerRecorder(result: false)
                let (server, client, clientApp, token) = try startServerAndClient(agentSessionKiller: { killer.record($0) })
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(command: .killAgentSession(.init(sessionID: "ghost-session")), authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertTrue(response.message.contains("No agent session"), response.message)
                XCTAssertEqual(killer.sessionIDs(), ["ghost-session"])
            }
        }

        /// With no killer wired (a misconfigured daemon), the endpoint reports itself unavailable rather
        /// than silently succeeding.
        func testKillAgentSessionReportsUnavailableWhenNoKillerWired() throws {
            try withTemporaryProfile { _ in
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(command: .killAgentSession(.init(sessionID: "child-session")), authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .internalError)
                XCTAssertTrue(response.message.contains("unavailable"), response.message)
            }
        }

        /// Sending input is a keystroke, not a lifecycle event: it records no agent status transition.
        /// ESC (byte 27) is the case that tempts an exception, because it is what an orchestrator sends
        /// when it wants a child to stop — but ESC means whatever the child's TUI decides in its current
        /// state (with a nested panel open it dismisses the panel and the agent keeps working), and Spaces
        /// cannot see that state. So a delivered keystroke leaves the row exactly as the agent's own
        /// signals left it, and only `agent signal` moves status.
        func testSendingEscapeToASpinningAgentLeavesItsStatusUntouched() throws {
            try withTemporaryProfile { _ in
                let sessionID = "agent-session"
                let agent = try seedAgentSession(
                    terminalSessionID: sessionID, label: "Claude Code CLI", status: .spinning, note: nil, signalAt: "2026-07-14T10:00:00Z")

                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()
                let recorder = AgentOrchestrationTerminalControlRecorder()
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.agent.orchestration.send")
                ) { request in
                    recorder.record(request)
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer { controlServer.stop() }

                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .sendTerminalInput(.init(sessionID: sessionID, bytes: Data([27]))), authToken: token, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                // The ESC byte really reached the terminal, so the unchanged row below is the invariant
                // holding rather than a send that quietly did nothing.
                XCTAssertEqual(recorder.requests().map(\.bytes), [Data([27])])

                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let reread = try XCTUnwrap(store.agentWindow(id: agent.id))
                XCTAssertEqual(reread.status, .spinning)
                // Any lifecycle write rewrites the row, so an unchanged `updatedAt` also rules out a
                // status-preserving rewrite.
                XCTAssertEqual(reread.updatedAt, agent.updatedAt)
                XCTAssertEqual(try store.lastAgentSignalAt(agentSessionID: agent.id), "2026-07-14T10:00:00Z")
                XCTAssertFalse(try store.agentSessionHasRecordedExitEvent(agentSessionID: agent.id))
            }
        }

        /// Renaming a coding agent names its row, and the name survives a fresh overview build because it
        /// is stored on the agent session rather than echoed back in the mutation's overview.
        func testRenamingAnAgentNamesItsRowAndPersists() throws {
            try withTemporaryProfile { _ in
                let agent = try seedAgentSession(
                    terminalSessionID: "agent-session", label: "Claude Code CLI", status: .idle, note: nil, signalAt: nil)
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .renameAgentSession(.init(workspaceID: "workspace-1", agentID: agent.id, title: "  Reviewer  ")), authToken: token,
                        clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertEqual(codingAgentRowNames(response), ["Reviewer"])
                XCTAssertEqual(
                    codingAgentRowNames(try client.send(SpacesDeviceAPIRequest(command: .overview, authToken: token, clientApp: clientApp))),
                    ["Reviewer"])
            }
        }

        /// The agent keeps signaling after the user renames its row, and every signal rewrites the label
        /// the row used to be named from. The rename lives in its own column, so the row keeps the name
        /// the user gave it while the runtime label underneath it moves on.
        func testAgentSignalWithANewLabelLeavesTheUserRenameStanding() throws {
            try withTemporaryProfile { _ in
                let agent = try seedAgentSession(
                    terminalSessionID: "agent-session", label: "Claude Code CLI", status: .idle, note: nil, signalAt: nil)
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }
                let renamed = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .renameAgentSession(.init(workspaceID: "workspace-1", agentID: agent.id, title: "Reviewer")), authToken: token,
                        clientApp: clientApp))
                XCTAssertTrue(renamed.ok, renamed.message)

                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                try WorkspaceOrchestrator(store: store).updateAgentWindowStatus(
                    workspaceID: "workspace-1", provider: .spaces, terminalTrackingID: "agent-session", label: "Codex CLI", status: .spinning)

                // The signal really did move the runtime label, so the unchanged row name below is the
                // separation holding rather than a write that quietly did nothing.
                XCTAssertEqual(try store.agentWindow(id: agent.id)?.label, "Codex CLI")
                XCTAssertEqual(
                    codingAgentRowNames(try client.send(SpacesDeviceAPIRequest(command: .overview, authToken: token, clientApp: clientApp))),
                    ["Reviewer"])
            }
        }

        /// Clearing the rename is the only way back from one, so an empty title clears it instead of being
        /// rejected, handing the row back to the label the agent reports for itself.
        func testEmptyTitleClearsAnAgentRenameBackToItsReportedLabel() throws {
            try withTemporaryProfile { _ in
                let agent = try seedAgentSession(
                    terminalSessionID: "agent-session", label: "Claude Code CLI", status: .idle, note: nil, signalAt: nil)
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }
                _ = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .renameAgentSession(.init(workspaceID: "workspace-1", agentID: agent.id, title: "Reviewer")), authToken: token,
                        clientApp: clientApp))

                let cleared = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .renameAgentSession(.init(workspaceID: "workspace-1", agentID: agent.id, title: "   ")), authToken: token,
                        clientApp: clientApp))

                XCTAssertTrue(cleared.ok, cleared.message)
                XCTAssertEqual(codingAgentRowNames(cleared), ["Claude Code CLI"])
            }
        }

        /// An id that names no agent session in the workspace is a loud error: a silent success would let a
        /// client believe a rename it can never see took effect.
        func testRenamingAnUnknownAgentFailsLoudly() throws {
            try withTemporaryProfile { _ in
                _ = try seedAgentSession(terminalSessionID: "agent-session", label: "Claude Code CLI", status: .idle, note: nil, signalAt: nil)
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .renameAgentSession(.init(workspaceID: "workspace-1", agentID: "ghost-agent", title: "Reviewer")), authToken: token,
                        clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertEqual(
                    codingAgentRowNames(try client.send(SpacesDeviceAPIRequest(command: .overview, authToken: token, clientApp: clientApp))),
                    ["Claude Code CLI"])
            }
        }

        /// Stop is the only lifecycle control a coding agent has, and it addresses the row by its agent
        /// session id: a hook-registered live agent stops, and its row leaves the overview.
        func testStoppingAHookRegisteredAgentRemovesItsRow() throws {
            try withTemporaryProfile { _ in
                let agent = try seedAgentSession(
                    terminalSessionID: "agent-session", label: "Claude Code CLI", status: .spinning, note: nil, signalAt: "2026-07-14T10:00:00Z")
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .stopCodingAgent(.init(workspaceID: "workspace-1", agentID: agent.id)), authToken: token, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertEqual(codingAgentRowNames(response), [])
                XCTAssertNil(try SQLiteStore(path: DatabaseLocator.defaultPath()).agentWindow(id: agent.id))
            }
        }

        // MARK: - Fixtures

        /// The names the seeded workspace's coding-agent rows carry in a response's overview — what every
        /// client renders for those rows.
        private func codingAgentRowNames(_ response: SpacesDeviceAPIResponse) -> [String] {
            response.overview?.workspaces.first(where: { $0.id == "workspace-1" })?.codingAgentRows.map(\.name) ?? []
        }

        @discardableResult private func seedAgentSession(
            terminalSessionID: String, label: String, status: AgentWindowStatus, note: String?, signalAt: String?
        ) throws -> AgentWindowRecord {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            let orchestrator = WorkspaceOrchestrator(store: store)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            try store.upsert(
                project: ProjectRecord(
                    id: "project-1", name: "Spaces", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [],
                    processes: [], browserSessions: []))
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: "workspace-1", projectID: "project-1", dir: dir + "/ws", dirname: nil, branch: "feature", isDefault: false, isRunning: false,
                    lastLaunchedAt: nil))
            let agent = try orchestrator.registerAgentWindow(
                workspaceID: "workspace-1", provider: .spaces, label: label, terminalTrackingID: terminalSessionID, status: status)
            if let note { try store.setAgentSessionNote(id: agent.id, note: note) }
            if let signalAt {
                try store.appendAgentSessionEvent(
                    agentSessionID: agent.id, eventType: "working", source: "spaces_agent_signal", message: nil, createdAt: signalAt)
            }
            return agent
        }

        private func seedWorkspace() throws {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            try store.upsert(
                project: ProjectRecord(
                    id: "project-1", name: "Spaces", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [],
                    processes: [], browserSessions: []))
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: "workspace-1", projectID: "project-1", dir: dir + "/ws", dirname: nil, branch: "feature", isDefault: false,
                    isRunning: false, lastLaunchedAt: nil))
        }

        @discardableResult private func seedPreSignalAgentTerminal(terminalSessionID: String, runStatus: AutomationRunStatus) throws -> AutomationRun
        {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            try store.upsert(
                project: ProjectRecord(
                    id: "project-1", name: "Spaces", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [],
                    processes: [], browserSessions: []))
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: "workspace-1", projectID: "project-1", dir: dir + "/ws", dirname: nil, branch: "feature", isDefault: false, isRunning: true,
                    lastLaunchedAt: nil))
            try store.upsert(
                window: WindowRecord(
                    id: "window-1", workspaceID: "workspace-1", app: TerminalHost.spaces.appName, name: "Automation agent", detail: nil,
                    targetURL: nil, terminalTrackingID: terminalSessionID, role: "terminal", orderIndex: 200, lastSeenAt: "2026-08-12T00:00:00Z"))
            let automation = Automation(
                id: "automation-1", name: "Automation agent", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .agent, script: "",
                agentCommand: "codex", agentPrompt: "Inspect the project", workspaceID: "workspace-1", timeoutSeconds: nil, concurrencyPolicy: .allow,
                missedRunPolicy: .runOnce, nextFireTime: nil, createdAt: Date(), updatedAt: Date())
            try store.upsertAutomation(automation)
            let run = AutomationRun(
                id: "run-1", automationID: automation.id, kind: .agent, status: runStatus, skipReason: nil, trigger: .manual, exitCode: nil,
                terminalSessionID: terminalSessionID, startedAt: Date(), endedAt: runStatus.isTerminal ? Date() : nil, createdAt: Date())
            try store.insertAutomationRun(run)
            let paths = try TerminalSessionPaths.forSession(id: terminalSessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: terminalSessionID, title: "Automation agent", workingDirectory: dir + "/ws", shell: "/bin/zsh", command: "codex",
                    createdAt: "2026-08-12T00:00:00Z", workspaceID: "workspace-1", kind: .agent, automationRunID: "run-1"), paths: paths)
            return run
        }

        private func automationOperations(cancelRun: @escaping @Sendable (String) throws -> AutomationRun) -> AutomationOperations {
            AutomationOperations(
                create: { _ in throw AutomationValidationError("unused test operation") },
                update: { _, _ in throw AutomationValidationError("unused test operation") },
                setNextRun: { _, _ in throw AutomationValidationError("unused test operation") }, delete: { _ in }, list: { [] }, runs: { _ in [] },
                trigger: { _ in throw AutomationValidationError("unused test operation") }, cancelRun: cancelRun,
                endAgents: { _ in throw AutomationValidationError("unused test operation") })
        }

        private func startServerAndClient(
            agentSessionKiller: (@Sendable (String) throws -> Bool)? = nil, automationOperations: AutomationOperations? = nil,
            builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil
        ) throws -> (server: SpacesDeviceAPIServer, client: SpacesDeviceAPIRequestSessionClient, clientApp: SpacesDeviceClientApp, token: String) {
            let identity = try agentOrchestrationTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedAgentOrchestrationPairingStore()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                builtInTerminalSessionLauncher: builtInTerminalSessionLauncher, agentSessionKiller: agentSessionKiller, automationOperations: automationOperations)
            try server.start()
            let client = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
            let clientApp = SpacesDeviceClientApp(
                installationID: "agent-orchestration-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0")
            return (server, client, clientApp, pairingStore.authToken)
        }

        private func withTemporaryProfile(_ body: (URL) throws -> Void) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
            let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
            setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
            unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            defer {
                if let originalDatabasePath {
                    setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
                } else {
                    unsetenv(SpacesProfile.databasePathEnvironmentVariable)
                }
                if let originalRuntimePath {
                    setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, originalRuntimePath, 1)
                } else {
                    unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
                }
                try? FileManager.default.removeItem(at: root)
            }
            try body(root)
        }

        private let agentOrchestrationTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-agent-orchestration-tests-tls-\(UUID().uuidString)", isDirectory: true)

        private func agentOrchestrationTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
            try TerminalServiceTLSIdentityStore.loadOrCreate(root: agentOrchestrationTestTLSRoot)
        }
    }

    private final class TerminalLaunchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedConfigurations: [TerminalSessionLaunchConfiguration] = []

        func launch(_ configuration: TerminalSessionLaunchConfiguration) -> TerminalServiceSessionSummary {
            lock.lock()
            storedConfigurations.append(configuration)
            lock.unlock()
            return TerminalServiceSessionSummary(
                id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
                launchConfiguration: configuration)
        }

        func configurations() -> [TerminalSessionLaunchConfiguration] {
            lock.lock()
            defer { lock.unlock() }
            return storedConfigurations
        }
    }

    /// Records the control requests a stand-in terminal session receives. The control server dispatches
    /// on its own queue, so access is lock-guarded.
    private final class AgentOrchestrationTerminalControlRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedRequests: [TerminalControlRequest] = []

        func record(_ request: TerminalControlRequest) {
            lock.lock()
            storedRequests.append(request)
            lock.unlock()
        }

        func requests() -> [TerminalControlRequest] {
            lock.lock()
            defer { lock.unlock() }
            return storedRequests
        }
    }

    /// Records the session ids the server's injected agent-session killer is invoked with and returns a
    /// fixed result, standing in for the daemon's notify-then-stop `killAgentSession` flow. The closure is
    /// `@Sendable` and runs on the server queue, so access is lock-guarded.
    private final class AgentSessionKillerRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        private let result: Bool

        init(result: Bool) { self.result = result }

        func record(_ sessionID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            ids.append(sessionID)
            return result
        }

        func sessionIDs() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    private final class AutomationRunCancelRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        private let result: AutomationRun

        init(result: AutomationRun) { self.result = result }

        func record(_ runID: String) -> AutomationRun {
            lock.lock()
            defer { lock.unlock() }
            ids.append(runID)
            return result
        }

        func runIDs() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    private final class AlwaysAuthorizedAgentOrchestrationPairingStore: SpacesDevicePairingStoreProtocol {
        let authToken = "valid-token"

        func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
        func listDevices() throws -> [SpacesDevicePairedClient] { [] }
        func revoke(installationID _: String) throws {}
        func removeAll() throws {}
        func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
            guard clientApp != nil, authToken == self.authToken else {
                throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
            }
        }
        func validate(clientApp _: SpacesDeviceClientApp) throws {}
    }
#endif
