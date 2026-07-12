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
    case remoteInstallPreflightTimedOut(String)
    case remoteInstallPreflightFailed(String)
    case remoteSpacesNotInstalled(message: String, linuxInstallCommand: String?)
    case remotePairCommandTimedOut(String)
    case remotePairCommandFailed(String)
    case invalidRemotePairingOutput(String)
    case deviceAPIUnreachable(host: String, port: Int, message: String)
    case pairingVersionIncompatible(String)
    case pairingRejected(String)
    case missingAuthToken
    case remoteInstallTimedOut(String)
    case remoteInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSSHHost: "SSH host is required to connect a remote device."
        case .invalidSSHPort(let port): "SSH port \(port) is invalid. Enter a port between 1 and 65535."
        case .sshUnavailable(let message): message
        case .sshValidationTimedOut(let destination):
            "SSH validation timed out for \(destination). Spaces uses BatchMode=yes and strict known-host checks; confirm the host, port, network route, and SSH service."
        case .sshValidationFailed(let message): message
        case .remoteInstallPreflightTimedOut(let destination):
            "SSH connected to \(destination), but the remote Spaces install check timed out. Confirm the remote user can run shell commands over SSH."
        case .remoteInstallPreflightFailed(let message): message
        case .remoteSpacesNotInstalled(let message, let linuxInstallCommand):
            // Keep CLI output fully actionable: when the probe identified a Linux device, append the
            // exact install/upgrade one-liner; otherwise the message already carries the guidance.
            if let linuxInstallCommand { "\(message)\n  \(linuxInstallCommand)" } else { message }
        case .remotePairCommandTimedOut(let destination):
            "SSH connected to \(destination), but Spaces did not finish preparing the connection. Confirm Spaces is installed and available for that user, then retry."
        case .remotePairCommandFailed(let message): message
        case .invalidRemotePairingOutput(let message): message
        case .deviceAPIUnreachable(let host, let port, let message):
            "SSH succeeded, but the remote Device API is not reachable at \(host):\(port). Confirm LAN/VPN/Tailscale/firewall access to that address and port. \(message)"
        case .pairingVersionIncompatible(let message): message
        case .pairingRejected(let message): "The remote device rejected pairing. \(message)"
        case .missingAuthToken: "The remote device accepted pairing but did not issue an auth token."
        case .remoteInstallTimedOut(let destination):
            "Installing Spaces on \(destination) timed out after 10 minutes. Check the device's network and try again."
        case .remoteInstallFailed(let message): message
        }
    }
}

public enum SpacesDevicePairingClient {
    private static let sshPath = "/usr/bin/ssh"
    static let baseRemotePairCommand = "~/.spaces/bin/spaces device pair --json"
    /// The remote installer downloads a release artifact and restarts the systemd user service, which
    /// needs far more headroom than the short pairing SSH calls (12-15s).
    static let remoteInstallTimeoutSeconds: TimeInterval = 600
    private static let remoteInstallProbeCommand = #"""
        os="$(uname -s 2>/dev/null || true)"
        arch="$(uname -m 2>/dev/null || true)"
        printf 'os=%s\narch=%s\n' "$os" "$arch"
        if [ "$os" = "Linux" ]; then
          linux_id="$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
          linux_version_id="$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
          printf 'linux_id=%s\nlinux_version_id=%s\n' "$linux_id" "$linux_version_id"
        fi
        """#

    public static func pairRemoteDevice(_ request: SpacesRemoteDevicePairingRequest) throws -> SpacesRemoteDevicePairingResult {
        let sshHost = try normalizedSSHHost(request.sshHost)
        let sshUser = normalized(request.sshUser)
        try validateSSHPort(request.sshPort)
        let destination = sshDestination(host: sshHost, user: sshUser)
        openSSHControlMaster(destination: destination, port: request.sshPort)
        defer { closeSSHControlMaster(destination: destination, port: request.sshPort) }
        let deviceAPIHost = try sshPairingDeviceAPIHost(destination: destination, port: request.sshPort, sshHost: sshHost)

        try validateRemoteDeviceSSH(destination: destination, port: request.sshPort)
        let probe = try validateRemoteDeviceInstall(destination: destination, port: request.sshPort)
        let metadata = try loadRemotePairingMetadata(
            destination: destination, port: request.sshPort, probe: probe, appVersion: request.clientAppVersion, profile: request.profile)

        try assertPairingCompatible(deviceProtocolVersion: metadata.protocolVersion, deviceAppVersion: metadata.appVersion, deviceName: metadata.name)
        let deviceID = stablePairedDeviceID(certificateFingerprint: metadata.certificateFingerprint, host: deviceAPIHost, port: metadata.port)
        let client = try SpacesDeviceAPIRequestClient(
            host: deviceAPIHost, port: metadata.port, certificateFingerprint: metadata.certificateFingerprint)
        let response: SpacesDeviceAPIResponse
        do {
            response = try client.request(
                SpacesDeviceAPIRequest(
                    command: .pair(
                        .init(
                            pairingCode: metadata.pairingCode, pairingNonce: metadata.pairingNonce, clientProtocolVersion: SpacesWireProtocol.version)
                    ),
                    clientApp: SpacesDeviceClientApp(
                        installationID: request.clientInstallationID, bundleID: request.clientBundleID, platform: clientPlatform,
                        deviceName: request.clientDeviceName, appVersion: request.clientAppVersion)))
        } catch {
            throw SpacesRemoteDevicePairingError.deviceAPIUnreachable(host: deviceAPIHost, port: metadata.port, message: error.localizedDescription)
        }
        guard response.ok else { throw SpacesRemoteDevicePairingError.pairingRejected(response.message) }
        guard let authToken = normalized(response.issuedAuthToken) else { throw SpacesRemoteDevicePairingError.missingAuthToken }

        let now = ISO8601DateFormatter().string(from: Date())
        let database = try SpacesClientDatabase.defaultDatabase()
        try database.upsert(
            device: SpacesPairedDeviceRecord(
                id: deviceID, name: metadata.name, platform: "remote", host: deviceAPIHost, port: metadata.port,
                certificateFingerprint: metadata.certificateFingerprint, sshHost: sshHost, sshUser: sshUser, sshPort: request.sshPort, createdAt: now,
                updatedAt: now, lastSelectedAt: now))
        try SpacesDeviceCredentialStore.saveToken(authToken, deviceID: deviceID, profile: request.profile)
        return SpacesRemoteDevicePairingResult(deviceID: deviceID, name: metadata.name, host: deviceAPIHost, port: metadata.port)
    }

    /// Runs the Linux installer one-liner on the remote host over SSH, pinned to this client's app
    /// version for wire compatibility, then pairs. Intended for recovery after pairing failed with
    /// `remoteSpacesNotInstalled` on a Linux device.
    public static func installSpacesOnRemoteDeviceAndPair(_ request: SpacesRemoteDevicePairingRequest) throws -> SpacesRemoteDevicePairingResult {
        let sshHost = try normalizedSSHHost(request.sshHost)
        let sshUser = normalized(request.sshUser)
        try validateSSHPort(request.sshPort)
        let destination = sshDestination(host: sshHost, user: sshUser)
        openSSHControlMaster(destination: destination, port: request.sshPort)
        defer { closeSSHControlMaster(destination: destination, port: request.sshPort) }

        let installCommand = SpacesLinuxInstaller.sshInstallCommand(version: normalized(request.clientAppVersion))
        let result = try runSSH(
            destination: destination, port: request.sshPort, remoteCommand: installCommand, timeoutSeconds: remoteInstallTimeoutSeconds)
        if result.timedOut { throw SpacesRemoteDevicePairingError.remoteInstallTimedOut(destination) }
        guard result.exitStatus == 0 else {
            throw SpacesRemoteDevicePairingError.remoteInstallFailed(
                remoteInstallFailureMessage(
                    destination: destination, standardOutput: result.standardOutput, standardError: result.standardError,
                    exitStatus: result.exitStatus))
        }
        // Pairing nests inside this flow's already-open ControlMaster: openSSHControlMaster returns early
        // when the master is live, so pairRemoteDevice reuses it, and its own defer closes it. The outer
        // defer's `-O exit` then no-ops harmlessly (runDetachedSSHProcess swallows failures and the socket
        // removal is `try?`). This nesting is intentional and safe.
        return try pairRemoteDevice(request)
    }

    /// Pairs this client with a daemon from a `spaces://pair` link — code and nonce redeemed over
    /// the fingerprint-pinned Device API — persisting the paired-device record and issued token.
    /// This is the no-SSH pairing path (`spaces device pair --link`); the resulting record carries
    /// no SSH metadata, so SSH-backed features (remote update, pairing-window reopen) stay
    /// unavailable for it until the device is re-paired over SSH.
    public static func pairDevice(
        link: SpacesDevicePairingLink, clientInstallationID: String, clientBundleID: String, clientDeviceName: String, clientAppVersion: String?,
        profile: SpacesProfile? = nil
    ) throws -> SpacesRemoteDevicePairingResult {
        try assertPairingCompatible(deviceProtocolVersion: link.protocolVersion, deviceAppVersion: link.appVersion, deviceName: link.name)
        let deviceID = stablePairedDeviceID(certificateFingerprint: link.certificateFingerprint, host: link.host, port: link.port)
        let client = try SpacesDeviceAPIRequestClient(host: link.host, port: link.port, certificateFingerprint: link.certificateFingerprint)
        let response: SpacesDeviceAPIResponse
        do {
            response = try client.request(
                SpacesDeviceAPIRequest(
                    command: .pair(.init(pairingCode: link.code, pairingNonce: link.nonce, clientProtocolVersion: SpacesWireProtocol.version)),
                    clientApp: SpacesDeviceClientApp(
                        installationID: clientInstallationID, bundleID: clientBundleID, platform: clientPlatform, deviceName: clientDeviceName,
                        appVersion: clientAppVersion)))
        } catch { throw SpacesRemoteDevicePairingError.deviceAPIUnreachable(host: link.host, port: link.port, message: error.localizedDescription) }
        guard response.ok else { throw SpacesRemoteDevicePairingError.pairingRejected(response.message) }
        guard let authToken = normalized(response.issuedAuthToken) else { throw SpacesRemoteDevicePairingError.missingAuthToken }

        let now = ISO8601DateFormatter().string(from: Date())
        let database = try SpacesClientDatabase.defaultDatabase()
        try database.upsert(
            device: SpacesPairedDeviceRecord(
                id: deviceID, name: link.name, platform: "remote", host: link.host, port: link.port,
                certificateFingerprint: link.certificateFingerprint, sshHost: nil, sshUser: nil, sshPort: nil, createdAt: now, updatedAt: now,
                lastSelectedAt: now))
        try SpacesDeviceCredentialStore.saveToken(authToken, deviceID: deviceID, profile: profile)
        return SpacesRemoteDevicePairingResult(deviceID: deviceID, name: link.name, host: link.host, port: link.port)
    }

    private static var clientPlatform: String {
        #if os(Linux)
            "linux"
        #else
            "macos"
        #endif
    }

    /// Refuses to redeem against a daemon whose wire-protocol version does not match this client's,
    /// failing fast before the one-time pairing window is consumed. Symmetric with the daemon's
    /// redemption gate: whichever side is older is told to update.
    private static func assertPairingCompatible(deviceProtocolVersion: Int, deviceAppVersion: String?, deviceName: String) throws {
        switch SpacesWireCompatibility.evaluate(daemonProtocolVersion: deviceProtocolVersion, localVersion: SpacesWireProtocol.version) {
        case .compatible: return
        case .daemonTooOld:
            let version = normalized(deviceAppVersion).map { "Spaces \($0)" } ?? "an older version of Spaces"
            throw SpacesRemoteDevicePairingError.pairingVersionIncompatible(
                "\(deviceName) is running \(version), which is older than this app. Update Spaces on \(deviceName), then pair again.")
        case .clientTooOld:
            let version = normalized(deviceAppVersion).map { "Spaces \($0)" } ?? "a newer version of Spaces"
            throw SpacesRemoteDevicePairingError.pairingVersionIncompatible(
                "\(deviceName) is running \(version), which is newer than this app. Update Spaces on this Mac, then pair again.")
        }
    }

    public static func openRemotePairingWindow(for device: SpacesPairedDeviceRecord, appVersion: String? = nil, profile: SpacesProfile? = nil) throws
        -> SpacesRemoteDevicePairingWindowResult
    {
        let sshHost = try normalizedSSHHost(device.sshHost ?? device.host)
        let sshUser = normalized(device.sshUser)
        try validateSSHPort(device.sshPort)
        let destination = sshDestination(host: sshHost, user: sshUser)
        openSSHControlMaster(destination: destination, port: device.sshPort)
        defer { closeSSHControlMaster(destination: destination, port: device.sshPort) }
        let deviceAPIHost = try remotePairingWindowDeviceAPIHost(destination: destination, port: device.sshPort, sshHost: sshHost)
        try validateRemoteDeviceSSH(destination: destination, port: device.sshPort)
        let probe = try validateRemoteDeviceInstall(destination: destination, port: device.sshPort)
        let metadata = try loadRemotePairingMetadata(
            destination: destination, port: device.sshPort, probe: probe, appVersion: appVersion, profile: profile)
        let link = SpacesDevicePairingLink(
            host: deviceAPIHost, port: metadata.port, nonce: metadata.pairingNonce, code: metadata.pairingCode,
            certificateFingerprint: metadata.certificateFingerprint, name: metadata.name, protocolVersion: metadata.protocolVersion,
            appVersion: metadata.appVersion)
        return SpacesRemoteDevicePairingWindowResult(
            name: metadata.name, host: deviceAPIHost, port: metadata.port, linkString: link.absoluteString, expiresAt: metadata.expiresAt)
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

    static func parseRemoteInstallProbeOutput(_ output: String, destination: String) throws -> RemoteInstallProbe {
        var pairs: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            pairs[String(parts[0])] = String(parts[1])
        }
        guard let operatingSystem = normalized(pairs["os"]) else {
            throw SpacesRemoteDevicePairingError.remoteInstallPreflightFailed(
                "SSH connected to \(destination), but the remote Spaces install check returned invalid output.")
        }
        return RemoteInstallProbe(
            operatingSystem: operatingSystem, architecture: normalized(pairs["arch"]), linuxID: normalized(pairs["linux_id"]),
            linuxVersionID: normalized(pairs["linux_version_id"]))
    }

    private static func normalizedSSHHost(_ value: String) throws -> String {
        guard let host = normalized(value) else { throw SpacesRemoteDevicePairingError.missingSSHHost }
        return host
    }

    private static func validateSSHPort(_ port: Int?) throws {
        guard let port else { return }
        guard (1...65_535).contains(port) else { throw SpacesRemoteDevicePairingError.invalidSSHPort(port) }
    }

    private static func sshPairingDeviceAPIHost(destination: String, port: Int?, sshHost: String) throws -> String {
        try sshPairingDeviceAPIHost(sshHost: sshHost, configuration: loadSSHResolvedConfiguration(destination: destination, port: port))
    }

    static func sshPairingDeviceAPIHost(sshHost: String, configuration: SSHResolvedConfiguration) throws -> String {
        let fallback = try normalizedSSHHost(sshHost)
        return configuration.resolvedHostname(fallback: fallback)
    }

    private static func remotePairingWindowDeviceAPIHost(destination: String, port: Int?, sshHost: String) throws -> String {
        try remotePairingWindowDeviceAPIHost(sshHost: sshHost, configuration: loadSSHResolvedConfiguration(destination: destination, port: port))
    }

    static func remotePairingWindowDeviceAPIHost(sshHost: String, configuration: SSHResolvedConfiguration) throws -> String {
        try sshPairingDeviceAPIHost(sshHost: sshHost, configuration: configuration)
    }

    private static func loadSSHResolvedConfiguration(destination: String, port: Int?, timeoutSeconds: TimeInterval = 5) throws
        -> SSHResolvedConfiguration
    {
        let result = try runSSHConfiguration(destination: destination, port: port, timeoutSeconds: timeoutSeconds)
        let normalizedDestination = try normalizedSSHHost(destination)
        if result.timedOut {
            throw SpacesRemoteDevicePairingError.sshValidationFailed(
                "SSH configuration lookup timed out for \(normalizedDestination). Check the SSH host or ssh config, then retry.")
        }
        guard result.exitStatus == 0 else {
            let detail = [result.standardError, result.standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                !$0.isEmpty
            }.joined(separator: "\n")
            let suffix = detail.isEmpty ? "Exit status \(result.exitStatus)." : detail
            throw SpacesRemoteDevicePairingError.sshValidationFailed("SSH configuration lookup failed for \(normalizedDestination). \(suffix)")
        }
        return parseOpenSSHConfiguration(result.standardOutput)
    }

    static func parseOpenSSHConfiguration(_ output: String) -> SSHResolvedConfiguration { SSHResolvedConfiguration.parseOpenSSHConfiguration(output) }

    private static func validateRemoteDeviceSSH(destination: String, port: Int?) throws {
        let result = try runSSH(destination: destination, port: port, remoteCommand: "true", timeoutSeconds: 12)
        if result.timedOut { throw SpacesRemoteDevicePairingError.sshValidationTimedOut(destination) }
        guard result.exitStatus == 0 else {
            throw SpacesRemoteDevicePairingError.sshValidationFailed(
                sshValidationFailureMessage(destination: destination, detail: result.standardError, exitStatus: result.exitStatus))
        }
    }

    private static func validateRemoteDeviceInstall(destination: String, port: Int?) throws -> RemoteInstallProbe {
        let result = try runSSH(destination: destination, port: port, remoteCommand: remoteInstallProbeCommand, timeoutSeconds: 12)
        if result.timedOut { throw SpacesRemoteDevicePairingError.remoteInstallPreflightTimedOut(destination) }
        guard result.exitStatus == 0 else {
            let detail = [result.standardError, result.standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                !$0.isEmpty
            }.joined(separator: "\n")
            let suffix = detail.isEmpty ? "Exit status \(result.exitStatus)." : detail
            throw SpacesRemoteDevicePairingError.remoteInstallPreflightFailed(
                "SSH connected to \(destination), but the remote Spaces install check failed. \(suffix)")
        }
        return try parseRemoteInstallProbeOutput(result.standardOutput, destination: destination)
    }

    private static func loadRemotePairingMetadata(
        destination: String, port: Int?, probe: RemoteInstallProbe, appVersion: String?, profile: SpacesProfile?
    ) throws -> RemotePairingMetadata {
        let result = try runSSH(destination: destination, port: port, remoteCommand: remotePairCommand(profile: profile), timeoutSeconds: 15)
        return try parseRemotePairingMetadataResult(result, destination: destination, probe: probe, appVersion: appVersion)
    }

    static func remotePairCommand(profile: SpacesProfile?) -> String {
        guard let remoteProfileRoot = remoteDevelopmentProfileRoot(profile: profile) else { return baseRemotePairCommand }
        let databasePath = remoteProfileRoot.hasSuffix("/") ? "\(remoteProfileRoot)spaces.db" : "\(remoteProfileRoot)/spaces.db"
        let runtimePath = remoteProfileRoot.hasSuffix("/") ? "\(remoteProfileRoot)runtime" : "\(remoteProfileRoot)/runtime"
        return "\(SpacesProfile.databasePathEnvironmentVariable)=\(remoteShellPathExpression(databasePath)) "
            + "\(SpacesProfile.runtimeDirectoryEnvironmentVariable)=\(remoteShellPathExpression(runtimePath)) \(baseRemotePairCommand)"
    }

    private static func remoteDevelopmentProfileRoot(profile providedProfile: SpacesProfile?) -> String? {
        if let override = normalized(ProcessInfo.processInfo.environment["SPACES_E2E_REMOTE_DEVICE_ROOT"]) { return override }
        let profile = providedProfile ?? (try? SpacesProfile.current())
        guard let profile else { return nil }
        let marker = "/.spaces-dev/profiles/spaces/"
        let canonicalRoot = SpacesProfile.canonicalPath(profile.rootDirectory)
        guard canonicalRoot.contains(marker) else { return nil }
        let profileName = URL(fileURLWithPath: canonicalRoot, isDirectory: true).lastPathComponent
        guard normalized(profileName) != nil else { return nil }
        return "~/.spaces-dev/profiles/spaces/\(profileName)"
    }

    private static func parseRemotePairingMetadataResult(
        _ result: SSHCommandResult, destination: String, probe: RemoteInstallProbe, appVersion: String?
    ) throws -> RemotePairingMetadata {
        if result.timedOut { throw SpacesRemoteDevicePairingError.remotePairCommandTimedOut(destination) }
        // A successful `spaces device pair --json` exits 0 with pairing JSON on stdout; only a failed
        // command can indicate a missing install. Branch on the nonzero exit first so pairing JSON that
        // happens to contain "not found"/"no such file" (e.g. inside a device name) is never misread as
        // not-installed.
        if result.exitStatus != 0 {
            // A missing `spaces` binary (exit 127 / "not found") means the remote has no Spaces installed.
            // We never auto-install; surface actionable install instructions for the remote's OS instead.
            if remoteSpacesNotInstalled(exitStatus: result.exitStatus, standardError: result.standardError, standardOutput: result.standardOutput) {
                throw remoteSpacesNotInstalledError(
                    lead: "SSH connected to \(destination), but Spaces is not installed for that user.", probe: probe, appVersion: appVersion)
            }
            throw SpacesRemoteDevicePairingError.remotePairCommandFailed(
                remotePairCommandFailureMessage(
                    destination: destination, standardError: result.standardError, standardOutput: result.standardOutput,
                    exitStatus: result.exitStatus))
        }
        let trimmedOutput = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        // No stdout means `spaces` produced no pairing window. Because the exit code is unreliable over
        // Tailscale SSH and similar transports (they report 0 even when the remote command failed), the
        // earlier nonzero-exit not-installed check can be bypassed entirely, landing a missing binary
        // here under a reported exit 0. With no pairing JSON on stdout, stderr can be read safely: a
        // "no such file" / "not found" there means the binary is missing, so give the precise
        // not-installed guidance. Otherwise `spaces` ran but returned nothing (e.g. a broken or
        // never-opened install), which the same install/setup guidance still resolves.
        guard let data = trimmedOutput.data(using: .utf8), !data.isEmpty else {
            if outputReportsMissingBinary(result.standardError) {
                throw remoteSpacesNotInstalledError(
                    lead: "SSH connected to \(destination), but Spaces is not installed for that user.", probe: probe, appVersion: appVersion)
            }
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput(
                installGuidanceMessage(lead: "SSH connected to \(destination), but Spaces there did not return a pairing window.", probe: probe))
        }
        do { return try JSONDecoder().decode(RemotePairingMetadata.self, from: data).validated() } catch {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput(
                installGuidanceMessage(
                    lead:
                        "SSH connected to \(destination), but Spaces there returned an unreadable pairing response (\(error.localizedDescription)).",
                    probe: probe))
        }
    }

    /// Builds the actionable install/setup guidance shown when SSH reaches the remote but Spaces there
    /// cannot hand back a pairing window. `lead` states what went wrong; this appends platform-specific
    /// guidance without embedding any install command (the command travels separately on the structured
    /// `remoteSpacesNotInstalled` error). Spaces never auto-installs remote daemons: Linux users run the
    /// installer one-liner on the device, and Mac users install and open the Spaces app there.
    static func installGuidanceMessage(lead: String, probe: RemoteInstallProbe) -> String {
        if probe.operatingSystem == "Linux" { return "\(lead) Install or update Spaces on the Ubuntu 24.04 device, then pair again." }
        return "\(lead) Install the Spaces app on the remote Mac, open it once, then pair again."
    }

    /// Constructs the structured not-installed error. For Linux probes the version-pinned install
    /// command travels alongside the guidance so the CLI can print a copy-pasteable one-liner; a
    /// nil/unnormalizable `appVersion` yields the evergreen (latest-release) command. Mac probes carry
    /// no command — the user installs the app instead.
    static func remoteSpacesNotInstalledError(lead: String, probe: RemoteInstallProbe, appVersion: String?) -> SpacesRemoteDevicePairingError {
        let command = probe.operatingSystem == "Linux" ? SpacesLinuxInstaller.installCommand(version: normalized(appVersion)) : nil
        return .remoteSpacesNotInstalled(message: installGuidanceMessage(lead: lead, probe: probe), linuxInstallCommand: command)
    }

    // MARK: SSH connection multiplexing
    //
    // A remote pairing flow runs several short SSH commands back to back (config lookup, reachability
    // check, install probe, `spaces device pair`). Opening a fresh
    // connection for each one pays the full TCP + key-exchange + auth cost every time, which over a jittery
    // WAN link is both slow and unreliable: a single cold connect can spike past a command's timeout and
    // abort the whole flow. Each flow therefore opens one shared SSH master connection up front and every
    // later `ssh`/`scp` reuses it over the existing channel, so only the master pays the connection cost.
    // The master is best-effort: if it cannot be established, the individual commands fall back to their own
    // direct connections, so multiplexing only changes a flow's speed and resilience, never its outcome.

    static func sshControlPath(destination: String, port: Int?) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(destination)|\(port.map(String.init) ?? "")".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        // Keep the socket path short (well under the ~104-char AF_UNIX limit) and under the per-user
        // temporary directory so only this user can connect to the master.
        return NSTemporaryDirectory() + "spaces-ssh-\(String(hash, radix: 16)).sock"
    }

    static func sshControlArguments(destination: String, port: Int?) -> [String] {
        ["-o", "ControlPath=\(sshControlPath(destination: destination, port: port))"]
    }

    /// Opens the shared SSH master connection so the commands that follow reuse it. Best-effort: failures are
    /// swallowed and the caller's commands fall back to direct connections. A cold connect can exceed one
    /// attempt's window on a jittery link, so timed-out attempts are retried a bounded number of times; a
    /// non-timeout failure (auth, host key) is left for the reachability check to report with an actionable
    /// message.
    private static func openSSHControlMaster(destination: String, port: Int?) {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else { return }
        let controlPath = sshControlPath(destination: destination, port: port)
        if sshControlMasterIsRunning(controlPath: controlPath, destination: destination, port: port) { return }
        try? FileManager.default.removeItem(atPath: controlPath)  // clear any stale socket before opening

        var arguments = [
            "-f", "-N", "-M", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
            "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=60",
        ]
        if let port { arguments += ["-p", String(port)] }
        arguments.append(destination)

        for _ in 0..<3 {
            let result = runDetachedSSHProcess(arguments: arguments, timeoutSeconds: 25)
            if result.timedOut { continue }  // transient jitter on the cold connect — retry
            return  // established, or a hard failure the reachability check will surface
        }
    }

    private static func closeSSHControlMaster(destination: String, port: Int?) {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else { return }
        let controlPath = sshControlPath(destination: destination, port: port)
        var arguments = ["-O", "exit", "-o", "ControlPath=\(controlPath)"]
        if let port { arguments += ["-p", String(port)] }
        arguments.append(destination)
        _ = runDetachedSSHProcess(arguments: arguments, timeoutSeconds: 10)
        try? FileManager.default.removeItem(atPath: controlPath)
    }

    private static func sshControlMasterIsRunning(controlPath: String, destination: String, port: Int?) -> Bool {
        guard FileManager.default.fileExists(atPath: controlPath) else { return false }
        var arguments = ["-O", "check", "-o", "ControlPath=\(controlPath)"]
        if let port { arguments += ["-p", String(port)] }
        arguments.append(destination)
        let result = runDetachedSSHProcess(arguments: arguments, timeoutSeconds: 10)
        return result.exitStatus == 0 && !result.timedOut
    }

    /// Runs an `ssh` control command whose output is discarded (master setup with `-f`, `-O check`,
    /// `-O exit`). Uses the null device for all stdio so a backgrounded master cannot hold a pipe open and
    /// block on read.
    private static func runDetachedSSHProcess(arguments: [String], timeoutSeconds: TimeInterval) -> (exitStatus: Int32, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (exitStatus: -1, timedOut: false) }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            while process.isRunning { Thread.sleep(forTimeInterval: 0.02) }
        }
        return (exitStatus: process.terminationStatus, timedOut: timedOut)
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
        arguments += sshControlArguments(destination: destination, port: port)
        if let port { arguments += ["-p", String(port)] }
        arguments += [destination, remoteShellCommand(remoteCommand)]
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

    static func sshConfigurationArguments(destination: String, port: Int?) -> [String] {
        var arguments = [
            "-G", "-T", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
        ]
        if let port { arguments += ["-p", String(port)] }
        arguments.append(destination)
        return arguments
    }

    private static func runSSHConfiguration(destination: String, port: Int?, timeoutSeconds: TimeInterval) throws -> SSHCommandResult {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw SpacesRemoteDevicePairingError.sshUnavailable("SSH is required to connect a remote device, but \(sshPath) is not executable.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = sshConfigurationArguments(destination: destination, port: port)

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

    /// Decides whether a failed `spaces device pair --json` means Spaces is not installed for the remote
    /// user. A missing binary makes the remote shell exit 127 or emit "not found"/"no such file". Only a
    /// nonzero exit qualifies here: a successful pair exits 0 with JSON that could itself contain those
    /// words (for example inside a device name), so an exit-0 result is never treated as not-installed by
    /// this path. The exit-0-with-empty-stdout case is handled separately in
    /// `parseRemotePairingMetadataResult`, which can safely read stderr because there is no pairing JSON
    /// to misread.
    static func remoteSpacesNotInstalled(exitStatus: Int32, standardError: String, standardOutput: String) -> Bool {
        guard exitStatus != 0 else { return false }
        if exitStatus == 127 { return true }
        return outputReportsMissingBinary("\(standardError)\n\(standardOutput)")
    }

    /// True when command output carries the shell's missing-binary signature ("no such file" / "not
    /// found"). The remote exit code is not always trustworthy — Tailscale SSH (and some other transports)
    /// return 0 regardless of the remote command's real status — so a missing `~/.spaces/bin/spaces` can
    /// surface only as this stderr text under a reported exit 0. This content check backstops the exit
    /// code so a not-installed remote is still recognized.
    static func outputReportsMissingBinary(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("no such file") || lowered.contains("not found")
    }

    /// Message for a `spaces device pair` failure that is not the not-installed case (which is handled
    /// earlier with actionable install instructions). Covers a runnable-but-broken install: a permission
    /// problem, or any other nonzero exit.
    static func remotePairCommandFailureMessage(destination: String, standardError: String, standardOutput: String, exitStatus: Int32) -> String {
        let detail = [standardError, standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(
            separator: "\n")
        let lowercased = detail.lowercased()
        if lowercased.contains("permission denied") {
            return "SSH connected to \(destination), but Spaces cannot be run by that remote user. Fix the install permissions, then retry."
        }
        let suffix = detail.isEmpty ? "Exit status \(exitStatus)." : detail
        return "SSH connected to \(destination), but `\(baseRemotePairCommand)` failed. \(suffix)"
    }

    /// Message for a nonzero-exit remote install. The installer script's `die` messages are user-facing,
    /// so the tail (last ~10 lines) of combined stdout+stderr is surfaced verbatim to explain the failure.
    static func remoteInstallFailureMessage(destination: String, standardOutput: String, standardError: String, exitStatus: Int32) -> String {
        let combined = [standardOutput, standardError].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(
            separator: "\n")
        let tail = combined.split(separator: "\n", omittingEmptySubsequences: false).suffix(10).joined(separator: "\n")
        let suffix = tail.isEmpty ? "Exit status \(exitStatus)." : tail
        return "Installing Spaces on \(destination) failed. \(suffix)"
    }

    private static func sshDestination(host: String, user: String?) -> String { user.map { "\($0)@\(host)" } ?? host }

    static func remoteShellCommand(_ command: String) -> String { "sh -c \(shellQuoted(command))" }

    private static func shellQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }

    private static func remoteShellPathExpression(_ path: String) -> String {
        if path == "~" { return "$HOME" }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return "\"$HOME/\(shellDoubleQuotedContent(suffix))\""
        }
        return shellQuoted(path)
    }

    private static func shellDoubleQuotedContent(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct RemoteInstallProbe: Equatable, Sendable {
    let operatingSystem: String
    let architecture: String?
    let linuxID: String?
    let linuxVersionID: String?
}

private struct RemotePairingMetadata: Decodable, Sendable {
    let name: String
    let host: String
    let port: Int
    let pairingNonce: String
    let pairingCode: String
    let certificateFingerprint: String
    let expiresAt: String?
    /// The remote daemon's wire-protocol version and app version, mirrored from its pairing link so
    /// the SSH pairing path can run the same compatibility gate as the `--link` path.
    let protocolVersion: Int
    let appVersion: String

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
        guard trimmed(pairingNonce) != nil, trimmed(pairingCode) != nil, trimmed(certificateFingerprint) != nil else {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput("Remote pairing JSON is missing required pairing credentials.")
        }
        guard trimmed(appVersion) != nil else {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput("Remote pairing JSON is missing the daemon app version.")
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

struct SSHResolvedConfiguration: Sendable, Equatable {
    let hostname: String?

    init(hostname: String? = nil) { self.hostname = Self.normalized(hostname) }

    func resolvedHostname(fallback: String) -> String { Self.normalized(hostname) ?? fallback.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func parseOpenSSHConfiguration(_ output: String) -> SSHResolvedConfiguration {
        var hostname: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "hostname" { hostname = normalized(String(parts[1])) }
        }
        return SSHResolvedConfiguration(hostname: hostname)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, trimmed.lowercased() != "none" else {
            return nil
        }
        return trimmed
    }
}
