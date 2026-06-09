import Darwin
import Foundation
import Network
import XCTest
import spacesmobilecore
import spacesterminalcore
import workspacecore

@testable import spacesmobilebridge

final class SpacesMobileBridgeServerTransportTests: XCTestCase {
    func testTLSPskClientCanPairAndPlaintextClientCannotReadResponse() throws {
        try withTemporaryProfile { _ in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let server = try SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey)
            try server.start()
            defer { server.stop() }

            let window = server.openPairingWindow(host: "127.0.0.1", name: "Test Mac", code: "12345678", nonce: "NONCE")
            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-TLS", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
                appVersion: "1.0")
            let response = try sendTLSRequest(
                SpacesMobileBridgeRequest(command: "pair", pairingCode: window.code, pairingNonce: window.nonce, clientApp: clientApp),
                port: server.listeningPort, transportKey: transportKey)

            XCTAssertTrue(response.ok)
            XCTAssertNotNil(response.issuedAuthToken)
            XCTAssertFalse(try plaintextReceivesBridgeResponse(port: server.listeningPort))
        }
    }

    func testUnsupportedBundleDoesNotConsumePairingWindow() throws {
        try withTemporaryProfile { _ in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let server = try SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey)
            try server.start()
            defer { server.stop() }

            let window = server.openPairingWindow(host: "127.0.0.1", name: "Test Mac", code: "12345678", nonce: "NONCE")
            let unsupportedClientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-UNSUPPORTED", bundleID: "com.example.thirdparty", platform: "ios", deviceName: "Third Party",
                appVersion: "1.0")

            let rejectedResponse = try sendTLSRequest(
                SpacesMobileBridgeRequest(command: "pair", pairingCode: window.code, pairingNonce: window.nonce, clientApp: unsupportedClientApp),
                port: server.listeningPort, transportKey: transportKey)
            XCTAssertFalse(rejectedResponse.ok)
            XCTAssertTrue(rejectedResponse.message.contains("Unsupported mobile bundle"))

            let supportedClientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-SUPPORTED", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let acceptedResponse = try sendTLSRequest(
                SpacesMobileBridgeRequest(command: "pair", pairingCode: window.code, pairingNonce: window.nonce, clientApp: supportedClientApp),
                port: server.listeningPort, transportKey: transportKey)

            XCTAssertTrue(acceptedResponse.ok)
            XCTAssertNotNil(acceptedResponse.issuedAuthToken)
        }
    }

    func testMismatchedTransportKeyLeavesReachablePortForRecoveryProbe() throws {
        try withTemporaryProfile { _ in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let server = try SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey)
            try server.start()
            defer { server.stop() }

            let staleTransportKey = SpacesMobileBridgeSettings.generateTransportKey()
            switch try tlsConnectionOutcome(port: server.listeningPort, transportKey: staleTransportKey) {
            case .ready: XCTFail("A stale transport key should not complete the TLS handshake.")
            case .failed(let error):
                XCTAssertEqual(
                    SpacesMobileBridgeAuthentication.recoveryMessage(for: error),
                    "This Mac no longer recognizes this device. Open Connection and pair this device again.")
            case .timedOut:
                XCTAssertFalse(try plaintextReceivesBridgeResponse(port: server.listeningPort))
                let probeError = NSError(
                    domain: "SpacesMobileBridgeClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The secure mobile bridge transport could not authenticate."])
                XCTAssertEqual(
                    SpacesMobileBridgeAuthentication.recoveryMessage(for: probeError),
                    "This Mac no longer recognizes this device. Open Connection and pair this device again.")
            }
        }
    }

    func testPartialTLSRequestEOFIsRejected() throws {
        try withTemporaryProfile { _ in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let server = try SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey)
            try server.start()
            defer { server.stop() }

            XCTAssertTrue(try partialTLSRequestEOFClosesConnection(port: server.listeningPort, transportKey: transportKey, server: server))
        }
    }

    func testTerminalLinkResolveRequiresAuthentication() throws {
        try withTemporaryProfile { _ in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let server = try SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-LINK-AUTH", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let response = try sendTLSRequest(
                SpacesMobileBridgeRequest(command: "resolveTerminalLink", clientApp: clientApp, sessionID: "session-1", terminalLink: "image.png"),
                port: server.listeningPort, transportKey: transportKey)

            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.message.localizedStandardContains("mobile auth token"))
            XCTAssertNil(response.terminalLinkMetadata)
        }
    }

    func testTerminalLinkWorkspaceRootLookupErrorsPropagate() throws {
        try withTemporaryProfile { root in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let pairingStore = AlwaysAuthorizedMobilePairingStore()
            let server = SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-LINK-ROOTS", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let invalidDatabasePath = root.appendingPathComponent("not-a-database", isDirectory: true)
            try FileManager.default.createDirectory(at: invalidDatabasePath, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", invalidDatabasePath.path, 1)
            let response = try sendTLSRequest(
                SpacesMobileBridgeRequest(
                    command: "resolveTerminalLink", authToken: pairingStore.authToken, clientApp: clientApp, sessionID: "session-1",
                    terminalLink: "image.png"), port: server.listeningPort, transportKey: transportKey)

            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.message.localizedStandardContains("Failed opening sqlite db"), response.message)
            XCTAssertFalse(response.message.localizedStandardContains("blocked path"), response.message)
            XCTAssertFalse(response.message.localizedStandardContains("invalid link"), response.message)
        }
    }

    func testTerminalLinkExternalResolveSkipsWorkspaceRootLookupAndSessionState() throws {
        try withTemporaryProfile { root in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let pairingStore = AlwaysAuthorizedMobilePairingStore()
            let server = SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-LINK-EXTERNAL", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")

            let invalidDatabasePath = root.appendingPathComponent("external-unavailable-spaces-db", isDirectory: true)
            try FileManager.default.createDirectory(at: invalidDatabasePath, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", invalidDatabasePath.path, 1)
            let response = try sendTLSRequest(
                SpacesMobileBridgeRequest(
                    command: "resolveTerminalLink", authToken: pairingStore.authToken, clientApp: clientApp, sessionID: "missing-session",
                    terminalLink: "https://example.com/screenshot.png"), port: server.listeningPort, transportKey: transportKey)

            XCTAssertTrue(response.ok, response.message)
            let metadata = try XCTUnwrap(response.terminalLinkMetadata)
            XCTAssertEqual(metadata.source, .externalURL)
            XCTAssertEqual(metadata.externalURL, "https://example.com/screenshot.png")
            XCTAssertEqual(metadata.mediaKind, .image)
            XCTAssertFalse(response.message.localizedStandardContains("sqlite"), response.message)
        }
    }

    func testTerminalLinkChunkReadUsesResolvedTransferAuthorizationWhenDatabaseBecomesUnavailable() throws {
        try withTemporaryProfile { root in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let pairingStore = AlwaysAuthorizedMobilePairingStore()
            let server = SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-LINK-CACHED", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let sessionID = "session-link-cached-\(UUID().uuidString)"
            let workspaceDir = try makeWorkspaceRootProfile(root: root, sessionID: sessionID)
            let image = workspaceDir.appendingPathComponent("preview.png")
            let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
            try imageData.write(to: image)

            let resolveResponse = try sendTLSRequest(
                SpacesMobileBridgeRequest(
                    command: "resolveTerminalLink", authToken: pairingStore.authToken, clientApp: clientApp, sessionID: sessionID,
                    terminalLink: "preview.png"), port: server.listeningPort, transportKey: transportKey)
            let metadata = try XCTUnwrap(resolveResponse.terminalLinkMetadata)
            XCTAssertTrue(resolveResponse.ok)
            XCTAssertEqual(metadata.source, .localFile)

            let invalidDatabasePath = root.appendingPathComponent("unavailable-spaces-db", isDirectory: true)
            try FileManager.default.createDirectory(at: invalidDatabasePath, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", invalidDatabasePath.path, 1)

            let chunkResponse = try sendTLSRequest(
                SpacesMobileBridgeRequest(
                    command: "readTerminalLinkChunk", authToken: pairingStore.authToken, clientApp: clientApp, sessionID: sessionID,
                    terminalLinkID: metadata.id, chunkOffset: 0, chunkLimit: 16), port: server.listeningPort, transportKey: transportKey)

            XCTAssertTrue(chunkResponse.ok, chunkResponse.message)
            let chunk = try XCTUnwrap(chunkResponse.terminalLinkChunk)
            XCTAssertEqual(Data(base64Encoded: chunk.base64Data), imageData)
            XCTAssertTrue(chunk.isFinal)
        }
    }

    func testTerminalLinkChunkReadRefreshesResolvedTransferAuthorization() throws {
        try withTemporaryProfile { root in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let pairingStore = AlwaysAuthorizedMobilePairingStore()
            let server = SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-LINK-REFRESH", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let sessionID = "session-link-refresh-\(UUID().uuidString)"
            let workspaceDir = try makeWorkspaceRootProfile(root: root, sessionID: sessionID)
            let image = workspaceDir.appendingPathComponent("preview-refresh.png")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02]).write(to: image)

            let resolveResponse = try sendTLSRequest(
                SpacesMobileBridgeRequest(
                    command: "resolveTerminalLink", authToken: pairingStore.authToken, clientApp: clientApp, sessionID: sessionID,
                    terminalLink: "preview-refresh.png"), port: server.listeningPort, transportKey: transportKey)
            let metadata = try XCTUnwrap(resolveResponse.terminalLinkMetadata)
            let originalExpiration = try XCTUnwrap(server.terminalLinkTransferAuthorizationExpirationForTesting(linkID: metadata.id))

            let chunkResponse = try sendTLSRequest(
                SpacesMobileBridgeRequest(
                    command: "readTerminalLinkChunk", authToken: pairingStore.authToken, clientApp: clientApp, sessionID: sessionID,
                    terminalLinkID: metadata.id, chunkOffset: 0, chunkLimit: 4), port: server.listeningPort, transportKey: transportKey)

            XCTAssertTrue(chunkResponse.ok, chunkResponse.message)
            let refreshedExpiration = try XCTUnwrap(server.terminalLinkTransferAuthorizationExpirationForTesting(linkID: metadata.id))
            XCTAssertGreaterThan(refreshedExpiration.timeIntervalSince1970, originalExpiration.timeIntervalSince1970)
        }
    }

    func testTerminalLinkChunkReadRejectsNeverResolvedLocalLinkWithoutWorkspaceRootScan() throws {
        try withTemporaryProfile { root in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let pairingStore = AlwaysAuthorizedMobilePairingStore()
            let server = SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-LINK-FORGED", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let image = root.appendingPathComponent("forged.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
            let metadata = try SpacesMobileTerminalLinkResolver.resolve(
                sessionID: "session-forged", link: image.path, workingDirectory: nil, homeDirectory: root.path)

            let invalidDatabasePath = root.appendingPathComponent("forged-unavailable-spaces-db", isDirectory: true)
            try FileManager.default.createDirectory(at: invalidDatabasePath, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", invalidDatabasePath.path, 1)
            let response = try sendTLSRequest(
                SpacesMobileBridgeRequest(
                    command: "readTerminalLinkChunk", authToken: pairingStore.authToken, clientApp: clientApp, sessionID: "session-forged",
                    terminalLinkID: metadata.id, chunkOffset: 0, chunkLimit: 4), port: server.listeningPort, transportKey: transportKey)

            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.message.localizedStandardContains("terminal link transfer id is invalid"), response.message)
            XCTAssertFalse(response.message.localizedStandardContains("sqlite"), response.message)
        }
    }

    private enum BridgeTransportConnectionOutcome {
        case ready
        case failed(Error)
        case timedOut
    }

    private func tlsConnectionOutcome(port: Int, transportKey: String) throws -> BridgeTransportConnectionOutcome {
        let finished = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.mobile.bridge.transport.outcome.test")
        let resultBox = BridgeTransportTestResultBox()
        let connection = NWConnection(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))),
            using: try SpacesMobileBridgeTransport.parameters(transportKey: transportKey, role: .client))

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finished.signal()
            case .failed(let error):
                resultBox.setError(error)
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

    private func sendTLSRequest(_ request: SpacesMobileBridgeRequest, port: Int, transportKey: String) throws -> SpacesMobileBridgeResponse {
        let ready = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.mobile.bridge.transport.test")
        let resultBox = BridgeTransportTestResultBox()
        let connection = NWConnection(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))),
            using: try SpacesMobileBridgeTransport.parameters(transportKey: transportKey, role: .client))

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

        var requestData = try SpacesMobileBridgeCodec.encodeRequest(request)
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
        return try SpacesMobileBridgeCodec.decodeResponse(resultBox.responseData())
    }

    private func plaintextReceivesBridgeResponse(port: Int) throws -> Bool {
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
        var requestData = try SpacesMobileBridgeCodec.encodeRequest(SpacesMobileBridgeRequest(command: "ping"))
        requestData.append(0x0A)
        _ = requestData.withUnsafeBytes { rawBuffer in write(socketFD, rawBuffer.baseAddress, rawBuffer.count) }

        var buffer = [UInt8](repeating: 0, count: 512)
        let count = read(socketFD, &buffer, buffer.count)
        guard count > 0 else { return false }
        return (try? SpacesMobileBridgeCodec.decodeResponse(Data(buffer.prefix(count)))) != nil
    }

    private func partialTLSRequestEOFClosesConnection(port: Int, transportKey: String, server: SpacesMobileBridgeServer) throws -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.mobile.bridge.partial-eof.test")
        let resultBox = BridgeTransportTestResultBox()
        let connection = NWConnection(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))),
            using: try SpacesMobileBridgeTransport.parameters(transportKey: transportKey, role: .client))

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

        let requestData = try SpacesMobileBridgeCodec.encodeRequest(SpacesMobileBridgeRequest(command: "ping"))
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

    private func waitForRequestConnectionCount(_ expectedCount: Int, on server: SpacesMobileBridgeServer, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if server.requestConnectionCountForTesting == expectedCount { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return server.requestConnectionCountForTesting == expectedCount
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
            id: "workspace-\(sessionID)", projectID: project.id, title: "Workspace", dir: workspaceDir.path, dirname: nil, branch: nil,
            isDefault: true, isArchived: false, isRunning: true, lastLaunchedAt: nil)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "terminal", workingDirectory: workspaceDir.path, shell: "/bin/zsh", command: nil,
                createdAt: "2026-06-09T12:00:00Z"), paths: paths)
        return workspaceDir
    }
}

private final class AlwaysAuthorizedMobilePairingStore: SpacesMobilePairingStoreProtocol {
    let authToken = "valid-token"

    func issueToken(for _: SpacesMobileClientApp) throws -> String { authToken }
    func listDevices() throws -> [SpacesMobilePairedDevice] { [] }
    func revoke(installationID _: String) throws {}
    func removeAll() throws {}
    func authorize(clientApp: SpacesMobileClientApp?, authToken: String?) throws {
        guard clientApp != nil, authToken == self.authToken else {
            throw NSError(domain: "SpacesMobileBridgeServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid mobile auth token."])
        }
    }
    func validate(clientApp _: SpacesMobileClientApp) throws {}
}

private final class BridgeTransportTestResultBox: @unchecked Sendable {
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
