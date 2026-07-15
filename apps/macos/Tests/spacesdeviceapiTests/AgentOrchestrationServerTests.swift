#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest
    import workspacecore

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// Device API server coverage for the remote orchestration surface (`spawnAgentSession`,
    /// `listAgentSessions`, `annotateAgentSession`, `terminateTerminalSession`): the remote spawn gate,
    /// the row shape carried over the wire, note sanitization, and the pre-signal remote kill.
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
                    SpacesDeviceAPIRequest(
                        command: .listAgentSessions(.init(sessionID: "agent-session")), authToken: token, clientApp: clientApp))

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

        func testTerminateTerminalSessionKillsPreSignalAgentSession() throws {
            try withTemporaryProfile { _ in
                let sessionID = try seedPreSignalAgentSession()
                let terminated = TerminatedSessionRecorder()
                let (server, client, clientApp, token) = try startServerAndClient(builtInTerminalSessionTerminator: { terminated.append($0) })
                defer {
                    client.cancel()
                    server.stop()
                }

                // The child has not signaled, so there is no agent row for stopCodingAgent to target —
                // this exercises exactly the pre-signal kill path the terminate command exists for.
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                XCTAssertTrue(try store.agentWindows(workspaceID: "workspace-1").isEmpty)

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .terminateTerminalSession(.init(sessionID: sessionID)), authToken: token, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertTrue(response.message.contains("Killed agent session"), response.message)
                // The session process was terminated and its tracked window row torn down, so the
                // refreshed overview no longer lists it.
                XCTAssertEqual(terminated.sessionIDs(), [sessionID])
                XCTAssertTrue(try store.windows(workspaceID: "workspace-1").filter { $0.terminalTrackingID == sessionID }.isEmpty)
            }
        }

        func testTerminateTerminalSessionFailsLoudlyForUnknownSession() throws {
            try withTemporaryProfile { _ in
                let (server, client, clientApp, token) = try startServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .terminateTerminalSession(.init(sessionID: "ghost-session")), authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertTrue(response.message.contains("No agent session"), response.message)
            }
        }

        // MARK: - Fixtures

        /// Creates a workspace and spawns an ad-hoc coding-agent terminal in it through a fake launcher,
        /// without emitting any hook signal — so the session has a tracked terminal window but no agent
        /// row, the pre-signal state a remote kill must handle. Returns the session id.
        private func seedPreSignalAgentSession() throws -> String {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceDir = root.appendingPathComponent("ws", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            try store.upsert(
                project: ProjectRecord(
                    id: "project-1", name: "Spaces", dir: root.path, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil,
                    ports: [], processes: [], browserSessions: []))
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: "workspace-1", projectID: "project-1", dir: workspaceDir.path, dirname: nil, branch: "feature", isDefault: false,
                    isArchived: false, isRunning: false, lastLaunchedAt: nil))
            let orchestrator = WorkspaceOrchestrator(
                store: store,
                builtInTerminalSessionLauncher: { configuration in
                    TerminalServiceSessionSummary(
                        id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                        backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                        controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
                        launchConfiguration: configuration)
                })
            return try orchestrator.createWorkspaceAgentSession(workspaceID: "workspace-1", command: "claude", title: "Reviewer").id
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
                    id: "workspace-1", projectID: "project-1", dir: dir + "/ws", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
                    isRunning: false, lastLaunchedAt: nil))
            let agent = try orchestrator.registerAgentWindow(
                workspaceID: "workspace-1", provider: .spaces, label: label, terminalTrackingID: terminalSessionID, status: status)
            if let note { try store.setAgentSessionNote(id: agent.id, note: note, updatedAt: "2026-07-14T00:00:00Z") }
            if let signalAt {
                try store.appendAgentSessionEvent(
                    agentSessionID: agent.id, eventType: "working", source: "spaces_agent_signal", message: nil, createdAt: signalAt)
            }
            return agent
        }

        private func startServerAndClient(
            builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil
        ) throws -> (
            server: SpacesDeviceAPIServer, client: SpacesDeviceAPIRequestSessionClient, clientApp: SpacesDeviceClientApp, token: String
        ) {
            let identity = try agentOrchestrationTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedAgentOrchestrationPairingStore()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                builtInTerminalSessionTerminator: builtInTerminalSessionTerminator)
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

    /// Records the session ids the server's terminator closure is invoked with. The closure is
    /// `@Sendable` and runs on the server queue, so access is lock-guarded.
    private final class TerminatedSessionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []

        func append(_ sessionID: String) {
            lock.lock()
            defer { lock.unlock() }
            ids.append(sessionID)
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
