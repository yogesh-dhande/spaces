import CryptoKit
import Foundation
import Network
@preconcurrency import Security

public enum TerminalServiceTLSFingerprint {
    public static func fingerprint(certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: data)
        return "SHA256:\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "").lowercased()
    }

    public static func matches(_ lhs: String, _ rhs: String) -> Bool { normalized(lhs) == normalized(rhs) }
}

#if os(macOS)
    public struct TerminalServiceTLSIdentity: @unchecked Sendable {
        public let identity: SecIdentity
        public let certificateFingerprint: String

        public init(identity: SecIdentity, certificateFingerprint: String) {
            self.identity = identity
            self.certificateFingerprint = certificateFingerprint
        }
    }

    public enum TerminalServiceTLSIdentityStore {
        public static func loadOrCreate(fileManager: FileManager = .default) throws -> TerminalServiceTLSIdentity {
            let root = try rootDirectory(fileManager: fileManager)
            return try loadOrCreate(root: root, fileManager: fileManager)
        }

        public static func loadOrCreate(root: URL, fileManager: FileManager = .default) throws -> TerminalServiceTLSIdentity {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let p12URL = root.appendingPathComponent("identity.p12", isDirectory: false)
            let passphraseURL = root.appendingPathComponent("identity.passphrase", isDirectory: false)

            if fileManager.fileExists(atPath: p12URL.path), fileManager.fileExists(atPath: passphraseURL.path) {
                return try importIdentity(p12URL: p12URL, passphraseURL: passphraseURL)
            }

            try generateIdentity(root: root, p12URL: p12URL, passphraseURL: passphraseURL, fileManager: fileManager)
            return try importIdentity(p12URL: p12URL, passphraseURL: passphraseURL)
        }

        public static func rootDirectory(fileManager: FileManager = .default) throws -> URL {
            try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager).appendingPathComponent("daemon-tls", isDirectory: true)
        }

        private static func importIdentity(p12URL: URL, passphraseURL: URL) throws -> TerminalServiceTLSIdentity {
            let p12Data = try Data(contentsOf: p12URL)
            let passphrase = try String(contentsOf: passphraseURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            var importedItems: CFArray?
            let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
            let status = SecPKCS12Import(p12Data as CFData, options, &importedItems)
            guard status == errSecSuccess, let items = importedItems as? [[String: Any]],
                let importedIdentity = items.first?[kSecImportItemIdentity as String]
            else { throw TerminalServiceTLSError.identityImportFailed(status) }
            let identity = importedIdentity as! SecIdentity

            var certificate: SecCertificate?
            let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
            guard certificateStatus == errSecSuccess, let certificate else {
                throw TerminalServiceTLSError.certificateExportFailed(certificateStatus)
            }
            return TerminalServiceTLSIdentity(
                identity: identity, certificateFingerprint: TerminalServiceTLSFingerprint.fingerprint(certificate: certificate))
        }

        private static func generateIdentity(root: URL, p12URL: URL, passphraseURL: URL, fileManager: FileManager) throws {
            let temporaryRoot = root.appendingPathComponent("generate-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            let keyURL = temporaryRoot.appendingPathComponent("key.pem", isDirectory: false)
            let certificateURL = temporaryRoot.appendingPathComponent("certificate.pem", isDirectory: false)
            let generatedP12URL = temporaryRoot.appendingPathComponent("identity.p12", isDirectory: false)
            let passphrase = randomPassphrase()

            try runOpenSSL([
                "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "825", "-nodes", "-subj", "/CN=spacesd", "-keyout", keyURL.path, "-out",
                certificateURL.path,
            ])
            try runOpenSSL([
                "pkcs12", "-export", "-out", generatedP12URL.path, "-inkey", keyURL.path, "-in", certificateURL.path, "-passout",
                "pass:\(passphrase)",
            ])

            if fileManager.fileExists(atPath: p12URL.path) { try fileManager.removeItem(at: p12URL) }
            if fileManager.fileExists(atPath: passphraseURL.path) { try fileManager.removeItem(at: passphraseURL) }
            try fileManager.moveItem(at: generatedP12URL, to: p12URL)
            try passphrase.write(to: passphraseURL, atomically: true, encoding: .utf8)
            chmod(p12URL.path, S_IRUSR | S_IWUSR)
            chmod(passphraseURL.path, S_IRUSR | S_IWUSR)
        }

        private static func randomPassphrase() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let data = status == errSecSuccess ? Data(bytes) : Data((UUID().uuidString + UUID().uuidString).utf8.prefix(32))
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(
                of: "=", with: "")
        }

        private static func runOpenSSL(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["openssl"] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw TerminalServiceTLSError.opensslFailed(
                    message?.isEmpty == false ? message! : "openssl exited with code \(process.terminationStatus)")
            }
        }
    }
#endif

public enum TerminalServiceTLSError: LocalizedError, Equatable {
    case missingCertificateFingerprint
    case peerCertificateUnavailable
    case certificatePinMismatch(expected: String, actual: String)
    case identityImportFailed(OSStatus)
    case certificateExportFailed(OSStatus)
    case opensslFailed(String)
    case requestTimedOut
    case connectionFailed(String)
    case invalidPort(Int)

    public var errorDescription: String? {
        switch self {
        case .missingCertificateFingerprint: "Remote spacesd certificate fingerprint is missing."
        case .peerCertificateUnavailable: "Remote spacesd did not present a certificate."
        case .certificatePinMismatch(let expected, let actual):
            "Remote spacesd certificate fingerprint mismatch. Expected \(expected), got \(actual)."
        case .identityImportFailed(let status): "Failed to import the spacesd TLS identity. Security status: \(status)."
        case .certificateExportFailed(let status): "Failed to read the spacesd TLS certificate. Security status: \(status)."
        case .opensslFailed(let message): "Failed to generate the spacesd TLS certificate: \(message)"
        case .requestTimedOut: "Timed out waiting for remote spacesd."
        case .connectionFailed(let message): "Remote spacesd TLS connection failed: \(message)"
        case .invalidPort(let port): "Remote spacesd TLS port is invalid: \(port)."
        }
    }
}

#if os(macOS)
    public final class TerminalServiceTLSServer: @unchecked Sendable {
        private final class RequestConnection: @unchecked Sendable {
            private let connection: NWConnection
            private let server: TerminalServiceTLSServer
            private var buffer = Data()

            init(connection: NWConnection, server: TerminalServiceTLSServer) {
                self.connection = connection
                self.server = server
            }

            func cancel() { connection.cancel() }

            func start(on queue: DispatchQueue) {
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    terminalServiceTLSTrace("server_connection_state \(state)")
                    switch state {
                    case .ready: self.receiveNext()
                    case .failed, .cancelled: self.server.removeConnection(self.connection)
                    default: break
                    }
                }
                connection.start(queue: queue)
            }

            private func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
                    guard let self else { return }
                    if let content, !content.isEmpty { self.buffer.append(content) }
                    if error != nil {
                        self.connection.cancel()
                        self.server.removeConnection(self.connection)
                        return
                    }
                    if let newlineIndex = self.buffer.firstIndex(of: 0x0A) {
                        let requestData = Data(self.buffer.prefix(upTo: newlineIndex))
                        self.processRequest(requestData)
                        return
                    }
                    guard isComplete else {
                        self.receiveNext()
                        return
                    }
                    self.processRequest(self.buffer)
                }
            }

            private func processRequest(_ requestData: Data) {
                let response: TerminalServiceResponse
                do {
                    let request = try TerminalServiceCodec.decodeRequest(requestData)
                    response = try server.validateAndHandle(request: request)
                } catch { response = TerminalServiceResponse(ok: false, message: String(describing: error)) }
                var responseData = (try? TerminalServiceCodec.encodeResponse(response)) ?? Data()
                responseData.append(0x0A)
                connection.send(
                    content: responseData, contentContext: .defaultMessage, isComplete: true,
                    completion: .contentProcessed { [weak self] _ in
                        guard let self else { return }
                        self.connection.cancel()
                        self.server.removeConnection(self.connection)
                    })
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
                guard semaphore.wait(timeout: .now() + timeout) == .success else { return .failure(TerminalServiceTLSError.requestTimedOut) }
                lock.lock()
                let result = self.result ?? .failure(TerminalServiceTLSError.requestTimedOut)
                lock.unlock()
                return result
            }
        }

        private let host: String
        private let port: Int
        private let authToken: String?
        private let identity: TerminalServiceTLSIdentity
        private let queue: DispatchQueue
        private let handleRequest: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
        private var listener: NWListener?
        private var connections: [ObjectIdentifier: RequestConnection] = [:]

        public private(set) var listeningPort: Int = 0
        public var certificateFingerprint: String { identity.certificateFingerprint }

        public init(
            host: String, port: Int, authToken: String? = nil, identity: TerminalServiceTLSIdentity, queue: DispatchQueue,
            handleRequest: @escaping @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
        ) {
            self.host = host
            self.port = port
            self.authToken = authToken
            self.identity = identity
            self.queue = queue
            self.handleRequest = handleRequest
        }

        public func start(timeout: TimeInterval = 5) throws {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw TerminalServiceTLSError.invalidPort(port) }
            let tlsOptions = NWProtocolTLS.Options()
            let securityOptions = tlsOptions.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)
            sec_protocol_options_set_peer_authentication_required(securityOptions, false)
            guard let secIdentity = sec_identity_create(identity.identity) else { throw TerminalServiceTLSError.identityImportFailed(errSecParam) }
            sec_protocol_options_set_local_identity(securityOptions, secIdentity)

            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            let createdListener: NWListener
            if isWildcardHost(host) {
                createdListener = try NWListener(using: parameters, on: nwPort)
            } else {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
                createdListener = try NWListener(using: parameters)
            }
            let startup = StartupSignal()
            createdListener.newConnectionHandler = { [weak self] connection in
                terminalServiceTLSTrace("server_accept \(connection.endpoint)")
                guard let self else {
                    connection.cancel()
                    return
                }
                let requestConnection = RequestConnection(connection: connection, server: self)
                self.connections[ObjectIdentifier(connection)] = requestConnection
                requestConnection.start(on: self.queue)
            }
            createdListener.stateUpdateHandler = { [weak self, weak createdListener] state in
                guard let self else { return }
                terminalServiceTLSTrace("server_listener_state \(state)")
                switch state {
                case .ready:
                    self.listeningPort = Int(createdListener?.port?.rawValue ?? UInt16(self.port))
                    startup.signal(.success(()))
                case .failed(let error): startup.signal(.failure(error))
                case .cancelled: break
                default: break
                }
            }
            listener = createdListener
            createdListener.start(queue: queue)
            switch startup.wait(timeout: timeout) {
            case .success: break
            case .failure(let error):
                createdListener.cancel()
                throw error
            }
        }

        public func stop() {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }

        private func removeConnection(_ connection: NWConnection) { connections.removeValue(forKey: ObjectIdentifier(connection)) }

        private func validateAndHandle(request: TerminalServiceRequest) throws -> TerminalServiceResponse {
            if let authToken, authToken != request.authToken { return TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client.") }
            return try handleRequest(request)
        }
    }
#endif

extension TerminalServiceClient {
    public static func sendPinnedTLS(
        request: TerminalServiceRequest, host: String, port: Int, authToken: String? = nil, certificateFingerprint: String, timeout: TimeInterval = 15
    ) throws -> TerminalServiceResponse {
        let expectedFingerprint = certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedFingerprint.isEmpty else { throw TerminalServiceTLSError.missingCertificateFingerprint }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw TerminalServiceTLSError.invalidPort(port) }

        let ready = DispatchSemaphore(value: 0)
        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(securityOptions, true)
        let pinBox = TerminalServiceTLSPinBox()
        sec_protocol_options_set_verify_block(
            securityOptions,
            { _, trust, complete in
                terminalServiceTLSTrace("client_verify")
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]
                guard let certificate = chain?.first else {
                    pinBox.setError(TerminalServiceTLSError.peerCertificateUnavailable)
                    ready.signal()
                    complete(false)
                    return
                }
                let actualFingerprint = TerminalServiceTLSFingerprint.fingerprint(certificate: certificate)
                guard TerminalServiceTLSFingerprint.matches(expectedFingerprint, actualFingerprint) else {
                    pinBox.setError(TerminalServiceTLSError.certificatePinMismatch(expected: expectedFingerprint, actual: actualFingerprint))
                    ready.signal()
                    complete(false)
                    return
                }
                complete(true)
            }, DispatchQueue.global(qos: .userInitiated))

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options()))
        let queue = DispatchQueue(label: "spaces.terminal.service.tls.client")
        let sent = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let resultBox = TerminalServiceTLSClientResultBox()

        connection.stateUpdateHandler = { state in
            terminalServiceTLSTrace("client_state \(state)")
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                resultBox.setError(pinBox.error() ?? TerminalServiceTLSError.connectionFailed(String(describing: error)))
                ready.signal()
                sent.signal()
                received.signal()
            case .cancelled: break
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            if let error = pinBox.error() { throw error }
            throw TerminalServiceTLSError.requestTimedOut
        }
        if let error = pinBox.error() {
            connection.cancel()
            throw error
        }
        if let error = resultBox.error() { throw error }

        var payload = try TerminalServiceCodec.encodeRequest(request.withAuthToken(authToken ?? request.authToken))
        payload.append(0x0A)
        connection.send(
            content: payload, contentContext: .defaultMessage, isComplete: false,
            completion: .contentProcessed { error in
                if let error { resultBox.setError(TerminalServiceTLSError.connectionFailed(String(describing: error))) }
                sent.signal()
            })
        guard sent.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            throw TerminalServiceTLSError.requestTimedOut
        }
        if let error = resultBox.error() { throw error }

        receiveTLSResponse(connection: connection, resultBox: resultBox, completion: received)
        guard received.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            throw TerminalServiceTLSError.requestTimedOut
        }
        connection.cancel()
        if let error = resultBox.error() { throw error }
        return try TerminalServiceCodec.decodeResponse(resultBox.responseData())
    }

    private static func receiveTLSResponse(
        connection: NWConnection, data: Data = Data(), resultBox: TerminalServiceTLSClientResultBox, completion: DispatchSemaphore
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let error {
                resultBox.setError(TerminalServiceTLSError.connectionFailed(String(describing: error)))
                completion.signal()
                return
            }
            var nextData = data
            if let content { nextData.append(content) }
            if let newlineIndex = nextData.firstIndex(of: 0x0A) {
                resultBox.setResponseData(Data(nextData.prefix(upTo: newlineIndex)))
                completion.signal()
                return
            }
            if isComplete {
                resultBox.setResponseData(nextData)
                completion.signal()
                return
            }
            receiveTLSResponse(connection: connection, data: nextData, resultBox: resultBox, completion: completion)
        }
    }
}

private final class TerminalServiceTLSPinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?

    func setError(_ error: any Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func error() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

private final class TerminalServiceTLSClientResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?
    private var storedResponseData = Data()

    func setError(_ error: any Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func error() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func setResponseData(_ data: Data) {
        lock.lock()
        storedResponseData = data
        lock.unlock()
    }

    func responseData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storedResponseData
    }
}

private func isWildcardHost(_ host: String) -> Bool {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedHost.isEmpty || trimmedHost == "0.0.0.0" || trimmedHost == "::"
}

private func terminalServiceTLSTrace(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["SPACES_TERMINAL_TLS_TRACE"] == "1" else { return }
    fputs("terminal-service-tls: \(message())\n", stderr)
}
