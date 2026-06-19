import Foundation
import spacesdevicecore
import spacesterminalcore

public struct SpacesRemoteDevicePairingRequest: Sendable {
    public let sshHost: String
    public let sshUser: String?
    public let sshPort: Int?
    public let clientInstallationID: String
    public let clientBundleID: String
    public let clientDeviceName: String
    public let clientAppVersion: String?
    public let profile: SpacesProfile?

    public init(
        sshHost: String, sshUser: String? = nil, sshPort: Int? = nil, clientInstallationID: String, clientBundleID: String, clientDeviceName: String,
        clientAppVersion: String?, profile: SpacesProfile? = nil
    ) {
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.clientInstallationID = clientInstallationID
        self.clientBundleID = clientBundleID
        self.clientDeviceName = clientDeviceName
        self.clientAppVersion = clientAppVersion
        self.profile = profile
    }
}

public struct SpacesRemoteDevicePairingResult: Sendable, Equatable {
    public let deviceID: String
    public let name: String
    public let host: String
    public let port: Int

    public init(deviceID: String, name: String, host: String, port: Int) {
        self.deviceID = deviceID
        self.name = name
        self.host = host
        self.port = port
    }
}

public struct SpacesRemoteDevicePairingWindowResult: Sendable, Equatable {
    public let name: String
    public let host: String
    public let port: Int
    public let linkString: String
    public let expiresAt: String?

    public init(name: String, host: String, port: Int, linkString: String, expiresAt: String?) {
        self.name = name
        self.host = host
        self.port = port
        self.linkString = linkString
        self.expiresAt = expiresAt
    }
}

public enum SpacesRemoteDevicePairingError: LocalizedError, Equatable {
    case missingSSHHost
    case invalidSSHPort(Int)
    case sshUnavailable(String)
    case sshValidationTimedOut(String)
    case sshValidationFailed(String)
    case remotePairCommandTimedOut(String)
    case remotePairCommandFailed(String)
    case invalidRemotePairingOutput(String)
    case deviceAPIUnreachable(host: String, port: Int, message: String)
    case pairingRejected(String)
    case missingAuthToken

    public var errorDescription: String? {
        switch self {
        case .missingSSHHost: "SSH host is required to connect a remote device."
        case .invalidSSHPort(let port): "SSH port \(port) is invalid. Enter a port between 1 and 65535."
        case .sshUnavailable(let message): message
        case .sshValidationTimedOut(let destination):
            "SSH validation timed out for \(destination). Spaces uses BatchMode=yes and strict known-host checks; confirm the host, port, network route, and SSH service."
        case .sshValidationFailed(let message): message
        case .remotePairCommandTimedOut(let destination):
            "SSH connected to \(destination), but `~/.spaces/bin/spaces pair --json` timed out. Confirm spacesd is installed and responsive for that remote user."
        case .remotePairCommandFailed(let message): message
        case .invalidRemotePairingOutput(let message): message
        case .deviceAPIUnreachable(let host, let port, let message):
            "SSH succeeded, but the remote Device API is not reachable at \(host):\(port). Confirm LAN/VPN/Tailscale/firewall access to that address and port. \(message)"
        case .pairingRejected(let message): "The remote device rejected pairing. \(message)"
        case .missingAuthToken: "The remote device accepted pairing but did not issue an auth token."
        }
    }
}

public enum SpacesDevicePairingClient {
    private static let sshPath = "/usr/bin/ssh"
    private static let remotePairCommand = "~/.spaces/bin/spaces pair --json"

    public static func pairRemoteDevice(_ request: SpacesRemoteDevicePairingRequest) throws -> SpacesRemoteDevicePairingResult {
        #if canImport(Network)
            let sshHost = try normalizedSSHHost(request.sshHost)
            let sshUser = normalized(request.sshUser)
            try validateSSHPort(request.sshPort)
            let destination = sshDestination(host: sshHost, user: sshUser)

            try validateRemoteDeviceSSH(destination: destination, port: request.sshPort)
            let metadata = try loadRemotePairingMetadata(destination: destination, port: request.sshPort)
            let deviceAPIHost = sshHost

            let deviceID = stablePairedDeviceID(certificateFingerprint: metadata.certificateFingerprint, host: deviceAPIHost, port: metadata.port)
            let client = try SpacesDeviceAPIRequestClient(host: deviceAPIHost, port: metadata.port, transportKey: metadata.transportKey)
            let response: SpacesDeviceAPIResponse
            do {
                response = try client.request(
                    SpacesDeviceAPIRequest(
                        command: .pair(.init(pairingCode: metadata.pairingCode, pairingNonce: metadata.pairingNonce)),
                        clientApp: SpacesDeviceClientApp(
                            installationID: request.clientInstallationID, bundleID: request.clientBundleID, platform: "macos",
                            deviceName: request.clientDeviceName, appVersion: request.clientAppVersion)))
            } catch {
                throw SpacesRemoteDevicePairingError.deviceAPIUnreachable(
                    host: deviceAPIHost, port: metadata.port, message: error.localizedDescription)
            }
            guard response.ok else { throw SpacesRemoteDevicePairingError.pairingRejected(response.message) }
            guard let authToken = normalized(response.issuedAuthToken) else { throw SpacesRemoteDevicePairingError.missingAuthToken }

            let now = ISO8601DateFormatter().string(from: Date())
            let database = try SpacesClientDatabase()
            try database.upsert(
                device: SpacesPairedDeviceRecord(
                    id: deviceID, name: metadata.name, platform: "remote", host: deviceAPIHost, port: metadata.port,
                    certificateFingerprint: metadata.certificateFingerprint, sshHost: sshHost, sshUser: sshUser, sshPort: request.sshPort,
                    createdAt: now, updatedAt: now, lastSelectedAt: now))
            try database.setActiveDeviceID(deviceID)
            try SpacesDeviceCredentialStore.saveToken(authToken, deviceID: deviceID, profile: request.profile)
            try SpacesDeviceCredentialStore.saveTransportKey(metadata.transportKey, deviceID: deviceID, profile: request.profile)
            return SpacesRemoteDevicePairingResult(deviceID: deviceID, name: metadata.name, host: deviceAPIHost, port: metadata.port)
        #else
            throw SpacesRemoteDevicePairingError.sshUnavailable("Remote device pairing requires Network.framework.")
        #endif
    }

    public static func openRemotePairingWindow(for device: SpacesPairedDeviceRecord) throws -> SpacesRemoteDevicePairingWindowResult {
        #if canImport(Network)
            let sshHost = try normalizedSSHHost(device.sshHost ?? device.host)
            let sshUser = normalized(device.sshUser)
            try validateSSHPort(device.sshPort)
            let destination = sshDestination(host: sshHost, user: sshUser)
            try validateRemoteDeviceSSH(destination: destination, port: device.sshPort)
            let metadata = try loadRemotePairingMetadata(destination: destination, port: device.sshPort)
            let link = SpacesDevicePairingLink(
                host: sshHost, port: metadata.port, nonce: metadata.pairingNonce, code: metadata.pairingCode, transportKey: metadata.transportKey,
                certificateFingerprint: metadata.certificateFingerprint, name: metadata.name)
            return SpacesRemoteDevicePairingWindowResult(
                name: metadata.name, host: sshHost, port: metadata.port, linkString: link.absoluteString, expiresAt: metadata.expiresAt)
        #else
            throw SpacesRemoteDevicePairingError.sshUnavailable("Remote device pairing requires Network.framework.")
        #endif
    }

    public static func localMacClientInstallationID(profile: SpacesProfile? = nil) -> String {
        let profileRoot = (try? (profile ?? SpacesProfile.current()).rootDirectory) ?? NSHomeDirectory()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in profileRoot.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "macos-\(String(hash, radix: 16))"
    }

    static func stablePairedDeviceID(certificateFingerprint: String, host: String, port: Int) -> String {
        let source = "\(certificateFingerprint)|\(host)|\(port)"
        let slug = source.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(
            in: CharacterSet(charactersIn: "-"))
        return "device-\(slug.prefix(48))"
    }

    static func sshValidationFailureMessage(destination: String, detail: String, exitStatus: Int32) -> String {
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalizedDetail.lowercased()
        if lowercased.contains("remote host identification has changed") {
            return
                "SSH host key validation failed for \(destination): the known_hosts entry changed. Verify the remote device identity, update the stale known_hosts entry, and retry."
        }
        if lowercased.contains("no ed25519 host key is known") || lowercased.contains("no ecdsa host key is known")
            || lowercased.contains("no rsa host key is known") || lowercased.contains("host key verification failed")
        {
            return
                "SSH host key validation failed for \(destination). Spaces uses StrictHostKeyChecking=yes, so the device must already be in known_hosts. Verify the remote host key, add it to known_hosts, and retry."
        }
        if lowercased.contains("permission denied") || lowercased.contains("publickey") || lowercased.contains("authentication failed") {
            return
                "SSH authentication failed for \(destination). Spaces uses BatchMode=yes, so password prompts are not allowed. Configure key-based SSH access or an unlocked SSH agent for this user, then retry."
        }
        if lowercased.contains("could not resolve hostname") || lowercased.contains("name or service not known") {
            return "SSH could not resolve \(destination). Check the host name or DNS/VPN configuration, then retry."
        }
        if lowercased.contains("connection timed out") || lowercased.contains("operation timed out") {
            return "SSH timed out connecting to \(destination). Check the port, firewall, VPN/Tailscale route, and remote sshd status."
        }
        if lowercased.contains("connection refused") {
            return "SSH connection to \(destination) was refused. Confirm sshd is running on the selected port."
        }
        if lowercased.contains("no route to host") || lowercased.contains("network is unreachable") {
            return "SSH cannot reach \(destination). Check LAN/VPN/Tailscale routing and firewall rules."
        }
        if lowercased.contains("connection closed") || lowercased.contains("kex_exchange_identification") {
            return "SSH connected to \(destination), but the server closed the connection during validation. Check sshd access rules and logs."
        }
        let suffix = normalizedDetail.isEmpty ? "Exit status \(exitStatus)." : normalizedDetail
        return "SSH validation failed for \(destination). \(suffix)"
    }

    private static func normalizedSSHHost(_ value: String) throws -> String {
        guard let host = normalized(value) else { throw SpacesRemoteDevicePairingError.missingSSHHost }
        return host
    }

    private static func validateSSHPort(_ port: Int?) throws {
        guard let port else { return }
        guard (1...65_535).contains(port) else { throw SpacesRemoteDevicePairingError.invalidSSHPort(port) }
    }

    private static func validateRemoteDeviceSSH(destination: String, port: Int?) throws {
        let result = try runSSH(destination: destination, port: port, remoteCommand: "true", timeoutSeconds: 12)
        if result.timedOut { throw SpacesRemoteDevicePairingError.sshValidationTimedOut(destination) }
        guard result.exitStatus == 0 else {
            throw SpacesRemoteDevicePairingError.sshValidationFailed(
                sshValidationFailureMessage(destination: destination, detail: result.standardError, exitStatus: result.exitStatus))
        }
    }

    private static func loadRemotePairingMetadata(destination: String, port: Int?) throws -> RemotePairingMetadata {
        let result = try runSSH(destination: destination, port: port, remoteCommand: remotePairCommand, timeoutSeconds: 15)
        if result.timedOut { throw SpacesRemoteDevicePairingError.remotePairCommandTimedOut(destination) }
        guard result.exitStatus == 0 else {
            throw SpacesRemoteDevicePairingError.remotePairCommandFailed(
                remotePairCommandFailureMessage(
                    destination: destination, standardError: result.standardError, standardOutput: result.standardOutput,
                    exitStatus: result.exitStatus))
        }
        let trimmedOutput = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmedOutput.data(using: .utf8), !data.isEmpty else {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput(
                "SSH connected to \(destination), but `\(remotePairCommand)` did not return pairing JSON.")
        }
        do { return try JSONDecoder().decode(RemotePairingMetadata.self, from: data).validated() } catch {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput(
                "SSH connected to \(destination), but `\(remotePairCommand)` returned invalid pairing JSON. \(error.localizedDescription)")
        }
    }

    private static func runSSH(destination: String, port: Int?, remoteCommand: String, timeoutSeconds: TimeInterval) throws -> SSHCommandResult {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw SpacesRemoteDevicePairingError.sshUnavailable("SSH is required to connect a remote device, but \(sshPath) is not executable.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        var arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
        ]
        if let port { arguments += ["-p", String(port)] }
        arguments += [destination, remoteCommand]
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do { try process.run() } catch {
            throw SpacesRemoteDevicePairingError.sshUnavailable("Failed to launch \(sshPath): \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            while process.isRunning { Thread.sleep(forTimeInterval: 0.02) }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return SSHCommandResult(
            exitStatus: process.terminationStatus, standardOutput: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: stderr.trimmingCharacters(in: .whitespacesAndNewlines), timedOut: timedOut)
    }

    private static func remotePairCommandFailureMessage(destination: String, standardError: String, standardOutput: String, exitStatus: Int32)
        -> String
    {
        let detail = [standardError, standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(
            separator: "\n")
        let lowercased = detail.lowercased()
        if exitStatus == 127 || lowercased.contains("no such file") || lowercased.contains("not found") {
            return
                "SSH connected to \(destination), but Spaces CLI was not found at ~/.spaces/bin/spaces. Install spacesd for that remote user, then retry."
        }
        if lowercased.contains("permission denied") {
            return
                "SSH connected to \(destination), but ~/.spaces/bin/spaces is not executable for that remote user. Fix the install permissions, then retry."
        }
        let suffix = detail.isEmpty ? "Exit status \(exitStatus)." : detail
        return "SSH connected to \(destination), but `\(remotePairCommand)` failed. \(suffix)"
    }

    private static func sshDestination(host: String, user: String?) -> String { user.map { "\($0)@\(host)" } ?? host }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private struct RemotePairingMetadata: Decodable, Sendable {
    let name: String
    let host: String
    let port: Int
    let pairingNonce: String
    let pairingCode: String
    let transportKey: String
    let certificateFingerprint: String
    let expiresAt: String?

    func validated() throws -> Self {
        guard trimmed(name) != nil else {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput("Remote pairing JSON is missing a device name.")
        }
        guard trimmed(host) != nil else {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput("Remote pairing JSON is missing a Device API host.")
        }
        guard (1...65_535).contains(port) else {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput("Remote pairing JSON contains an invalid Device API port.")
        }
        guard trimmed(pairingNonce) != nil, trimmed(pairingCode) != nil, trimmed(transportKey) != nil, trimmed(certificateFingerprint) != nil else {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput("Remote pairing JSON is missing required pairing credentials.")
        }
        return self
    }

    private func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct SSHCommandResult: Sendable, Equatable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}
