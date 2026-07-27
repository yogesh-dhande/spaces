#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest
    import workspacecore

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// Device API server coverage for the remote orchestration surface (`spawnAgentSession`,
    /// `listAgentSessions`, `annotateAgentSession`, `killAgentSession`): the remote spawn gate, the row
    /// shape carried over the wire, note sanitization, and the injected-killer routing for remote kill.
    final class AgentOrchestrationServerTests: XCTestCase {
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

        // MARK: - Fixtures

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
                    id: "workspace-1", projectID: "project-1", dir: dir + "/ws", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
                    isRunning: false, lastLaunchedAt: nil))
            let agent = try orchestrator.registerAgentWindow(
                workspaceID: "workspace-1", provider: .spaces, label: label, terminalTrackingID: terminalSessionID, status: status)
            if let note { try store.setAgentSessionNote(id: agent.id, note: note) }
            if let signalAt {
                try store.appendAgentSessionEvent(
                    agentSessionID: agent.id, eventType: "working", source: "spaces_agent_signal", message: nil, createdAt: signalAt)
            }
            return agent
        }

        private func startServerAndClient(agentSessionKiller: (@Sendable (String) throws -> Bool)? = nil) throws -> (
            server: SpacesDeviceAPIServer, client: SpacesDeviceAPIRequestSessionClient, clientApp: SpacesDeviceClientApp, token: String
        ) {
            let identity = try agentOrchestrationTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedAgentOrchestrationPairingStore()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore, agentSessionKiller: agentSessionKiller)
            try server.start()
            let client = try SpacesDeviceAPIRequestSessionClient(
                host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
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
