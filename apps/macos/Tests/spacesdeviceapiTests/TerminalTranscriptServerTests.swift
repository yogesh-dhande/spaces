#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    final class TerminalTranscriptServerTests: XCTestCase {
        func testTerminalTranscriptCappedSuffixStartsAtALineBoundary() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-transcript-\(UUID().uuidString)"
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()
                // 500 lines of exactly 10 bytes each ("line-0042\n"), so a 995-byte cap lands
                // mid-line and the returned suffix must advance to the next line boundary.
                let transcript = Data((0..<500).map { String(format: "line-%04d\n", $0) }.joined().utf8)
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let (server, requestClient, clientApp, authToken) = try makeServerAndClient()
                defer {
                    requestClient.cancel()
                    server.stop()
                }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: sessionID, maxBytes: 995)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let result = try XCTUnwrap(response.terminalTranscript)
                XCTAssertEqual(result.totalBytes, 5000)
                XCTAssertEqual(result.data, transcript.suffix(990))
                // The read is bounded to the size snapshot, so the returned suffix never exceeds the cap
                // even if the session were still appending output past the snapshotted EOF.
                XCTAssertLessThanOrEqual(result.data.count, 995)
                let text = try XCTUnwrap(String(data: result.data, encoding: .utf8))
                XCTAssertTrue(text.hasPrefix("line-"), "capped suffix should start on a whole line, got: \(text.prefix(20))")
            }
        }

        func testTerminalTranscriptCappedSuffixWithoutNewlinesIsReturnedRaw() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-transcript-raw-\(UUID().uuidString)"
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()
                let transcript = Data(repeating: UInt8(ascii: "x"), count: 5000)
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

        func testTerminalTranscriptReportsTheRunIdentityFromRuntimeState() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-transcript-identity-\(UUID().uuidString)"
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()
                try Data("hello".utf8).write(to: URL(fileURLWithPath: paths.outputPath))
                // A runtime row hangs off the session's own `terminal_sessions` row, which the session host
                // writes before its first runtime-state write.
                try TerminalSessionPersistence.writeLaunchConfiguration(
                    TerminalSessionLaunchConfiguration(
                        sessionID: sessionID, title: "transcript", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
                        createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
                // The persisted runtime state's child PID + exit time identify the run the transcript was
                // read from; the response must carry that identity so a client can reject a fetch that
                // straddled a relaunch.
                let runtimeState = TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 4242, state: .exited, updatedAt: "2026-06-05T00:00:09Z",
                    exitedAt: "2026-06-05T00:00:09Z", columns: 8, rows: 5)
                try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)

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
                XCTAssertEqual(result.runIdentity, "4242|2026-06-05T00:00:09Z")
                XCTAssertEqual(result.runIdentity, runtimeState.runIdentity)
            }
        }

        func testTerminalTranscriptRunIdentityIsNilWhenNoRuntimeStateExists() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-transcript-no-runtime-\(UUID().uuidString)"
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()
                try Data("hello".utf8).write(to: URL(fileURLWithPath: paths.outputPath))

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
                XCTAssertNil(result.runIdentity)
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
