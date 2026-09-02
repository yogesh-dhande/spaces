#if canImport(Network) && canImport(Security)
    import Darwin
    import Foundation
    import Network
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore
    @testable import workspacecore

    final class ServiceTunnelServerTests: XCTestCase {
        override class func tearDown() {
            try? FileManager.default.removeItem(at: serviceTunnelTestTLSRoot)
            super.tearDown()
        }

        func testEchoTunnelRelaysBinaryBytesInBothDirections() throws {
            try withTemporaryProfile { _ in
                let echo = try TunnelEchoServer()
                defer { echo.stop() }
                try seedWorkspaceService(workspaceID: "workspace-1", serviceName: "web", port: echo.port)

                let harness = try startServer()
                defer { harness.stop() }
                let client = try harness.openTunnel(workspaceID: "workspace-1", serviceName: "web")

                // Non-UTF8, newline-free payloads to prove the pipe is byte-exact and framing-agnostic.
                for seed in [0, 97, 200] {
                    let chunk = Self.binaryChunk(byteCount: 4096, seed: seed)
                    try client.send(chunk)
                    let echoed = try client.readExactly(chunk.count)
                    XCTAssertEqual(echoed, chunk)
                }
                client.cancel()
            }
        }

        func testUnknownWorkspaceAndUnknownServiceReturnNotFound() throws {
            try withTemporaryProfile { _ in
                try seedWorkspaceService(workspaceID: "workspace-1", serviceName: "web", port: 65000)

                let harness = try startServer()
                defer { harness.stop() }

                let unknownWorkspace = try harness.openTunnelExpectingResponse(workspaceID: "missing", serviceName: "web")
                XCTAssertFalse(unknownWorkspace.ok)
                XCTAssertEqual(unknownWorkspace.errorCode, .notFound)

                let unknownService = try harness.openTunnelExpectingResponse(workspaceID: "workspace-1", serviceName: "api")
                XCTAssertFalse(unknownService.ok)
                XCTAssertEqual(unknownService.errorCode, .notFound)
            }
        }

        func testServiceNotListeningReturnsServiceNotRunning() throws {
            try withTemporaryProfile { _ in
                let closedPort = try reservedFreePort()
                try seedWorkspaceService(workspaceID: "workspace-1", serviceName: "web", port: closedPort)

                let harness = try startServer()
                defer { harness.stop() }

                let response = try harness.openTunnelExpectingResponse(workspaceID: "workspace-1", serviceName: "web")
                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .serviceNotRunning)
            }
        }

        /// Service-side half-close: the service echoes the payload and then closes its write side. The
        /// daemon must deliver every echoed byte followed by a clean EOF to the client. (Network.framework
        /// TLS has no observable half-close, so the daemon ends the tunnel with a clean full close after
        /// service EOF; the client must still see all bytes first.)
        func testServiceEOFDeliversEchoThenCleanClose() throws {
            try withTemporaryProfile { _ in
                let payload = Self.binaryChunk(byteCount: 2048, seed: 33)
                let echo = try TunnelEchoServer(closeAfterEchoingByteCount: payload.count)
                defer { echo.stop() }
                try seedWorkspaceService(workspaceID: "workspace-1", serviceName: "web", port: echo.port)

                let harness = try startServer()
                defer { harness.stop() }
                let client = try harness.openTunnel(workspaceID: "workspace-1", serviceName: "web")

                try client.send(payload)
                let echoed = try client.readExactly(payload.count)
                XCTAssertEqual(echoed, payload)
                XCTAssertThrowsError(try client.readExactly(1, timeout: 3)) { error in XCTAssertEqual(error as? RawTunnelClientError, .closed) }
                client.cancel()
            }
        }

        /// Client-side close: a clean client close surfaces at the daemon after the in-flight payload,
        /// and the daemon must flush every buffered phone byte to the service (half-closing the loopback
        /// write side) rather than dropping bytes on teardown.
        func testClientCloseFlushesPendingBytesToService() throws {
            try withTemporaryProfile { _ in
                let payload = Self.binaryChunk(byteCount: 2048, seed: 51)
                let echo = try TunnelEchoServer()
                defer { echo.stop() }
                try seedWorkspaceService(workspaceID: "workspace-1", serviceName: "web", port: echo.port)

                let harness = try startServer()
                defer { harness.stop() }
                let client = try harness.openTunnel(workspaceID: "workspace-1", serviceName: "web")

                try client.send(payload)
                client.cancel()

                XCTAssertTrue(echo.waitForReceived(byteCount: payload.count, timeout: 5))
                XCTAssertEqual(echo.receivedData(), payload)
            }
        }

        func testServerStopSeversActiveTunnel() throws {
            try withTemporaryProfile { _ in
                let echo = try TunnelEchoServer()
                defer { echo.stop() }
                try seedWorkspaceService(workspaceID: "workspace-1", serviceName: "web", port: echo.port)

                let harness = try startServer()
                let client = try harness.openTunnel(workspaceID: "workspace-1", serviceName: "web")

                let chunk = Self.binaryChunk(byteCount: 256, seed: 7)
                try client.send(chunk)
                XCTAssertEqual(try client.readExactly(chunk.count), chunk)

                harness.stop()

                XCTAssertThrowsError(try client.readExactly(1, timeout: 5)) { error in XCTAssertEqual(error as? RawTunnelClientError, .closed) }
                client.cancel()
            }
        }

        func testRelayCancelBalancesNeverActivatedReadSource() throws {
            var fileDescriptors = [Int32](repeating: -1, count: 2)
            let pipeResult = fileDescriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.pipe(baseAddress)
            }
            XCTAssertEqual(pipeResult, 0)
            try XCTSkipIf(pipeResult != 0, "Could not create relay test pipe.")
            let readFD = fileDescriptors[0]
            let writeFD = fileDescriptors[1]
            defer { close(writeFD) }

            let cancelHandlerRan = DispatchSemaphore(value: 0)
            let relayQueue = DispatchQueue(label: "spaces.device.api.tunnel.test.never-activated-source")
            let relaySource = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: relayQueue)
            relaySource.setCancelHandler {
                close(readFD)
                cancelHandlerRan.signal()
            }
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            let relay = SpacesDeviceServiceTunnelRelay(
                workspaceID: "workspace-1", serviceName: "web", installationID: "install-1", loopbackFD: readFD, relayQueue: relayQueue,
                relaySource: relaySource, connection: connection)

            let result = withExtendedLifetime(relay) {
                relay.prepareForCancel()
                relaySource.cancel()
                return cancelHandlerRan.wait(timeout: .now() + 0.5)
            }
            XCTAssertEqual(result, .success, "Teardown must balance the source's base activation before canceling it.")
            if result != .success {
                relaySource.resume()
                _ = cancelHandlerRan.wait(timeout: .now() + 1)
            }
        }

        // MARK: - Seeding

        private func seedWorkspaceService(workspaceID: String, serviceName: String, port: Int) throws {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            try store.upsert(project: ProjectRecord(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: false, defaultBranch: nil))
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: workspaceID, projectID: "project-1", dir: "/tmp/project/\(workspaceID)", dirname: workspaceID, branch: "main",
                    isDefault: false, isRunning: true, lastLaunchedAt: nil))
            try store.setWorkspacePorts(workspaceID: workspaceID, ports: [port], names: [serviceName])
        }

        // MARK: - Server harness

        private func startServer() throws -> ServerHarness {
            let identity = try serviceTunnelTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedServiceTunnelPairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            return ServerHarness(server: server, identity: identity, authToken: pairingStore.authToken)
        }

        private static func binaryChunk(byteCount: Int, seed: Int) -> Data {
            var bytes = [UInt8]()
            bytes.reserveCapacity(byteCount)
            for index in 0..<byteCount {
                let value = UInt8((seed + index) % 256)
                // Keep the payload newline-free so a byte can never be mistaken for a Device API frame
                // delimiter by any observer of the raw pipe.
                bytes.append(value == 0x0A ? 0x0B : value)
            }
            return Data(bytes)
        }

        /// Binds an ephemeral loopback port and closes it immediately, yielding a port with no listener
        /// so a dial gets a deterministic, prompt connection refusal.
        private func reservedFreePort() throws -> Int {
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(socketFD) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
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

    // MARK: - Test doubles

    private final class ServerHarness {
        let server: SpacesDeviceAPIServer
        private let identity: TerminalServiceTLSIdentity
        private let authToken: String

        init(server: SpacesDeviceAPIServer, identity: TerminalServiceTLSIdentity, authToken: String) {
            self.server = server
            self.identity = identity
            self.authToken = authToken
        }

        func stop() { server.stop() }

        private func requestLine(workspaceID: String, serviceName: String) throws -> Data {
            let clientApp = SpacesDeviceClientApp(
                installationID: "service-tunnel-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                appVersion: "1.0")
            let request = SpacesDeviceAPIRequest(
                command: .openServiceTunnel(SpacesDeviceServiceTunnelRequest(workspaceID: workspaceID, serviceName: serviceName)),
                authToken: authToken, clientApp: clientApp)
            return try SpacesDeviceAPICodec.encodeRequest(request)
        }

        private func connect() throws -> RawTunnelClient {
            try RawTunnelClient(host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
        }

        /// Opens a tunnel and asserts the ok line before returning the live raw connection.
        func openTunnel(workspaceID: String, serviceName: String) throws -> RawTunnelClient {
            let client = try connect()
            try client.sendLine(requestLine(workspaceID: workspaceID, serviceName: serviceName))
            let response = try SpacesDeviceAPICodec.decodeResponse(client.readLine())
            guard response.ok else {
                client.cancel()
                throw RawTunnelClientError.rejected(response)
            }
            return client
        }

        /// Sends a tunnel request and returns the single response line without asserting success, for the
        /// failure-path cases.
        func openTunnelExpectingResponse(workspaceID: String, serviceName: String) throws -> SpacesDeviceAPIResponse {
            let client = try connect()
            defer { client.cancel() }
            try client.sendLine(requestLine(workspaceID: workspaceID, serviceName: serviceName))
            return try SpacesDeviceAPICodec.decodeResponse(client.readLine())
        }
    }

    enum RawTunnelClientError: Error, Equatable {
        case timeout
        case closed
        case notReady
        case rejected(SpacesDeviceAPIResponse)
    }

    /// A raw pinned-TLS client that speaks bytes, not Device API frames, after the ok line: it buffers all
    /// inbound bytes so the tunnel's byte pipe can be asserted exactly.
    final class RawTunnelClient: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "spaces.device.api.tunnel.test.client")
        private let condition = NSCondition()
        private var buffer = Data()
        private var closed = false
        private var failure: Error?

        init(host: String, port: Int, certificateFingerprint: String, timeout: TimeInterval = 10) throws {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw RawTunnelClientError.notReady }
            let parameters = SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint)
            connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
            let ready = DispatchSemaphore(value: 0)
            let errorBox = ErrorBox()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.signal()
                case .failed(let error):
                    errorBox.set(error)
                    ready.signal()
                default: break
                }
            }
            connection.start(queue: queue)
            guard ready.wait(timeout: .now() + timeout) == .success else {
                connection.cancel()
                throw RawTunnelClientError.timeout
            }
            if let error = errorBox.get() {
                connection.cancel()
                throw error
            }
            receiveLoop()
        }

        private func receiveLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] content, _, isComplete, error in
                guard let self else { return }
                condition.lock()
                if let content, !content.isEmpty { buffer.append(content) }
                if error != nil || isComplete { closed = true }
                if let error { failure = error }
                condition.broadcast()
                condition.unlock()
                if error == nil, !isComplete { receiveLoop() }
            }
        }

        func send(_ data: Data, timeout: TimeInterval = 5) throws {
            let sent = DispatchSemaphore(value: 0)
            let errorBox = ErrorBox()
            connection.send(
                content: data, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { error in
                    if let error { errorBox.set(error) }
                    sent.signal()
                })
            guard sent.wait(timeout: .now() + timeout) == .success else { throw RawTunnelClientError.timeout }
            if let error = errorBox.get() { throw error }
        }

        func sendLine(_ data: Data) throws {
            var payload = data
            payload.append(0x0A)
            try send(payload)
        }

        func readLine(timeout: TimeInterval = 5) throws -> Data {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newlineIndex])
                    buffer = Data(buffer[buffer.index(after: newlineIndex)...])
                    return line
                }
                if let failure { throw failure }
                if closed { throw RawTunnelClientError.closed }
                guard waitUntil(deadline) else { throw RawTunnelClientError.timeout }
            }
        }

        func readExactly(_ count: Int, timeout: TimeInterval = 5) throws -> Data {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while buffer.count < count {
                if let failure { throw failure }
                if closed { throw RawTunnelClientError.closed }
                guard waitUntil(deadline) else { throw RawTunnelClientError.timeout }
            }
            let out = Data(buffer.prefix(count))
            buffer = Data(buffer.dropFirst(count))
            return out
        }

        /// Waits for a broadcast up to a short slice of the remaining budget. Returns false once the
        /// deadline has passed so the caller can surface a timeout. Caller holds `condition`.
        private func waitUntil(_ deadline: Date) -> Bool {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.25)))
            return true
        }

        func cancel() { connection.cancel() }
    }

    /// A local TCP echo server for the loopback service side of the tunnel. Echoes every received chunk,
    /// records everything received, and (when configured) half-closes its write side with a real FIN
    /// (`.finalMessage`, plain TCP) after echoing the expected byte count — modelling a service that
    /// finishes its response.
    final class TunnelEchoServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "spaces.device.api.tunnel.test.echo")
        private let closeAfterEchoingByteCount: Int?
        private let stateLock = NSLock()
        private var connections: [NWConnection] = []
        private var received = Data()
        private var echoedByteCount = 0
        private let receivedCondition = NSCondition()
        private(set) var port = 0

        init(closeAfterEchoingByteCount: Int? = nil) throws {
            self.closeAfterEchoingByteCount = closeAfterEchoingByteCount
            let created = try NWListener(using: .tcp)
            listener = created
            let ready = DispatchSemaphore(value: 0)
            let portBox = IntBox()
            created.stateUpdateHandler = { state in
                if case .ready = state {
                    portBox.set(Int(created.port?.rawValue ?? 0))
                    ready.signal()
                }
            }
            created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            created.start(queue: queue)
            guard ready.wait(timeout: .now() + 5) == .success else {
                created.cancel()
                throw RawTunnelClientError.timeout
            }
            port = portBox.get()
        }

        func receivedData() -> Data {
            stateLock.lock()
            defer { stateLock.unlock() }
            return received
        }

        func waitForReceived(byteCount: Int, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            receivedCondition.lock()
            defer { receivedCondition.unlock() }
            while receivedData().count < byteCount, Date() < deadline { _ = receivedCondition.wait(until: Date(timeIntervalSinceNow: 0.05)) }
            return receivedData().count >= byteCount
        }

        private func accept(_ connection: NWConnection) {
            stateLock.lock()
            connections.append(connection)
            stateLock.unlock()
            connection.start(queue: queue)
            echo(connection)
        }

        private func echo(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] content, _, isComplete, error in
                guard let self else { return }
                if let content, !content.isEmpty {
                    stateLock.lock()
                    received.append(content)
                    echoedByteCount += content.count
                    let shouldClose = closeAfterEchoingByteCount.map { echoedByteCount >= $0 } ?? false
                    stateLock.unlock()
                    receivedCondition.lock()
                    receivedCondition.broadcast()
                    receivedCondition.unlock()
                    // Plain TCP: `.finalMessage` emits a genuine FIN, half-closing the write side.
                    connection.send(
                        content: content, contentContext: shouldClose ? .finalMessage : .defaultMessage, isComplete: shouldClose,
                        completion: .contentProcessed { _ in })
                    if !isComplete { self.echo(connection) }
                } else if error != nil || isComplete {
                    // Keep the connection object alive; the daemon owns full teardown.
                } else {
                    self.echo(connection)
                }
            }
        }

        func stop() {
            listener.cancel()
            stateLock.lock()
            let active = connections
            connections.removeAll()
            stateLock.unlock()
            for connection in active { connection.cancel() }
        }
    }

    private final class IntBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func set(_ newValue: Int) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
        func get() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Error?
        func set(_ newValue: Error) {
            lock.lock()
            if value == nil { value = newValue }
            lock.unlock()
        }
        func get() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let serviceTunnelTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "spaces-service-tunnel-tests-tls-\(UUID().uuidString)", isDirectory: true)

    private func serviceTunnelTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
        try TerminalServiceTLSIdentityStore.loadOrCreate(root: serviceTunnelTestTLSRoot)
    }

    private final class AlwaysAuthorizedServiceTunnelPairingStore: SpacesDevicePairingStoreProtocol {
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
