#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    final class TerminalPasteImageServerTests: XCTestCase {
        func testTerminalPasteImageWritesUserOnlyTempFileAndInjectsPath() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-image-paste-\(UUID().uuidString)"
                let clientID = "client-image-paste"
                let ownerEpoch: UInt64 = 9
                let paths = try seedOwnedRunningSession(sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch)

                let recorder = TerminalPasteImageControlRecorder()
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.paste-image.test")
                ) { request in
                    recorder.record(request)
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer { controlServer.stop() }

                let identity = try pasteImageTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedPasteImagePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let requestClient = try SpacesDeviceAPIRequestSessionClient(
                    host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                defer { requestClient.cancel() }
                let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                let clientApp = SpacesDeviceClientApp(
                    installationID: "paste-image-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                    appVersion: "1.0")

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .terminalPasteImage(
                            SpacesDeviceTerminalPasteImageRequest(
                                sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch, fileExtension: "png", imageData: imageData)),
                        authToken: pairingStore.authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let terminalRequest = try XCTUnwrap(recorder.waitForRequest(timeout: 5))
                let remotePath = try XCTUnwrap(terminalRequest.text)
                defer { try? FileManager.default.removeItem(atPath: remotePath) }
                XCTAssertEqual(terminalRequest.command, "send")
                XCTAssertEqual(terminalRequest.clientID, clientID)
                XCTAssertEqual(terminalRequest.ownerEpoch, ownerEpoch)
                XCTAssertTrue(remotePath.hasPrefix("/tmp/spaces-paste-"))
                XCTAssertTrue(remotePath.hasSuffix(".png"))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remotePath)), imageData)
                let permissions =
                    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: remotePath)[.posixPermissions] as? NSNumber).intValue & 0o777
                XCTAssertEqual(permissions, 0o600)
            }
        }

        func testTerminalPasteImageRemovesTempFileWhenControlRejectsInjectedPath() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-image-paste-reject-\(UUID().uuidString)"
                let clientID = "client-image-paste"
                let ownerEpoch: UInt64 = 10
                let paths = try seedOwnedRunningSession(sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch)

                let recorder = TerminalPasteImageControlRecorder()
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.paste-image.reject.test")
                ) { request in
                    recorder.record(request)
                    return TerminalControlResponse(ok: false, message: "Only the active owner can send input.")
                }
                try controlServer.start()
                defer { controlServer.stop() }

                let identity = try pasteImageTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedPasteImagePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let requestClient = try SpacesDeviceAPIRequestSessionClient(
                    host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                defer { requestClient.cancel() }
                let clientApp = SpacesDeviceClientApp(
                    installationID: "paste-image-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                    appVersion: "1.0")

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .terminalPasteImage(
                            SpacesDeviceTerminalPasteImageRequest(
                                sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch, fileExtension: "png",
                                imageData: Data([0x89, 0x50, 0x4E, 0x47]))), authToken: pairingStore.authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                let remotePath = try XCTUnwrap(recorder.waitForRequest(timeout: 5)?.text)
                XCTAssertFalse(FileManager.default.fileExists(atPath: remotePath))
            }
        }

        private func seedOwnedRunningSession(sessionID: String, clientID: String, ownerEpoch: UInt64) throws -> TerminalSessionPaths {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "cat", workingDirectory: "/tmp", shell: "/bin/zsh", command: "cat",
                    createdAt: "2026-07-02T00:00:00Z"), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 123,
                    state: .running, updatedAt: "2026-07-02T00:00:01Z"), paths: paths)
            let terminalClient = TerminalClient(
                id: clientID, kind: .remoteViewer, identity: TerminalClientIdentity(label: "Remote Mac"), connectedAt: "2026-07-02T00:00:01Z",
                leaseRefreshedAt: "2026-07-02T00:00:01Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: sessionID, client: terminalClient, mode: .owner, paths: paths, attachedAt: "2026-07-02T00:00:01Z")
            try TerminalSessionPersistence.writeRemoteSessionState(remoteStatePayload(sessionID: sessionID, ownerEpoch: ownerEpoch), paths: paths)
            return paths
        }

        private func remoteStatePayload(sessionID: String, ownerEpoch: UInt64) throws -> GhosttyRemoteSessionStatePayload {
            let snapshot = GhosttyTerminalSnapshot(
                columns: 1, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0,
                cells: [GhosttyTerminalSnapshot.Cell(codepoint: 32, foregroundRGB: 0xFFFFFF, backgroundRGB: 0, flags: 0)])
            let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: ownerEpoch, snapshot: snapshot)
            return GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-07-02T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: nil, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "cat", workingDirectory: "/tmp",
                outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
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

    private let pasteImageTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "spaces-paste-image-tests-tls-\(UUID().uuidString)", isDirectory: true)

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair
    /// only needs a stable certificate to pin.
    private func pasteImageTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
        try TerminalServiceTLSIdentityStore.loadOrCreate(root: pasteImageTestTLSRoot)
    }

    private final class TerminalPasteImageControlRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var request: TerminalControlRequest?

        func record(_ request: TerminalControlRequest) {
            lock.lock()
            self.request = request
            lock.unlock()
            semaphore.signal()
        }

        func waitForRequest(timeout: TimeInterval) -> TerminalControlRequest? {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return request
        }
    }

    private final class AlwaysAuthorizedPasteImagePairingStore: SpacesDevicePairingStoreProtocol {
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
