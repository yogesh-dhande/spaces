import Darwin
import Foundation
import Network
import XCTest
import spacesmobilecore
import spacesterminalcore

@testable import spacesmobilebridge

@MainActor final class SpacesMobileBridgeSupervisorTests: XCTestCase {
    func testControlStatusRelaunchesTerminalServiceWhenControlEndpointIsMissing() throws {
        var ensureCount = 0
        var relaunchCount = 0
        var statusCount = 0

        let response = try SpacesMobileBridgeControlClient.statusEnsuringCurrentTerminalService(
            timeout: 1,
            ensureRunning: { _ in
                ensureCount += 1
                return false
            },
            relaunch: { _ in
                relaunchCount += 1
                return true
            },
            status: { _ in
                statusCount += 1
                if statusCount == 1 { throw POSIXError(.ENOENT) }
                return SpacesMobileBridgeControlResponse(ok: true, message: "Loaded mobile bridge status.")
            })

        XCTAssertTrue(response.ok)
        XCTAssertEqual(ensureCount, 1)
        XCTAssertEqual(relaunchCount, 1)
        XCTAssertEqual(statusCount, 2)
    }

    func testControlStatusDoesNotRelaunchTerminalServiceForNonEndpointFailure() throws {
        var relaunchCount = 0

        XCTAssertThrowsError(
            try SpacesMobileBridgeControlClient.statusEnsuringCurrentTerminalService(
                timeout: 1, ensureRunning: { _ in false },
                relaunch: { _ in
                    relaunchCount += 1
                    return true
                }, status: { _ in throw POSIXError(.EACCES) }))
        XCTAssertEqual(relaunchCount, 0)
    }

    func testOpenPairingWindowUsesStableFallbackPortWhenConfiguredPortIsUnavailable() async throws {
        try await withTemporaryProfile { _ in
            let occupiedSocket = try makeOccupiedPortSocket()
            defer { close(occupiedSocket.fileDescriptor) }
            let settingsStore = SpacesMobileBridgeSettingsStore()
            let expectedFallbackPorts = try settingsStore.stableFallbackPorts()

            let environment = [
                SpacesMobileBridgeDefaults.portEnvironmentVariable: "\(occupiedSocket.port)",
                SpacesMobileBridgeDefaults.transportKeyEnvironmentVariable: SpacesMobileBridgeSettings.generateTransportKey(),
            ]
            let supervisor = SpacesMobileBridgeSupervisor(
                settingsStore: SpacesMobileBridgeSettingsStore(environment: environment), environment: environment, restartInterval: 60)
            supervisor.start()
            defer { supervisor.stop() }

            let status = try supervisor.status()
            XCTAssertEqual(status.host, SpacesMobileBridgeDefaults.host)
            XCTAssertTrue(expectedFallbackPorts.contains(status.port))

            let response = try await Task.detached { try SpacesMobileBridgeControlClient.openPairingWindow() }.value
            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.status?.port, status.port)
            XCTAssertNotNil(response.pairingWindow)
            XCTAssertEqual(try settingsStore.loadOrCreate().port, status.port)
        }
    }

    func testOpenPairingWindowDoesNotEmitIPv6WildcardHost() async throws {
        try await withTemporaryProfile { _ in
            let environment = [
                SpacesMobileBridgeDefaults.hostEnvironmentVariable: "::", SpacesMobileBridgeDefaults.portEnvironmentVariable: "0",
                SpacesMobileBridgeDefaults.transportKeyEnvironmentVariable: SpacesMobileBridgeSettings.generateTransportKey(),
            ]
            let supervisor = SpacesMobileBridgeSupervisor(
                settingsStore: SpacesMobileBridgeSettingsStore(environment: environment), environment: environment, restartInterval: 60)
            supervisor.start()
            defer { supervisor.stop() }

            let response = try await Task.detached { try SpacesMobileBridgeControlClient.openPairingWindow() }.value
            let linkString = try XCTUnwrap(response.pairingWindow?.linkString)
            let link = try SpacesMobilePairingLink.parse(linkString)

            XCTAssertTrue(response.ok)
            XCTAssertNotEqual(link.host, "::")
            XCTAssertFalse(SpacesMobileBridgeDefaults.isWildcardHost(link.host))
        }
    }

    func testWildcardPairingLinkHostPrefersHardwareLANAddress() {
        let activeFlags = IFF_UP | IFF_RUNNING
        let addresses = SpacesMobileBridgeNetworkInterfaces.sortedIPv4Addresses(from: [
            .init(name: "utun4", address: "100.64.12.34", flags: activeFlags | IFF_POINTOPOINT, discoveryIndex: 0),
            .init(name: "vmnet8", address: "192.168.64.1", flags: activeFlags, discoveryIndex: 1),
            .init(name: "en0", address: "192.168.1.24", flags: activeFlags, discoveryIndex: 2),
            .init(name: "bridge100", address: "192.168.2.1", flags: activeFlags, discoveryIndex: 3),
        ])

        XCTAssertEqual(addresses.first, "192.168.1.24")
        XCTAssertEqual(SpacesMobileBridgeNetworkInterfaces.pairingLinkHost(boundHost: "0.0.0.0", networkAddresses: addresses), "192.168.1.24")
    }

    func testStateHistorySeedReturnsFullReplayWhenOutputFitsBudget() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-history-full-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "history", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                    command: "cat", createdAt: "2026-05-26T00:00:00Z"), paths: paths)

            let outputLog = Data("\u{1B}[32mREADY\u{1B}[0m\n".utf8)
            try outputLog.write(to: URL(fileURLWithPath: paths.outputPath))

            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-HISTORY-FULL", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let authToken = try SpacesMobilePairingStore().issueToken(for: clientApp)
            let server = try SpacesMobileBridgeServer(host: SpacesMobileBridgeDefaults.loopbackHost, port: 0, transportKey: transportKey)
            try server.start()
            defer { server.stop() }

            let response = try await Task.detached {
                try Self.sendBridgeRequest(
                    SpacesMobileBridgeRequest(
                        command: "state", authToken: authToken, clientApp: clientApp, sessionID: sessionID, includeOutputHistory: true),
                    port: server.listeningPort, transportKey: transportKey)
            }.value

            XCTAssertEqual(response.sessionState?.outputData, outputLog)
            XCTAssertEqual(response.sessionState?.outputByteCount, outputLog.count)
            XCTAssertEqual(response.sessionState?.outputEndByteOffset, outputLog.count)
        }
    }

    func testStateHistorySeedOmitsPartialReplayWhenOutputExceedsBudget() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-history-tail-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "tail", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                    createdAt: "2026-05-26T00:00:00Z"), paths: paths)

            let droppedPrefix = Data("DROP-MARKER\n".utf8)
            let tailMarker = Data("\nTAIL-MARKER".utf8)
            var outputLog = droppedPrefix
            outputLog.append(Data(repeating: 0x41, count: SpacesMobileBridgeServer.maxHistorySeedOutputBytes + 1024))
            outputLog.append(tailMarker)
            try outputLog.write(to: URL(fileURLWithPath: paths.outputPath))

            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-HISTORY-TAIL", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let authToken = try SpacesMobilePairingStore().issueToken(for: clientApp)
            let server = try SpacesMobileBridgeServer(host: SpacesMobileBridgeDefaults.loopbackHost, port: 0, transportKey: transportKey)
            try server.start()
            defer { server.stop() }

            let response = try await Task.detached {
                try Self.sendBridgeRequest(
                    SpacesMobileBridgeRequest(
                        command: "state", authToken: authToken, clientApp: clientApp, sessionID: sessionID, includeOutputHistory: true),
                    port: server.listeningPort, transportKey: transportKey)
            }.value

            XCTAssertNil(response.sessionState?.outputData)
            XCTAssertEqual(response.sessionState?.outputByteCount, outputLog.count)
            XCTAssertEqual(response.sessionState?.outputEndByteOffset, outputLog.count)
        }
    }

    func testRevokeDeviceClosesActiveSubscribeConnection() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-revoke-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            let subscriptionServer = MobileBridgeTestSubscriptionServer(socketPath: paths.subscriptionSocketPath)
            try subscriptionServer.start()
            defer { subscriptionServer.stop() }

            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let environment = [SpacesMobileBridgeDefaults.transportKeyEnvironmentVariable: transportKey]
            let settingsStore = SpacesMobileBridgeSettingsStore(environment: environment)
            _ = try settingsStore.updatePort(makeAvailablePort())

            let clientApp = SpacesMobileClientApp(
                installationID: "INSTALLATION-REVOKE", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
                appVersion: "1.0")
            let authToken = try SpacesMobilePairingStore().issueToken(for: clientApp)

            let supervisor = SpacesMobileBridgeSupervisor(settingsStore: settingsStore, environment: environment, restartInterval: 60)
            supervisor.start()
            defer { supervisor.stop() }

            let status = try supervisor.status()
            let connection = try startSubscribeConnection(
                sessionID: sessionID, clientApp: clientApp, authToken: authToken, port: status.port, transportKey: transportKey)
            defer { connection.cancel() }

            XCTAssertTrue(subscriptionServer.waitForAccepted(timeout: 5))

            let response = try await Task.detached { try SpacesMobileBridgeControlClient.revokeDevice(installationID: clientApp.installationID) }
                .value
            XCTAssertTrue(response.ok)
            XCTAssertTrue(waitForConnectionClosure(connection, timeout: 5))
        }
    }

    func testRevokePairingWaitsForInFlightBridgeAuthorizationBeforeSaving() throws {
        let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
        let clientApp = SpacesMobileClientApp(
            installationID: "INSTALLATION-REVOKE-RACE", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
            appVersion: "1.0")
        let pairingStore = BlockingAuthorizePairingStore(clientApp: clientApp)
        let server = SpacesMobileBridgeServer(
            host: SpacesMobileBridgeDefaults.loopbackHost, port: 0, transportKey: transportKey, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let requestFinished = DispatchSemaphore(value: 0)
        let requestResult = MobileBridgeSupervisorTestResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try Self.sendBridgeRequest(
                    SpacesMobileBridgeRequest(command: "ping", authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                    transportKey: transportKey)
                requestResult.setResponse(response)
            } catch { requestResult.setError(error) }
            requestFinished.signal()
        }

        XCTAssertTrue(pairingStore.waitForAuthorizeStarted(timeout: 5))

        let revokeFinished = DispatchSemaphore(value: 0)
        let revokeResult = MobileBridgeSupervisorTestResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do { revokeResult.setDevices(try server.revokePairing(installationID: clientApp.installationID)) } catch { revokeResult.setError(error) }
            revokeFinished.signal()
        }

        if revokeFinished.wait(timeout: .now() + 0.2) == .success { XCTFail("revoke should wait for the in-flight bridge authorization to finish") }

        pairingStore.finishAuthorize()

        guard requestFinished.wait(timeout: .now() + 5) == .success else {
            XCTFail("timed out waiting for the bridge request")
            return
        }
        guard revokeFinished.wait(timeout: .now() + 5) == .success else {
            XCTFail("timed out waiting for revoke")
            return
        }

        XCTAssertNil(requestResult.error())
        XCTAssertEqual(requestResult.response()?.ok, true)
        XCTAssertNil(revokeResult.error())
        XCTAssertEqual(revokeResult.devices(), [])
        XCTAssertEqual(try pairingStore.listDevices(), [])
    }

    func testResetPairingsWaitsForInFlightBridgeAuthorizationBeforeSaving() throws {
        let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
        let clientApp = SpacesMobileClientApp(
            installationID: "INSTALLATION-RESET-RACE", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
            appVersion: "1.0")
        let pairingStore = BlockingAuthorizePairingStore(clientApp: clientApp)
        let server = SpacesMobileBridgeServer(
            host: SpacesMobileBridgeDefaults.loopbackHost, port: 0, transportKey: transportKey, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let requestFinished = DispatchSemaphore(value: 0)
        let requestResult = MobileBridgeSupervisorTestResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try Self.sendBridgeRequest(
                    SpacesMobileBridgeRequest(command: "ping", authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                    transportKey: transportKey)
                requestResult.setResponse(response)
            } catch { requestResult.setError(error) }
            requestFinished.signal()
        }

        XCTAssertTrue(pairingStore.waitForAuthorizeStarted(timeout: 5))

        let resetFinished = DispatchSemaphore(value: 0)
        let resetResult = MobileBridgeSupervisorTestResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.resetPairingsAndStop()
                resetResult.setFlag(true)
            } catch { resetResult.setError(error) }
            resetFinished.signal()
        }

        if resetFinished.wait(timeout: .now() + 0.2) == .success { XCTFail("reset should wait for the in-flight bridge authorization to finish") }

        pairingStore.finishAuthorize()

        guard resetFinished.wait(timeout: .now() + 5) == .success else {
            XCTFail("timed out waiting for reset")
            return
        }
        guard requestFinished.wait(timeout: .now() + 5) == .success else {
            XCTFail("timed out waiting for the bridge request")
            return
        }

        XCTAssertNil(resetResult.error())
        XCTAssertTrue(resetResult.flag())
        XCTAssertEqual(try pairingStore.listDevices(), [])
    }

    private func makeOccupiedPortSocket() throws -> (fileDescriptor: Int32, port: Int) {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr(SpacesMobileBridgeDefaults.loopbackHost))
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard Darwin.listen(fileDescriptor, 1) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

            var boundAddress = sockaddr_in()
            var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    getsockname(fileDescriptor, sockaddrPointer, &boundAddressLength)
                }
            }
            guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return (fileDescriptor, Int(UInt16(bigEndian: boundAddress.sin_port)))
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    private func makeAvailablePort() throws -> Int {
        let socket = try makeOccupiedPortSocket()
        close(socket.fileDescriptor)
        return socket.port
    }

    private func startSubscribeConnection(sessionID: String, clientApp: SpacesMobileClientApp, authToken: String, port: Int, transportKey: String)
        throws -> NWConnection
    {
        let ready = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.mobile.bridge.supervisor.subscribe.test")
        let resultBox = MobileBridgeSupervisorTestResultBox()
        let connection = NWConnection(
            host: NWEndpoint.Host(SpacesMobileBridgeDefaults.loopbackHost), port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))),
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
        guard ready.wait(timeout: .now() + 5) == .success else {
            connection.cancel()
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = resultBox.error() {
            connection.cancel()
            throw error
        }

        var requestData = try SpacesMobileBridgeCodec.encodeRequest(
            SpacesMobileBridgeRequest(
                command: "subscribe", authToken: authToken, clientApp: clientApp, sessionID: sessionID, clientID: "mobile-client-revoke"))
        requestData.append(0x0A)
        connection.send(
            content: requestData,
            completion: .contentProcessed { error in
                if let error { resultBox.setError(error) }
                sent.signal()
            })
        guard sent.wait(timeout: .now() + 5) == .success else {
            connection.cancel()
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = resultBox.error() {
            connection.cancel()
            throw error
        }

        return connection
    }

    private func waitForConnectionClosure(_ connection: NWConnection, timeout: TimeInterval) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        let resultBox = MobileBridgeSupervisorTestResultBox()

        @Sendable func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                if isComplete || error != nil {
                    resultBox.setFlag(true)
                    finished.signal()
                    return
                }
                receiveNext()
            }
        }
        receiveNext()

        guard finished.wait(timeout: .now() + timeout) == .success else { return false }
        return resultBox.flag()
    }

    nonisolated private static func sendBridgeRequest(_ request: SpacesMobileBridgeRequest, port: Int, transportKey: String) throws
        -> SpacesMobileBridgeResponse
    {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw POSIXError(.EINVAL) }
        let ready = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.mobile.bridge.supervisor.request.test")
        let resultBox = MobileBridgeSupervisorTestResultBox()
        let connection = NWConnection(
            host: NWEndpoint.Host(SpacesMobileBridgeDefaults.loopbackHost), port: nwPort,
            using: try SpacesMobileBridgeTransport.parameters(transportKey: transportKey, role: .client))
        defer { connection.cancel() }

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
        guard ready.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
        if let error = resultBox.error() { throw error }

        var requestData = try SpacesMobileBridgeCodec.encodeRequest(request)
        requestData.append(0x0A)
        connection.send(
            content: requestData,
            completion: .contentProcessed { error in
                if let error { resultBox.setError(error) }
                sent.signal()
            })
        guard sent.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
        if let error = resultBox.error() { throw error }

        @Sendable func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let content, !content.isEmpty {
                    resultBox.appendData(content)
                    if resultBox.responseData().contains(0x0A) {
                        received.signal()
                        return
                    }
                }
                if let error {
                    resultBox.setError(error)
                    received.signal()
                    return
                }
                if isComplete {
                    received.signal()
                    return
                }
                receiveNext()
            }
        }
        receiveNext()

        guard received.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
        if let error = resultBox.error() { throw error }
        return try SpacesMobileBridgeCodec.decodeResponse(resultBox.responseData())
    }

    private func withTemporaryProfile(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let originalRuntimePath = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime").path, 1)
        defer {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimePath { setenv("SPACES_RUNTIME_DIR", originalRuntimePath, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        try await body(root)
    }
}

private final class MobileBridgeSupervisorTestResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedFlag = false
    private var storedData = Data()
    private var storedDevices: [SpacesMobilePairedDevice]?
    private var storedResponse: SpacesMobileBridgeResponse?

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

    func setFlag(_ flag: Bool) {
        lock.lock()
        storedFlag = flag
        lock.unlock()
    }

    func flag() -> Bool {
        lock.lock()
        let flag = storedFlag
        lock.unlock()
        return flag
    }

    func appendData(_ data: Data) {
        lock.lock()
        storedData.append(data)
        lock.unlock()
    }

    func responseData() -> Data {
        lock.lock()
        let data = storedData
        lock.unlock()
        return data
    }

    func setDevices(_ devices: [SpacesMobilePairedDevice]) {
        lock.lock()
        storedDevices = devices
        lock.unlock()
    }

    func devices() -> [SpacesMobilePairedDevice]? {
        lock.lock()
        let devices = storedDevices
        lock.unlock()
        return devices
    }

    func setResponse(_ response: SpacesMobileBridgeResponse) {
        lock.lock()
        storedResponse = response
        lock.unlock()
    }

    func response() -> SpacesMobileBridgeResponse? {
        lock.lock()
        let response = storedResponse
        lock.unlock()
        return response
    }
}

private final class BlockingAuthorizePairingStore: SpacesMobilePairingStoreProtocol, @unchecked Sendable {
    let authToken = "AUTH-TOKEN"

    private let clientApp: SpacesMobileClientApp
    private let authorizeStarted = DispatchSemaphore(value: 0)
    private let authorizeCanFinish = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isPaired = true

    init(clientApp: SpacesMobileClientApp) { self.clientApp = clientApp }

    func issueToken(for clientApp: SpacesMobileClientApp) throws -> String {
        try validate(clientApp: clientApp)
        lock.lock()
        isPaired = true
        lock.unlock()
        return authToken
    }

    func listDevices() throws -> [SpacesMobilePairedDevice] {
        lock.lock()
        let paired = isPaired
        lock.unlock()
        guard paired else { return [] }
        return [
            SpacesMobilePairedDevice(
                installationID: clientApp.installationID, bundleID: clientApp.bundleID, platform: clientApp.platform,
                deviceName: clientApp.deviceName, appVersion: clientApp.appVersion, createdAt: "2026-01-01T00:00:00Z",
                lastUsedAt: "2026-01-01T00:00:01Z")
        ]
    }

    func revoke(installationID: String) throws {
        guard installationID.trimmingCharacters(in: .whitespacesAndNewlines) == clientApp.installationID else { return }
        lock.lock()
        isPaired = false
        lock.unlock()
    }

    func removeAll() throws {
        lock.lock()
        isPaired = false
        lock.unlock()
    }

    func authorize(clientApp: SpacesMobileClientApp?, authToken: String?) throws {
        guard let clientApp else { throw SpacesMobilePairingError.missingClientApp }
        try validate(clientApp: clientApp)
        guard authToken == self.authToken else { throw SpacesMobilePairingError.invalidAuthToken }

        authorizeStarted.signal()
        guard authorizeCanFinish.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }

        lock.lock()
        isPaired = true
        lock.unlock()
    }

    func validate(clientApp: SpacesMobileClientApp) throws {
        guard clientApp.bundleID == SpacesMobileFirstPartyPolicy.allowedBundleID else {
            throw SpacesMobilePairingError.unsupportedBundle(clientApp.bundleID)
        }
        guard clientApp.installationID == self.clientApp.installationID else {
            throw SpacesMobilePairingError.unpairedInstallation(clientApp.installationID)
        }
    }

    func waitForAuthorizeStarted(timeout: TimeInterval) -> Bool { authorizeStarted.wait(timeout: .now() + timeout) == .success }

    func finishAuthorize() { authorizeCanFinish.signal() }
}

private final class MobileBridgeTestSubscriptionServer: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "spaces.mobile.bridge.supervisor.subscription.test")
    private let accepted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listenSocketFD: Int32 = -1
    private var clientSocketFD: Int32 = -1

    init(socketPath: String) { self.socketPath = socketPath }

    func start() throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        do {
            var address = try makeSocketAddress(path: socketPath)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard listen(socketFD, 1) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            listenSocketFD = socketFD
            queue.async { [weak self] in self?.acceptConnection() }
        } catch {
            close(socketFD)
            throw error
        }
    }

    func waitForAccepted(timeout: TimeInterval) -> Bool { accepted.wait(timeout: .now() + timeout) == .success }

    func stop() {
        lock.lock()
        let clientFD = clientSocketFD
        let listenFD = listenSocketFD
        clientSocketFD = -1
        listenSocketFD = -1
        lock.unlock()

        if clientFD >= 0 {
            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
        }
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptConnection() {
        let socketFD = currentListenSocket()
        guard socketFD >= 0 else { return }
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }
        lock.lock()
        clientSocketFD = clientFD
        lock.unlock()
        accepted.signal()
    }

    private func currentListenSocket() -> Int32 {
        lock.lock()
        let socketFD = listenSocketFD
        lock.unlock()
        return socketFD
    }

    private func makeSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            _ = utf8Path.withUnsafeBufferPointer { buffer in memcpy(pointer, buffer.baseAddress, buffer.count) }
        }
        return address
    }
}
