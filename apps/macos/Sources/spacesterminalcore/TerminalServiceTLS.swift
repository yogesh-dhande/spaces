import Dispatch
import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(Darwin)
    import Darwin
#endif
#if canImport(Glibc)
    import Glibc
#endif
#if canImport(Network)
    import Network
#endif
#if canImport(OpenSSL)
    import OpenSSL
#endif
#if canImport(Security)
    @preconcurrency import Security
#else
    public typealias OSStatus = Int32
#endif

public enum TerminalServiceTLSFingerprint {
    #if canImport(Security)
        public static func fingerprint(certificate: SecCertificate) -> String {
            let data = SecCertificateCopyData(certificate) as Data
            let digest = SHA256.hash(data: data)
            return "SHA256:\(digest.map { String(format: "%02x", $0) }.joined())"
        }
    #endif

    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "").lowercased()
    }

    public static func matches(_ lhs: String, _ rhs: String) -> Bool { normalized(lhs) == normalized(rhs) }
}

#if os(macOS)
    public struct TerminalServiceTLSIdentity: @unchecked Sendable {
        public let identity: SecIdentity
        public let certificateFingerprint: String
        private let keychain: SecKeychain?

        public init(identity: SecIdentity, certificateFingerprint: String, keychain: SecKeychain? = nil) {
            self.identity = identity
            self.certificateFingerprint = certificateFingerprint
            self.keychain = keychain
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
            let keychain = try serviceKeychain(root: root, fileManager: fileManager)

            if fileManager.fileExists(atPath: p12URL.path), fileManager.fileExists(atPath: passphraseURL.path) {
                return try importIdentity(p12URL: p12URL, passphraseURL: passphraseURL, keychain: keychain)
            }

            try generateIdentity(root: root, p12URL: p12URL, passphraseURL: passphraseURL, fileManager: fileManager)
            return try importIdentity(p12URL: p12URL, passphraseURL: passphraseURL, keychain: keychain)
        }

        public static func rootDirectory(fileManager: FileManager = .default) throws -> URL {
            try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager).appendingPathComponent("daemon-tls", isDirectory: true)
        }

        private static func importIdentity(p12URL: URL, passphraseURL: URL, keychain: SecKeychain) throws -> TerminalServiceTLSIdentity {
            let p12Data = try Data(contentsOf: p12URL)
            let passphrase = try String(contentsOf: passphraseURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            var importedItems: CFArray?
            let options = [kSecImportExportPassphrase as String: passphrase, kSecImportExportKeychain as String: keychain] as CFDictionary
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
                identity: identity, certificateFingerprint: TerminalServiceTLSFingerprint.fingerprint(certificate: certificate), keychain: keychain)
        }

        private static func serviceKeychain(root: URL, fileManager: FileManager) throws -> SecKeychain {
            // SecPKCS12Import accepts a SecKeychain import target; using our own keychain avoids login-keychain UI in daemon contexts.
            let keychainURL = root.appendingPathComponent("identity.keychain-db", isDirectory: false)
            let passphraseURL = root.appendingPathComponent("identity.keychain.passphrase", isDirectory: false)

            if fileManager.fileExists(atPath: keychainURL.path), fileManager.fileExists(atPath: passphraseURL.path) {
                let passphrase = try String(contentsOf: passphraseURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                if let keychain = try openServiceKeychain(url: keychainURL, passphrase: passphrase) { return keychain }
                try? fileManager.removeItem(at: keychainURL)
                try? fileManager.removeItem(at: passphraseURL)
            }

            let passphrase = randomPassphrase()
            var keychain: SecKeychain?
            let status = passphrase.withCString { passphrasePointer in
                SecKeychainCreate(keychainURL.path, UInt32(strlen(passphrasePointer)), passphrasePointer, false, nil, &keychain)
            }
            guard status == errSecSuccess, let keychain else { throw TerminalServiceTLSError.identityImportFailed(status) }
            try passphrase.write(to: passphraseURL, atomically: true, encoding: .utf8)
            chmod(keychainURL.path, S_IRUSR | S_IWUSR)
            chmod(passphraseURL.path, S_IRUSR | S_IWUSR)
            return keychain
        }

        private static func openServiceKeychain(url: URL, passphrase: String) throws -> SecKeychain? {
            var keychain: SecKeychain?
            let openStatus = SecKeychainOpen(url.path, &keychain)
            guard openStatus == errSecSuccess, let keychain else { return nil }
            let unlockStatus = passphrase.withCString { passphrasePointer in
                SecKeychainUnlock(keychain, UInt32(strlen(passphrasePointer)), passphrasePointer, true)
            }
            guard unlockStatus == errSecSuccess else {
                if unlockStatus == errSecNoSuchKeychain { return nil }
                throw TerminalServiceTLSError.identityImportFailed(unlockStatus)
            }
            return keychain
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
            try? output.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw TerminalServiceTLSError.opensslFailed(
                    message?.isEmpty == false ? message! : "openssl exited with code \(process.terminationStatus)")
            }
        }
    }
#endif

#if os(Linux)
    public struct TerminalServiceTLSIdentity: @unchecked Sendable {
        public let certificatePath: String
        public let privateKeyPath: String
        public let certificateFingerprint: String

        public init(certificatePath: String, privateKeyPath: String, certificateFingerprint: String) {
            self.certificatePath = certificatePath
            self.privateKeyPath = privateKeyPath
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
            let keyURL = root.appendingPathComponent("key.pem", isDirectory: false)
            let certificateURL = root.appendingPathComponent("certificate.pem", isDirectory: false)
            if !fileManager.fileExists(atPath: keyURL.path) || !fileManager.fileExists(atPath: certificateURL.path) {
                try generateIdentity(keyURL: keyURL, certificateURL: certificateURL, fileManager: fileManager)
            }
            let fingerprint = try certificateFingerprint(certificateURL: certificateURL)
            return TerminalServiceTLSIdentity(certificatePath: certificateURL.path, privateKeyPath: keyURL.path, certificateFingerprint: fingerprint)
        }

        public static func rootDirectory(fileManager: FileManager = .default) throws -> URL {
            try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager).appendingPathComponent("daemon-tls", isDirectory: true)
        }

        private static func generateIdentity(keyURL: URL, certificateURL: URL, fileManager: FileManager) throws {
            let temporaryRoot = keyURL.deletingLastPathComponent().appendingPathComponent("generate-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            let generatedKeyURL = temporaryRoot.appendingPathComponent("key.pem", isDirectory: false)
            let generatedCertificateURL = temporaryRoot.appendingPathComponent("certificate.pem", isDirectory: false)
            try runOpenSSL(
                [
                    "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "825", "-nodes", "-subj", "/CN=spacesd", "-keyout",
                    generatedKeyURL.path, "-out", generatedCertificateURL.path,
                ], captureOutput: false)

            if fileManager.fileExists(atPath: keyURL.path) { try fileManager.removeItem(at: keyURL) }
            if fileManager.fileExists(atPath: certificateURL.path) { try fileManager.removeItem(at: certificateURL) }
            try fileManager.moveItem(at: generatedKeyURL, to: keyURL)
            try fileManager.moveItem(at: generatedCertificateURL, to: certificateURL)
            chmod(keyURL.path, S_IRUSR | S_IWUSR)
            chmod(certificateURL.path, S_IRUSR | S_IWUSR)
        }

        private static func certificateFingerprint(certificateURL: URL) throws -> String {
            let output = try runOpenSSL(["x509", "-in", certificateURL.path, "-noout", "-fingerprint", "-sha256"], captureOutput: true)
            guard let fingerprint = output.split(separator: "=", maxSplits: 1).last else {
                throw TerminalServiceTLSError.opensslFailed("openssl did not print a SHA-256 certificate fingerprint.")
            }
            return "SHA256:\(fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "").lowercased())"
        }

        @discardableResult private static func runOpenSSL(_ arguments: [String], captureOutput: Bool) throws -> String {
            var outputPipe: [Int32] = [-1, -1]
            var nullFD: Int32 = -1
            if captureOutput {
                guard pipe(&outputPipe) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } else {
                nullFD = open("/dev/null", O_WRONLY)
                guard nullFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }

            var cArguments: [UnsafeMutablePointer<CChar>?] = (["openssl"] + arguments).map { strdup($0) }
            cArguments.append(nil)
            defer { for argument in cArguments { if let argument { free(argument) } } }

            let pid = fork()
            guard pid >= 0 else {
                if outputPipe[0] >= 0 { close(outputPipe[0]) }
                if outputPipe[1] >= 0 { close(outputPipe[1]) }
                if nullFD >= 0 { close(nullFD) }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            if pid == 0 {
                if captureOutput {
                    close(outputPipe[0])
                    dup2(outputPipe[1], STDOUT_FILENO)
                    dup2(outputPipe[1], STDERR_FILENO)
                    close(outputPipe[1])
                } else {
                    dup2(nullFD, STDOUT_FILENO)
                    dup2(nullFD, STDERR_FILENO)
                    close(nullFD)
                }
                execv("/usr/bin/openssl", &cArguments)
                _exit(127)
            }

            if captureOutput { close(outputPipe[1]) } else { close(nullFD) }

            let data = captureOutput ? try readAll(from: outputPipe[0]) : Data()
            if outputPipe[0] >= 0 { close(outputPipe[0]) }

            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedExitCode = exitCode(status: status)
            guard resolvedExitCode == 0 else {
                let statusDescription = resolvedExitCode.map { "openssl exited with code \($0)" } ?? "openssl did not exit cleanly"
                throw TerminalServiceTLSError.opensslFailed(message.isEmpty ? statusDescription : message)
            }
            return message
        }

        private static func readAll(from fileDescriptor: Int32) throws -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fileDescriptor, &buffer, buffer.count)
                if count == 0 { return data }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                data.append(buffer, count: count)
            }
        }

        private static func exitCode(status: Int32) -> Int32? {
            guard status & 0x7f == 0 else { return nil }
            return (status >> 8) & 0xff
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
            private var relaySource: DispatchSourceRead?
            private var relaySocketFD: Int32 = -1

            init(connection: NWConnection, server: TerminalServiceTLSServer) {
                self.connection = connection
                self.server = server
            }

            func cancel() {
                relaySource?.cancel()
                relaySource = nil
                connection.cancel()
            }

            func start(on queue: DispatchQueue) {
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    terminalServiceTLSTrace("server_connection_state \(state)")
                    switch state {
                    case .ready: self.receiveNext()
                    case .failed, .cancelled:
                        self.relaySource?.cancel()
                        self.relaySource = nil
                        self.server.removeConnection(self.connection)
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
                        self.buffer.removeSubrange(self.buffer.startIndex...newlineIndex)
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

            private func processBufferedRequestIfAvailable() {
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let requestData = Data(buffer.prefix(upTo: newlineIndex))
                    buffer.removeSubrange(buffer.startIndex...newlineIndex)
                    processRequest(requestData)
                    return
                }
                receiveNext()
            }

            private func processRequest(_ requestData: Data) {
                let response: TerminalServiceResponse
                do {
                    let request = try TerminalServiceCodec.decodeRequest(requestData)
                    response = try server.validateAndHandle(request: request)
                } catch {
                    sendResponseAndClose(TerminalServiceResponse(ok: false, message: String(describing: error)))
                    return
                }
                if response.ok, let streamSocketPath = response.streamSocketPath {
                    startStreamRelay(socketPath: streamSocketPath)
                    return
                }
                sendResponse(response, closeAfterSend: Self.shouldCloseAfterResponse(response))
            }

            private func sendResponse(_ response: TerminalServiceResponse, closeAfterSend: Bool) {
                var responseData = (try? TerminalServiceCodec.encodeResponse(response)) ?? Data()
                responseData.append(0x0A)
                connection.send(
                    content: responseData, contentContext: .defaultMessage, isComplete: closeAfterSend,
                    completion: .contentProcessed { [weak self] _ in
                        guard let self else { return }
                        if closeAfterSend {
                            self.connection.cancel()
                            self.server.removeConnection(self.connection)
                        } else {
                            self.processBufferedRequestIfAvailable()
                        }
                    })
            }

            private func sendResponseAndClose(_ response: TerminalServiceResponse) { sendResponse(response, closeAfterSend: true) }

            private static func shouldCloseAfterResponse(_ response: TerminalServiceResponse) -> Bool {
                guard !response.ok else { return false }
                return response.message.localizedStandardContains("unauthorized")
            }

            private func startStreamRelay(socketPath: String) {
                do {
                    let socketFD = try server.connectUnixSocket(path: socketPath)
                    try server.setNonBlocking(socketFD)
                    relaySocketFD = socketFD
                    let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: server.queue)
                    source.setEventHandler { [weak self] in self?.relayReadableData() }
                    source.setCancelHandler { [weak self] in
                        guard let self else { return }
                        if self.relaySocketFD >= 0 {
                            shutdown(self.relaySocketFD, SHUT_RDWR)
                            close(self.relaySocketFD)
                            self.relaySocketFD = -1
                        }
                    }
                    relaySource = source
                    source.resume()
                } catch {
                    let response = TerminalServiceResponse(ok: false, message: String(describing: error))
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

            private func relayReadableData() {
                guard relaySocketFD >= 0 else { return }
                var readBuffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = read(relaySocketFD, &readBuffer, readBuffer.count)
                    if count > 0 {
                        connection.send(
                            content: Data(readBuffer.prefix(count)), contentContext: .defaultMessage, isComplete: false, completion: .idempotent)
                        continue
                    }
                    if count == 0 {
                        finishStreamRelay()
                        return
                    }
                    if errno == EWOULDBLOCK || errno == EAGAIN { return }
                    finishStreamRelay()
                    return
                }
            }

            private func finishStreamRelay() {
                relaySource?.cancel()
                relaySource = nil
                connection.cancel()
                server.removeConnection(connection)
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
        private let authorizeRequest: (@Sendable (TerminalServiceRequest) -> TerminalServiceResponse?)?
        private let identity: TerminalServiceTLSIdentity
        private let queue: DispatchQueue
        private let handleRequest: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
        private var listener: NWListener?
        private var connections: [ObjectIdentifier: RequestConnection] = [:]

        public private(set) var listeningPort: Int = 0
        public var certificateFingerprint: String { identity.certificateFingerprint }

        public init(
            host: String, port: Int, authToken: String? = nil, identity: TerminalServiceTLSIdentity, queue: DispatchQueue,
            authorizeRequest: (@Sendable (TerminalServiceRequest) -> TerminalServiceResponse?)? = nil,
            handleRequest: @escaping @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
        ) {
            self.host = host
            self.port = port
            self.authToken = authToken
            self.authorizeRequest = authorizeRequest
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
            if let authorizationFailure = authorizeRequest?(request) { return authorizationFailure }
            if let authToken, authToken != request.authToken { return TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client.") }
            return try handleRequest(request)
        }

        private func connectUnixSocket(path: String) throws -> Int32 {
            let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let maxLength = MemoryLayout.size(ofValue: address.sun_path)
            let utf8Path = path.utf8CString
            guard utf8Path.count <= maxLength else {
                close(socketFD)
                throw POSIXError(.ENAMETOOLONG)
            }
            withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
                utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
            }
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

        private func setNonBlocking(_ fileDescriptor: Int32) throws {
            let currentFlags = fcntl(fileDescriptor, F_GETFL)
            guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
#endif

#if os(Linux)
    public final class TerminalServiceTLSServer: @unchecked Sendable {
        private let host: String
        private let port: Int
        private let authToken: String?
        private let authorizeRequest: (@Sendable (TerminalServiceRequest) -> TerminalServiceResponse?)?
        private let identity: TerminalServiceTLSIdentity
        private let queue: DispatchQueue
        private let handleRequest: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
        private var listenSocketFD: Int32 = -1
        private var acceptSource: DispatchSourceRead?
        private var sslContext: OpaquePointer?

        public private(set) var listeningPort: Int = 0
        public var certificateFingerprint: String { identity.certificateFingerprint }

        public init(
            host: String, port: Int, authToken: String? = nil, identity: TerminalServiceTLSIdentity, queue: DispatchQueue,
            authorizeRequest: (@Sendable (TerminalServiceRequest) -> TerminalServiceResponse?)? = nil,
            handleRequest: @escaping @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
        ) {
            self.host = host
            self.port = port
            self.authToken = authToken
            self.authorizeRequest = authorizeRequest
            self.identity = identity
            self.queue = queue
            self.handleRequest = handleRequest
        }

        public func start(timeout: TimeInterval = 5) throws {
            guard (0...Int(UInt16.max)).contains(port) else { throw TerminalServiceTLSError.invalidPort(port) }
            let context = try Self.makeSSLContext(identity: identity)
            let socketFD = try Self.makeListenSocket(host: host, port: port)
            try Self.setCloseOnExec(socketFD)
            try Self.setNonBlocking(socketFD)
            listenSocketFD = socketFD
            sslContext = context
            listeningPort = try Self.resolveListeningPort(socketFD: socketFD)

            let startup = DispatchSemaphore(value: 0)
            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptReadyConnections() }
            source.setCancelHandler { [weak self] in
                guard let self else { return }
                if self.listenSocketFD >= 0 { close(self.listenSocketFD) }
                if let sslContext = self.sslContext { SSL_CTX_free(sslContext) }
                self.listenSocketFD = -1
                self.sslContext = nil
            }
            acceptSource = source
            source.resume()
            startup.signal()
            guard startup.wait(timeout: .now() + timeout) == .success else { throw TerminalServiceTLSError.requestTimedOut }
        }

        public func stop() {
            acceptSource?.cancel()
            acceptSource = nil
        }

        private func acceptReadyConnections() {
            while true {
                let clientFD = accept(listenSocketFD, nil, nil)
                if clientFD < 0 {
                    if errno == EWOULDBLOCK || errno == EAGAIN { return }
                    return
                }
                do {
                    try Self.setCloseOnExec(clientFD)
                    try Self.setBlocking(clientFD)
                    Self.setSocketTimeout(clientFD, seconds: 120)
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else {
                            close(clientFD)
                            return
                        }
                        do { try self.handleClient(fileDescriptor: clientFD) } catch { terminalServiceTLSTrace("linux_server_client_error \(error)") }
                    }
                } catch {
                    terminalServiceTLSTrace("linux_server_client_error \(error)")
                    close(clientFD)
                }
            }
        }

        private func handleClient(fileDescriptor: Int32) throws {
            guard let sslContext else {
                close(fileDescriptor)
                return
            }
            guard let ssl = SSL_new(sslContext) else {
                close(fileDescriptor)
                throw TerminalServiceTLSError.connectionFailed(Self.openSSLErrorMessage("failed to create SSL session"))
            }
            defer {
                SSL_shutdown(ssl)
                SSL_free(ssl)
                close(fileDescriptor)
            }

            SSL_set_fd(ssl, fileDescriptor)
            guard SSL_accept(ssl) == 1 else { throw TerminalServiceTLSError.connectionFailed(Self.openSSLErrorMessage("TLS handshake failed")) }
            var requestBuffer = Data()
            while true {
                guard let requestData = try Self.readTLSRequestLine(ssl: ssl, buffer: &requestBuffer) else { return }
                let response: TerminalServiceResponse
                do {
                    let request = try TerminalServiceCodec.decodeRequest(requestData)
                    response = try validateAndHandle(request: request)
                } catch {
                    var responseData =
                        (try? TerminalServiceCodec.encodeResponse(TerminalServiceResponse(ok: false, message: String(describing: error)))) ?? Data()
                    responseData.append(0x0A)
                    try Self.writeTLSResponse(responseData, ssl: ssl)
                    return
                }
                if response.ok, let streamSocketPath = response.streamSocketPath {
                    try Self.relayUnixSocket(path: streamSocketPath, ssl: ssl)
                    return
                }
                var responseData = (try? TerminalServiceCodec.encodeResponse(response)) ?? Data()
                responseData.append(0x0A)
                try Self.writeTLSResponse(responseData, ssl: ssl)
                if Self.shouldCloseAfterResponse(response) { return }
            }
        }

        private func validateAndHandle(request: TerminalServiceRequest) throws -> TerminalServiceResponse {
            if let authorizationFailure = authorizeRequest?(request) { return authorizationFailure }
            if let authToken, authToken != request.authToken { return TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client.") }
            return try handleRequest(request)
        }

        private static func makeSSLContext(identity: TerminalServiceTLSIdentity) throws -> OpaquePointer {
            OPENSSL_init_ssl(0, nil)
            guard let method = TLS_server_method(), let context = SSL_CTX_new(method) else {
                throw TerminalServiceTLSError.connectionFailed(openSSLErrorMessage("failed to create TLS context"))
            }
            guard spaces_SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) == 1 else {
                SSL_CTX_free(context)
                throw TerminalServiceTLSError.connectionFailed(openSSLErrorMessage("failed to configure minimum TLS version"))
            }
            _ = spaces_SSL_CTX_set_max_proto_version(context, TLS1_3_VERSION)
            guard SSL_CTX_use_certificate_file(context, identity.certificatePath, SSL_FILETYPE_PEM) == 1 else {
                SSL_CTX_free(context)
                throw TerminalServiceTLSError.connectionFailed(openSSLErrorMessage("failed to load TLS certificate"))
            }
            guard SSL_CTX_use_PrivateKey_file(context, identity.privateKeyPath, SSL_FILETYPE_PEM) == 1 else {
                SSL_CTX_free(context)
                throw TerminalServiceTLSError.connectionFailed(openSSLErrorMessage("failed to load TLS private key"))
            }
            guard SSL_CTX_check_private_key(context) == 1 else {
                SSL_CTX_free(context)
                throw TerminalServiceTLSError.connectionFailed(openSSLErrorMessage("TLS private key does not match certificate"))
            }
            return context
        }

        private static func makeListenSocket(host: String, port: Int) throws -> Int32 {
            let socketFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var yes: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            if isWildcardHost(host) {
                address.sin_addr = in_addr(s_addr: in_addr_t(0))
            } else {
                guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                    close(socketFD)
                    throw POSIXError(.EADDRNOTAVAIL)
                }
            }

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                close(socketFD)
                throw POSIXError(code)
            }
            guard listen(socketFD, 16) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                close(socketFD)
                throw POSIXError(code)
            }
            return socketFD
        }

        private static func resolveListeningPort(socketFD: Int32) throws -> Int {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in getsockname(socketFD, sockaddrPointer, &length) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return Int(UInt16(bigEndian: address.sin_port))
        }

        private static func setNonBlocking(_ fileDescriptor: Int32) throws {
            let currentFlags = fcntl(fileDescriptor, F_GETFL)
            guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        private static func setCloseOnExec(_ fileDescriptor: Int32) throws {
            let currentFlags = fcntl(fileDescriptor, F_GETFD)
            guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fcntl(fileDescriptor, F_SETFD, currentFlags | FD_CLOEXEC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        private static func setBlocking(_ fileDescriptor: Int32) throws {
            let currentFlags = fcntl(fileDescriptor, F_GETFL)
            guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fcntl(fileDescriptor, F_SETFL, currentFlags & ~O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        private static func setSocketTimeout(_ fileDescriptor: Int32, seconds: TimeInterval) {
            var value = timeval(tv_sec: Int(seconds.rounded(.down)), tv_usec: 0)
            setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        }

        private static func relayUnixSocket(path: String, ssl: OpaquePointer) throws {
            let socketFD = try connectUnixSocket(path: path)
            defer {
                shutdown(socketFD, Int32(SHUT_RDWR))
                close(socketFD)
            }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(socketFD, &buffer, buffer.count)
                if count == 0 { return }
                if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try buffer.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    try writeTLSResponse(Data(bytes: baseAddress, count: count), ssl: ssl)
                }
            }
        }

        private static func connectUnixSocket(path: String) throws -> Int32 {
            let socketFD = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
            guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let maxLength = MemoryLayout.size(ofValue: address.sun_path)
            let utf8Path = path.utf8CString
            guard utf8Path.count <= maxLength else {
                close(socketFD)
                throw POSIXError(.ENAMETOOLONG)
            }
            withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
                utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
            }
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

        private static func readTLSRequestLine(ssl: OpaquePointer, buffer data: inout Data) throws -> Data? {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                if let newlineIndex = data.firstIndex(of: 0x0A) {
                    let requestData = Data(data.prefix(upTo: newlineIndex))
                    data.removeSubrange(data.startIndex...newlineIndex)
                    return requestData
                }
                let count = SSL_read(ssl, &buffer, Int32(buffer.count))
                if count > 0 {
                    data.append(buffer, count: Int(count))
                    continue
                }
                let error = SSL_get_error(ssl, count)
                if error == SSL_ERROR_ZERO_RETURN {
                    guard !data.isEmpty else { return nil }
                    defer { data.removeAll(keepingCapacity: true) }
                    return data
                }
                throw TerminalServiceTLSError.connectionFailed(openSSLErrorMessage("failed to read TLS request"))
            }
        }

        private static func shouldCloseAfterResponse(_ response: TerminalServiceResponse) -> Bool {
            guard !response.ok else { return false }
            return response.message.localizedStandardContains("unauthorized")
        }

        private static func writeTLSResponse(_ data: Data, ssl: OpaquePointer) throws {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var offset = 0
                while bytesRemaining > 0 {
                    let chunkSize = min(bytesRemaining, Int(Int32.max))
                    let written = SSL_write(ssl, baseAddress.advanced(by: offset), Int32(chunkSize))
                    guard written > 0 else { throw TerminalServiceTLSError.connectionFailed(openSSLErrorMessage("failed to write TLS response")) }
                    bytesRemaining -= Int(written)
                    offset += Int(written)
                }
            }
        }

        private static func openSSLErrorMessage(_ prefix: String) -> String {
            let code = ERR_get_error()
            guard code != 0, let message = ERR_error_string(code, nil) else { return prefix }
            return "\(prefix): \(String(cString: message))"
        }
    }
#endif

#if canImport(Network) && canImport(Security)
    extension TerminalServiceClient {
        public static func sendPinnedTLS(
            request: TerminalServiceRequest, host: String, port: Int, authToken: String? = nil, certificateFingerprint: String,
            timeout: TimeInterval = 15
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

            let connection = NWConnection(
                host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options()))
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
#endif

private func isWildcardHost(_ host: String) -> Bool {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedHost.isEmpty || trimmedHost == "0.0.0.0" || trimmedHost == "::"
}

private func terminalServiceTLSTrace(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["SPACES_TERMINAL_TLS_TRACE"] == "1" else { return }
    FileHandle.standardError.write(Data("terminal-service-tls: \(message())\n".utf8))
}
