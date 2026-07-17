#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    final class TerminalTranscriptServerTests: XCTestCase {
        func testTerminalTranscriptReturnsCappedSuffix() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-transcript-\(UUID().uuidString)"
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()
                let transcript = Data((0..<5000).map { UInt8($0 % 251) })
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let (server, requestClient, clientApp, authToken) = try makeServerAndClient()
                defer {
                    requestClient.cancel()
                    server.stop()
                }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: sessionID, maxBytes: 1000)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let result = try XCTUnwrap(response.terminalTranscript)
                XCTAssertEqual(result.totalBytes, 5000)
                XCTAssertEqual(result.data.count, 1000)
                XCTAssertEqual(result.data, transcript.suffix(1000))
            }
        }

        func testTerminalTranscriptReturnsWholeTranscriptWhenUnderCap() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-transcript-small-\(UUID().uuidString)"
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()
                let transcript = Data("hello world".utf8)
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let (server, requestClient, clientApp, authToken) = try makeServerAndClient()
                defer {
                    requestClient.cancel()
                    server.stop()
                }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: sessionID, maxBytes: 1_000_000)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let result = try XCTUnwrap(response.terminalTranscript)
                XCTAssertEqual(result.totalBytes, UInt64(transcript.count))
                XCTAssertEqual(result.data, transcript)
            }
        }

        func testTerminalTranscriptMissingOutputErrors() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-transcript-missing-\(UUID().uuidString)"
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()

                let (server, requestClient, clientApp, authToken) = try makeServerAndClient()
                defer {
                    requestClient.cancel()
                    server.stop()
                }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: sessionID, maxBytes: 1000)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .sessionNotAvailable)
            }
        }

        private func makeServerAndClient() throws -> (SpacesDeviceAPIServer, SpacesDeviceAPIRequestSessionClient, SpacesDeviceClientApp, String) {
            let identity = try transcriptTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedTranscriptPairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            let requestClient = try SpacesDeviceAPIRequestSessionClient(
                host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            let clientApp = SpacesDeviceClientApp(
                installationID: "transcript-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                appVersion: "1.0")
            return (server, requestClient, clientApp, pairingStore.authToken)
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

    private let transcriptTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "spaces-transcript-tests-tls-\(UUID().uuidString)", isDirectory: true)

    private func transcriptTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
        try TerminalServiceTLSIdentityStore.loadOrCreate(root: transcriptTestTLSRoot)
    }

    private final class AlwaysAuthorizedTranscriptPairingStore: SpacesDevicePairingStoreProtocol {
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
