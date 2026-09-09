#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// A remote viewer returning from the background renews its lease and reads the session in the same
    /// request: the Device API answers a heartbeat with the session's state, and carries the frame the
    /// viewer already displays down to the live core so an unchanged screen comes back with no frame bytes.
    /// A `.state` read says instead whether it wants a screen at all, and that reaches the same core.
    final class TerminalHeartbeatStateServerTests: XCTestCase {
        override class func tearDown() {
            try? FileManager.default.removeItem(at: heartbeatStateTestTLSRoot)
            super.tearDown()
        }

        func testHeartbeatAnswersWithSessionStateAndCarriesTheHeldFrameIdentityToTheLiveCore() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-heartbeat-state-\(UUID().uuidString)"
                let clientID = "client-heartbeat-state"
                let paths = try seedRunningSession(sessionID: sessionID)
                let heldFrame = TerminalHeldFrameIdentity(ownerEpoch: 7, sessionRevision: 42)

                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.heartbeat-state.test")
                ) { _ in TerminalControlResponse(ok: true, message: "Renewed lease.") }
                try controlServer.start()
                defer { controlServer.stop() }

                let observedRead = OneShotStateReadRecorder()
                let response = try sendHeartbeat(
                    sessionID: sessionID, clientID: clientID, heldFrame: heldFrame,
                    liveTerminalSessionStateProvider: { requestedSessionID, requestedRead in
                        observedRead.record(requestedRead)
                        guard requestedSessionID == sessionID else { return nil }
                        return Self.statePayload(sessionID: sessionID)
                    })

                XCTAssertTrue(response.ok, response.message)
                let sessionState = try XCTUnwrap(response.sessionState, "a successful heartbeat carries the session's state")
                XCTAssertEqual(sessionState.sessionID, sessionID)
                XCTAssertEqual(sessionState.title, "zsh")
                XCTAssertEqual(
                    observedRead.value, .screen(heldFrame: heldFrame), "the viewer's held frame must reach the core that decides the omission")
            }
        }

        /// A viewer whose lease the daemon expired while the app was suspended gets the error it already
        /// routes to a reattach, with no state to mistake for a live session's.
        func testRejectedHeartbeatCarriesNoSessionState() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-heartbeat-rejected-\(UUID().uuidString)"
                let paths = try seedRunningSession(sessionID: sessionID)

                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.heartbeat-rejected.test")
                ) { _ in TerminalControlResponse(ok: false, message: "Client not found.", errorCode: .notFound) }
                try controlServer.start()
                defer { controlServer.stop() }

                let response = try sendHeartbeat(
                    sessionID: sessionID, clientID: "client-heartbeat-rejected", heldFrame: nil,
                    liveTerminalSessionStateProvider: { _, _ in Self.statePayload(sessionID: sessionID) })

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .notFound)
                XCTAssertNil(response.sessionState)
            }
        }

        /// A `.state` read carries what the reader wants down to the same live core the heartbeat reaches:
        /// the connect bootstrap read asks for metadata alone, and every other read asks for the screen.
        func testStateRequestForwardsWhetherTheReaderWantsTheScreen() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-state-read-\(UUID().uuidString)"
                _ = try seedRunningSession(sessionID: sessionID)

                for includesRenderUpdate in [true, false] {
                    let observedRead = OneShotStateReadRecorder()
                    let response = try send(
                        command: .state(SpacesDeviceTerminalSessionRequest(sessionID: sessionID, includesRenderUpdate: includesRenderUpdate)),
                        liveTerminalSessionStateProvider: { requestedSessionID, requestedRead in
                            observedRead.record(requestedRead)
                            guard requestedSessionID == sessionID else { return nil }
                            return Self.statePayload(sessionID: sessionID)
                        })

                    XCTAssertTrue(response.ok, response.message)
                    XCTAssertEqual(response.sessionState?.sessionID, sessionID)
                    XCTAssertEqual(
                        observedRead.value, includesRenderUpdate ? .screen(heldFrame: nil) : .metadataOnly,
                        "the request's own answer to \"do you want the screen\" is what must reach the core")
                }
            }
        }

        /// A control whose answer carries session state says whether it wants the screen on it, the same
        /// way a `.state` request does. The iOS viewer asks for none on a takeover, because the transfer's
        /// own `attachment_state` broadcast brings it the frame; every other reader keeps the screen and
        /// keeps the held-frame omission with it.
        func testAControlRequestForwardsWhetherTheAcknowledgmentCarriesTheScreen() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-takeover-state-\(UUID().uuidString)"
                let paths = try seedRunningSession(sessionID: sessionID)
                let heldFrame = TerminalHeldFrameIdentity(ownerEpoch: 3, sessionRevision: 9)

                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.takeover-state.test")
                ) { _ in TerminalControlResponse(ok: true, message: "Took over.") }
                try controlServer.start()
                defer { controlServer.stop() }

                for includesRenderUpdate in [true, false] {
                    let observedRead = OneShotStateReadRecorder()
                    let response = try send(
                        command: .terminalControl(
                            SpacesDeviceTerminalControlRequest(
                                action: .takeover, sessionID: sessionID, clientID: "client-takeover-state", heldFrameIdentity: heldFrame,
                                includesRenderUpdate: includesRenderUpdate)),
                        liveTerminalSessionStateProvider: { requestedSessionID, requestedRead in
                            observedRead.record(requestedRead)
                            guard requestedSessionID == sessionID else { return nil }
                            return Self.statePayload(sessionID: sessionID)
                        })

                    XCTAssertTrue(response.ok, response.message)
                    let sessionState = try XCTUnwrap(response.sessionState, "a successful takeover still carries the session's state")
                    XCTAssertEqual(sessionState.sessionID, sessionID)
                    XCTAssertEqual(
                        observedRead.value, includesRenderUpdate ? .screen(heldFrame: heldFrame) : .metadataOnly,
                        "the request's own answer to \"do you want the screen\" is what must reach the core")
                }
            }
        }

        private func sendHeartbeat(
            sessionID: String, clientID: String, heldFrame: TerminalHeldFrameIdentity?,
            liveTerminalSessionStateProvider: @escaping SpacesDeviceAPIServer.LiveTerminalSessionStateProvider
        ) throws -> SpacesDeviceAPIResponse {
            try send(
                command: .terminalControl(
                    SpacesDeviceTerminalControlRequest(action: .heartbeat, sessionID: sessionID, clientID: clientID, heldFrameIdentity: heldFrame)),
                liveTerminalSessionStateProvider: liveTerminalSessionStateProvider)
        }

        private func send(
            command: SpacesDeviceAPICommand, liveTerminalSessionStateProvider: @escaping SpacesDeviceAPIServer.LiveTerminalSessionStateProvider
        ) throws -> SpacesDeviceAPIResponse {
            let identity = try heartbeatStateTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedHeartbeatStatePairingStore()
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                liveTerminalSessionStateProvider: liveTerminalSessionStateProvider)
            try server.start()
            defer { server.stop() }
            let requestClient = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
            defer { requestClient.cancel() }
            return try requestClient.send(
                SpacesDeviceAPIRequest(
                    command: command, authToken: pairingStore.authToken,
                    clientApp: SpacesDeviceClientApp(
                        installationID: "heartbeat-state-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                        deviceName: "Mac", appVersion: "1.0")))
        }

        private func seedRunningSession(sessionID: String) throws -> TerminalSessionPaths {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "zsh", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                    createdAt: "2026-09-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 123,
                    state: .running, updatedAt: "2026-09-09T00:00:01Z"), paths: paths)
            return paths
        }

        /// A frameless payload, which is exactly what the live core exports for a viewer that already
        /// holds the session's current frame.
        private nonisolated static func statePayload(sessionID: String) -> GhosttyRemoteSessionStatePayload {
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-09-09T00:00:02Z",
                sessionStateRevision: 1, sessionStateFlags: nil, screenStateRevision: 42, runtimeState: nil, attachmentSnapshot: nil, title: "zsh",
                workingDirectory: "/tmp", outputByteCount: nil)
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
    }

    private let heartbeatStateTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "spaces-heartbeat-state-tests-tls-\(UUID().uuidString)", isDirectory: true)

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair
    /// only needs a stable certificate to pin.
    private func heartbeatStateTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
        try TerminalServiceTLSIdentityStore.loadOrCreate(root: heartbeatStateTestTLSRoot)
    }

    private final class OneShotStateReadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: TerminalOneShotStateRead?

        func record(_ read: TerminalOneShotStateRead) {
            lock.lock()
            stored = read
            lock.unlock()
        }

        var value: TerminalOneShotStateRead? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class AlwaysAuthorizedHeartbeatStatePairingStore: SpacesDevicePairingStoreProtocol {
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
