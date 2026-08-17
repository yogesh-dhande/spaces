#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// Two request shapes wait on a target session's engine: a terminal command, over that session's
    /// control socket, and a `.state` catch-up read, through the live-core export. While either wait is
    /// outstanding the daemon still has to answer everything else, because a client whose input send timed
    /// out asks exactly this daemon whether the link is alive before it tears its stream down.
    final class TerminalControlQueueServerTests: XCTestCase {
        func testAStalledTerminalControlDoesNotDelayAPingOnAnotherConnection() throws {
            try withTemporaryProfile {
                let sessionID = "session-control-queue-\(UUID().uuidString)"
                let paths = try seedRunningSession(sessionID: sessionID)

                // Stands in for an engine saturated by output: it accepts the control connection and never
                // answers, so the command occupies whatever queue runs it for the client's full timeout.
                let controlRequestArrived = DispatchSemaphore(value: 0)
                let releaseControlRequest = DispatchSemaphore(value: 0)
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.control-queue.test")
                ) { _ in
                    controlRequestArrived.signal()
                    releaseControlRequest.wait()
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer {
                    releaseControlRequest.signal()
                    controlServer.stop()
                }

                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "control-queue-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")

                let inputClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { inputClient.cancel() }
                let inputFinished = expectation(description: "The stalled terminal control eventually returns.")
                DispatchQueue.global().async {
                    _ = try? inputClient.send(
                        SpacesDeviceAPIRequest(
                            command: .terminalControl(
                                SpacesDeviceTerminalControlRequest(
                                    action: .send, sessionID: sessionID, clientID: "client-control-queue", text: "ls")),
                            authToken: pairingStore.authToken, clientApp: clientApp))
                    inputFinished.fulfill()
                }
                XCTAssertEqual(controlRequestArrived.wait(timeout: .now() + 5), .success, "The terminal control must reach the stalled session.")

                let probeClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 2)
                let startedAt = Date()
                let pong = try probeClient.request(SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(pong.ok, pong.message)
                XCTAssertEqual(pong.message, "pong")
                XCTAssertLessThan(elapsed, 1.5, "A ping must not wait behind a terminal command stalled on its session's engine.")

                releaseControlRequest.signal()
                wait(for: [inputFinished], timeout: 10)
            }
        }

        /// The other engine-blocking shape: a `.state` catch-up read for a session this daemon hosts live
        /// exports the frame straight out of the session's core, so it waits on the same saturated engine
        /// the control commands do. A pane resyncing while it types issues exactly this pair, and the
        /// `.state` must not be what makes the probe's ping miss its deadline.
        func testAStalledStateReadDoesNotDelayAPingOnAnotherConnection() throws {
            try withTemporaryProfile {
                let sessionID = "session-state-queue-\(UUID().uuidString)"
                _ = try seedRunningSession(sessionID: sessionID)

                // Stands in for `TerminalEngineActor.runSynchronously` on a saturated engine: the live-core
                // export blocks until released, occupying whatever queue runs the `.state` request.
                let stateRequestArrived = DispatchSemaphore(value: 0)
                let releaseStateRequest = DispatchSemaphore(value: 0)
                let statePayload = try liveStatePayload(sessionID: sessionID)
                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(
                    host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                    liveTerminalSessionStateProvider: { _ in
                        stateRequestArrived.signal()
                        releaseStateRequest.wait()
                        return statePayload
                    })
                try server.start()
                defer {
                    releaseStateRequest.signal()
                    server.stop()
                }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "control-queue-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")

                let stateClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { stateClient.cancel() }
                let stateFinished = expectation(description: "The stalled state read eventually returns.")
                DispatchQueue.global().async {
                    _ = try? stateClient.send(
                        SpacesDeviceAPIRequest(
                            command: .state(SpacesDeviceTerminalSessionRequest(sessionID: sessionID)),
                            authToken: pairingStore.authToken, clientApp: clientApp))
                    stateFinished.fulfill()
                }
                XCTAssertEqual(stateRequestArrived.wait(timeout: .now() + 5), .success, "The state read must reach the stalled live core.")

                let probeClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 2)
                let startedAt = Date()
                let pong = try probeClient.request(SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(pong.ok, pong.message)
                XCTAssertEqual(pong.message, "pong")
                XCTAssertLessThan(elapsed, 1.5, "A ping must not wait behind a state read stalled on its session's engine.")

                releaseStateRequest.signal()
                wait(for: [stateFinished], timeout: 10)
            }
        }

        /// The smallest payload a live core could export: the test only needs the read to be blocking and
        /// to answer eventually, not to carry a particular frame.
        private func liveStatePayload(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
            let snapshot = GhosttyTerminalSnapshot(
                columns: 1, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0,
                cells: [GhosttyTerminalSnapshot.Cell(codepoint: 32, foregroundRGB: 0xFFFFFF, backgroundRGB: 0, flags: 0)])
            let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 1, snapshot: snapshot)
            return GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-08-16T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: nil, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "zsh", workingDirectory: "/tmp",
                outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
        }

        private func seedRunningSession(sessionID: String) throws -> TerminalSessionPaths {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "zsh", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                    createdAt: "2026-08-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 123,
                    state: .running, updatedAt: "2026-08-16T00:00:01Z"), paths: paths)
            return paths
        }

        private func withTemporaryProfile(_ body: () throws -> Void) throws {
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
            try body()
        }
    }

    private let controlQueueTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "spaces-control-queue-tests-tls-\(UUID().uuidString)", isDirectory: true)

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair
    /// only needs a stable certificate to pin.
    private func controlQueueTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
        try TerminalServiceTLSIdentityStore.loadOrCreate(root: controlQueueTestTLSRoot)
    }

    private final class AlwaysAuthorizedControlQueuePairingStore: SpacesDevicePairingStoreProtocol {
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
