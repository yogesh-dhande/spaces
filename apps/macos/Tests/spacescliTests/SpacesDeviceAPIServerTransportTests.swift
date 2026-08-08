import Darwin
import Foundation
import Network
import XCTest
import spacesterminalcore

@testable import spacesdeviceapi
@testable import spacesdevicecore
@testable import workspacecore

final class SpacesDeviceAPIServerTransportTests: XCTestCase {
    /// Deleting a workspace can be asked to delete its branches, and the notice the daemon computes for that
    /// is failure-only: a branch deleted cleanly, as asked here, carries no notice on the response at all,
    /// rather than a fixed "Deleted workspace." report the client would have to show regardless.
    func testDeleteWorkspaceCarriesBranchDeletionOutcomeToTheClient() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }

            // A real repository with a real branch checked out in a real worktree: the delete has to remove
            // the worktree and the branch for its report to mean anything.
            let projectDir = root.appendingPathComponent("delete-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try runDeviceAPITestGit(["init", "-b", "main"], cwd: projectDir.path)
            try "hello".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runDeviceAPITestGit(["add", "README.md"], cwd: projectDir.path)
            try runDeviceAPITestGit(
                ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: projectDir.path)
            let worktreeDir = root.appendingPathComponent("delete-worktree", isDirectory: true)
            try runDeviceAPITestGit(["worktree", "add", "-b", "feature-report", worktreeDir.path], cwd: projectDir.path)

            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(id: "project-delete", name: "Delete Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main")
            let workspace = WorkspaceRecord(
                id: "workspace-delete", projectID: project.id, dir: worktreeDir.path, dirname: "delete-worktree", branch: "feature-report",
                baseBranch: "main", isDefault: false, isRunning: false, lastLaunchedAt: nil)
            try store.upsert(project: project)
            try store.upsert(workspace: workspace)

            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-WORKSPACE-DELETE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .archiveWorkspace(.init(workspaceID: workspace.id, deleteLocalBranch: true, deleteRemoteBranch: false)),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            XCTAssertNil(response.mutationNotice, "branch deletion going as asked carries no notice")
            XCTAssertNil(try store.workspace(id: workspace.id), "the workspace record is gone")
            XCTAssertFalse(GitClient().branchExists(path: projectDir.path, branch: "feature-report"))
        }
    }

    /// A delete that was not asked to touch any branch has nothing extra to report, so it carries no notice
    /// and the client stays silent instead of showing an empty report.
    func testDeleteWorkspaceWithoutBranchDeletionCarriesNoNotice() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }

            let projectDir = root.appendingPathComponent("quiet-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try runDeviceAPITestGit(["init", "-b", "main"], cwd: projectDir.path)
            try "hello".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runDeviceAPITestGit(["add", "README.md"], cwd: projectDir.path)
            try runDeviceAPITestGit(
                ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: projectDir.path)
            let worktreeDir = root.appendingPathComponent("quiet-worktree", isDirectory: true)
            try runDeviceAPITestGit(["worktree", "add", "-b", "feature-quiet", worktreeDir.path], cwd: projectDir.path)

            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(id: "project-quiet", name: "Quiet Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main")
            try store.upsert(project: project)
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: "workspace-quiet", projectID: project.id, dir: worktreeDir.path, dirname: "quiet-worktree", branch: "feature-quiet",
                    baseBranch: "main", isDefault: false, isRunning: false, lastLaunchedAt: nil))

            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-WORKSPACE-DELETE-QUIET", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .archiveWorkspace(.init(workspaceID: "workspace-quiet", deleteLocalBranch: false, deleteRemoteBranch: false)),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            XCTAssertNil(response.mutationNotice)
            XCTAssertNil(try store.workspace(id: "workspace-quiet"))
            XCTAssertTrue(GitClient().branchExists(path: projectDir.path, branch: "feature-quiet"), "an untouched branch survives the delete")
        }
    }

    /// Deleting a workspace stops its terminals, removes its git worktree, and can delete its branches —
    /// seconds of work. Every other client keeps polling the overview throughout, so the delete must not
    /// hold the Device API request queue: when it did, those polls waited for the whole delete and the
    /// phone showed a connection error exactly as the deleted workspace disappeared.
    func testDeletingAWorkspaceDoesNotBlockOverviewRequestsFromOtherConnections() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let teardownStarted = DispatchSemaphore(value: 0)
            let releaseTeardown = DispatchSemaphore(value: 0)
            let deleteFinished = DispatchSemaphore(value: 0)
            let deleteResult = DeviceAPITransportTestResultBox()
            // The workspace's terminal is terminated partway through the delete, so blocking the terminator
            // holds a real delete open for as long as the test needs without depending on timing.
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                builtInTerminalSessionTerminator: { _ in
                    teardownStarted.signal()
                    releaseTeardown.wait()
                })
            try server.start()
            defer { server.stop() }

            let projectDir = root.appendingPathComponent("busy-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try runDeviceAPITestGit(["init", "-b", "main"], cwd: projectDir.path)
            try "hello".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runDeviceAPITestGit(["add", "README.md"], cwd: projectDir.path)
            try runDeviceAPITestGit(
                ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: projectDir.path)
            let worktreeDir = root.appendingPathComponent("busy-worktree", isDirectory: true)
            try runDeviceAPITestGit(["worktree", "add", "-b", "feature-busy", worktreeDir.path], cwd: projectDir.path)

            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(id: "project-busy", name: "Busy Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main")
            try store.upsert(project: project)
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: "workspace-busy", projectID: project.id, dir: worktreeDir.path, dirname: "busy-worktree", branch: "feature-busy",
                    baseBranch: "main", isDefault: false, isRunning: true, lastLaunchedAt: nil))
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: "process-busy", workspaceID: "workspace-busy", templateName: "api", command: "npm start",
                    terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "session-busy", pid: nil, status: .running, logPath: nil,
                    lastOutputAt: nil, startedAt: nil, exitedAt: nil))

            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-DELETE-QUEUE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let deleteRequest = SpacesDeviceAPIRequest(
                command: .archiveWorkspace(.init(workspaceID: "workspace-busy", deleteLocalBranch: true, deleteRemoteBranch: false)),
                authToken: pairingStore.authToken, clientApp: clientApp)

            DispatchQueue.global(qos: .userInitiated).async {
                defer { deleteFinished.signal() }
                do {
                    let client = try SpacesDeviceAPIRequestClient(
                        resolver: SpacesDeviceEndpointResolver(
                            hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
                    deleteResult.setResponseData(try SpacesDeviceAPICodec.encodeResponse(try client.request(deleteRequest)))
                } catch { deleteResult.setError(error) }
            }

            XCTAssertEqual(teardownStarted.wait(timeout: .now() + 15), .success, "the delete must reach the workspace teardown")
            defer { releaseTeardown.signal() }

            // The refresh poll a client issues on its own connection while the delete is still running.
            let pollClient = try SpacesDeviceAPIRequestClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint), timeoutSeconds: 5)
            let overview = try pollClient.request(SpacesDeviceAPIRequest(command: .overview, authToken: pairingStore.authToken, clientApp: clientApp))
            XCTAssertTrue(overview.ok, overview.message)

            releaseTeardown.signal()
            XCTAssertEqual(deleteFinished.wait(timeout: .now() + 30), .success)
            if let error = deleteResult.error() { throw error }
            // Moving the work off the request queue must not change what the client gets back: one
            // synchronous response, with the branch deleted as asked and so no notice attached.
            let deleteResponse = try SpacesDeviceAPICodec.decodeResponse(deleteResult.responseData())
            XCTAssertTrue(deleteResponse.ok, deleteResponse.message)
            XCTAssertNil(deleteResponse.mutationNotice, "branch deletion going as asked carries no notice")
            XCTAssertNil(try store.workspace(id: "workspace-busy"))
        }
    }

    /// A client whose delete response was lost probes the overview to learn what happened, and a workspace
    /// still listed means two very different things: the delete failed, or a slow stop script is still
    /// running and the daemon is about to remove it. Only the daemon knows which, so it reports the
    /// workspaces it is currently tearing down — and stops reporting one the moment its teardown ends.
    func testOverviewReportsAWorkspaceAsTearingDownOnlyWhileItsDeleteIsRunning() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let teardownStarted = DispatchSemaphore(value: 0)
            let releaseTeardown = DispatchSemaphore(value: 0)
            let deleteFinished = DispatchSemaphore(value: 0)
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                builtInTerminalSessionTerminator: { _ in
                    teardownStarted.signal()
                    releaseTeardown.wait()
                })
            try server.start()
            defer { server.stop() }

            let projectDir = root.appendingPathComponent("teardown-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try runDeviceAPITestGit(["init", "-b", "main"], cwd: projectDir.path)
            try "hello".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runDeviceAPITestGit(["add", "README.md"], cwd: projectDir.path)
            try runDeviceAPITestGit(
                ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: projectDir.path)
            let worktreeDir = root.appendingPathComponent("teardown-worktree", isDirectory: true)
            try runDeviceAPITestGit(["worktree", "add", "-b", "feature-teardown", worktreeDir.path], cwd: projectDir.path)

            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(id: "project-teardown", name: "Teardown", dir: projectDir.path, isGitRepo: true, defaultBranch: "main")
            try store.upsert(project: project)
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: "workspace-teardown", projectID: project.id, dir: worktreeDir.path, dirname: "teardown-worktree", branch: "feature-teardown",
                    baseBranch: "main", isDefault: false, isRunning: true, lastLaunchedAt: nil))
            // A running process gives the delete a terminal to tear down, which is where it parks.
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: "process-teardown", workspaceID: "workspace-teardown", templateName: "api", command: "npm start",
                    terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "session-teardown", pid: nil, status: .running, logPath: nil,
                    lastOutputAt: nil, startedAt: nil, exitedAt: nil))

            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-TEARDOWN-SET", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            DispatchQueue.global(qos: .userInitiated).async {
                defer { deleteFinished.signal() }
                _ = try? self.sendTLSRequest(
                    SpacesDeviceAPIRequest(
                        command: .archiveWorkspace(.init(workspaceID: "workspace-teardown", deleteLocalBranch: false, deleteRemoteBranch: false)),
                        authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                    certificateFingerprint: identity.certificateFingerprint)
            }
            XCTAssertEqual(teardownStarted.wait(timeout: .now() + 30), .success, "the delete must reach the workspace teardown")

            let duringDelete = try sendTLSRequest(
                SpacesDeviceAPIRequest(command: .overview, authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)
            XCTAssertTrue(duringDelete.ok, duringDelete.message)
            let midOverview = try XCTUnwrap(duringDelete.overview)
            XCTAssertEqual(
                midOverview.workspaceIDsWithTeardownInFlight, ["workspace-teardown"],
                "a workspace still listed while its delete runs must be reported as tearing down")
            XCTAssertTrue(midOverview.workspaces.contains { $0.id == "workspace-teardown" }, "and it is still listed, which is the whole ambiguity")

            releaseTeardown.signal()
            XCTAssertEqual(deleteFinished.wait(timeout: .now() + 60), .success)

            let afterDelete = try sendTLSRequest(
                SpacesDeviceAPIRequest(command: .overview, authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)
            let finalOverview = try XCTUnwrap(afterDelete.overview)
            XCTAssertTrue(finalOverview.workspaceIDsWithTeardownInFlight.isEmpty, "the id is released once the teardown ends")
            XCTAssertNil(try store.workspace(id: "workspace-teardown"))
        }
    }

    func testAgentHookStatusDoesNotBlockOtherDeviceAPIRequests() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let hookStarted = DispatchSemaphore(value: 0)
            let releaseHook = DispatchSemaphore(value: 0)
            let hookFinished = DispatchSemaphore(value: 0)
            let hookResult = DeviceAPITransportTestResultBox()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                agentHookStatusLoader: {
                    hookStarted.signal()
                    releaseHook.wait()
                    return []
                })
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-HOOK-QUEUE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0")
            let hookRequest = SpacesDeviceAPIRequest(command: .agentHooksStatus, authToken: pairingStore.authToken, clientApp: clientApp)

            DispatchQueue.global(qos: .userInitiated).async {
                defer { hookFinished.signal() }
                do {
                    let client = try SpacesDeviceAPIRequestClient(
                        resolver: SpacesDeviceEndpointResolver(
                            hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
                    let response = try client.request(hookRequest)
                    hookResult.setResponseData(try SpacesDeviceAPICodec.encodeResponse(response))
                } catch { hookResult.setError(error) }
            }

            XCTAssertEqual(hookStarted.wait(timeout: .now() + 5), .success)
            defer { releaseHook.signal() }

            let pingClient = try SpacesDeviceAPIRequestClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint), timeoutSeconds: 1)
            let ping = try pingClient.request(SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp))
            XCTAssertTrue(ping.ok, ping.message)

            releaseHook.signal()
            XCTAssertEqual(hookFinished.wait(timeout: .now() + 5), .success)
            if let error = hookResult.error() { throw error }
            let hookResponse = try SpacesDeviceAPICodec.decodeResponse(hookResult.responseData())
            XCTAssertTrue(hookResponse.ok, hookResponse.message)
        }
    }

    func testReusableRequestSessionConnectsLazily() throws {
        let client = try SpacesDeviceAPIRequestSessionClient(
            resolver: SpacesDeviceEndpointResolver(
                hosts: ["127.0.0.1"], port: makeAvailableTCPPort(), certificateFingerprint: try testTLSIdentity().certificateFingerprint))

        XCTAssertEqual(client.openedConnectionCountForTesting, 0)
    }

    func testReusableRequestSessionTreatsEOFAsClosedConnectionForReplaySafeRequests() {
        XCTAssertTrue(SpacesDeviceAPIRequestSessionClient.debugIsClosedConnectionErrorForTesting(SpacesDeviceAPIRequestClientError.emptyResponse))
    }

    func testReusableRequestSessionSendsMultipleRequestsOnOneConnection() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-SESSION-REUSE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0")
            let client = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))

            let request = SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp)
            let firstResponse = try client.send(request)
            XCTAssertTrue(firstResponse.ok, firstResponse.message)
            XCTAssertEqual(firstResponse.message, "pong")
            XCTAssertTrue(waitForRequestConnectionCount(1, on: server, timeout: 5))

            let secondResponse = try client.send(request)
            XCTAssertTrue(secondResponse.ok, secondResponse.message)
            XCTAssertEqual(secondResponse.message, "pong")
            XCTAssertTrue(waitForRequestConnectionCount(1, on: server, timeout: 5))

            client.cancel()
            XCTAssertTrue(waitForRequestConnectionCount(0, on: server, timeout: 5))
        }
    }

    func testReusableRequestSessionReconnectsBeforeNonReplayableRequestAfterIdleCutoff() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let uptime = DeviceAPITransportTestUptime()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-SESSION-IDLE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0")
            let client = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint),
                idleReconnectInterval: 1, uptime: uptime.value)
            defer { client.cancel() }

            let pingRequest = SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp)
            let firstResponse = try client.send(pingRequest)
            XCTAssertTrue(firstResponse.ok, firstResponse.message)
            XCTAssertEqual(client.openedConnectionCountForTesting, 1)

            uptime.set(0.5)
            let secondResponse = try client.send(pingRequest)
            XCTAssertTrue(secondResponse.ok, secondResponse.message)
            XCTAssertEqual(client.openedConnectionCountForTesting, 1)

            uptime.set(2)
            let controlResponse = try client.send(
                SpacesDeviceAPIRequest(
                    command: .terminalControl(.init(action: .send, sessionID: "missing-session", text: "x")), authToken: pairingStore.authToken,
                    clientApp: clientApp))
            XCTAssertFalse(controlResponse.ok)
            XCTAssertEqual(client.openedConnectionCountForTesting, 2)
        }
    }

    func testPinnedTLSClientCanPairAndPlaintextClientCannotReadResponse() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let server = try SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let window = server.openPairingWindow(hosts: ["127.0.0.1"], name: "Test Mac", code: "12345678", nonce: "NONCE")
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-TLS", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
                appVersion: "1.0")
            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .pair(.init(pairingCode: window.code, pairingNonce: window.nonce, clientProtocolVersion: SpacesWireProtocol.version)),
                    clientApp: clientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok)
            XCTAssertNotNil(response.issuedAuthToken)
            XCTAssertFalse(try plaintextReceivesDeviceAPIResponse(port: server.listeningPort))
        }
    }

    func testIncompatibleClientProtocolVersionIsRejectedWithoutConsumingWindow() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let server = try SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let window = server.openPairingWindow(hosts: ["127.0.0.1"], name: "Test Mac", code: "12345678", nonce: "NONCE")
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-VERSION", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
                appVersion: "1.0")

            // A client one wire version ahead is rejected before the code is validated, so the window
            // survives for a compatible retry with the same code/nonce.
            let rejected = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .pair(
                        .init(pairingCode: window.code, pairingNonce: window.nonce, clientProtocolVersion: SpacesWireProtocol.version + 1)),
                    clientApp: clientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            XCTAssertFalse(rejected.ok)
            XCTAssertNil(rejected.issuedAuthToken)

            // A missing clientProtocolVersion reads as an incompatible (too-old) client and is also rejected.
            let missingVersion = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .pair(.init(pairingCode: window.code, pairingNonce: window.nonce, clientProtocolVersion: nil)), clientApp: clientApp),
                port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            XCTAssertFalse(missingVersion.ok)

            let accepted = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .pair(.init(pairingCode: window.code, pairingNonce: window.nonce, clientProtocolVersion: SpacesWireProtocol.version)),
                    clientApp: clientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            XCTAssertTrue(accepted.ok)
            XCTAssertNotNil(accepted.issuedAuthToken)
        }
    }

    func testUnsupportedBundleDoesNotConsumePairingWindow() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let server = try SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let window = server.openPairingWindow(hosts: ["127.0.0.1"], name: "Test Mac", code: "12345678", nonce: "NONCE")
            let unsupportedClientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-UNSUPPORTED", bundleID: "com.example.thirdparty", platform: "ios", deviceName: "Third Party",
                appVersion: "1.0")

            let rejectedResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .pair(.init(pairingCode: window.code, pairingNonce: window.nonce, clientProtocolVersion: SpacesWireProtocol.version)),
                    clientApp: unsupportedClientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            XCTAssertFalse(rejectedResponse.ok)
            XCTAssertTrue(rejectedResponse.message.contains("Unsupported Spaces client bundle"))

            let supportedClientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-SUPPORTED", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let acceptedResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .pair(.init(pairingCode: window.code, pairingNonce: window.nonce, clientProtocolVersion: SpacesWireProtocol.version)),
                    clientApp: supportedClientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(acceptedResponse.ok)
            XCTAssertNotNil(acceptedResponse.issuedAuthToken)
        }
    }

    func testMismatchedFingerprintLeavesReachablePortForRecoveryProbe() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let server = try SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let staleFingerprint = "SHA256:" + String(repeating: "0", count: 64)
            switch try tlsConnectionOutcome(port: server.listeningPort, certificateFingerprint: staleFingerprint) {
            case .ready: XCTFail("A stale certificate fingerprint should not complete the TLS handshake.")
            case .failed(let error):
                XCTAssertEqual(
                    SpacesDeviceAPIAuthentication.recoveryMessage(for: error),
                    "This Mac no longer recognizes this device. Open Devices and pair this device again.")
            case .timedOut: XCTAssertFalse(try plaintextReceivesDeviceAPIResponse(port: server.listeningPort))
            }
        }
    }

    func testPartialTLSRequestEOFIsRejected() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let server = try SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            XCTAssertTrue(
                try partialTLSRequestEOFClosesConnection(
                    port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint, server: server))
        }
    }

    func testTerminalLinkResolveRequiresAuthentication() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let server = try SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-LINK-AUTH", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(command: .resolveTerminalLink(.init(sessionID: "session-1", terminalLink: "image.png")), clientApp: clientApp),
                port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.message.localizedStandardContains("device auth token"))
            XCTAssertNil(response.terminalLinkMetadata)
        }
    }

    func testSendTerminalInputValidatesPayloadAndSessionAvailability() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-AGENT-SEND", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            func send(_ payload: SpacesDeviceTerminalInputRequest) throws -> SpacesDeviceAPIResponse {
                try sendTLSRequest(
                    SpacesDeviceAPIRequest(command: .sendTerminalInput(payload), authToken: pairingStore.authToken, clientApp: clientApp),
                    port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            }

            let missingPayload = try send(.init(sessionID: "agent-send-session"))
            XCTAssertFalse(missingPayload.ok)
            XCTAssertTrue(missingPayload.message.localizedStandardContains("text or bytes"))

            let bothPayloads = try send(.init(sessionID: "agent-send-session", text: "echo hi", bytes: Data([0x03])))
            XCTAssertFalse(bothPayloads.ok)
            XCTAssertTrue(bothPayloads.message.localizedStandardContains("not both"))

            // Well-formed input against a session with no live control socket reports unavailability
            // instead of hanging or succeeding silently.
            let unavailableSession = try send(.init(sessionID: "agent-send-session", text: "echo hi", appendNewline: true))
            XCTAssertFalse(unavailableSession.ok)
            XCTAssertTrue(unavailableSession.message.localizedStandardContains("not available"))
        }
    }

    func testTailTerminalOutputRendersSessionOutputLog() throws {
        try withTemporaryProfile { _ in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-AGENT-TAIL", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            func tail(_ payload: SpacesDeviceTerminalTailRequest) throws -> SpacesDeviceAPIResponse {
                try sendTLSRequest(
                    SpacesDeviceAPIRequest(command: .tailTerminalOutput(payload), authToken: pairingStore.authToken, clientApp: clientApp),
                    port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            }

            let noOutput = try tail(.init(sessionID: "agent-tail-session"))
            XCTAssertFalse(noOutput.ok)
            XCTAssertTrue(noOutput.message.localizedStandardContains("no output"))

            let paths = try TerminalSessionPaths.forSession(id: "agent-tail-session")
            try FileManager.default.createDirectory(atPath: paths.rootDirectory, withIntermediateDirectories: true)
            try Data("first line\nsecond line\nhello-agent\n".utf8).write(to: URL(fileURLWithPath: paths.outputPath))

            let tailed = try tail(.init(sessionID: "agent-tail-session", lines: 2))
            XCTAssertTrue(tailed.ok, tailed.message)
            let text = try XCTUnwrap(tailed.terminalOutput)
            XCTAssertTrue(text.contains("hello-agent"))
            XCTAssertFalse(text.contains("first line"))
        }
    }

    func testCreateProjectImportsDaemonLocalDirectory() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let projectDir = root.appendingPathComponent("daemon-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-PROJECT-CREATE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .createProject(.init(projectDir: projectDir.path, gitURL: nil)), authToken: pairingStore.authToken, clientApp: clientApp),
                port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            let projectID = try XCTUnwrap(response.projectID)
            XCTAssertEqual(response.overview?.projects.first(where: { $0.id == projectID })?.dir, projectDir.path)
            XCTAssertEqual(response.overview?.workspaces.first(where: { $0.projectID == projectID })?.isDefault, true)
            XCTAssertEqual(response.workspaceID, response.overview?.workspaces.first(where: { $0.projectID == projectID && $0.isDefault })?.id)
        }
    }

    func testProjectConfigAndHiddenWorkspaceMutationsReturnParityOverview() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let projectDir = root.appendingPathComponent("configured-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-PARITY-OVERVIEW", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let config = SpacesDeviceProjectConfig(
                setupScript: "echo setup", stopScript: "echo stop", ports: [SpacesDeviceServiceDefinition(id: "port-api", name: "api")],
                processes: [SpacesDeviceProcessTemplate(id: "process-api", name: "api", command: "npm run api")],
                browserSessions: [SpacesDeviceBrowserSession(name: "api-browser", url: "http://localhost:$SPACES_API_PORT")])

            let createResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .createProject(.init(projectDir: projectDir.path, gitURL: nil, config: config)), authToken: pairingStore.authToken,
                    clientApp: clientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(createResponse.ok, createResponse.message)
            let projectID = try XCTUnwrap(createResponse.projectID)
            let workspaceID = try XCTUnwrap(createResponse.workspaceID)
            let project = try XCTUnwrap(createResponse.overview?.projects.first(where: { $0.id == projectID }))
            XCTAssertEqual(project.config.setupScript, "echo setup")
            XCTAssertEqual(project.config.stopScript, "echo stop")
            XCTAssertEqual(project.config.ports.first?.name, "api")
            XCTAssertEqual(project.config.processes.first?.command, "npm run api")
            XCTAssertEqual(project.config.browserSessions.first?.url, "http://localhost:$SPACES_API_PORT")

            let hideResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .updateWorkspaceMetadata(.init(workspaceID: workspaceID, isHidden: true, updatesHidden: true)),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(hideResponse.ok, hideResponse.message)
            XCTAssertEqual(hideResponse.overview?.workspaces.first(where: { $0.id == workspaceID })?.isHidden, true)
        }
    }

    func testWorkspaceMetadataBranchRenameSurvivesLaterNotesFailure() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let projectDir = root.appendingPathComponent("metadata-rename-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try initializeGitRepository(at: projectDir, initialBranch: "develop")
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-METADATA-BRANCH-ROLLBACK", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let createResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .createProject(.init(projectDir: projectDir.path, gitURL: nil)), authToken: pairingStore.authToken, clientApp: clientApp),
                port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            XCTAssertTrue(createResponse.ok, createResponse.message)
            let workspaceID = try XCTUnwrap(createResponse.workspaceID)
            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            try store.execute(
                sql: """
                    CREATE TRIGGER fail_workspace_notes_update
                    BEFORE UPDATE OF notes ON workspaces
                    WHEN NEW.id = '\(workspaceID)'
                    BEGIN
                      SELECT RAISE(ABORT, 'forced notes failure');
                    END
                    """, bindings: [])

            let updateResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .updateWorkspaceMetadata(
                        .init(
                            workspaceID: workspaceID, branch: "feature-api-rename", notes: "this write fails", updatesBranch: true, updatesNotes: true
                        )), authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertFalse(updateResponse.ok)
            XCTAssertTrue(updateResponse.message.localizedStandardContains("forced notes failure"), updateResponse.message)
            let updatedWorkspace = try XCTUnwrap(store.workspace(id: workspaceID))
            XCTAssertEqual(updatedWorkspace.branch, "feature-api-rename")
            XCTAssertEqual(try currentGitBranch(at: projectDir), "feature-api-rename")
            XCTAssertNil(updatedWorkspace.notes)
        }
    }

    func testCreateProjectOverviewResolvesServiceURLBrowserSessions() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let projectDir = root.appendingPathComponent("service-url-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-SERVICE-URL", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let config = SpacesDeviceProjectConfig(
                ports: [SpacesDeviceServiceDefinition(id: "service-web", name: "web")],
                processes: [SpacesDeviceProcessTemplate(id: "process-web", name: "webserver", command: "PORT=$SPACES_WEB_PORT npm run dev")],
                browserSessions: [SpacesDeviceBrowserSession(name: "weburl", url: "$SPACES_WEB_URL")])

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .createProject(.init(projectDir: projectDir.path, gitURL: nil, config: config)), authToken: pairingStore.authToken,
                    clientApp: clientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            let workspaceID = try XCTUnwrap(response.workspaceID)
            let workspace = try XCTUnwrap(response.overview?.workspaces.first(where: { $0.id == workspaceID }))
            let slug = SpacesProfile.workspaceHostSlug(
                branch: workspace.branch, projectName: projectDir.lastPathComponent, isGitRepo: false, workspaceID: workspaceID)
            XCTAssertEqual(workspace.config.browserSessions.first?.url, "$SPACES_WEB_URL")
            XCTAssertEqual(workspace.config.resolvedBrowserSessions.first?.url, "http://web.\(slug).localhost:\(AppConfig.defaultRouterPort)")
        }
    }

    func testRestartWorkspaceLifecycleUsesDeviceAPIOrchestratorPath() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let launches = DeviceAPITerminalLaunchCapture()
            let terminations = DeviceAPITerminalTerminationCapture()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                builtInTerminalSessionTerminator: { terminations.append($0) },
                builtInTerminalSessionLauncher: { configuration in
                    let childPID = launches.append(configuration)
                    return TerminalServiceSessionSummary(
                        id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                        backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123,
                        childPID: Int32(childPID), controlSocketPath: "/tmp/control-\(configuration.sessionID)",
                        outputPath: "/tmp/output-\(configuration.sessionID)", launchConfiguration: configuration)
                })
            try server.start()
            defer { server.stop() }

            let projectDir = root.appendingPathComponent("restart-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(id: "project-restart", name: "Restart Project", dir: projectDir.path, isGitRepo: false, defaultBranch: nil)
            let workspace = WorkspaceRecord(
                id: "workspace-restart", projectID: project.id, dir: projectDir.path, dirname: nil, branch: nil, isDefault: true, isRunning: true,
                lastLaunchedAt: "2026-06-18T12:00:00Z")
            try store.upsert(project: project)
            try store.upsert(workspace: workspace)
            try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
            try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "true")
            try store.setWorkspaceProcesses(
                workspaceID: workspace.id, processes: [ProcessTemplate(id: "process-api", name: "api", command: "echo api")])
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: "old-process", workspaceID: workspace.id, templateID: "process-api", templateName: "api", command: "echo old",
                    terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "old-session", pid: 777, status: .running, logPath: nil,
                    lastOutputAt: nil, startedAt: "2026-06-18T12:00:01Z", exitedAt: nil))
            try store.upsert(
                window: WindowRecord(
                    id: "browser-window", workspaceID: workspace.id, app: "Google Chrome", name: "docs", detail: "http://localhost:9000/docs",
                    targetURL: "http://localhost:9000/docs", role: "browser", orderIndex: 0, lastSeenAt: "2026-06-18T12:00:02Z"))
            try store.upsert(
                window: WindowRecord(
                    id: "shell-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell", detail: "zsh",
                    terminalTrackingID: "shell-session", role: "terminal", orderIndex: 300, lastSeenAt: "2026-06-18T12:00:03Z"))
            try store.upsert(
                window: WindowRecord(
                    id: "agent-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "Mock Agent", detail: "codex",
                    terminalTrackingID: "agent-session", role: "terminal", orderIndex: 400, lastSeenAt: "2026-06-18T12:00:04Z"))
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: "old-agent", workspaceID: workspace.id, provider: .spaces, label: "Mock Agent", terminalTrackingID: "agent-session",
                    sessionKey: nil, status: .spinning, createdAt: "2026-06-18T12:00:04Z", updatedAt: "2026-06-18T12:00:04Z"))

            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-WORKSPACE-RESTART", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .restartWorkspace(.init(workspaceID: workspace.id)), authToken: pairingStore.authToken, clientApp: clientApp),
                port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            XCTAssertEqual(response.workspaceID, workspace.id)
            XCTAssertEqual(terminations.sessionIDs(), ["old-session", "agent-session", "shell-session"])
            XCTAssertEqual(launches.titles(), ["api"])
            let updatedWorkspace = try XCTUnwrap(try store.workspace(id: workspace.id))
            XCTAssertTrue(updatedWorkspace.isRunning)
            let processes = try store.runningProcesses(workspaceID: workspace.id)
            XCTAssertEqual(processes.count, 1)
            let relaunchedProcess = try XCTUnwrap(processes.first)
            XCTAssertEqual(relaunchedProcess.templateID, "process-api")
            XCTAssertEqual(relaunchedProcess.templateName, "api")
            XCTAssertEqual(relaunchedProcess.status, .running)
            XCTAssertNotEqual(relaunchedProcess.terminalTrackingID, "old-session")
            XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
            XCTAssertEqual(try store.windows(workspaceID: workspace.id).map(\.name), ["api"])
            let overviewWorkspace = try XCTUnwrap(response.overview?.workspaces.first(where: { $0.id == workspace.id }))
            XCTAssertTrue(overviewWorkspace.isRunning)
            XCTAssertEqual(overviewWorkspace.processRows.count, 1)
            XCTAssertTrue(overviewWorkspace.terminalRows.isEmpty)
        }
    }

    func testOverviewResponseCarriesDaemonStatusWithRestartImpactCounts() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }

            let projectDir = root.appendingPathComponent("impact-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(id: "project-impact", name: "Impact Project", dir: projectDir.path, isGitRepo: false, defaultBranch: nil)
            let workspace = WorkspaceRecord(
                id: "workspace-impact", projectID: project.id, dir: projectDir.path, dirname: nil, branch: nil, isDefault: true, isRunning: true,
                lastLaunchedAt: "2026-06-18T12:00:00Z")
            try store.upsert(project: project)
            try store.upsert(workspace: workspace)
            // One running and one exited process: only the running one is restart-impacting.
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: "running-process", workspaceID: workspace.id, templateID: "process-web", templateName: "web", command: "npm run dev",
                    pid: 4242, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "2026-06-18T12:00:01Z", exitedAt: nil))
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: "exited-process", workspaceID: workspace.id, templateID: "process-api", templateName: "api", command: "echo api", pid: nil,
                    status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "2026-06-18T12:00:01Z", exitedAt: "2026-06-18T12:00:09Z"))
            // One spinning (active) and one waiting agent: each maps to its own impact tally.
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: "spinning-agent", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "spin-session",
                    sessionKey: nil, status: .spinning, createdAt: "2026-06-18T12:00:04Z", updatedAt: "2026-06-18T12:00:04Z"))
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: "waiting-agent", workspaceID: workspace.id, provider: .spaces, label: "Claude", terminalTrackingID: "wait-session",
                    sessionKey: nil, status: .waiting, createdAt: "2026-06-18T12:00:05Z", updatedAt: "2026-06-18T12:00:05Z"))

            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-OVERVIEW-IMPACT", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(command: .overview, authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            // The overview carries the frozen-core handshake inline so a compatible client reads the
            // compatibility verdict and restart impact without a second round-trip.
            let status = try XCTUnwrap(response.overview?.daemonStatus)
            XCTAssertEqual(status.protocolVersion, SpacesWireProtocol.version)
            XCTAssertEqual(status.runningProcesses, 1)
            XCTAssertEqual(status.activeAgents, 1)
            XCTAssertEqual(status.waitingAgents, 1)
            // The server is bound to a pinned (non-wildcard) host, so `pairingLinkHosts` returns it
            // verbatim — same derivation a pairing link uses, so the two can never disagree.
            XCTAssertEqual(status.deviceAPIAddresses, ["127.0.0.1"])
        }
    }

    func testOpenWorkspaceTerminalReturnsReservedStartingSessionBeforeLauncherCompletes() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let launcher = BlockingDeviceAPITerminalLauncher()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore, builtInTerminalSessionLauncher: launcher.launch)
            try server.start()
            defer {
                launcher.release()
                _ = launcher.waitUntilFinished(timeout: 2)
                server.stop()
            }

            let projectDir = root.appendingPathComponent("terminal-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(id: "project-terminal", name: "Terminal Project", dir: projectDir.path, isGitRepo: false, defaultBranch: nil)
            let workspace = WorkspaceRecord(
                id: "workspace-terminal", projectID: project.id, dir: projectDir.path, dirname: nil, branch: nil, isDefault: true, isRunning: false,
                lastLaunchedAt: nil)
            try store.upsert(project: project)
            try store.upsert(workspace: workspace)
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-WORKSPACE-TERMINAL", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let startedAt = Date()
            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .openWorkspaceTerminal(.init(workspaceID: workspace.id)), authToken: pairingStore.authToken, clientApp: clientApp),
                port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            let elapsed = Date().timeIntervalSince(startedAt)

            XCTAssertTrue(response.ok, response.message)
            XCTAssertLessThan(elapsed, 2)
            let sessionID = try XCTUnwrap(response.sessionID)
            XCTAssertTrue(launcher.waitUntilStarted(timeout: 2))
            XCTAssertEqual(launcher.configurationsSnapshot().map(\.sessionID), [sessionID])
            let overview = try XCTUnwrap(response.overview)
            let summary = try XCTUnwrap(overview.sessions.first { $0.id == sessionID })
            XCTAssertEqual(summary.state, .starting)
            XCTAssertEqual(summary.workspaceID, workspace.id)
            XCTAssertFalse(summary.isControlAvailable)
            XCTAssertFalse(summary.isSubscriptionAvailable)
            let overviewWorkspace = try XCTUnwrap(overview.workspaces.first { $0.id == workspace.id })
            let row = try XCTUnwrap(overviewWorkspace.terminalRows.first { $0.sessionID == sessionID })
            XCTAssertEqual(row.runState, .running)
            XCTAssertTrue(row.canOpenTerminal)
            XCTAssertTrue(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)

            launcher.release()
            XCTAssertTrue(launcher.waitUntilFinished(timeout: 2))
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .running)
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.controlSocketPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.subscriptionSocketPath))
        }
    }

    func testOpenWorkspaceTerminalResponseKeepsReservedSessionWhenBackgroundLaunchFailsImmediately() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let launcher = FailingDeviceAPITerminalLauncher()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore, builtInTerminalSessionLauncher: launcher.launch)
            try server.start()
            defer { server.stop() }

            let projectDir = root.appendingPathComponent("terminal-failure-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(
                id: "project-terminal-failure", name: "Terminal Failure Project", dir: projectDir.path, isGitRepo: false, defaultBranch: nil)
            let workspace = WorkspaceRecord(
                id: "workspace-terminal-failure", projectID: project.id, dir: projectDir.path, dirname: nil, branch: nil, isDefault: true,
                isRunning: false, lastLaunchedAt: nil)
            try store.upsert(project: project)
            try store.upsert(workspace: workspace)
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-WORKSPACE-TERMINAL-FAILURE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .openWorkspaceTerminal(.init(workspaceID: workspace.id)), authToken: pairingStore.authToken, clientApp: clientApp),
                port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            let sessionID = try XCTUnwrap(response.sessionID)
            let overview = try XCTUnwrap(response.overview)
            let summary = try XCTUnwrap(overview.sessions.first { $0.id == sessionID })
            XCTAssertEqual(summary.state, .starting)
            XCTAssertEqual(summary.workspaceID, workspace.id)
            let overviewWorkspace = try XCTUnwrap(overview.workspaces.first { $0.id == workspace.id })
            let row = try XCTUnwrap(overviewWorkspace.terminalRows.first { $0.sessionID == sessionID })
            XCTAssertEqual(row.runState, .running)
            XCTAssertTrue(row.canOpenTerminal)

            XCTAssertTrue(launcher.waitUntilFinished(timeout: 2))
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            XCTAssertTrue(waitForTerminalRuntimeState(.failed, sessionID: sessionID, timeout: 2))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlSocketPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.subscriptionSocketPath))
            XCTAssertTrue(waitForWorkspaceWindowsEmpty(workspaceID: workspace.id, store: store, timeout: 2))
        }
    }

    func testRunWorkspaceProcessReturnsLaunchedTerminalSessionID() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let launches = DeviceAPITerminalLaunchCapture()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                builtInTerminalSessionLauncher: { configuration in
                    let childPID = launches.append(configuration)
                    let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
                    try paths.ensureDirectories()
                    try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
                    _ = FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    _ = FileManager.default.createFile(atPath: paths.subscriptionSocketPath, contents: Data())
                    _ = FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
                    try TerminalSessionPersistence.writeRuntimeState(
                        TerminalSessionRuntimeState(
                            sessionID: configuration.sessionID, backend: configuration.backend,
                            servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: Int32(childPID), state: .running,
                            updatedAt: "2026-06-22T12:00:00Z", title: configuration.title, workingDirectory: configuration.workingDirectory),
                        paths: paths)
                    return TerminalServiceSessionSummary(
                        id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                        backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running,
                        servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: Int32(childPID),
                        controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath, launchConfiguration: configuration)
                })
            try server.start()
            defer { server.stop() }

            let projectDir = root.appendingPathComponent("process-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(id: "project-process", name: "Process Project", dir: projectDir.path, isGitRepo: false, defaultBranch: nil)
            let workspace = WorkspaceRecord(
                id: "workspace-process", projectID: project.id, dir: projectDir.path, dirname: nil, branch: nil, isDefault: true, isRunning: false,
                lastLaunchedAt: nil)
            try store.upsert(project: project)
            try store.upsert(workspace: workspace)
            try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
            try store.setWorkspaceProcesses(
                workspaceID: workspace.id, processes: [ProcessTemplate(id: "process-api", name: "api", command: "echo api")])
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-RUN-PROCESS", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .runWorkspaceProcess(.init(workspaceID: workspace.id, processKey: "api", processTemplateID: "process-api")),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            let sessionID = try XCTUnwrap(response.sessionID)
            XCTAssertEqual(launches.configurationsSnapshot().map(\.sessionID), [sessionID])
            let overviewWorkspace = try XCTUnwrap(response.overview?.workspaces.first { $0.id == workspace.id })
            let processRow = try XCTUnwrap(overviewWorkspace.processRows.first { $0.name == "api" })
            XCTAssertEqual(processRow.sessionID, sessionID)
            XCTAssertEqual(processRow.runState, .running)
        }
    }

    func testOpenWorkspaceTerminalCleansReservedSessionWhenOverviewRefreshFails() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let launches = DeviceAPITerminalLaunchCapture()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                builtInTerminalSessionLauncher: { configuration in
                    let childPID = launches.append(configuration)
                    return TerminalServiceSessionSummary(
                        id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                        backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123,
                        childPID: Int32(childPID), controlSocketPath: "/tmp/control-\(configuration.sessionID)",
                        outputPath: "/tmp/output-\(configuration.sessionID)", launchConfiguration: configuration)
                },
                overviewLoaderForTesting: { _ in
                    throw NSError(
                        domain: "SpacesDeviceAPIServerTransportTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "overview refresh failed"])
                })
            try server.start()
            defer { server.stop() }

            let projectDir = root.appendingPathComponent("terminal-overview-failure-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let project = ProjectRecord(
                id: "project-terminal-overview-failure", name: "Terminal Overview Failure Project", dir: projectDir.path, isGitRepo: false,
                defaultBranch: nil)
            let workspace = WorkspaceRecord(
                id: "workspace-terminal-overview-failure", projectID: project.id, dir: projectDir.path, dirname: nil, branch: nil, isDefault: true,
                isRunning: false, lastLaunchedAt: nil)
            try store.upsert(project: project)
            try store.upsert(workspace: workspace)
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-WORKSPACE-TERMINAL-OVERVIEW-FAILURE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID,
                platform: "ios", deviceName: "iPhone", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .openWorkspaceTerminal(.init(workspaceID: workspace.id)), authToken: pairingStore.authToken, clientApp: clientApp),
                port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.message.localizedStandardContains("overview refresh failed"), response.message)
            XCTAssertTrue(launches.configurationsSnapshot().isEmpty)
            let knownSessions = try TerminalSessionPersistence.listKnownSessions()
            XCTAssertEqual(knownSessions.count, 1)
            let reservedSession = try XCTUnwrap(knownSessions.first)
            let paths = try TerminalSessionPaths.forSession(id: reservedSession.sessionID)
            XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlSocketPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.subscriptionSocketPath))
            XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
            XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        }
    }

    func testCreateProjectRequiresOneSource() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let projectDir = root.appendingPathComponent("daemon-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-PROJECT-SOURCE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let missingResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .createProject(.init(projectDir: nil, gitURL: nil)), authToken: pairingStore.authToken, clientApp: clientApp),
                port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            let bothResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .createProject(.init(projectDir: projectDir.path, gitURL: "https://example.com/repo.git")),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertFalse(missingResponse.ok)
            XCTAssertEqual(missingResponse.message, "Provide exactly one project directory or Git URL.")
            XCTAssertFalse(bothResponse.ok)
            XCTAssertEqual(bothResponse.message, "Provide exactly one project directory or Git URL.")
        }
    }

    func testTerminalLinkWorkspaceRootLookupErrorsPropagate() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-LINK-ROOTS", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let invalidDatabasePath = root.appendingPathComponent("not-a-database", isDirectory: true)
            try FileManager.default.createDirectory(at: invalidDatabasePath, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", invalidDatabasePath.path, 1)
            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .resolveTerminalLink(.init(sessionID: "session-1", terminalLink: "image.png")), authToken: pairingStore.authToken,
                    clientApp: clientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.message.localizedStandardContains("Failed opening sqlite db"), response.message)
            XCTAssertFalse(response.message.localizedStandardContains("blocked path"), response.message)
            XCTAssertFalse(response.message.localizedStandardContains("invalid link"), response.message)
        }
    }

    func testTerminalLinkExternalResolveSkipsWorkspaceRootLookupAndSessionState() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-LINK-EXTERNAL", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let invalidDatabasePath = root.appendingPathComponent("external-unavailable-spaces-db", isDirectory: true)
            try FileManager.default.createDirectory(at: invalidDatabasePath, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", invalidDatabasePath.path, 1)
            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .resolveTerminalLink(.init(sessionID: "missing-session", terminalLink: "https://example.com/screenshot.png")),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            let metadata = try XCTUnwrap(response.terminalLinkMetadata)
            XCTAssertEqual(metadata.source, .externalURL)
            XCTAssertEqual(metadata.externalURL, "https://example.com/screenshot.png")
            XCTAssertEqual(metadata.artifactKind, .image)
            XCTAssertFalse(response.message.localizedStandardContains("sqlite"), response.message)
        }
    }

    func testTerminalLinkAbsolutePathResolvesWithoutSessionState() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-LINK-ABSOLUTE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            // No launch configuration is ever written for this session, so `terminalWorkingDirectory`
            // would throw `unknownSession` if it were looked up. An absolute-path link doesn't need a
            // working directory to anchor it, so resolution must still succeed.
            let image = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: image) }
            try Data([0x89, 0x50, 0x4E, 0x47, 0x01]).write(to: image)

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .resolveTerminalLink(.init(sessionID: "session-without-launch-config", terminalLink: image.path)),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            let metadata = try XCTUnwrap(response.terminalLinkMetadata)
            XCTAssertEqual(metadata.source, .localFile)
            XCTAssertEqual(metadata.displayName, image.lastPathComponent)
        }
    }

    func testRelativeTerminalLinkAnchorsInForegroundProcessLiveWorkingDirectory() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-LINK-LIVE-CWD", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let sessionID = "session-live-cwd-\(UUID().uuidString)"
            // The launch configuration and the tracked runtime-state working directory both point at the
            // stale launch directory (which never receives the fixture), so a passing resolution can only
            // come from consulting the foreground process's real cwd.
            let staleDir = try makeWorkspaceRootProfile(root: root, sessionID: sessionID)

            // The live cwd lives under /private/tmp so the resolver authorizes it via its fixed prefix
            // allowlist without registering it as a workspace root. Match the kernel-reported cwd path by
            // creating the directory at the resolved (/private/tmp) location the sleep child will chdir to.
            let liveDir = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
                "spaces-live-cwd-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: liveDir) }
            let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0A, 0x0B])
            try imageData.write(to: liveDir.appendingPathComponent("statement.png"))

            let foreground = Process()
            foreground.executableURL = URL(fileURLWithPath: "/bin/sleep")
            foreground.arguments = ["30"]
            foreground.currentDirectoryURL = liveDir
            try foreground.run()
            defer {
                foreground.terminate()
                foreground.waitUntilExit()
            }

            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: foreground.processIdentifier,
                    state: .running, updatedAt: "2026-06-09T12:00:00Z", workingDirectory: staleDir.path, foregroundPID: foreground.processIdentifier),
                paths: paths)

            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .resolveTerminalLink(.init(sessionID: sessionID, terminalLink: "./statement.png")), authToken: pairingStore.authToken,
                    clientApp: clientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(response.ok, response.message)
            let metadata = try XCTUnwrap(response.terminalLinkMetadata)
            XCTAssertEqual(metadata.source, .localFile)
            XCTAssertEqual(metadata.displayName, "statement.png")
        }
    }

    func testTerminalLinkChunkReadUsesResolvedTransferAuthorizationWhenDatabaseBecomesUnavailable() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-LINK-CACHED", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let sessionID = "session-link-cached-\(UUID().uuidString)"
            let workspaceDir = try makeWorkspaceRootProfile(root: root, sessionID: sessionID)
            let image = workspaceDir.appendingPathComponent("preview.png")
            let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
            try imageData.write(to: image)

            let resolveResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .resolveTerminalLink(.init(sessionID: sessionID, terminalLink: "preview.png")), authToken: pairingStore.authToken,
                    clientApp: clientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            let metadata = try XCTUnwrap(resolveResponse.terminalLinkMetadata)
            XCTAssertTrue(resolveResponse.ok)
            XCTAssertEqual(metadata.source, .localFile)

            let invalidDatabasePath = root.appendingPathComponent("unavailable-spaces-db", isDirectory: true)
            try FileManager.default.createDirectory(at: invalidDatabasePath, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", invalidDatabasePath.path, 1)

            let chunkResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .readTerminalLinkChunk(.init(sessionID: sessionID, terminalLinkID: metadata.id, offset: 0, limit: 16)),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(chunkResponse.ok, chunkResponse.message)
            let chunk = try XCTUnwrap(chunkResponse.terminalLinkChunk)
            XCTAssertEqual(Data(base64Encoded: chunk.base64Data), imageData)
            XCTAssertTrue(chunk.isFinal)
        }
    }

    func testTerminalLinkChunkReadRefreshesResolvedTransferAuthorization() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-LINK-REFRESH", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let sessionID = "session-link-refresh-\(UUID().uuidString)"
            let workspaceDir = try makeWorkspaceRootProfile(root: root, sessionID: sessionID)
            let image = workspaceDir.appendingPathComponent("preview-refresh.png")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02]).write(to: image)

            let resolveResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .resolveTerminalLink(.init(sessionID: sessionID, terminalLink: "preview-refresh.png")),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)
            let metadata = try XCTUnwrap(resolveResponse.terminalLinkMetadata)
            let originalExpiration = try XCTUnwrap(server.terminalLinkTransferAuthorizationExpirationForTesting(linkID: metadata.id))

            let chunkResponse = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .readTerminalLinkChunk(.init(sessionID: sessionID, terminalLinkID: metadata.id, offset: 0, limit: 4)),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertTrue(chunkResponse.ok, chunkResponse.message)
            let refreshedExpiration = try XCTUnwrap(server.terminalLinkTransferAuthorizationExpirationForTesting(linkID: metadata.id))
            XCTAssertGreaterThan(refreshedExpiration.timeIntervalSince1970, originalExpiration.timeIntervalSince1970)
        }
    }

    func testTerminalLinkChunkReadRejectsNeverResolvedLocalLinkWithoutWorkspaceRootScan() throws {
        try withTemporaryProfile { root in
            let identity = try testTLSIdentity()
            let pairingStore = AlwaysAuthorizedDevicePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-LINK-FORGED", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let image = root.appendingPathComponent("forged.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
            let metadata = try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: "session-forged", link: image.path, workingDirectory: nil, homeDirectory: root.path)

            let invalidDatabasePath = root.appendingPathComponent("forged-unavailable-spaces-db", isDirectory: true)
            try FileManager.default.createDirectory(at: invalidDatabasePath, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", invalidDatabasePath.path, 1)
            let response = try sendTLSRequest(
                SpacesDeviceAPIRequest(
                    command: .readTerminalLinkChunk(.init(sessionID: "session-forged", terminalLinkID: metadata.id, offset: 0, limit: 4)),
                    authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)

            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.message.localizedStandardContains("terminal link transfer id is invalid"), response.message)
            XCTAssertFalse(response.message.localizedStandardContains("sqlite"), response.message)
        }
    }

    private enum DeviceAPITransportConnectionOutcome {
        case ready
        case failed(Error)
        case timedOut
    }

    private func tlsConnectionOutcome(port: Int, certificateFingerprint: String) throws -> DeviceAPITransportConnectionOutcome {
        let finished = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.device.api.transport.outcome.test")
        let resultBox = DeviceAPITransportTestResultBox()
        // Reported the way the clients report it: the verify block's own rejection, not the raw NWError.
        // A `.failed` TLS state alone does not distinguish a refused pin from a dropped handshake, so a
        // caller that wants the re-pair verdict has to carry this box.
        let pinRejection = SpacesPinnedTLSPinRejection()
        let connection = NWConnection(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))),
            using: SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint, pinRejection: pinRejection))

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finished.signal()
            case .failed(let error):
                resultBox.setError(pinRejection.error ?? error)
                finished.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard finished.wait(timeout: .now() + 1) == .success else {
            connection.cancel()
            return .timedOut
        }
        connection.cancel()
        if let error = resultBox.error() { return .failed(error) }
        return .ready
    }

    private func sendTLSRequest(_ request: SpacesDeviceAPIRequest, port: Int, certificateFingerprint: String) throws -> SpacesDeviceAPIResponse {
        let ready = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.device.api.transport.test")
        let resultBox = DeviceAPITransportTestResultBox()
        let connection = NWConnection(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))),
            using: SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint))

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                resultBox.setError(error)
                ready.signal()
                sent.signal()
                received.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        if let error = resultBox.error() { throw error }

        var requestData = try SpacesDeviceAPICodec.encodeRequest(request)
        requestData.append(0x0A)
        connection.send(
            content: requestData,
            completion: .contentProcessed { error in
                if let error { resultBox.setError(error) }
                sent.signal()
            })
        XCTAssertEqual(sent.wait(timeout: .now() + 5), .success)
        if let error = resultBox.error() { throw error }

        @Sendable func receiveNext(_ data: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    resultBox.setError(error)
                    received.signal()
                    return
                }
                var nextData = data
                if let content { nextData.append(content) }
                if let newlineIndex = nextData.firstIndex(of: 0x0A) {
                    resultBox.setResponseData(Data(nextData.prefix(upTo: newlineIndex)))
                    received.signal()
                    return
                }
                if isComplete {
                    resultBox.setResponseData(nextData)
                    received.signal()
                    return
                }
                receiveNext(nextData)
            }
        }
        receiveNext(Data())
        XCTAssertEqual(received.wait(timeout: .now() + 5), .success)
        connection.cancel()
        if let error = resultBox.error() { throw error }
        return try SpacesDeviceAPICodec.decodeResponse(resultBox.responseData())
    }

    private func plaintextReceivesDeviceAPIResponse(port: Int) throws -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var requestData = try SpacesDeviceAPICodec.encodeRequest(SpacesDeviceAPIRequest(command: .ping))
        requestData.append(0x0A)
        _ = requestData.withUnsafeBytes { rawBuffer in write(socketFD, rawBuffer.baseAddress, rawBuffer.count) }

        var buffer = [UInt8](repeating: 0, count: 512)
        let count = read(socketFD, &buffer, buffer.count)
        guard count > 0 else { return false }
        return (try? SpacesDeviceAPICodec.decodeResponse(Data(buffer.prefix(count)))) != nil
    }

    private func partialTLSRequestEOFClosesConnection(port: Int, certificateFingerprint: String, server: SpacesDeviceAPIServer) throws -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.device.api.partial-eof.test")
        let resultBox = DeviceAPITransportTestResultBox()
        let connection = NWConnection(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))),
            using: SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint))

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                resultBox.setError(error)
                ready.signal()
                sent.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        if let error = resultBox.error() { throw error }
        XCTAssertTrue(waitForRequestConnectionCount(1, on: server, timeout: 5))

        let requestData = try SpacesDeviceAPICodec.encodeRequest(SpacesDeviceAPIRequest(command: .ping))
        connection.send(
            content: requestData, contentContext: .defaultMessage, isComplete: true,
            completion: .contentProcessed { error in
                if let error { resultBox.setError(error) }
                sent.signal()
            })
        XCTAssertEqual(sent.wait(timeout: .now() + 5), .success)
        if let error = resultBox.error() { throw error }

        connection.cancel()
        return waitForRequestConnectionCount(0, on: server, timeout: 5)
    }

    private func waitForRequestConnectionCount(_ expectedCount: Int, on server: SpacesDeviceAPIServer, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if server.requestConnectionCountForTesting == expectedCount { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return server.requestConnectionCountForTesting == expectedCount
    }

    private func waitForTerminalRuntimeState(_ expectedState: TerminalSessionState, sessionID: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let paths = try? TerminalSessionPaths.forSession(id: sessionID),
                let state = try? TerminalSessionPersistence.readRuntimeState(paths: paths).state, state == expectedState
            {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let state = try? TerminalSessionPersistence.readRuntimeState(paths: paths).state
        else { return false }
        return state == expectedState
    }

    private func waitForWorkspaceWindowsEmpty(workspaceID: String, store: SQLiteStore, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? store.windows(workspaceID: workspaceID).isEmpty) == true { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return (try? store.windows(workspaceID: workspaceID).isEmpty) == true
    }

    private func makeAvailableTCPPort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in getsockname(socketFD, sockaddrPointer, &length) }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func initializeGitRepository(at directory: URL, initialBranch: String) throws {
        try runGit(["init", "-b", initialBranch], cwd: directory)
        try "hello".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: directory)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: directory)
    }

    private func currentGitBranch(at directory: URL) throws -> String {
        try runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult private func runGit(_ arguments: [String], cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "spaces.tests.git", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(outputText)"])
        }
        return outputText
    }

    private func withTemporaryProfile(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let originalRuntimePath = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        unsetenv("SPACES_RUNTIME_DIR")
        defer {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimePath { setenv("SPACES_RUNTIME_DIR", originalRuntimePath, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        try body(root)
    }

    private func makeWorkspaceRootProfile(root: URL, sessionID: String) throws -> URL {
        let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        let workspaceDir = projectDir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let project = ProjectRecord(id: "project-\(sessionID)", name: "Project", dir: projectDir.path, isGitRepo: false, defaultBranch: nil)
        let workspace = WorkspaceRecord(
            id: "workspace-\(sessionID)", projectID: project.id, dir: workspaceDir.path, dirname: nil, branch: nil, isDefault: true, isRunning: true,
            lastLaunchedAt: nil)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "terminal", workingDirectory: workspaceDir.path, shell: "/bin/zsh", command: nil,
                createdAt: "2026-06-09T12:00:00Z", workspaceID: workspace.id, kind: .shell), paths: paths)
        return workspaceDir
    }
}

private let deviceAPITransportTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "spaces-device-api-transport-tests-tls-\(UUID().uuidString)", isDirectory: true)

/// One pinned-TLS identity per test process: generation is expensive and every server/client pair
/// only needs a stable certificate to pin.
private func testTLSIdentity() throws -> TerminalServiceTLSIdentity {
    try TerminalServiceTLSIdentityStore.loadOrCreate(root: deviceAPITransportTestTLSRoot)
}

private final class AlwaysAuthorizedDevicePairingStore: SpacesDevicePairingStoreProtocol {
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

private final class DeviceAPITransportTestUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval = 0

    func set(_ value: TimeInterval) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func value() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private final class DeviceAPITerminalLaunchCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [TerminalSessionLaunchConfiguration] = []

    func append(_ configuration: TerminalSessionLaunchConfiguration) -> Int {
        lock.lock()
        defer { lock.unlock() }
        configurations.append(configuration)
        return 9_000 + configurations.count
    }

    func titles() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return configurations.map(\.title)
    }

    func configurationsSnapshot() -> [TerminalSessionLaunchConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }
}

private final class BlockingDeviceAPITerminalLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var configurations: [TerminalSessionLaunchConfiguration] = []
    private var didRelease = false

    func launch(_ configuration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary {
        lock.lock()
        configurations.append(configuration)
        lock.unlock()
        started.signal()
        released.wait()
        defer { finished.signal() }

        let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
        FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
        FileManager.default.createFile(atPath: paths.subscriptionSocketPath, contents: Data())
        FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: configuration.sessionID, backend: configuration.backend, servicePID: Int32(ProcessInfo.processInfo.processIdentifier),
                childPID: 9_001, state: .running, updatedAt: "2026-06-22T12:00:00Z", title: configuration.title,
                workingDirectory: configuration.workingDirectory), paths: paths)
        return TerminalServiceSessionSummary(
            id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory, backend: configuration.backend,
            lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: Int32(ProcessInfo.processInfo.processIdentifier),
            childPID: 9_001, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
    }

    func configurationsSnapshot() -> [TerminalSessionLaunchConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }

    func release() {
        lock.lock()
        guard !didRelease else {
            lock.unlock()
            return
        }
        didRelease = true
        lock.unlock()
        released.signal()
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool { started.wait(timeout: .now() + timeout) == .success }
    func waitUntilFinished(timeout: TimeInterval) -> Bool { finished.wait(timeout: .now() + timeout) == .success }
}

private final class FailingDeviceAPITerminalLauncher: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)

    func launch(_: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary {
        defer { finished.signal() }
        throw NSError(domain: "SpacesDeviceAPIServerTransportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "launcher failed"])
    }

    func waitUntilFinished(timeout: TimeInterval) -> Bool { finished.wait(timeout: .now() + timeout) == .success }
}

private final class DeviceAPITerminalTerminationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(sessionID)
    }

    func sessionIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class DeviceAPITransportTestResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedResponseData = Data()

    func setError(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func error() -> Error? {
        lock.lock()
        let error = storedError
        lock.unlock()
        return error
    }

    func setResponseData(_ data: Data) {
        lock.lock()
        storedResponseData = data
        lock.unlock()
    }

    func responseData() -> Data {
        lock.lock()
        let data = storedResponseData
        lock.unlock()
        return data
    }
}

/// Runs `git` for the Device API server tests' repository fixtures. The Device API delete path shells out to
/// real git, so these tests need real repositories rather than seeded rows.
private func runDeviceAPITestGit(_ arguments: [String], cwd: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_AUTHOR_NAME"] = "spaces-test"
    environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
    environment["GIT_COMMITTER_NAME"] = "spaces-test"
    environment["GIT_COMMITTER_EMAIL"] = "test@example.com"
    environment.removeValue(forKey: "GIT_DIR")
    environment.removeValue(forKey: "GIT_WORK_TREE")
    process.environment = environment
    let errorPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(
            domain: "spaces.tests", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"])
    }
}
