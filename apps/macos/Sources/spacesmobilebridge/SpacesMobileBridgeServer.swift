import Darwin
import Dispatch
import Foundation
import Network
import spacesmobilecore
import spacesterminalcore
import workspacecore

protocol SpacesMobilePairingStoreProtocol: Sendable {
    func issueToken(for clientApp: SpacesMobileClientApp) throws -> String
    func listDevices() throws -> [SpacesMobilePairedDevice]
    func revoke(installationID: String) throws
    func removeAll() throws
    func authorize(clientApp: SpacesMobileClientApp?, authToken: String?) throws
    func validate(clientApp: SpacesMobileClientApp) throws
}

extension SpacesMobilePairingStore: SpacesMobilePairingStoreProtocol {}

public final class SpacesMobileBridgeServer: @unchecked Sendable {
    private static let ownerGatedTerminalCommands: Set<String> = ["send", "key", "clearScreen", "resize", "scroll"]
    private static let streamRelayReadBufferSize = 256 * 1024

    private struct NetworkShaper: Sendable {
        static let profileEnvironmentKey = "SPACES_MOBILE_BRIDGE_NETWORK_PROFILE"
        static let rttEnvironmentKey = "SPACES_MOBILE_BRIDGE_NETWORK_RTT_MS"
        static let bandwidthEnvironmentKey = "SPACES_MOBILE_BRIDGE_NETWORK_BANDWIDTH_BPS"
        static let chunkEnvironmentKey = "SPACES_MOBILE_BRIDGE_NETWORK_CHUNK_BYTES"

        let profile: String
        let rttMS: Int
        let bandwidthBPS: Int
        let chunkBytes: Int

        var isEnabled: Bool { profile != "local" && (rttMS > 0 || bandwidthBPS > 0 || chunkBytes > 0) }

        private final class SendChain: @unchecked Sendable {
            private let chunks: [Data]
            private let connection: NWConnection
            private let queue: DispatchQueue
            private let interChunkDelayMicroseconds: @Sendable (Int) -> Int
            private let onSendBegin: @Sendable () -> Void
            private let completion: @Sendable (Error?) -> Void

            init(
                chunks: [Data], connection: NWConnection, queue: DispatchQueue, interChunkDelayMicroseconds: @escaping @Sendable (Int) -> Int,
                onSendBegin: @escaping @Sendable () -> Void, completion: @escaping @Sendable (Error?) -> Void
            ) {
                self.chunks = chunks
                self.connection = connection
                self.queue = queue
                self.interChunkDelayMicroseconds = interChunkDelayMicroseconds
                self.onSendBegin = onSendBegin
                self.completion = completion
            }

            func send(index: Int) {
                guard index < chunks.count else {
                    completion(nil)
                    return
                }
                let chunk = chunks[index]
                if index == 0 { onSendBegin() }
                connection.send(
                    content: chunk, contentContext: .defaultMessage, isComplete: false,
                    completion: .contentProcessed { [self] error in
                        if let error {
                            self.completion(error)
                            return
                        }
                        let delayMicroseconds = self.interChunkDelayMicroseconds(chunk.count)
                        if delayMicroseconds <= 0 {
                            self.queue.async { self.send(index: index + 1) }
                        } else {
                            self.queue.asyncAfter(deadline: .now() + .microseconds(delayMicroseconds)) { self.send(index: index + 1) }
                        }
                    })
            }
        }

        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            let resolvedProfile = environment[Self.profileEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "local"
            profile = resolvedProfile.isEmpty ? "local" : resolvedProfile
            let constrained = profile == "ios-constrained"
            rttMS = Self.intValue(environment[Self.rttEnvironmentKey], fallback: constrained ? 80 : 0)
            bandwidthBPS = Self.intValue(environment[Self.bandwidthEnvironmentKey], fallback: constrained ? 8_000_000 : 0)
            chunkBytes = Self.intValue(environment[Self.chunkEnvironmentKey], fallback: constrained ? 16 * 1024 : 0)
        }

        func send(
            content data: Data, to connection: NWConnection, on queue: DispatchQueue, onSendBegin: @escaping @Sendable () -> Void = {},
            completion: @escaping @Sendable (Error?) -> Void
        ) {
            guard isEnabled, !data.isEmpty else {
                onSendBegin()
                connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed(completion))
                return
            }

            let chunks = chunked(data)
            let initialDelay = DispatchTimeInterval.milliseconds(max(rttMS / 2, 0))
            let bandwidthBPS = bandwidthBPS
            let chain = SendChain(
                chunks: chunks, connection: connection, queue: queue,
                interChunkDelayMicroseconds: { byteCount in Self.interChunkDelayMicroseconds(forByteCount: byteCount, bandwidthBPS: bandwidthBPS) },
                onSendBegin: onSendBegin, completion: completion)
            queue.asyncAfter(deadline: .now() + initialDelay) { chain.send(index: 0) }
        }

        private func chunked(_ data: Data) -> [Data] {
            let size = chunkBytes > 0 ? chunkBytes : data.count
            guard data.count > size else { return [data] }
            var chunks: [Data] = []
            chunks.reserveCapacity(Int(ceil(Double(data.count) / Double(size))))
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
                chunks.append(data[offset..<end])
                offset = end
            }
            return chunks
        }

        private static func interChunkDelayMicroseconds(forByteCount byteCount: Int, bandwidthBPS: Int) -> Int {
            guard bandwidthBPS > 0, byteCount > 0 else { return 0 }
            let bytesPerSecond = Double(bandwidthBPS) / 8.0
            let seconds = Double(byteCount) / max(bytesPerSecond, 1)
            return max(Int((seconds * 1_000_000).rounded()), 0)
        }

        private static func intValue(_ rawValue: String?, fallback: Int) -> Int {
            guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else { return fallback }
            return max(Int(rawValue) ?? fallback, 0)
        }
    }

    private struct StreamRelay {
        let sessionID: String
        let installationID: String
        let relaySocketFD: Int32
        let relayQueue: DispatchQueue
        let relaySource: DispatchSourceRead
        let heartbeatTimer: DispatchSourceTimer?
        let connection: NWConnection
        let sendSequencer: StreamSendSequencer
    }

    private final class StreamSendSequencer: @unchecked Sendable {
        typealias Operation = @Sendable (@escaping @Sendable (Error?) -> Void) -> Void

        private var pendingOperations: [Operation] = []
        private var isRunning = false

        func enqueue(_ operation: @escaping Operation) {
            pendingOperations.append(operation)
            startNextIfNeeded()
        }

        private func startNextIfNeeded() {
            guard !isRunning, !pendingOperations.isEmpty else { return }
            isRunning = true
            let operation = pendingOperations.removeFirst()
            operation { [weak self] _ in self?.finishCurrent() }
        }

        private func finishCurrent() {
            isRunning = false
            startNextIfNeeded()
        }
    }

    private final class RequestConnection: @unchecked Sendable {
        fileprivate let connection: NWConnection
        private let server: SpacesMobileBridgeServer
        private let peerID: String
        private var buffer = Data()
        private var didSubscribe = false
        private var didReceiveEOF = false

        init(connection: NWConnection, server: SpacesMobileBridgeServer) {
            self.connection = connection
            self.server = server
            peerID = String(describing: connection.endpoint)
        }

        func start(on queue: DispatchQueue) {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.server.trace("request_connection_ready peer=\(self.peerID)")
                    self.receiveNext()
                case .failed(let error):
                    self.server.trace("request_connection_failed peer=\(self.peerID) error=\(error)")
                    self.server.closeStreamRelay(connection: self.connection)
                    self.server.closeRequestConnection(connection: self.connection)
                    self.connection.cancel()
                case .cancelled:
                    self.server.trace("request_connection_cancelled peer=\(self.peerID)")
                    self.server.closeStreamRelay(connection: self.connection)
                    self.server.closeRequestConnection(connection: self.connection)
                default: break
                }
            }
            connection.start(queue: queue)
        }

        private func receiveNext() {
            guard !didSubscribe else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
                guard let self else { return }
                if let content, !content.isEmpty { self.buffer.append(content) }
                if let error {
                    self.server.trace("request_receive_error peer=\(self.peerID) error=\(error)")
                    self.connection.cancel()
                    return
                }
                if isComplete { self.didReceiveEOF = true }
                if !self.buffer.isEmpty || self.didReceiveEOF {
                    self.processBufferedLines()
                    return
                }
                self.receiveNext()
            }
        }

        private func processBufferedLines() {
            guard !didSubscribe else { return }
            guard server.acceptingRequests else {
                connection.cancel()
                return
            }
            guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
                if didReceiveEOF {
                    if !buffer.isEmpty { server.trace("request_incomplete peer=\(peerID) bytes=\(buffer.count)") }
                    connection.cancel()
                } else {
                    receiveNext()
                }
                return
            }

            let line = Data(buffer.prefix(upTo: newlineIndex))
            buffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else {
                processBufferedLines()
                return
            }

            do {
                let request = try SpacesMobileBridgeCodec.decodeRequest(line)
                server.trace(
                    "request_received peer=\(peerID) command=\(request.command) session=\(request.sessionID ?? "-") client=\(request.clientID ?? request.client?.id ?? "-")"
                )
                try server.authorize(request)
                guard request.command != "subscribe" else {
                    didSubscribe = true
                    try server.handleSubscribeRequest(request, connection: connection)
                    return
                }
                let response = try server.handleRequest(request, peerID: peerID)
                server.sendResponse(response, to: connection) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.server.trace("request_response_error peer=\(self.peerID) error=\(error)")
                        self.connection.cancel()
                        return
                    }
                    self.processBufferedLines()
                }
            } catch {
                server.trace("request_error peer=\(peerID) error=\(String(describing: error).replacingOccurrences(of: "\n", with: "\\n"))")
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                server.sendResponse(SpacesMobileBridgeResponse(ok: false, message: message), to: connection) { [weak self] _ in
                    self?.connection.cancel()
                }
            }
        }
    }

    private final class StartupSignal: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: Result<Void, Error>?

        func signal(_ result: Result<Void, Error>) {
            lock.lock()
            let shouldSignal = self.result == nil
            if shouldSignal { self.result = result }
            lock.unlock()
            if shouldSignal { semaphore.signal() }
        }

        func wait(timeout: TimeInterval) -> Result<Void, Error> {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return .failure(POSIXError(.ETIMEDOUT)) }
            lock.lock()
            let result = self.result ?? .failure(POSIXError(.EIO))
            lock.unlock()
            return result
        }
    }

    private let host: String
    private let port: Int
    private let transportKey: String
    private let pairingCoordinator: SpacesMobilePairingCoordinator
    private let pairingStore: any SpacesMobilePairingStoreProtocol
    private let onPairingSucceeded: (@Sendable (SpacesMobileClientApp) -> Void)?
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private let networkShaper: NetworkShaper
    private let traceEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_BRIDGE_TRACE"] == "1"

    private var listener: NWListener?
    private var requestConnections: [ObjectIdentifier: RequestConnection] = [:]
    private var streamRelays: [ObjectIdentifier: StreamRelay] = [:]
    private var running = false
    private var acceptingRequests = false

    public init(
        host: String, port: Int, transportKey: String, pairingCoordinator: SpacesMobilePairingCoordinator = SpacesMobilePairingCoordinator(),
        pairingStore: SpacesMobilePairingStore? = nil, onPairingSucceeded: (@Sendable (SpacesMobileClientApp) -> Void)? = nil
    ) throws {
        self.host = host
        self.port = port
        self.transportKey = transportKey
        self.pairingCoordinator = pairingCoordinator
        self.onPairingSucceeded = onPairingSucceeded
        if let pairingStore { self.pairingStore = pairingStore } else { self.pairingStore = try SpacesMobilePairingStore() }
        networkShaper = NetworkShaper()
        queue = DispatchQueue(label: "spaces.mobile.bridge")
        queue.setSpecific(key: queueKey, value: ())
    }

    init(
        host: String, port: Int, transportKey: String, pairingCoordinator: SpacesMobilePairingCoordinator = SpacesMobilePairingCoordinator(),
        pairingStoreProtocol: any SpacesMobilePairingStoreProtocol, onPairingSucceeded: (@Sendable (SpacesMobileClientApp) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.transportKey = transportKey
        self.pairingCoordinator = pairingCoordinator
        self.pairingStore = pairingStoreProtocol
        self.onPairingSucceeded = onPairingSucceeded
        networkShaper = NetworkShaper()
        queue = DispatchQueue(label: "spaces.mobile.bridge")
        queue.setSpecific(key: queueKey, value: ())
    }

    public private(set) var listeningPort: Int = 0

    public var isRunning: Bool {
        stateLock.lock()
        let value = running
        stateLock.unlock()
        return value
    }

    var requestConnectionCountForTesting: Int {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return requestConnections.count }
        return queue.sync { requestConnections.count }
    }

    public func start(timeout: TimeInterval = 5) throws {
        let nwPort = try Self.nwPort(port)
        let parameters = try SpacesMobileBridgeTransport.parameters(transportKey: transportKey, role: .server)
        if !SpacesMobileBridgeDefaults.isWildcardHost(host) {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }

        let createdListener = try NWListener(using: parameters, on: nwPort)
        let startup = StartupSignal()

        createdListener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            guard self.acceptingRequests else {
                connection.cancel()
                return
            }
            self.trace("request_connection_accept peer=\(String(describing: connection.endpoint))")
            let requestConnection = RequestConnection(connection: connection, server: self)
            self.requestConnections[ObjectIdentifier(connection)] = requestConnection
            requestConnection.start(on: self.queue)
        }
        createdListener.stateUpdateHandler = { [weak self, weak createdListener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.listeningPort = Int(createdListener?.port?.rawValue ?? UInt16(self.port))
                self.acceptingRequests = true
                self.setRunning(true)
                startup.signal(.success(()))
            case .failed(let error):
                self.acceptingRequests = false
                self.setRunning(false)
                startup.signal(.failure(error))
            case .cancelled:
                self.acceptingRequests = false
                self.setRunning(false)
            default: break
            }
        }
        listener = createdListener
        createdListener.start(queue: queue)

        switch startup.wait(timeout: timeout) {
        case .success: break
        case .failure(let error):
            createdListener.stateUpdateHandler = nil
            createdListener.newConnectionHandler = nil
            createdListener.cancel()
            throw error
        }
    }

    public func stop() { queue.async { self.stopOnQueue() } }

    func listPairedDevices() throws -> [SpacesMobilePairedDevice] { try syncOnQueue { try self.pairingStore.listDevices() } }

    func revokePairing(installationID: String) throws -> [SpacesMobilePairedDevice] {
        try syncOnQueue {
            try self.pairingStore.revoke(installationID: installationID)
            self.closeStreamRelaysOnQueue(forInstallationID: installationID)
            return try self.pairingStore.listDevices()
        }
    }

    func resetPairingsAndStop() throws {
        try syncOnQueue {
            self.stopOnQueue()
            try self.pairingStore.removeAll()
        }
    }

    public func closeStreamRelays(forInstallationID installationID: String) {
        let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeStreamRelaysOnQueue(forInstallationID: normalizedID)
        } else {
            queue.sync { self.closeStreamRelaysOnQueue(forInstallationID: normalizedID) }
        }
    }

    public func openPairingWindow(host linkHost: String, name: String, duration: TimeInterval = SpacesMobilePairingCoordinator.defaultWindowDuration)
        -> SpacesMobilePairingWindow
    {
        pairingCoordinator.openWindow(
            host: linkHost, port: listeningPort > 0 ? listeningPort : port, transportKey: transportKey, name: name, duration: duration)
    }

    public func openPairingWindow(
        host linkHost: String, name: String, duration: TimeInterval = SpacesMobilePairingCoordinator.defaultWindowDuration, code: String,
        nonce: String? = nil
    ) -> SpacesMobilePairingWindow {
        pairingCoordinator.openWindow(
            host: linkHost, port: listeningPort > 0 ? listeningPort : port, transportKey: transportKey, name: name, duration: duration, code: code,
            nonce: nonce)
    }

    public func pairingWindowSnapshot() -> SpacesMobilePairingWindowSnapshot? { pairingCoordinator.snapshot() }

    private func handleRequest(_ request: SpacesMobileBridgeRequest, peerID: String) throws -> SpacesMobileBridgeResponse {
        switch request.command {
        case "pair":
            guard let clientApp = request.clientApp else {
                return SpacesMobileBridgeResponse(ok: false, message: SpacesMobilePairingError.missingClientApp.localizedDescription)
            }
            try pairingStore.validate(clientApp: clientApp)
            try pairingCoordinator.validate(code: request.pairingCode, nonce: request.pairingNonce, peerID: peerID)
            let issuedToken = try pairingStore.issueToken(for: clientApp)
            onPairingSucceeded?(clientApp)
            return SpacesMobileBridgeResponse(ok: true, message: "Paired iOS client.", issuedAuthToken: issuedToken)
        case "ping": return SpacesMobileBridgeResponse(ok: true, message: "pong")
        case "overview": return SpacesMobileBridgeResponse(ok: true, message: "Loaded mobile overview.", overview: try loadOverview())
        case "state": return try handleStateRequest(request)
        case "attach": return try handleTerminalControlRequest(request, command: "attach")
        case "detach": return try handleTerminalControlRequest(request, command: "detach")
        case "heartbeat": return try handleTerminalControlRequest(request, command: "heartbeat")
        case "takeover": return try handleTerminalControlRequest(request, command: "takeover")
        case "send": return try handleTerminalControlRequest(request, command: "send")
        case "key": return try handleTerminalControlRequest(request, command: "key")
        case "clearScreen": return try handleTerminalControlRequest(request, command: "clearScreen")
        case "resize": return try handleTerminalControlRequest(request, command: "resize")
        case "scroll": return try handleTerminalControlRequest(request, command: "scroll")
        default: return SpacesMobileBridgeResponse(ok: false, message: "Unsupported mobile bridge command '\(request.command)'.")
        }
    }

    private func authorize(_ request: SpacesMobileBridgeRequest) throws {
        guard request.command != "pair" else { return }
        do { try pairingStore.authorize(clientApp: request.clientApp, authToken: request.authToken) } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw NSError(domain: "SpacesMobileBridgeServer", code: 401, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func handleTerminalControlRequest(_ request: SpacesMobileBridgeRequest, command: String) throws -> SpacesMobileBridgeResponse {
        guard let sessionID = request.sessionID else { return SpacesMobileBridgeResponse(ok: false, message: "Missing session ID.") }
        let clientID = Self.normalizedClientID(from: request)
        if Self.ownerGatedTerminalCommands.contains(command), clientID == nil {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing mobile client ID.")
        }

        let startedAt = Date()
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.")
        }

        let terminalRequest = TerminalControlRequest(
            command: command, text: request.text, key: request.key, clientID: clientID, client: request.client,
            attachmentMode: request.attachmentMode, columns: request.columns, rows: request.rows, ownerEpoch: request.ownerEpoch,
            resizeSerial: request.resizeSerial, scrollHorizontal: request.scrollHorizontal, scrollVertical: request.scrollVertical,
            scrollMods: request.scrollMods, appendNewline: request.appendNewline)
        let response = try TerminalControlClient.send(request: terminalRequest, socketPath: paths.controlSocketPath)
        TerminalPerformance.logMetric(
            "mobile_bridge_\(command)", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: response.ok)
        return SpacesMobileBridgeResponse(ok: response.ok, message: response.message)
    }

    private static func normalizedClientID(from request: SpacesMobileBridgeRequest) -> String? {
        guard let clientID = request.clientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else { return nil }
        return clientID
    }

    private func loadOverview() throws -> SpacesMobileOverviewPayload {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let projects = try store.projects()
        let workspaces = try projects.flatMap { project in
            try store.workspaces(projectID: project.id).map { workspace in
                SpacesMobileOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace)
            }
        }
        let sessions = try TerminalSessionCatalog.listLiveSessions()
        return SpacesMobileOverviewBuilder.build(workspaces: workspaces, sessions: sessions)
    }

    private func handleStateRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let sessionID = request.sessionID else { return SpacesMobileBridgeResponse(ok: false, message: "Missing session ID.") }
        let startedAt = Date()
        let payload = try loadCurrentState(sessionID: sessionID)
        TerminalPerformance.logMetric(
            "mobile_bridge_state", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
        return SpacesMobileBridgeResponse(ok: true, message: "Loaded terminal state.", sessionState: payload)
    }

    private func handleSubscribeRequest(_ request: SpacesMobileBridgeRequest, connection: NWConnection) throws {
        guard let sessionID = request.sessionID else {
            sendResponse(SpacesMobileBridgeResponse(ok: false, message: "Missing session ID."), to: connection) { _ in connection.cancel() }
            return
        }
        guard let installationID = request.clientApp?.installationID.trimmingCharacters(in: .whitespacesAndNewlines), !installationID.isEmpty else {
            sendResponse(SpacesMobileBridgeResponse(ok: false, message: "Missing mobile installation ID."), to: connection) { _ in connection.cancel()
            }
            return
        }
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
            sendResponse(SpacesMobileBridgeResponse(ok: false, message: "Terminal session '\(sessionID)' has no live state stream."), to: connection)
            { _ in connection.cancel() }
            return
        }

        let startedAt = Date()
        let relaySocketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
        try setNonBlocking(relaySocketFD)

        let relayQueue = DispatchQueue(label: "spaces.mobile.bridge.stream.\(sessionID).\(ObjectIdentifier(connection))")
        let relaySource = DispatchSource.makeReadSource(fileDescriptor: relaySocketFD, queue: relayQueue)
        relaySource.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.relayStateData(from: relaySocketFD, to: connection)
        }
        relaySource.setCancelHandler { close(relaySocketFD) }

        let heartbeatTimer: DispatchSourceTimer?
        if let clientID = request.clientID {
            let timer = DispatchSource.makeTimerSource(queue: relayQueue)
            timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
            timer.setEventHandler {
                _ = try? TerminalControlClient.send(
                    request: TerminalControlRequest(command: "heartbeat", clientID: clientID), socketPath: paths.controlSocketPath)
            }
            heartbeatTimer = timer
        } else {
            heartbeatTimer = nil
        }

        streamRelays[ObjectIdentifier(connection)] = StreamRelay(
            sessionID: sessionID, installationID: installationID, relaySocketFD: relaySocketFD, relayQueue: relayQueue, relaySource: relaySource,
            heartbeatTimer: heartbeatTimer, connection: connection, sendSequencer: StreamSendSequencer())

        relaySource.resume()
        heartbeatTimer?.resume()

        TerminalPerformance.logMetric(
            "mobile_bridge_subscribe", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
    }

    private func relayStateData(from relaySocketFD: Int32, to connection: NWConnection) {
        var buffer = [UInt8](repeating: 0, count: Self.streamRelayReadBufferSize)
        var relayedData = Data()
        var firstReadUptimeNanoseconds: UInt64?
        while true {
            let count = read(relaySocketFD, &buffer, buffer.count)
            if count == 0 {
                if !relayedData.isEmpty {
                    enqueueRelayedStateData(relayedData, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection)
                }
                queue.async { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.closeStreamRelay(connection: connection)
                }
                return
            }
            if count < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    if !relayedData.isEmpty {
                        enqueueRelayedStateData(relayedData, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection)
                    }
                    return
                }
                queue.async { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.closeStreamRelay(connection: connection)
                }
                return
            }
            firstReadUptimeNanoseconds = firstReadUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds
            relayedData.append(buffer, count: count)
        }
    }

    private func enqueueRelayedStateData(_ data: Data, firstReadUptimeNanoseconds: UInt64?, to connection: NWConnection) {
        queue.async { [weak self, weak connection, data, firstReadUptimeNanoseconds] in
            guard let self, let connection else { return }
            self.sendRelayedStateData(data, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection)
        }
    }

    private func sendRelayedStateData(_ data: Data, firstReadUptimeNanoseconds: UInt64?, to connection: NWConnection) {
        guard let relay = streamRelays[ObjectIdentifier(connection)] else { return }
        let attributes = streamRelayAttributes(for: data)
        logBridgePerformance(
            sessionID: relay.sessionID, name: "stream_relay_read",
            emittedUptimeNanoseconds: firstReadUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds, count: data.count, attributes: attributes)
        relay.sendSequencer.enqueue { [weak self, weak connection, sessionID = relay.sessionID, attributes, data] finish in
            guard let self, let connection else {
                finish(nil)
                return
            }
            self.networkShaper.send(
                content: data, to: connection, on: self.queue,
                onSendBegin: { [weak self, sessionID, attributes, count = data.count] in
                    var sendAttributes = attributes
                    sendAttributes["network_send_bytes"] = String(count)
                    self?.logBridgePerformance(sessionID: sessionID, name: "stream_network_send_begin", count: count, attributes: sendAttributes)
                }
            ) { [weak self, weak connection] error in
                self?.queue.async { [weak self, weak connection] in
                    if let error {
                        self?.trace("stream_relay_send_error error=\(error)")
                        if let self, let connection { self.closeStreamRelay(connection: connection) }
                    }
                    finish(error)
                }
            }
        }
    }

    private func streamRelayAttributes(for data: Data) -> [String: String] {
        var attributes: [String: String] = [
            "payload_bytes": String(data.count), "payload_count": String(data.split(separator: 0x0A, omittingEmptySubsequences: true).count),
        ]
        guard let firstLine = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first,
            let payload = try? GhosttyRemoteSessionStateCodec.decodeLine(Data(firstLine))
        else {
            attributes["render_update"] = "unknown"
            return attributes
        }
        attributes["reason"] = payload.reason
        attributes["render_update"] = payload.renderUpdate == nil ? "0" : "1"
        attributes["render_update_bytes"] = String(payload.renderUpdate?.count ?? 0)
        if let update = payload.decodedRenderUpdate {
            attributes["frame_kind"] = update.frameKindMetricValue
            attributes["operation_count"] = String(update.operationCount)
            attributes["changed_cell_count"] = String(update.changedCellCount)
            attributes["scroll_operation_count"] = String(update.scrollOperationCount)
            attributes["base_revision"] = update.baseRevision.map(String.init) ?? "nil"
            attributes["full_frame_fallback_reason"] = update.fallbackReason ?? "none"
        }
        attributes["target_revision"] = payload.screenStateRevision.map(String.init) ?? "nil"
        return attributes
    }

    private func closeStreamRelay(connection: NWConnection) {
        guard let relay = streamRelays.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        trace("stream_relay_close peer=\(String(describing: connection.endpoint))")
        relay.heartbeatTimer?.cancel()
        relay.relaySource.cancel()
        shutdown(relay.relaySocketFD, SHUT_RDWR)
        connection.cancel()
    }

    private func closeRequestConnection(connection: NWConnection) {
        requestConnections.removeValue(forKey: ObjectIdentifier(connection))
        trace("request_connection_closed active=\(requestConnections.count)")
    }

    private func closeStreamRelaysOnQueue(forInstallationID installationID: String) {
        let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        let connections = streamRelays.values.filter { $0.installationID == normalizedID }.map(\.connection)
        for connection in connections { closeStreamRelay(connection: connection) }
    }

    private func stopOnQueue() {
        acceptingRequests = false
        for relay in Array(streamRelays.values) { closeStreamRelay(connection: relay.connection) }
        for connection in Array(requestConnections.values.map(\.connection)) { connection.cancel() }
        requestConnections.removeAll()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        setRunning(false)
    }

    private func syncOnQueue<T>(_ work: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try queue.sync(execute: work)
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try setNoSIGPIPE(socketFD)
        var address = try makeUnixSocketAddress(path: path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        return socketFD
    }

    private func makeUnixSocketAddress(path: String) throws -> sockaddr_un {
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

    private func loadCurrentState(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
            throw NSError(
                domain: "SpacesMobileBridgeServer", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' has no live state stream."])
        }

        let socketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
        defer {
            shutdown(socketFD, SHUT_RDWR)
            close(socketFD)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socketFD, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(buffer, count: count)
            if let newlineIndex = data.firstIndex(of: 0x0A) {
                data.removeSubrange(newlineIndex..<data.endIndex)
                break
            }
        }

        guard !data.isEmpty else {
            throw NSError(
                domain: "SpacesMobileBridgeServer", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' did not return a state payload."])
        }
        return try GhosttyRemoteSessionStateCodec.decodeLine(data)
    }

    private func sendResponse(_ response: SpacesMobileBridgeResponse, to connection: NWConnection, completion: @escaping @Sendable (Error?) -> Void) {
        do {
            var data = try SpacesMobileBridgeCodec.encodeResponse(response)
            data.append(0x0A)
            networkShaper.send(content: data, to: connection, on: queue, completion: completion)
        } catch { completion(error) }
    }

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func setNoSIGPIPE(_ fileDescriptor: Int32) throws {
        var yes: Int32 = 1
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func nwPort(_ port: Int) throws -> NWEndpoint.Port {
        guard (0...65_535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw POSIXError(.EINVAL) }
        return nwPort
    }

    private func trace(_ message: String) {
        guard traceEnabled else { return }
        fputs("spaces-mobile-bridge-trace \(message)\n", stdout)
        fflush(stdout)
    }

    private func logBridgePerformance(
        sessionID: String, name: String, emittedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds, count: Int? = nil,
        attributes: [String: String] = [:]
    ) {
        SpacesMobileTerminalPerformanceLogger.emit(
            .init(
                sessionID: sessionID, source: "mobile-bridge", name: name, emittedUptimeNanoseconds: emittedUptimeNanoseconds, count: count,
                attributes: attributes))
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }
}
