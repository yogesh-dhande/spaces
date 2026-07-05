import Foundation
import spacesdevicecore
import spacesterminalcore

#if canImport(CryptoKit)
    import CryptoKit
#endif

public struct SpacesRemoteDevicePairingRequest: Sendable {
    public let sshHost: String
    public let sshUser: String?
    public let sshPort: Int?
    public let clientInstallationID: String
    public let clientBundleID: String
    public let clientDeviceName: String
    public let clientAppVersion: String?
    public let remoteArtifactPublicKey: String?
    public let profile: SpacesProfile?

    public init(
        sshHost: String, sshUser: String? = nil, sshPort: Int? = nil, clientInstallationID: String, clientBundleID: String, clientDeviceName: String,
        clientAppVersion: String?, remoteArtifactPublicKey: String? = nil, profile: SpacesProfile? = nil
    ) {
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.clientInstallationID = clientInstallationID
        self.clientBundleID = clientBundleID
        self.clientDeviceName = clientDeviceName
        self.clientAppVersion = clientAppVersion
        self.remoteArtifactPublicKey = remoteArtifactPublicKey
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
    case remoteMacDMGInstallRequired(String)
    case remoteLinuxSetupTimedOut(String)
    case remoteLinuxSetupFailed(String)
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
        case .remoteInstallPreflightTimedOut(let destination):
            "SSH connected to \(destination), but the remote Spaces install check timed out. Confirm the remote user can run shell commands over SSH."
        case .remoteInstallPreflightFailed(let message): message
        case .remoteMacDMGInstallRequired(let message): message
        case .remoteLinuxSetupTimedOut(let destination):
            "SSH connected to \(destination), but Linux setup timed out. Check the network connection and retry."
        case .remoteLinuxSetupFailed(let message): message
        case .remotePairCommandTimedOut(let destination):
            "SSH connected to \(destination), but Spaces did not finish preparing the connection. Confirm Spaces is installed and available for that user, then retry."
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
    private static let scpPath = "/usr/bin/scp"
    private static let curlPath = "/usr/bin/curl"
    private static let remoteArtifactManifestBaseURL = "https://github.com/yogesh-dhande/spaces/releases/download"
    private static let remotePairCommand = "~/.spaces/bin/spaces pair --json"
    private static let remoteInstallProbeCommand = #"""
        os="$(uname -s 2>/dev/null || true)"
        arch="$(uname -m 2>/dev/null || true)"
        printf 'os=%s\narch=%s\n' "$os" "$arch"
        if [ "$os" = "Linux" ]; then
          linux_id="$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
          linux_version_id="$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
          printf 'linux_id=%s\nlinux_version_id=%s\n' "$linux_id" "$linux_version_id"
        fi
        if [ "$os" = "Darwin" ]; then
          app="/Applications/Spaces.app"
          resources="$app/Contents/Resources"
          cli_target="$resources/spaces"
          daemon_target="$resources/spacesd"
          caddy_target="$resources/caddy"
          home_cli="$HOME/.spaces/bin/spaces"
          home_daemon="$HOME/.spaces/bin/spacesd"
          plist="$HOME/Library/LaunchAgents/dev.usespaces.spacesd.plist"
          link_points_to() {
            [ -L "$1" ] && [ "$(readlink "$1" 2>/dev/null || true)" = "$2" ] && [ -x "$1" ]
          }
          if [ -d "$app" ] && [ -x "$cli_target" ] && [ -x "$daemon_target" ] && [ -x "$caddy_target" ]; then spaces_app=1; else spaces_app=0; fi
          if link_points_to /usr/local/bin/spaces "$cli_target"; then usr_local_spaces=1; else usr_local_spaces=0; fi
          if link_points_to /usr/local/bin/spacesd "$daemon_target"; then usr_local_spacesd=1; else usr_local_spacesd=0; fi
          if link_points_to /usr/local/bin/spaces-caddy "$caddy_target"; then usr_local_spaces_caddy=1; else usr_local_spaces_caddy=0; fi
          if link_points_to "$home_cli" "$cli_target"; then home_spaces_cli=1; else home_spaces_cli=0; fi
          if link_points_to "$home_daemon" "$daemon_target"; then home_spacesd=1; else home_spacesd=0; fi
          if [ -f "$plist" ] && grep -Fq "<string>$home_daemon</string>" "$plist"; then launch_agent=1; else launch_agent=0; fi
          printf 'spaces_app=%s\nusr_local_spaces=%s\nusr_local_spacesd=%s\nusr_local_spaces_caddy=%s\nhome_spaces_cli=%s\nhome_spacesd=%s\nlaunch_agent=%s\n' "$spaces_app" "$usr_local_spaces" "$usr_local_spacesd" "$usr_local_spaces_caddy" "$home_spaces_cli" "$home_spacesd" "$launch_agent"
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
        let metadata = try loadRemotePairingMetadataPreparingLinuxIfNeeded(
            destination: destination, port: request.sshPort, probe: probe, appVersion: request.clientAppVersion,
            remoteArtifactPublicKey: request.remoteArtifactPublicKey)

        let deviceID = stablePairedDeviceID(certificateFingerprint: metadata.certificateFingerprint, host: deviceAPIHost, port: metadata.port)
        let client = try SpacesDeviceAPIRequestClient(host: deviceAPIHost, port: metadata.port, certificateFingerprint: metadata.certificateFingerprint)
        let response: SpacesDeviceAPIResponse
        do {
            response = try client.request(
                SpacesDeviceAPIRequest(
                    command: .pair(.init(pairingCode: metadata.pairingCode, pairingNonce: metadata.pairingNonce)),
                    clientApp: SpacesDeviceClientApp(
                        installationID: request.clientInstallationID, bundleID: request.clientBundleID, platform: clientPlatform,
                        deviceName: request.clientDeviceName, appVersion: request.clientAppVersion)))
        } catch {
            throw SpacesRemoteDevicePairingError.deviceAPIUnreachable(
                host: deviceAPIHost, port: metadata.port, message: error.localizedDescription)
        }
        guard response.ok else { throw SpacesRemoteDevicePairingError.pairingRejected(response.message) }
        guard let authToken = normalized(response.issuedAuthToken) else { throw SpacesRemoteDevicePairingError.missingAuthToken }

        let now = ISO8601DateFormatter().string(from: Date())
        let database = try SpacesClientDatabase.defaultDatabase()
        try database.upsert(
            device: SpacesPairedDeviceRecord(
                id: deviceID, name: metadata.name, platform: "remote", host: deviceAPIHost, port: metadata.port,
                certificateFingerprint: metadata.certificateFingerprint, sshHost: sshHost, sshUser: sshUser, sshPort: request.sshPort,
                createdAt: now, updatedAt: now, lastSelectedAt: now))
        try SpacesDeviceCredentialStore.saveToken(authToken, deviceID: deviceID, profile: request.profile)
        return SpacesRemoteDevicePairingResult(deviceID: deviceID, name: metadata.name, host: deviceAPIHost, port: metadata.port)
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
        let deviceID = stablePairedDeviceID(certificateFingerprint: link.certificateFingerprint, host: link.host, port: link.port)
        let client = try SpacesDeviceAPIRequestClient(host: link.host, port: link.port, certificateFingerprint: link.certificateFingerprint)
        let response: SpacesDeviceAPIResponse
        do {
            response = try client.request(
                SpacesDeviceAPIRequest(
                    command: .pair(.init(pairingCode: link.code, pairingNonce: link.nonce)),
                    clientApp: SpacesDeviceClientApp(
                        installationID: clientInstallationID, bundleID: clientBundleID, platform: clientPlatform, deviceName: clientDeviceName,
                        appVersion: clientAppVersion)))
        } catch {
            throw SpacesRemoteDevicePairingError.deviceAPIUnreachable(host: link.host, port: link.port, message: error.localizedDescription)
        }
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

    public static func openRemotePairingWindow(
        for device: SpacesPairedDeviceRecord, appVersion: String? = nil, remoteArtifactPublicKey: String? = nil
    ) throws -> SpacesRemoteDevicePairingWindowResult {
        let sshHost = try normalizedSSHHost(device.sshHost ?? device.host)
        let sshUser = normalized(device.sshUser)
        try validateSSHPort(device.sshPort)
        let destination = sshDestination(host: sshHost, user: sshUser)
        openSSHControlMaster(destination: destination, port: device.sshPort)
        defer { closeSSHControlMaster(destination: destination, port: device.sshPort) }
        let deviceAPIHost = try remotePairingWindowDeviceAPIHost(destination: destination, port: device.sshPort, sshHost: sshHost)
        try validateRemoteDeviceSSH(destination: destination, port: device.sshPort)
        let probe = try validateRemoteDeviceInstall(destination: destination, port: device.sshPort)
        let metadata = try loadRemotePairingMetadataPreparingLinuxIfNeeded(
            destination: destination, port: device.sshPort, probe: probe, appVersion: appVersion, remoteArtifactPublicKey: remoteArtifactPublicKey
        )
        let link = SpacesDevicePairingLink(
            host: deviceAPIHost, port: metadata.port, nonce: metadata.pairingNonce, code: metadata.pairingCode,
            certificateFingerprint: metadata.certificateFingerprint, name: metadata.name)
        return SpacesRemoteDevicePairingWindowResult(
            name: metadata.name, host: deviceAPIHost, port: metadata.port, linkString: link.absoluteString, expiresAt: metadata.expiresAt)
    }

    /// Refreshes a remote **Linux** daemon's binary from the signed release artifact for `appVersion`,
    /// reusing the pairing install pipeline (manifest + Ed25519 verify, archive + SHA256 verify, scp,
    /// `install.sh`). The installer restarts the user service into the updated binary, so this both
    /// updates and restarts the daemon. Returns `false` when the device is not a reachable remote Linux
    /// host (a remote Mac or missing SSH metadata), so the caller can fall back to the restart RPC.
    /// Destructive: the restart stops the daemon's terminals, processes, and coding agents — callers
    /// must confirm the restart impact with the user first. macOS-only (requires SSH).
    @discardableResult public static func updateRemoteLinuxDaemon(
        for device: SpacesPairedDeviceRecord, appVersion: String? = nil, remoteArtifactPublicKey: String? = nil
    ) throws -> Bool {
        guard let sshHostRaw = device.sshHost else { return false }
        let sshHost = try normalizedSSHHost(sshHostRaw)
        let sshUser = normalized(device.sshUser)
        try validateSSHPort(device.sshPort)
        let destination = sshDestination(host: sshHost, user: sshUser)
        openSSHControlMaster(destination: destination, port: device.sshPort)
        defer { closeSSHControlMaster(destination: destination, port: device.sshPort) }
        try validateRemoteDeviceSSH(destination: destination, port: device.sshPort)
        let probe = try validateRemoteDeviceInstall(destination: destination, port: device.sshPort)
        guard probe.operatingSystem == "Linux" else { return false }
        try installRemoteLinuxSpaces(
            destination: destination, port: device.sshPort, probe: probe, appVersion: appVersion, remoteArtifactPublicKey: remoteArtifactPublicKey
        )
        return true
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

    static func validateRemoteInstallProbe(_ probe: RemoteInstallProbe, destination: String) throws {
        guard probe.operatingSystem == "Darwin" else { return }
        var missing: [String] = []
        if !probe.spacesAppInstalled { missing.append("/Applications/Spaces.app") }
        if !probe.systemCLIExecutable { missing.append("/usr/local/bin/spaces") }
        if !probe.systemDaemonExecutable { missing.append("/usr/local/bin/spacesd") }
        if !probe.systemCaddyExecutable { missing.append("/usr/local/bin/spaces-caddy") }
        if !probe.canonicalCLIExecutable { missing.append("~/.spaces/bin/spaces") }
        if !probe.canonicalDaemonExecutable { missing.append("~/.spaces/bin/spacesd") }
        if !probe.launchAgentInstalled { missing.append("~/Library/LaunchAgents/dev.usespaces.spacesd.plist") }
        guard missing.isEmpty else {
            throw SpacesRemoteDevicePairingError.remoteMacDMGInstallRequired(
                remoteMacDMGInstallRequiredMessage(destination: destination, missing: missing))
        }
    }

    static func remoteMacDMGInstallRequiredMessage(destination: String, missing _: [String]) -> String {
        "SSH connected to \(destination), but Spaces is not fully installed on that Mac. Install the Spaces app on the remote Mac, open it once if needed, then retry."
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
            linuxVersionID: normalized(pairs["linux_version_id"]), spacesAppInstalled: pairs["spaces_app"] == "1",
            systemCLIExecutable: pairs["usr_local_spaces"] == "1", systemDaemonExecutable: pairs["usr_local_spacesd"] == "1",
            systemCaddyExecutable: pairs["usr_local_spaces_caddy"] == "1", canonicalCLIExecutable: pairs["home_spaces_cli"] == "1",
            canonicalDaemonExecutable: pairs["home_spacesd"] == "1", launchAgentInstalled: pairs["launch_agent"] == "1")
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
        let probe = try parseRemoteInstallProbeOutput(result.standardOutput, destination: destination)
        try validateRemoteInstallProbe(probe, destination: destination)
        return probe
    }

    private static func loadRemotePairingMetadata(destination: String, port: Int?) throws -> RemotePairingMetadata {
        let result = try runSSH(destination: destination, port: port, remoteCommand: remotePairCommand, timeoutSeconds: 15)
        return try parseRemotePairingMetadataResult(result, destination: destination)
    }

    private static func loadRemotePairingMetadataPreparingLinuxIfNeeded(
        destination: String, port: Int?, probe: RemoteInstallProbe, appVersion: String?, remoteArtifactPublicKey: String?
    ) throws -> RemotePairingMetadata {
        let firstResult = try runSSH(destination: destination, port: port, remoteCommand: remotePairCommand, timeoutSeconds: 15)
        if firstResult.exitStatus == 0 && !firstResult.timedOut { return try parseRemotePairingMetadataResult(firstResult, destination: destination) }
        guard probe.operatingSystem == "Linux" else { return try parseRemotePairingMetadataResult(firstResult, destination: destination) }
        try installRemoteLinuxSpaces(
            destination: destination, port: port, probe: probe, appVersion: appVersion, remoteArtifactPublicKey: remoteArtifactPublicKey)
        return try loadRemotePairingMetadata(destination: destination, port: port)
    }

    private static func parseRemotePairingMetadataResult(_ result: SSHCommandResult, destination: String) throws -> RemotePairingMetadata {
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

    private static func installRemoteLinuxSpaces(
        destination: String, port: Int?, probe: RemoteInstallProbe, appVersion: String?, remoteArtifactPublicKey: String?
    ) throws {
        let artifact = try loadRemoteLinuxArtifact(
            probe: probe, appVersion: appVersion, remoteArtifactPublicKey: remoteArtifactPublicKey, destination: destination)
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("spaces-linux-setup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let archiveURL = tempDirectory.appendingPathComponent(artifact.archiveName)
        try downloadRemoteLinuxArtifact(artifact, to: archiveURL)
        try verifyRemoteLinuxArtifactArchive(archiveURL, expectedSHA256: artifact.sha256)

        let remoteTempDirectory = try createRemoteLinuxSetupDirectory(destination: destination, port: port)
        defer { try? cleanupRemoteLinuxSetupDirectory(remoteTempDirectory, destination: destination, port: port) }

        let remoteArchivePath = "\(remoteTempDirectory)/\(artifact.archiveName)"
        try copyRemoteLinuxArtifact(archiveURL, remoteArchivePath: remoteArchivePath, destination: destination, port: port)
        try runRemoteLinuxInstallScript(
            remoteTempDirectory: remoteTempDirectory, remoteArchivePath: remoteArchivePath, destination: destination, port: port)
    }

    static func remoteLinuxArtifactPlatform(probe: RemoteInstallProbe, destination: String) throws -> (platform: String, architecture: String) {
        guard probe.operatingSystem == "Linux" else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed("Automatic setup is only available for Linux devices.")
        }
        guard probe.linuxID == "ubuntu", probe.linuxVersionID == "24.04" else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "SSH connected to \(destination), but automatic Linux setup supports Ubuntu 24.04 on x86_64 and arm64. Use an Ubuntu 24.04 device, then retry."
            )
        }
        guard let architecture = normalizedRemoteLinuxArchitecture(probe.architecture) else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "SSH connected to \(destination), but automatic Linux setup supports x86_64 and arm64 Linux devices.")
        }
        return ("ubuntu-24.04", architecture)
    }

    static func selectRemoteLinuxArtifact(from manifest: RemoteArtifactManifest, probe: RemoteInstallProbe, appVersion: String?, destination: String)
        throws -> RemoteLinuxArtifact
    {
        guard manifest.schemaVersion == 1 else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces could not read the Linux installer manifest for this version. Update Spaces, then retry.")
        }
        guard let appVersion = normalized(appVersion), manifest.appVersion == appVersion else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces could not find a Linux installer for this app version. Update Spaces, then retry.")
        }
        let platform = try remoteLinuxArtifactPlatform(probe: probe, destination: destination)
        guard
            let artifact = manifest.artifacts.first(where: {
                $0.version == appVersion && $0.platform == platform.platform && $0.architecture == platform.architecture
            })
        else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces could not find a Linux installer for this device. Use Ubuntu 24.04 on x86_64 or arm64, then retry.")
        }
        guard let url = URL(string: artifact.url), url.scheme == "https" else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces could not verify the Linux installer download for this version. Update Spaces, then retry.")
        }
        return artifact
    }

    static func verifyRemoteArtifactManifestSignature(manifestData: Data, signature: Data, publicKey: String?) throws {
        guard let publicKey = normalized(publicKey), let publicKeyData = Data(base64Encoded: publicKey) else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces cannot verify the Linux installer for this version. Update Spaces, then retry.")
        }
        #if canImport(CryptoKit)
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            guard key.isValidSignature(signature, for: manifestData) else {
                throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                    "Spaces could not verify the Linux installer for this version. Update Spaces, then retry.")
            }
        #else
            _ = publicKeyData
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces cannot verify Linux installers on this platform. Connect from the Mac app, then retry.")
        #endif
    }

    private static func loadRemoteLinuxArtifact(probe: RemoteInstallProbe, appVersion: String?, remoteArtifactPublicKey: String?, destination: String)
        throws -> RemoteLinuxArtifact
    {
        guard let appVersion = normalized(appVersion) else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces could not find a Linux installer for this app version. Update Spaces, then retry.")
        }
        let manifestURL = remoteArtifactManifestURL(appVersion: appVersion)
        let signatureURL = remoteArtifactManifestSignatureURL(appVersion: appVersion)
        let manifestData = try downloadRemoteLinuxSetupData(from: manifestURL, description: "Linux installer manifest", timeoutSeconds: 30)
        let signature = try downloadRemoteLinuxSetupData(from: signatureURL, description: "Linux installer signature", timeoutSeconds: 30)
        try verifyRemoteArtifactManifestSignature(manifestData: manifestData, signature: signature, publicKey: remoteArtifactPublicKey)
        let manifest = try JSONDecoder().decode(RemoteArtifactManifest.self, from: manifestData)
        return try selectRemoteLinuxArtifact(from: manifest, probe: probe, appVersion: appVersion, destination: destination)
    }

    private static func remoteArtifactManifestURL(appVersion: String) -> URL {
        let releaseTag = appVersion.hasPrefix("v") ? appVersion : "v\(appVersion)"
        return URL(string: "\(remoteArtifactManifestBaseURL)/\(releaseTag)/spaces-remote-artifacts.json")!
    }

    private static func remoteArtifactManifestSignatureURL(appVersion: String) -> URL {
        let releaseTag = appVersion.hasPrefix("v") ? appVersion : "v\(appVersion)"
        return URL(string: "\(remoteArtifactManifestBaseURL)/\(releaseTag)/spaces-remote-artifacts.json.sig")!
    }

    private static func downloadRemoteLinuxSetupData(from url: URL, description: String, timeoutSeconds: TimeInterval) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-linux-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try downloadURL(url, to: tempURL, description: description, timeoutSeconds: timeoutSeconds)
        return try Data(contentsOf: tempURL)
    }

    private static func downloadRemoteLinuxArtifact(_ artifact: RemoteLinuxArtifact, to destination: URL) throws {
        guard let url = URL(string: artifact.url) else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces could not read the Linux installer download for this version. Update Spaces, then retry.")
        }
        try downloadURL(url, to: destination, description: "Linux installer", timeoutSeconds: 300)
    }

    private static func downloadURL(_ url: URL, to destination: URL, description: String, timeoutSeconds: TimeInterval) throws {
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces cannot download the \(description) because this Mac is missing its system download tool.")
        }
        let result = try runLocalProcess(
            executablePath: curlPath, arguments: curlDownloadArguments(url: url, destination: destination, timeoutSeconds: timeoutSeconds),
            timeoutSeconds: timeoutSeconds + 5)
        if result.timedOut {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces could not download the \(description) before the connection timed out. Check this Mac's internet connection, then retry.")
        }
        guard result.exitStatus == 0 else {
            let detail = [result.standardError, result.standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                !$0.isEmpty
            }.joined(separator: "\n")
            let suffix = detail.isEmpty ? "Exit status \(result.exitStatus)." : detail
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed("Spaces could not download the \(description). \(suffix)")
        }
    }

    static func curlDownloadArguments(url: URL, destination: URL, timeoutSeconds: TimeInterval) -> [String] {
        ["-f", "-sS", "-L", "--connect-timeout", "15", "--max-time", String(Int(timeoutSeconds)), "-o", destination.path, url.absoluteString]
    }

    private static func verifyRemoteLinuxArtifactArchive(_ archiveURL: URL, expectedSHA256: String) throws {
        #if canImport(CryptoKit)
            let data = try Data(contentsOf: archiveURL)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expectedSHA256.lowercased() else {
                throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                    "Spaces could not verify the Linux installer download. Update Spaces, then retry.")
            }
        #else
            _ = archiveURL
            _ = expectedSHA256
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "Spaces cannot verify Linux installers on this platform. Connect from the Mac app, then retry.")
        #endif
    }

    private static func createRemoteLinuxSetupDirectory(destination: String, port: Int?) throws -> String {
        let result = try runSSH(
            destination: destination, port: port, remoteCommand: #"mktemp -d "${TMPDIR:-/tmp}/spaces-install.XXXXXX""#, timeoutSeconds: 12)
        if result.timedOut { throw SpacesRemoteDevicePairingError.remoteLinuxSetupTimedOut(destination) }
        guard result.exitStatus == 0, let directory = normalized(result.standardOutput) else {
            let detail = [result.standardError, result.standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                !$0.isEmpty
            }.joined(separator: "\n")
            let suffix = detail.isEmpty ? "Exit status \(result.exitStatus)." : detail
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "SSH connected to \(destination), but Linux setup could not create a temporary install directory. \(suffix)")
        }
        return directory
    }

    private static func cleanupRemoteLinuxSetupDirectory(_ directory: String, destination: String, port: Int?) throws {
        _ = try runSSH(destination: destination, port: port, remoteCommand: "rm -rf \(shellQuoted(directory))", timeoutSeconds: 10)
    }

    private static func copyRemoteLinuxArtifact(_ archiveURL: URL, remoteArchivePath: String, destination: String, port: Int?) throws {
        guard FileManager.default.isExecutableFile(atPath: scpPath) else {
            throw SpacesRemoteDevicePairingError.sshUnavailable(
                "SSH file copy is required to set up Linux devices, but \(scpPath) is not executable.")
        }
        var arguments = [
            "-q", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
        ]
        arguments += sshControlArguments(destination: destination, port: port)
        if let port { arguments += ["-P", String(port)] }
        arguments += [archiveURL.path, scpRemoteDestination(destination: destination, remotePath: remoteArchivePath)]
        let result = try runLocalProcess(executablePath: scpPath, arguments: arguments, timeoutSeconds: 300)
        if result.timedOut { throw SpacesRemoteDevicePairingError.remoteLinuxSetupTimedOut(destination) }
        guard result.exitStatus == 0 else {
            let detail = [result.standardError, result.standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                !$0.isEmpty
            }.joined(separator: "\n")
            let suffix = detail.isEmpty ? "Exit status \(result.exitStatus)." : detail
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed(
                "SSH connected to \(destination), but Spaces could not copy the Linux installer. \(suffix)")
        }
    }

    private static func runRemoteLinuxInstallScript(remoteTempDirectory: String, remoteArchivePath: String, destination: String, port: Int?) throws {
        let command = """
            set -e
            temp_dir=\(shellQuoted(remoteTempDirectory))
            archive_path=\(shellQuoted(remoteArchivePath))
            install_dir="$temp_dir/install"
            rm -rf "$install_dir"
            mkdir -p "$install_dir"
            tar -xzf "$archive_path" -C "$install_dir" --strip-components=1
            "$install_dir/install.sh"
            rm -rf "$temp_dir"
            """
        let result = try runSSH(destination: destination, port: port, remoteCommand: command, timeoutSeconds: 120)
        if result.timedOut { throw SpacesRemoteDevicePairingError.remoteLinuxSetupTimedOut(destination) }
        guard result.exitStatus == 0 else {
            let detail = [result.standardError, result.standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                !$0.isEmpty
            }.joined(separator: "\n")
            let suffix = detail.isEmpty ? "Exit status \(result.exitStatus)." : detail
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed("SSH connected to \(destination), but Linux setup did not finish. \(suffix)")
        }
    }

    // MARK: SSH connection multiplexing
    //
    // A remote pairing/setup flow runs several short SSH commands back to back (config lookup, reachability
    // check, install probe, `spaces pair`, and, for Linux hosts, the installer copy/run). Opening a fresh
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

    private static func runLocalProcess(executablePath: String, arguments: [String], timeoutSeconds: TimeInterval) throws -> SSHCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do { try process.run() } catch {
            throw SpacesRemoteDevicePairingError.remoteLinuxSetupFailed("Failed to launch \(executablePath): \(error.localizedDescription)")
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

    static func remotePairCommandFailureMessage(destination: String, standardError: String, standardOutput: String, exitStatus: Int32) -> String {
        let detail = [standardError, standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(
            separator: "\n")
        let lowercased = detail.lowercased()
        if exitStatus == 127 || lowercased.contains("no such file") || lowercased.contains("not found") {
            return
                "SSH connected to \(destination), but Spaces is not available for that user. On a Mac, install the Spaces app. On Linux, retry automatic setup."
        }
        if lowercased.contains("permission denied") {
            return "SSH connected to \(destination), but Spaces cannot be run by that remote user. Fix the install permissions, then retry."
        }
        let suffix = detail.isEmpty ? "Exit status \(exitStatus)." : detail
        return "SSH connected to \(destination), but `\(remotePairCommand)` failed. \(suffix)"
    }

    private static func sshDestination(host: String, user: String?) -> String { user.map { "\($0)@\(host)" } ?? host }

    static func remoteShellCommand(_ command: String) -> String { "sh -c \(shellQuoted(command))" }

    static func scpRemoteDestination(destination: String, remotePath: String) -> String {
        let userPrefix: String
        let host: String
        if let atIndex = destination.firstIndex(of: "@") {
            userPrefix = "\(destination[..<destination.index(after: atIndex)])"
            host = String(destination[destination.index(after: atIndex)...])
        } else {
            userPrefix = ""
            host = destination
        }
        let formattedHost: String
        if host.contains(":"), !host.hasPrefix("[") { formattedHost = "[\(host)]" } else { formattedHost = host }
        return "\(userPrefix)\(formattedHost):\(remotePath)"
    }

    private static func normalizedRemoteLinuxArchitecture(_ value: String?) -> String? {
        switch normalized(value) {
        case "x86_64", "amd64": "x86_64"
        case "arm64", "aarch64": "arm64"
        default: nil
        }
    }

    private static func shellQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }

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
    let spacesAppInstalled: Bool
    let systemCLIExecutable: Bool
    let systemDaemonExecutable: Bool
    var systemCaddyExecutable: Bool = false
    let canonicalCLIExecutable: Bool
    var canonicalDaemonExecutable: Bool = false
    let launchAgentInstalled: Bool
}

struct RemoteArtifactManifest: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let releaseTag: String
    let artifacts: [RemoteLinuxArtifact]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case appVersion = "app_version"
        case releaseTag = "release_tag"
        case artifacts
    }
}

struct RemoteLinuxArtifact: Decodable, Equatable, Sendable {
    let id: String
    let version: String
    let platform: String
    let architecture: String
    let archiveName: String
    let url: String
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case platform
        case architecture
        case archiveName = "archive_name"
        case url
        case sha256
    }
}

private struct RemotePairingMetadata: Decodable, Sendable {
    let name: String
    let host: String
    let port: Int
    let pairingNonce: String
    let pairingCode: String
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
        guard trimmed(pairingNonce) != nil, trimmed(pairingCode) != nil, trimmed(certificateFingerprint) != nil else {
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
