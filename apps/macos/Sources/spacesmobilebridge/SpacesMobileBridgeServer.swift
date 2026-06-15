import Darwin
import Dispatch
import Foundation
import Network
import spacesmobilecore
import spacesterminalcore
import workspacecore

#if canImport(Security)
    @preconcurrency import Security
#endif

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
    private static let defaultTerminalLinkTransferAuthorizationTTL: TimeInterval = 10 * 60

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
            private let isComplete: Bool
            private let interChunkDelayMicroseconds: @Sendable (Int) -> Int
            private let onSendBegin: @Sendable () -> Void
            private let completion: @Sendable (Error?) -> Void

            init(
                chunks: [Data], connection: NWConnection, queue: DispatchQueue, isComplete: Bool,
                interChunkDelayMicroseconds: @escaping @Sendable (Int) -> Int, onSendBegin: @escaping @Sendable () -> Void,
                completion: @escaping @Sendable (Error?) -> Void
            ) {
                self.chunks = chunks
                self.connection = connection
                self.queue = queue
                self.isComplete = isComplete
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
                    content: chunk, contentContext: .defaultMessage, isComplete: isComplete && index == chunks.count - 1,
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
            isComplete: Bool = false, applyInitialDelay: Bool = true, applyBandwidthDelay: Bool = true,
            completion: @escaping @Sendable (Error?) -> Void
        ) {
            guard isEnabled, !data.isEmpty else {
                onSendBegin()
                connection.send(content: data, contentContext: .defaultMessage, isComplete: isComplete, completion: .contentProcessed(completion))
                return
            }

            let chunks = chunked(data)
            let initialDelay = DispatchTimeInterval.milliseconds(applyInitialDelay ? max(rttMS / 2, 0) : 0)
            let bandwidthBPS = applyBandwidthDelay ? bandwidthBPS : 0
            let chain = SendChain(
                chunks: chunks, connection: connection, queue: queue, isComplete: isComplete,
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

    private struct TerminalLinkTransferAuthorization: Sendable {
        let sessionID: String
        let resolvedPath: String
        let expiresAt: Date
    }

    private struct RemoteTerminalSessionList {
        let entries: [TerminalSessionCatalogEntry]
        let hasFinalRenderBySessionID: [String: Bool]
    }

    private struct RemoteTerminalEndpointKey: Hashable {
        let host: String
        let port: Int
        let authToken: String?
        let certificateFingerprint: String
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
                    self.server.closeRequestConnectionAfterNetworkUpdate(connection: self.connection, cancelNetworkConnection: true)
                case .cancelled:
                    self.server.trace("request_connection_cancelled peer=\(self.peerID)")
                    self.server.closeRequestConnectionAfterNetworkUpdate(connection: self.connection, cancelNetworkConnection: false)
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
    private let certificateFingerprint: String
    private let pairingCoordinator: SpacesMobilePairingCoordinator
    private let pairingStore: any SpacesMobilePairingStoreProtocol
    private let onPairingSucceeded: (@Sendable (SpacesMobileClientApp) -> Void)?
    private let launchSpacesAppHandler: (() throws -> SpacesAppLaunchOutcome)?
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private let networkShaper: NetworkShaper
    private let terminalLinkTransferAuthorizationTTL: TimeInterval
    private let traceEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_BRIDGE_TRACE"] == "1"

    private var listener: NWListener?
    private var requestConnections: [ObjectIdentifier: RequestConnection] = [:]
    private var streamRelays: [ObjectIdentifier: StreamRelay] = [:]
    private var streamRelaysClosingAfterFinalSend: Set<ObjectIdentifier> = []
    private var terminalLinkTransferAuthorizations: [String: TerminalLinkTransferAuthorization] = [:]
    private var running = false
    private var acceptingRequests = false

    public init(
        host: String, port: Int, transportKey: String, certificateFingerprint: String = SpacesMobileBridgeSettings.generateCertificateFingerprint(),
        pairingCoordinator: SpacesMobilePairingCoordinator = SpacesMobilePairingCoordinator(), pairingStore: SpacesMobilePairingStore? = nil,
        onPairingSucceeded: (@Sendable (SpacesMobileClientApp) -> Void)? = nil
    ) throws {
        self.host = host
        self.port = port
        self.transportKey = transportKey
        self.certificateFingerprint = certificateFingerprint
        self.pairingCoordinator = pairingCoordinator
        self.onPairingSucceeded = onPairingSucceeded
        launchSpacesAppHandler = nil
        if let pairingStore { self.pairingStore = pairingStore } else { self.pairingStore = try SpacesMobilePairingStore() }
        networkShaper = NetworkShaper()
        terminalLinkTransferAuthorizationTTL = Self.defaultTerminalLinkTransferAuthorizationTTL
        queue = DispatchQueue(label: "spaces.mobile.bridge")
        queue.setSpecific(key: queueKey, value: ())
    }

    init(
        host: String, port: Int, transportKey: String, certificateFingerprint: String = SpacesMobileBridgeSettings.generateCertificateFingerprint(),
        pairingCoordinator: SpacesMobilePairingCoordinator = SpacesMobilePairingCoordinator(),
        pairingStoreProtocol: any SpacesMobilePairingStoreProtocol, onPairingSucceeded: (@Sendable (SpacesMobileClientApp) -> Void)? = nil,
        networkEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        launchSpacesAppHandler: (() throws -> SpacesAppLaunchOutcome)? = nil,
        terminalLinkTransferAuthorizationTTL: TimeInterval = SpacesMobileBridgeServer.defaultTerminalLinkTransferAuthorizationTTL
    ) {
        self.host = host
        self.port = port
        self.transportKey = transportKey
        self.certificateFingerprint = certificateFingerprint
        self.pairingCoordinator = pairingCoordinator
        self.pairingStore = pairingStoreProtocol
        self.onPairingSucceeded = onPairingSucceeded
        self.launchSpacesAppHandler = launchSpacesAppHandler
        networkShaper = NetworkShaper(environment: networkEnvironment)
        self.terminalLinkTransferAuthorizationTTL = terminalLinkTransferAuthorizationTTL
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

    func terminalLinkTransferAuthorizationExpirationForTesting(linkID: String) -> Date? {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return terminalLinkTransferAuthorizations[linkID]?.expiresAt }
        return queue.sync { terminalLinkTransferAuthorizations[linkID]?.expiresAt }
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
            host: linkHost, port: listeningPort > 0 ? listeningPort : port, transportKey: transportKey,
            certificateFingerprint: certificateFingerprint, name: name, duration: duration)
    }

    public func openPairingWindow(
        host linkHost: String, name: String, duration: TimeInterval = SpacesMobilePairingCoordinator.defaultWindowDuration, code: String,
        nonce: String? = nil
    ) -> SpacesMobilePairingWindow {
        pairingCoordinator.openWindow(
            host: linkHost, port: listeningPort > 0 ? listeningPort : port, transportKey: transportKey,
            certificateFingerprint: certificateFingerprint, name: name, duration: duration, code: code, nonce: nonce)
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
        case "overview":
            return SpacesMobileBridgeResponse(ok: true, message: "Loaded mobile overview.", overview: try loadOverview(clientApp: request.clientApp))
        case "launchSpacesApp": return try handleLaunchSpacesAppRequest()
        case "workspaceCreateOptions": return try handleWorkspaceCreateOptionsRequest(request)
        case "createWorkspace": return try handleCreateWorkspaceRequest(request)
        case "openWorkspaceTerminal": return try handleOpenWorkspaceTerminalRequest(request)
        case "stopWorkspaceTerminal": return try handleStopWorkspaceTerminalRequest(request)
        case "runWorkspaceProcess": return try handleRunWorkspaceProcessRequest(request)
        case "stopWorkspaceProcess": return try handleStopWorkspaceProcessRequest(request)
        case "restartWorkspaceProcess": return try handleRestartWorkspaceProcessRequest(request)
        case "runCodingAgent": return try handleRunCodingAgentRequest(request)
        case "stopCodingAgent": return try handleStopCodingAgentRequest(request)
        case "restartCodingAgent": return try handleRestartCodingAgentRequest(request)
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
        case "resolveTerminalLink": return try handleResolveTerminalLinkRequest(request)
        case "readTerminalLinkChunk": return try handleReadTerminalLinkChunkRequest(request)
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
        trace(
            "terminal_control_request source_session=\(request.sessionID ?? "-") target_session=\(sessionID) client=\(clientID ?? request.client?.id ?? "-") command=\(command)"
        )
        if Self.ownerGatedTerminalCommands.contains(command), clientID == nil {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing mobile client ID.")
        }

        let startedAt = Date()
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return SpacesMobileBridgeResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.")
        }
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
        let sessionState = response.ok && command == "takeover" ? try? loadCurrentState(sessionID: sessionID) : nil
        return SpacesMobileBridgeResponse(ok: response.ok, message: response.message, sessionState: sessionState)
    }

    private static func normalizedClientID(from request: SpacesMobileBridgeRequest) -> String? {
        guard let clientID = request.clientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else { return nil }
        return clientID
    }

    private func handleLaunchSpacesAppRequest() throws -> SpacesMobileBridgeResponse {
        guard let launchSpacesAppHandler else {
            return SpacesMobileBridgeResponse(ok: false, message: "launchSpacesApp is only available from the daemon-hosted mobile bridge.")
        }
        let outcome = try launchSpacesAppHandler()
        return SpacesMobileBridgeResponse(ok: true, message: outcome.message)
    }

    private func loadOverview(clientApp: SpacesMobileClientApp? = nil) throws -> SpacesMobileOverviewPayload {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = mobileOrchestrator(store: store)
        let projects = try store.projects()
        let hostsByID = Dictionary(uniqueKeysWithValues: try store.computeHosts().map { ($0.id, $0) })
        let workspaces = try projects.flatMap { project in
            try store.workspaces(projectID: project.id, includeArchived: false).filter { !$0.isHidden }.map { workspace in
                SpacesMobileOverviewBuilder.WorkspaceDescriptor(
                    project: project, workspace: workspace, settings: try? orchestrator.workspaceSettings(workspaceID: workspace.id),
                    runningProcesses: try store.runningProcesses(workspaceID: workspace.id),
                    agentWindows: try store.agentWindows(workspaceID: workspace.id), windows: try store.windows(workspaceID: workspace.id),
                    terminalDaemonEndpoint: terminalDaemonEndpoint(project: project, workspace: workspace, hostsByID: hostsByID, clientApp: clientApp)
                )
            }
        }
        let localSessions = try TerminalSessionCatalog.listLiveSessions()
        let databaseRemoteSessions = loadDatabaseRemoteTerminalSessions(workspaces: workspaces)
        let remoteSessions = loadRemoteTerminalSessions(workspaces: workspaces)
        let sessions = mergedTerminalSessions(localSessions + databaseRemoteSessions.entries + remoteSessions.entries)
        let hasFinalRenderBySessionID = databaseRemoteSessions.hasFinalRenderBySessionID.merging(remoteSessions.hasFinalRenderBySessionID) {
            _, remote in remote
        }
        let workspaceRows = try loadWorkspaceTerminalRows(
            store: store, workspaces: workspaces, sessions: sessions, hasFinalRenderBySessionID: hasFinalRenderBySessionID)
        return SpacesMobileOverviewBuilder.build(projects: projects, workspaces: workspaces, workspaceRows: workspaceRows, liveSessions: sessions)
    }

    private func terminalDaemonEndpoint(
        project: ProjectRecord, workspace: WorkspaceRecord, hostsByID: [String: ComputeHostRecord], clientApp: SpacesMobileClientApp? = nil
    ) -> SpacesMobileTerminalDaemonEndpoint? {
        switch ComputeHostPlanner.selectHost(project: project, workspace: workspace, hostsByID: hostsByID) {
        case .local: return nil
        case .remote(let host):
            let adminToken = try? ComputeHostCredentialStore.resolvedAuthToken(hostID: host.id)
            let mobileToken = issueMobileTerminalCredential(host: host, adminToken: adminToken, clientApp: clientApp)
            return SpacesMobileTerminalDaemonEndpoint(
                host: host.daemonEndpoint.host, port: host.daemonEndpoint.port, authToken: mobileToken,
                certificateFingerprint: host.daemonEndpoint.certificateFingerprint)
        }
    }

    private func issueMobileTerminalCredential(host: ComputeHostRecord, adminToken: String?, clientApp: SpacesMobileClientApp?) -> String? {
        guard let clientApp else {
            trace("mobile_credential_issue_skipped host_id=\(host.id) reason=missing_client_app")
            return nil
        }
        if let cached = try? SpacesMobileRemoteTerminalCredentialStore.token(
            hostID: host.id, installationID: clientApp.installationID, certificateFingerprint: host.daemonEndpoint.certificateFingerprint)
        {
            trace("mobile_credential_issue_cached host_id=\(host.id)")
            return cached
        }
        guard let adminToken, !adminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            trace("mobile_credential_issue_skipped host_id=\(host.id) reason=missing_admin_token")
            return nil
        }
        do {
            let response = try TerminalServiceClient.sendPinnedTLS(
                request: TerminalServiceRequest(
                    command: "mobileCredential",
                    mobileCredentialRequest: TerminalServiceMobileCredentialRequest(
                        operation: .issue, installationID: clientApp.installationID, deviceName: clientApp.deviceName, platform: clientApp.platform)),
                host: host.daemonEndpoint.host, port: host.daemonEndpoint.port, authToken: adminToken,
                certificateFingerprint: host.daemonEndpoint.certificateFingerprint, timeout: 5)
            guard response.ok else {
                trace("mobile_credential_issue_failed host_id=\(host.id) message=\(Self.sanitizedTraceDetail(response.message))")
                return nil
            }
            if response.mobileCredentialToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                trace("mobile_credential_issue_failed host_id=\(host.id) message=missing_token")
            }
            if let token = response.mobileCredentialToken, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? SpacesMobileRemoteTerminalCredentialStore.saveToken(
                    token, hostID: host.id, installationID: clientApp.installationID,
                    certificateFingerprint: host.daemonEndpoint.certificateFingerprint)
                return token
            }
            return nil
        } catch {
            trace("mobile_credential_issue_error host_id=\(host.id) error=\(Self.sanitizedTraceDetail(error.localizedDescription))")
            return nil
        }
    }

    private static func sanitizedTraceDetail(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }

    private func loadDatabaseRemoteTerminalSessions(workspaces: [SpacesMobileOverviewBuilder.WorkspaceDescriptor]) -> RemoteTerminalSessionList {
        let remoteWorkspaceIDs = Set(workspaces.filter { $0.terminalDaemonEndpoint != nil }.map(\.workspace.id))
        guard !remoteWorkspaceIDs.isEmpty else { return RemoteTerminalSessionList(entries: [], hasFinalRenderBySessionID: [:]) }

        var entries: [TerminalSessionCatalogEntry] = []
        var hasFinalRenderBySessionID: [String: Bool] = [:]
        let configurations = (try? TerminalSessionPersistence.listKnownSessions()) ?? []
        for launchConfiguration in configurations {
            guard let workspaceID = launchConfiguration.workspaceID, remoteWorkspaceIDs.contains(workspaceID) else { continue }
            guard let paths = try? TerminalSessionPaths.forSession(id: launchConfiguration.sessionID),
                let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
            else { continue }
            let hasFinalRender = (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))?.renderSnapshot != nil
            guard runtimeState.state.isInteractive || hasFinalRender else { continue }
            hasFinalRenderBySessionID[launchConfiguration.sessionID] = hasFinalRender
            entries.append(
                TerminalSessionCatalogEntry(
                    launchConfiguration: launchConfiguration, runtimeState: runtimeState,
                    attachmentSnapshot: (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot(),
                    paths: paths, isControlAvailable: runtimeState.state.isInteractive, isSubscriptionAvailable: runtimeState.state.isInteractive))
        }
        return RemoteTerminalSessionList(entries: entries, hasFinalRenderBySessionID: hasFinalRenderBySessionID)
    }

    private func loadRemoteTerminalSessions(workspaces: [SpacesMobileOverviewBuilder.WorkspaceDescriptor]) -> RemoteTerminalSessionList {
        var entries: [TerminalSessionCatalogEntry] = []
        var hasFinalRenderBySessionID: [String: Bool] = [:]
        var endpointsByKey: [RemoteTerminalEndpointKey: SpacesMobileTerminalDaemonEndpoint] = [:]
        for endpoint in adminTerminalDaemonEndpoints(workspaces: workspaces) {
            let key = RemoteTerminalEndpointKey(
                host: endpoint.host, port: endpoint.port, authToken: endpoint.authToken, certificateFingerprint: endpoint.certificateFingerprint)
            endpointsByKey[key] = endpoint
        }
        for endpoint in endpointsByKey.values {
            guard
                let response = try? TerminalServiceClient.sendPinnedTLS(
                    request: TerminalServiceRequest(command: "list"), host: endpoint.host, port: endpoint.port, authToken: endpoint.authToken,
                    certificateFingerprint: endpoint.certificateFingerprint, timeout: 2), response.ok, let sessions = response.sessions
            else { continue }
            for summary in sessions {
                if let entry = remoteTerminalCatalogEntry(summary) { entries.append(entry) }
                hasFinalRenderBySessionID[summary.id] = summary.hasFinalRender
            }
        }
        return RemoteTerminalSessionList(entries: entries, hasFinalRenderBySessionID: hasFinalRenderBySessionID)
    }

    private func adminTerminalDaemonEndpoints(workspaces: [SpacesMobileOverviewBuilder.WorkspaceDescriptor]) -> [SpacesMobileTerminalDaemonEndpoint] {
        guard let store = try? SQLiteStore(path: DatabaseLocator.defaultPath()) else { return [] }
        var endpointsByHostID: [String: SpacesMobileTerminalDaemonEndpoint] = [:]
        for descriptor in workspaces {
            let hostID = descriptor.workspace.hostID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hostID.isEmpty, let host = try? store.computeHost(id: hostID),
                let token = try? ComputeHostCredentialStore.resolvedAuthToken(hostID: host.id)
            else { continue }
            endpointsByHostID[host.id] = SpacesMobileTerminalDaemonEndpoint(
                host: host.daemonEndpoint.host, port: host.daemonEndpoint.port, authToken: token,
                certificateFingerprint: host.daemonEndpoint.certificateFingerprint)
        }
        return Array(endpointsByHostID.values)
    }

    private func mergedTerminalSessions(_ sessions: [TerminalSessionCatalogEntry]) -> [TerminalSessionCatalogEntry] {
        var order: [String] = []
        var entriesByID: [String: TerminalSessionCatalogEntry] = [:]
        for session in sessions {
            if entriesByID[session.sessionID] == nil { order.append(session.sessionID) }
            entriesByID[session.sessionID] = session
        }
        return order.compactMap { entriesByID[$0] }
    }

    private func remoteTerminalCatalogEntry(_ summary: TerminalServiceSessionSummary) -> TerminalSessionCatalogEntry? {
        let fallbackTimestamp = summary.runtimeState?.updatedAt ?? ISO8601DateFormatter().string(from: Date())
        let launchConfiguration =
            summary.launchConfiguration
            ?? TerminalSessionLaunchConfiguration(
                sessionID: summary.id, backend: summary.backend, lifetimePolicy: summary.lifetimePolicy, title: summary.title,
                workingDirectory: summary.workingDirectory, shell: "/bin/bash", command: nil, createdAt: fallbackTimestamp, workspaceID: nil,
                kind: .shell)
        let runtimeState =
            summary.runtimeState
            ?? TerminalSessionRuntimeState(
                sessionID: summary.id, backend: summary.backend, servicePID: summary.servicePID, childPID: summary.childPID, state: summary.state,
                updatedAt: fallbackTimestamp, title: summary.title, workingDirectory: summary.workingDirectory)
        guard let paths = try? TerminalSessionPaths.forSession(id: summary.id) else { return nil }
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState,
            attachmentSnapshot: summary.attachmentSnapshot ?? TerminalSessionAttachmentSnapshot(), paths: paths,
            isControlAvailable: summary.state.isInteractive, isSubscriptionAvailable: summary.state.isInteractive)
    }

    private func loadWorkspaceTerminalRows(
        store: SQLiteStore, workspaces: [SpacesMobileOverviewBuilder.WorkspaceDescriptor], sessions: [TerminalSessionCatalogEntry],
        hasFinalRenderBySessionID: [String: Bool]
    ) throws -> [SpacesMobileOverviewBuilder.WorkspaceTerminalRow] {
        var rows: [SpacesMobileOverviewBuilder.WorkspaceTerminalRow] = []
        var representedSessionIDs = Set<String>()
        let sessionsByID = Dictionary(sessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { existing, _ in existing })
        for descriptor in workspaces {
            let processesBySlot = Dictionary(grouping: try store.runningProcesses(workspaceID: descriptor.workspace.id), by: { processSlotKey($0) })
            for process in processesBySlot.values.compactMap(preferredProcessRecord).sorted(by: {
                $0.templateName.localizedStandardCompare($1.templateName) == .orderedAscending
            }) {
                guard process.terminalApp == TerminalHost.spaces.appName,
                    let sessionID = normalizedTerminalSessionID(process.terminalNativeID ?? process.terminalTrackingID)
                else { continue }
                guard representedSessionIDs.insert(sessionID).inserted else { continue }
                guard let entry = sessionsByID[sessionID] ?? terminalCatalogEntry(sessionID: sessionID) else { continue }
                rows.append(
                    SpacesMobileOverviewBuilder.WorkspaceTerminalRow(
                        entry: entry, workspace: descriptor, title: process.templateName, rowKind: .process, rowSourceID: process.id,
                        hasFinalRender: hasFinalRenderBySessionID[sessionID] ?? terminalFinalRenderAvailable(sessionID: sessionID)))
            }

            let agentsBySlot = Dictionary(grouping: try store.agentWindows(workspaceID: descriptor.workspace.id), by: { agentSlotKey($0) })
            for agent in agentsBySlot.values.compactMap(preferredAgentRecord).sorted(by: {
                ($0.label ?? "").localizedStandardCompare($1.label ?? "") == .orderedAscending
            }) {
                guard agent.provider == .spaces, let sessionID = normalizedTerminalSessionID(agent.terminalNativeID ?? agent.terminalTrackingID)
                else { continue }
                guard representedSessionIDs.insert(sessionID).inserted else { continue }
                guard let entry = sessionsByID[sessionID] ?? terminalCatalogEntry(sessionID: sessionID) else { continue }
                rows.append(
                    SpacesMobileOverviewBuilder.WorkspaceTerminalRow(
                        entry: entry, workspace: descriptor, title: agent.label ?? entry.effectiveTitle, rowKind: .agent, rowSourceID: agent.id,
                        hasFinalRender: hasFinalRenderBySessionID[sessionID] ?? terminalFinalRenderAvailable(sessionID: sessionID)))
            }
        }
        return rows
    }

    private func preferredProcessRecord(_ records: [RunningProcessRecord]) -> RunningProcessRecord? {
        records.max { lhs, rhs in
            let lhsRank = processRecordRank(lhs)
            let rhsRank = processRecordRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (lhs.startedAt ?? lhs.exitedAt ?? "") < (rhs.startedAt ?? rhs.exitedAt ?? "")
        }
    }

    private func processRecordRank(_ record: RunningProcessRecord) -> Int {
        switch record.status {
        case .running: return 3
        case .idle: return 2
        case .exited: return 1
        }
    }

    private func preferredAgentRecord(_ records: [AgentWindowRecord]) -> AgentWindowRecord? {
        records.max { lhs, rhs in
            let lhsRank = agentRecordRank(lhs)
            let rhsRank = agentRecordRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func agentRecordRank(_ record: AgentWindowRecord) -> Int {
        if record.provider == .spaces, let sessionID = normalizedTerminalSessionID(record.terminalNativeID ?? record.terminalTrackingID),
            let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.state.isInteractive == true
        {
            return 4
        }
        switch record.status {
        case .spinning: return 3
        case .waiting: return 2
        case .idle: return 1
        case .done: return 0
        }
    }

    private func processSlotKey(_ record: RunningProcessRecord) -> String {
        if let templateID = record.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty {
            return "process-id:\(templateID)"
        }
        return "process:\(normalizedSlotName(record.templateName))"
    }

    private func agentSlotKey(_ record: AgentWindowRecord) -> String {
        if let claimedLauncherID = record.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines), !claimedLauncherID.isEmpty {
            return "agent-id:\(claimedLauncherID)"
        }
        let slotName = record.claimedLauncherName ?? record.label ?? record.id
        return "agent:\(normalizedSlotName(slotName))"
    }

    private func normalizedSlotName(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func terminalCatalogEntry(sessionID: String, fileManager: FileManager = .default) -> TerminalSessionCatalogEntry? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        else { return nil }
        guard !runtimeState.state.isInteractive || TerminalSessionCatalog.isInteractiveServiceAlive(for: runtimeState) else { return nil }
        let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? .init()
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot, paths: paths,
            isControlAvailable: fileManager.fileExists(atPath: paths.controlSocketPath),
            isSubscriptionAvailable: fileManager.fileExists(atPath: paths.subscriptionSocketPath))
    }

    private func terminalFinalRenderAvailable(sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        return (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))?.renderSnapshot != nil
    }

    private func normalizedTerminalSessionID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func mobileOrchestrator(store: SQLiteStore) -> WorkspaceOrchestrator {
        WorkspaceOrchestrator(store: store, builtInTerminalWindowOpener: { _, _ in })
    }

    private func handleWorkspaceCreateOptionsRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = mobileOrchestrator(store: store)
        let projects = try store.projects().map {
            SpacesMobileProjectSummary(
                id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch, isCollapsed: $0.isCollapsed)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selectedProjectID = normalizedString(request.projectID) ?? projects.first?.id
        let branchOptions: [String]
        if let selectedProjectID, let project = try store.project(id: selectedProjectID), project.isGitRepo {
            branchOptions = try orchestrator.gitBranchOptions(projectID: selectedProjectID)
        } else {
            branchOptions = []
        }
        return SpacesMobileBridgeResponse(
            ok: true, message: "Loaded workspace create options.",
            workspaceCreateOptions: SpacesMobileWorkspaceCreateOptions(
                projects: projects, selectedProjectID: selectedProjectID, branchOptions: branchOptions))
    }

    private func handleCreateWorkspaceRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let projectID = normalizedString(request.projectID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing project ID.")
        }
        guard let title = normalizedString(request.workspaceTitle) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing workspace title.")
        }
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = mobileOrchestrator(store: store)
        let project = try store.project(id: projectID)
        let workspace = try orchestrator.createWorkspace(
            projectID: projectID, name: title, branch: normalizedString(request.branch), targetBranch: normalizedString(request.targetBranch),
            directoryName: normalizedString(request.directoryName), runSetupScript: true, allowRemoteBranchLookup: true,
            allowExistingBranchReuse: request.allowExistingBranchReuse)
        let message = "Created workspace '\(workspace.title)'\(project.map { " in \($0.name)" } ?? "")."
        return try refreshedMutationResponse(message: message, workspaceID: workspace.id)
    }

    private func handleOpenWorkspaceTerminalRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let workspaceID = normalizedString(request.workspaceID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing workspace ID.")
        }
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let sessionID = try mobileOrchestrator(store: store).openWorkspaceTerminal(workspaceID: workspaceID)
        return try refreshedMutationResponse(message: "Opened workspace terminal.", workspaceID: workspaceID, sessionID: sessionID)
    }

    private func handleStopWorkspaceTerminalRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let workspaceID = normalizedString(request.workspaceID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing workspace ID.")
        }
        guard let sessionID = normalizedString(request.sessionID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing terminal session ID.")
        }
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard try mobileOrchestrator(store: store).stopAdHocBuiltInTerminalSession(workspaceID: workspaceID, sessionID: sessionID) else {
            return try refreshedMutationResponse(message: "Workspace terminal was already stopped.", workspaceID: workspaceID)
        }
        return try refreshedMutationResponse(message: "Stopped workspace terminal.", workspaceID: workspaceID)
    }

    private func handleRunWorkspaceProcessRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let workspaceID = normalizedString(request.workspaceID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing workspace ID.")
        }
        guard let processKey = normalizedString(request.processKey) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing process key.")
        }
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        if let processTemplateID = normalizedString(request.processTemplateID) {
            try mobileOrchestrator(store: store).runConfiguredProcess(
                workspaceID: workspaceID, processTemplateID: processTemplateID, processKey: processKey)
        } else {
            try mobileOrchestrator(store: store).runConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
        }
        return try refreshedMutationResponse(message: "Ran process '\(processKey)'.", workspaceID: workspaceID)
    }

    private func handleStopWorkspaceProcessRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let workspaceID = normalizedString(request.workspaceID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing workspace ID.")
        }
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let processID = try resolvedRunningProcessID(request: request, store: store)
        try mobileOrchestrator(store: store).stopWorkspaceProcess(workspaceID: workspaceID, processID: processID)
        return try refreshedMutationResponse(message: "Stopped process.", workspaceID: workspaceID)
    }

    private func handleRestartWorkspaceProcessRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let workspaceID = normalizedString(request.workspaceID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing workspace ID.")
        }
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let processID = try resolvedRunningProcessID(request: request, store: store)
        try mobileOrchestrator(store: store).restartWorkspaceProcess(workspaceID: workspaceID, processID: processID)
        return try refreshedMutationResponse(message: "Restarted process.", workspaceID: workspaceID)
    }

    private func handleRunCodingAgentRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let workspaceID = normalizedString(request.workspaceID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing workspace ID.")
        }
        guard let agentName = normalizedString(request.agentName) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing coding agent name.")
        }
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let record =
            if let agentLauncherID = normalizedString(request.agentLauncherID) {
                try mobileOrchestrator(store: store).launchAgentLauncher(workspaceID: workspaceID, launcherID: agentLauncherID)
            } else { try mobileOrchestrator(store: store).launchAgentLauncher(workspaceID: workspaceID, name: agentName) }
        return try refreshedMutationResponse(
            message: "Ran coding agent '\(agentName)'.", workspaceID: workspaceID,
            sessionID: normalizedString(record.terminalNativeID ?? record.terminalTrackingID))
    }

    private func handleStopCodingAgentRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let workspaceID = normalizedString(request.workspaceID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing workspace ID.")
        }
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard let agentID = try resolvedAgentID(request: request, store: store) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing coding agent ID.")
        }
        try mobileOrchestrator(store: store).stopCodingAgent(workspaceID: workspaceID, agentID: agentID)
        return try refreshedMutationResponse(message: "Stopped coding agent.", workspaceID: workspaceID)
    }

    private func handleRestartCodingAgentRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let workspaceID = normalizedString(request.workspaceID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing workspace ID.")
        }
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard let agentID = try resolvedAgentID(request: request, store: store) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing coding agent ID.")
        }
        let record = try mobileOrchestrator(store: store).restartCodingAgent(workspaceID: workspaceID, agentID: agentID)
        return try refreshedMutationResponse(
            message: "Restarted coding agent.", workspaceID: workspaceID,
            sessionID: normalizedString(record.terminalNativeID ?? record.terminalTrackingID))
    }

    private func refreshedMutationResponse(message: String, workspaceID: String? = nil, sessionID: String? = nil) throws -> SpacesMobileBridgeResponse
    { SpacesMobileBridgeResponse(ok: true, message: message, overview: try loadOverview(), workspaceID: workspaceID, sessionID: sessionID) }

    private func resolvedRunningProcessID(request: SpacesMobileBridgeRequest, store: SQLiteStore) throws -> String {
        if let processID = normalizedString(request.processID) { return processID }
        if let workspaceID = normalizedString(request.workspaceID), let processTemplateID = normalizedString(request.processTemplateID),
            let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.templateID == processTemplateID })
        {
            return process.id
        }
        guard let workspaceID = normalizedString(request.workspaceID), let processKey = normalizedString(request.processKey) else {
            throw NSError(domain: "SpacesMobileBridgeServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing process ID."])
        }
        let normalizedProcessKey = normalizedRowKey(processKey)
        guard
            let process = try store.runningProcesses(workspaceID: workspaceID).first(where: {
                normalizedRowKey($0.templateName) == normalizedProcessKey
            })
        else { throw NSError(domain: "SpacesMobileBridgeServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Running process not found."]) }
        return process.id
    }

    private func resolvedAgentID(request: SpacesMobileBridgeRequest, store: SQLiteStore) throws -> String? {
        if let agentID = normalizedString(request.agentID) { return agentID }
        if let workspaceID = normalizedString(request.workspaceID), let agentLauncherID = normalizedString(request.agentLauncherID),
            let agentID = try store.agentWindows(workspaceID: workspaceID).first(where: { $0.claimedLauncherID == agentLauncherID })?.id
        {
            return agentID
        }
        guard let workspaceID = normalizedString(request.workspaceID), let agentName = normalizedString(request.agentName) else { return nil }
        let normalizedAgentName = normalizedRowKey(agentName)
        return try store.agentWindows(workspaceID: workspaceID).first { normalizedRowKey($0.label ?? $0.claimedLauncherName) == normalizedAgentName }?
            .id
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func normalizedRowKey(_ value: String?) -> String { normalizedString(value)?.lowercased() ?? "" }

    private func handleStateRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let sessionID = request.sessionID else { return SpacesMobileBridgeResponse(ok: false, message: "Missing session ID.") }
        let startedAt = Date()
        let payload = try loadCurrentState(sessionID: sessionID)
        TerminalPerformance.logMetric(
            "mobile_bridge_state", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
        return SpacesMobileBridgeResponse(ok: true, message: "Loaded terminal state.", sessionState: payload)
    }

    private func handleResolveTerminalLinkRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let sessionID = normalizedString(request.sessionID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing session ID.")
        }
        pruneTerminalLinkTransferAuthorizations(now: Date())
        let metadata: SpacesMobileTerminalLinkMetadata
        if canResolveTerminalLinkWithoutLocalState(request.terminalLink) {
            metadata = try SpacesMobileTerminalLinkResolver.resolve(
                sessionID: sessionID, link: request.terminalLink, workingDirectory: nil, workspaceRoots: [])
        } else {
            let workspaceRoots = try loadWorkspaceRoots()
            metadata = try SpacesMobileTerminalLinkResolver.resolve(
                sessionID: sessionID, link: request.terminalLink, workingDirectory: terminalWorkingDirectory(sessionID: sessionID),
                workspaceRoots: workspaceRoots)
        }
        if metadata.source == .localFile {
            let resolvedPath = try SpacesMobileTerminalLinkResolver.resolvedLocalFilePath(linkID: metadata.id)
            authorizeTerminalLinkTransfer(linkID: metadata.id, sessionID: sessionID, resolvedPath: resolvedPath, now: Date())
        }
        return SpacesMobileBridgeResponse(ok: true, message: "Resolved terminal link.", terminalLinkMetadata: metadata)
    }

    private func handleReadTerminalLinkChunkRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let sessionID = normalizedString(request.sessionID) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Missing session ID.")
        }
        guard let linkID = normalizedString(request.terminalLinkID) else { throw SpacesMobileTerminalLinkResolverError.invalidLinkID }
        guard let authorization = try terminalLinkTransferAuthorization(linkID: linkID, sessionID: sessionID, now: Date()) else {
            throw SpacesMobileTerminalLinkResolverError.invalidLinkID
        }
        let chunk = try SpacesMobileTerminalLinkResolver.readChunk(
            sessionID: sessionID, linkID: linkID, offset: request.chunkOffset, limit: request.chunkLimit, workspaceRoots: [authorization.resolvedPath]
        )
        authorizeTerminalLinkTransfer(linkID: linkID, sessionID: sessionID, resolvedPath: authorization.resolvedPath, now: Date())
        return SpacesMobileBridgeResponse(ok: true, message: "Read terminal link chunk.", terminalLinkChunk: chunk)
    }

    private func authorizeTerminalLinkTransfer(linkID: String, sessionID: String, resolvedPath: String, now: Date) {
        terminalLinkTransferAuthorizations[linkID] = TerminalLinkTransferAuthorization(
            sessionID: sessionID, resolvedPath: resolvedPath, expiresAt: now.addingTimeInterval(terminalLinkTransferAuthorizationTTL))
    }

    private func terminalLinkTransferAuthorization(linkID: String, sessionID: String, now: Date) throws -> TerminalLinkTransferAuthorization? {
        pruneTerminalLinkTransferAuthorizations(now: now)
        guard let authorization = terminalLinkTransferAuthorizations[linkID] else { return nil }
        guard authorization.sessionID == sessionID else { throw SpacesMobileTerminalLinkResolverError.sessionMismatch }
        return authorization
    }

    private func pruneTerminalLinkTransferAuthorizations(now: Date) {
        terminalLinkTransferAuthorizations = terminalLinkTransferAuthorizations.filter { $0.value.expiresAt > now }
    }

    private func canResolveTerminalLinkWithoutLocalState(_ value: String?) -> Bool {
        guard let link = normalizedString(value), let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return scheme != "file"
    }

    private func terminalWorkingDirectory(sessionID: String) throws -> String {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let workingDirectory = normalizedString((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.workingDirectory) {
            return workingDirectory
        }
        return try TerminalSessionPersistence.readLaunchConfiguration(paths: paths).workingDirectory
    }

    private func loadWorkspaceRoots() throws -> [String] {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let projects = try store.projects()
        var roots = Set(projects.map(\.dir))
        for project in projects {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
            roots.formUnion(workspaces.map(\.dir))
        }
        return Array(roots)
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
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            let payload =
                (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))
                ?? (try? endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState))
            if let payload {
                sendStreamPayloadAndComplete(payload, sessionID: sessionID, to: connection)
            } else {
                sendResponse(SpacesMobileBridgeResponse(ok: false, message: "Terminal session '\(sessionID)' has no final state."), to: connection) {
                    _ in connection.cancel()
                }
            }
            return
        }
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

    private func sendStreamPayloadAndComplete(_ payload: GhosttyRemoteSessionStatePayload, sessionID: String, to connection: NWConnection) {
        do {
            let data = try GhosttyRemoteSessionStateCodec.encodeLine(payload)
            let attributes = streamRelayAttributes(for: data)
            logBridgePerformance(sessionID: sessionID, name: "stream_relay_read", count: data.count, attributes: attributes)
            networkShaper.send(
                content: data, to: connection, on: queue,
                onSendBegin: { [weak self, sessionID, attributes, count = data.count] in
                    self?.logBridgePerformance(sessionID: sessionID, name: "stream_network_send_begin", count: count, attributes: attributes)
                }, isComplete: true
            ) { [weak self, weak connection] error in
                if let error {
                    self?.trace("stream_final_payload_send_error session=\(sessionID) error=\(error)")
                    connection?.cancel()
                } else {
                    connection?.cancel()
                }
            }
        } catch {
            sendResponse(SpacesMobileBridgeResponse(ok: false, message: String(describing: error)), to: connection) { _ in connection.cancel() }
        }
    }

    private func relayStateData(from relaySocketFD: Int32, to connection: NWConnection) {
        var buffer = [UInt8](repeating: 0, count: Self.streamRelayReadBufferSize)
        var relayedData = Data()
        var firstReadUptimeNanoseconds: UInt64?
        while true {
            let count = read(relaySocketFD, &buffer, buffer.count)
            if count == 0 {
                if !relayedData.isEmpty {
                    enqueueRelayedStateData(relayedData, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection, closeAfterSend: true)
                } else {
                    queue.async { [weak self, weak connection] in
                        guard let self, let connection else { return }
                        self.closeStreamRelayAfterQueuedSendsDrain(connection: connection)
                    }
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
                    self.closeStreamRelayUnlessFinalSendPending(connection: connection)
                }
                return
            }
            firstReadUptimeNanoseconds = firstReadUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds
            relayedData.append(buffer, count: count)
        }
    }

    private func enqueueRelayedStateData(_ data: Data, firstReadUptimeNanoseconds: UInt64?, to connection: NWConnection, closeAfterSend: Bool = false)
    {
        queue.async { [weak self, weak connection, data, firstReadUptimeNanoseconds, closeAfterSend] in
            guard let self, let connection else { return }
            if closeAfterSend, self.prepareStreamRelayForFinalSend(connection: connection) == nil { return }
            self.sendRelayedStateData(data, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection, closeAfterSend: closeAfterSend)
        }
    }

    private func prepareStreamRelayForFinalSend(connection: NWConnection) -> (relay: StreamRelay, didStartClosing: Bool)? {
        let key = ObjectIdentifier(connection)
        guard let relay = streamRelays[key] else { return nil }
        let didStartClosing = streamRelaysClosingAfterFinalSend.insert(key).inserted
        guard didStartClosing else { return (relay, false) }
        relay.heartbeatTimer?.cancel()
        relay.relaySource.cancel()
        shutdown(relay.relaySocketFD, SHUT_RDWR)
        return (relay, true)
    }

    private func sendRelayedStateData(_ data: Data, firstReadUptimeNanoseconds: UInt64?, to connection: NWConnection, closeAfterSend: Bool = false) {
        guard let relay = streamRelays[ObjectIdentifier(connection)] else { return }
        let attributes = streamRelayAttributes(for: data)
        logBridgePerformance(
            sessionID: relay.sessionID, name: "stream_relay_read",
            emittedUptimeNanoseconds: firstReadUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds, count: data.count, attributes: attributes)
        relay.sendSequencer.enqueue { [weak self, weak connection, sessionID = relay.sessionID, attributes, data, closeAfterSend] finish in
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
                }, isComplete: closeAfterSend, applyInitialDelay: closeAfterSend, applyBandwidthDelay: closeAfterSend
            ) { [weak self, weak connection] error in
                self?.queue.async { [weak self, weak connection] in
                    if let error {
                        self?.trace("stream_relay_send_error error=\(error)")
                        if let self, let connection { self.closeStreamRelay(connection: connection) }
                    } else if closeAfterSend, let self, let connection {
                        self.closeStreamRelay(connection: connection)
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

    private func closeStreamRelay(connection: NWConnection, cancelNetworkConnection: Bool = true) {
        let key = ObjectIdentifier(connection)
        guard let relay = streamRelays.removeValue(forKey: key) else {
            streamRelaysClosingAfterFinalSend.remove(key)
            return
        }
        let relayReadSideAlreadyClosed = streamRelaysClosingAfterFinalSend.remove(key) != nil
        trace("stream_relay_close peer=\(String(describing: connection.endpoint))")
        if !relayReadSideAlreadyClosed {
            relay.heartbeatTimer?.cancel()
            relay.relaySource.cancel()
            shutdown(relay.relaySocketFD, SHUT_RDWR)
        }
        if cancelNetworkConnection { connection.cancel() }
    }

    private func closeStreamRelayUnlessFinalSendPending(connection: NWConnection) {
        guard !streamRelaysClosingAfterFinalSend.contains(ObjectIdentifier(connection)) else { return }
        closeStreamRelay(connection: connection)
    }

    private func closeStreamRelayAfterQueuedSendsDrain(connection: NWConnection) {
        guard let prepared = prepareStreamRelayForFinalSend(connection: connection), prepared.didStartClosing else { return }
        prepared.relay.sendSequencer.enqueue { [weak self, weak connection] finish in
            defer { finish(nil) }
            guard let self, let connection else { return }
            self.closeStreamRelay(connection: connection)
        }
    }

    private func closeRequestConnection(connection: NWConnection) {
        requestConnections.removeValue(forKey: ObjectIdentifier(connection))
        trace("request_connection_closed active=\(requestConnections.count)")
    }

    private func closeRequestConnectionAfterNetworkUpdate(connection: NWConnection, cancelNetworkConnection: Bool) {
        performOnQueue {
            self.closeStreamRelay(connection: connection, cancelNetworkConnection: cancelNetworkConnection)
            self.closeRequestConnection(connection: connection)
        }
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
        terminalLinkTransferAuthorizations.removeAll()
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

    private func performOnQueue(_ work: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() } else { queue.async(execute: work) }
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
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            if let finalState = try? TerminalSessionPersistence.readRemoteSessionState(paths: paths) { return finalState }
            return try endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState)
        }
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

    private func endedStatePayload(sessionID: String, paths: TerminalSessionPaths, runtimeState: TerminalSessionRuntimeState) throws
        -> GhosttyRemoteSessionStatePayload
    {
        let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot()
        let emittedAt = runtimeState.exitedAt ?? runtimeState.updatedAt
        return GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: emittedAt, sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
            title: runtimeState.title ?? launchConfiguration?.title ?? sessionID,
            workingDirectory: runtimeState.workingDirectory ?? launchConfiguration?.workingDirectory ?? paths.rootDirectory, outputByteCount: nil)
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

private enum SpacesMobileRemoteTerminalCredentialStore {
    private static let service = "app.asmvik.Spaces.mobile-terminal-credential"

    static func token(hostID: String, installationID: String, certificateFingerprint: String) throws -> String? {
        #if canImport(Security)
            let query = try baseQuery(hostID: hostID, installationID: installationID, certificateFingerprint: certificateFingerprint).merging([
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        #else
            nil
        #endif
    }

    static func saveToken(_ token: String, hostID: String, installationID: String, certificateFingerprint: String) throws {
        #if canImport(Security)
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let query = try baseQuery(hostID: hostID, installationID: installationID, certificateFingerprint: certificateFingerprint)
            let tokenData = Data(trimmed.utf8)
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: tokenData] as CFDictionary)
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else { return }
            var addQuery = query
            addQuery[kSecValueData as String] = tokenData
            SecItemAdd(addQuery as CFDictionary, nil)
        #endif
    }

    #if canImport(Security)
        private static func baseQuery(hostID: String, installationID: String, certificateFingerprint: String) throws -> [String: Any] {
            let profile = try SpacesProfile.current()
            return [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: "\(profile.rootDirectory)#\(hostID)#\(certificateFingerprint)#\(installationID)",
            ]
        }
    #endif
}
