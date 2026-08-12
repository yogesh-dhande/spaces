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
    /// Optional user-chosen display name for the paired device. When nil, the daemon-reported name is used.
    public let customName: String?
    public let profile: SpacesProfile?

    public init(
        sshHost: String, sshUser: String? = nil, sshPort: Int? = nil, clientInstallationID: String, clientBundleID: String, clientDeviceName: String,
        clientAppVersion: String?, customName: String? = nil, profile: SpacesProfile? = nil
    ) {
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.clientInstallationID = clientInstallationID
        self.clientBundleID = clientBundleID
        self.clientDeviceName = clientDeviceName
        self.clientAppVersion = clientAppVersion
        self.customName = customName
        self.profile = profile
    }
}

public struct SpacesRemoteDevicePairingResult: Sendable, Equatable {
    public let deviceID: String
    public let name: String
    /// The address the pairing request was redeemed against, for display. The stored record keeps every
    /// candidate address the device offered.
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
    /// A development profile's own deployed CLI is missing on the device, so this worktree has never been
    /// deployed there (or its profile was removed). Deliberately not `remoteSpacesNotInstalled`: that case
    /// carries the production installer command and drives the app's "Install Spaces over SSH" affordance,
    /// which installs only `~/.spaces` and could never make this pairing succeed.
    case remoteDevelopmentProfileNotDeployed(String)
    case remotePairCommandTimedOut(String)
    case remotePairCommandFailed(String)
    case invalidRemotePairingOutput(String)
    /// Names every candidate address the redemption was attempted against, since a link carries the
    /// device's LAN and tailnet addresses and all of them are raced.
    case deviceAPIUnreachable(hosts: [String], port: Int, message: String)
    case pairingVersionIncompatible(String)
    case pairingRejected(String)
    case missingAuthToken
    case remoteInstallTimedOut(String)
    case remoteInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSSHHost: "An SSH host is required for this action. Enter one to connect, or pair the device over SSH to enable remote updates."
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
        case .remoteDevelopmentProfileNotDeployed(let message): message
        case .remotePairCommandTimedOut(let destination):
            "SSH connected to \(destination), but Spaces did not finish preparing the connection. Confirm Spaces is installed and available for that user, then retry."
        case .remotePairCommandFailed(let message): message
        case .invalidRemotePairingOutput(let message): message
        case .deviceAPIUnreachable(let hosts, let port, let message):
            "The remote Device API is not reachable at \(hosts.map { "\($0):\(port)" }.joined(separator: ", ")). Confirm LAN/VPN/Tailscale/firewall access to those addresses and port. \(message)"
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
    static let devicePairSubcommand = "device pair --json"
    /// The pairing command for a remote installed profile: the CLI installed beside the daemon it pairs.
    static let installedRemotePairCommand = "~/.spaces/bin/spaces \(devicePairSubcommand)"
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
        let deviceID = stablePairedDeviceID(certificateFingerprint: metadata.certificateFingerprint, port: metadata.port)
        // Redeemed against the address SSH just proved reachable, not the daemon's advertised list: this
        // flow reached the device over SSH to that host, so it is the one candidate already known good.
        let client = try SpacesDeviceAPIRequestClient(
            resolver: SpacesDeviceEndpointResolver(
                hosts: [deviceAPIHost], port: metadata.port, certificateFingerprint: metadata.certificateFingerprint))
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
            throw SpacesRemoteDevicePairingError.deviceAPIUnreachable(
                hosts: [deviceAPIHost], port: metadata.port, message: error.localizedDescription)
        }
        guard response.ok else { throw SpacesRemoteDevicePairingError.pairingRejected(response.message) }
        guard let authToken = normalized(response.issuedAuthToken) else { throw SpacesRemoteDevicePairingError.missingAuthToken }

        // Prefer the user's name when they typed one at connect time, else the daemon-reported name.
        let displayName = normalized(request.customName) ?? metadata.name
        let now = ISO8601DateFormatter().string(from: Date())
        let database = try SpacesClientDatabase.defaultDatabase()
        try database.upsert(
            device: SpacesPairedDeviceRecord(
                id: deviceID, name: displayName, platform: "remote",
                hosts: relayedPairingHosts(deviceAPIHost: deviceAPIHost, advertisedHosts: metadata.hosts), port: metadata.port,
                certificateFingerprint: metadata.certificateFingerprint, sshHost: sshHost, sshUser: sshUser, sshPort: request.sshPort, createdAt: now,
                updatedAt: now, lastSelectedAt: now))
        try SpacesDeviceCredentialStore.saveToken(authToken, deviceID: deviceID, profile: request.profile)
        return SpacesRemoteDevicePairingResult(deviceID: deviceID, name: displayName, host: deviceAPIHost, port: metadata.port)
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

        try runRemoteInstaller(destination: destination, port: request.sshPort, version: normalized(request.clientAppVersion))
        // Pairing nests inside this flow's already-open ControlMaster: openSSHControlMaster returns early
        // when the master is live, so pairRemoteDevice reuses it, and its own defer closes it. The outer
        // defer's `-O exit` then no-ops harmlessly (runDetachedSSHProcess swallows failures and the socket
        // removal is `try?`). This nesting is intentional and safe.
        return try pairRemoteDevice(request)
    }

    /// Updates Spaces on an already-paired Linux device by running the installer over SSH, pinned to
    /// `appVersion` so the device lands on the version this client speaks. The device keeps its pairing:
    /// there is no re-pair and no install probe, only the installer run.
    ///
    /// The Linux installer lands the new release beside the running one and pokes the live daemon
    /// (`spaces daemon apply-update`), which execs the staged binary at the same pid instead of exiting
    /// for systemd to respawn it, so the running terminals, workspace processes, and coding agents on
    /// that device survive the update.
    ///
    /// Accepted consequence: once the daemon moves forward, clients on older app builds are wire-blocked
    /// on this device until those apps update. Their sessions keep running underneath the block, so
    /// updating the client restores the connection with nothing lost.
    public static func updateSpacesOnRemoteDevice(device: SpacesPairedDeviceRecord, appVersion: String?) throws {
        guard let sshHost = normalized(device.sshHost) else { throw SpacesRemoteDevicePairingError.missingSSHHost }
        let sshUser = normalized(device.sshUser)
        try validateSSHPort(device.sshPort)
        let destination = sshDestination(host: sshHost, user: sshUser)
        openSSHControlMaster(destination: destination, port: device.sshPort)
        defer { closeSSHControlMaster(destination: destination, port: device.sshPort) }
        try runRemoteInstaller(destination: destination, port: device.sshPort, version: normalized(appVersion))
    }

    /// Runs the Linux installer over SSH and maps its outcome. Expects the caller to have opened (and to
    /// close) the ControlMaster for `destination`, since both callers run other SSH commands around it.
    private static func runRemoteInstaller(destination: String, port: Int?, version: String?) throws {
        let installCommand = SpacesLinuxInstaller.sshInstallCommand(version: version)
        let result = try runSSH(destination: destination, port: port, remoteCommand: installCommand, timeoutSeconds: remoteInstallTimeoutSeconds)
        if result.timedOut { throw SpacesRemoteDevicePairingError.remoteInstallTimedOut(destination) }
        guard result.exitStatus == 0 else {
            throw SpacesRemoteDevicePairingError.remoteInstallFailed(
                remoteInstallFailureMessage(
                    destination: destination, standardOutput: result.standardOutput, standardError: result.standardError,
                    exitStatus: result.exitStatus))
        }
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
        // The link's hosts arrive ordered most-preferred first and already normalized and capped by
        // `SpacesDevicePairingLink.parse` (a link's `host` parameter repeats, so the bound is applied
        // once there, for every client that redeems), and all of them are stored as the record's
        // candidates. The redemption itself races them through a throwaway resolver — one with no
        // persistence callback, since there is no stored record to record a proven address against
        // yet — so scanning a pairing link works away from the device's LAN, not only on it.
        guard !link.hosts.isEmpty else {
            throw SpacesRemoteDevicePairingError.invalidRemotePairingOutput("Pairing link is missing a Device API host.")
        }
        try assertPairingCompatible(deviceProtocolVersion: link.protocolVersion, deviceAppVersion: link.appVersion, deviceName: link.name)
        let deviceID = stablePairedDeviceID(certificateFingerprint: link.certificateFingerprint, port: link.port)
        let resolver = SpacesDeviceEndpointResolver(hosts: link.hosts, port: link.port, certificateFingerprint: link.certificateFingerprint)
        let client = try SpacesDeviceAPIRequestClient(resolver: resolver)
        let response: SpacesDeviceAPIResponse
        do {
            response = try client.request(
                SpacesDeviceAPIRequest(
                    command: .pair(.init(pairingCode: link.code, pairingNonce: link.nonce, clientProtocolVersion: SpacesWireProtocol.version)),
                    clientApp: SpacesDeviceClientApp(
                        installationID: clientInstallationID, bundleID: clientBundleID, platform: clientPlatform, deviceName: clientDeviceName,
                        appVersion: clientAppVersion)))
        } catch { throw SpacesRemoteDevicePairingError.deviceAPIUnreachable(hosts: link.hosts, port: link.port, message: error.localizedDescription) }
        guard response.ok else { throw SpacesRemoteDevicePairingError.pairingRejected(response.message) }
        guard let authToken = normalized(response.issuedAuthToken) else { throw SpacesRemoteDevicePairingError.missingAuthToken }

        // The candidate that answered becomes the record's proven address, so the first connect after
        // pairing goes straight to it instead of re-racing the whole link. A redemption that got a
        // response always proved one; `link.hosts[0]` only keeps the expression total.
        let provenHost = resolver.currentCachedHost() ?? link.hosts[0]
        let now = ISO8601DateFormatter().string(from: Date())
        let database = try SpacesClientDatabase.defaultDatabase()
        try database.upsert(
            device: SpacesPairedDeviceRecord(
                id: deviceID, name: link.name, platform: "remote", hosts: link.hosts, activeHost: provenHost, port: link.port,
                certificateFingerprint: link.certificateFingerprint, sshHost: nil, sshUser: nil, sshPort: nil, createdAt: now, updatedAt: now,
                lastSelectedAt: now))
        try SpacesDeviceCredentialStore.saveToken(authToken, deviceID: deviceID, profile: profile)
        return SpacesRemoteDevicePairingResult(deviceID: deviceID, name: link.name, host: provenHost, port: link.port)
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
        let sshHost = try normalizedSSHHost(device.sshHost ?? device.dialHost ?? "")
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
            hosts: relayedPairingHosts(deviceAPIHost: deviceAPIHost, advertisedHosts: metadata.hosts), port: metadata.port,
            nonce: metadata.pairingNonce, code: metadata.pairingCode, certificateFingerprint: metadata.certificateFingerprint, name: metadata.name,
            protocolVersion: metadata.protocolVersion, appVersion: metadata.appVersion)
        return SpacesRemoteDevicePairingWindowResult(
            name: metadata.name, host: deviceAPIHost, port: metadata.port, linkString: link.absoluteString, expiresAt: metadata.expiresAt)
    }

    /// Builds the host list for a relayed pairing link (`openRemotePairingWindow`, the "Pair iPhone or
    /// iPad with a remote device" QR shown for an already-connected remote Mac): `deviceAPIHost` — the
    /// SSH-resolved effective OpenSSH `HostName` — leads, because it is the one address *this* Mac has
    /// actually proven routable right now. The remote daemon's own advertised `hosts` (its pairing
    /// metadata's view of its own LAN/tailnet addresses) follow rather than get discarded: the phone
    /// scanning the code is a different device from this Mac, so a route that works from here (an SSH
    /// alias, a jump host, a LAN this Mac happens to share with the target) is not guaranteed to work
    /// from the phone, while the daemon's own tailnet address usually is. De-duplicated, order otherwise
    /// preserved, so a daemon that happens to advertise its own SSH-resolved address back is not listed
    /// twice.
    static func relayedPairingHosts(deviceAPIHost: String, advertisedHosts: [String]) -> [String] {
        var hosts = [deviceAPIHost]
        for host in advertisedHosts where !hosts.contains(host) { hosts.append(host) }
        return hosts
    }

    /// `installationID` is a default parameter value on `SpacesDeviceClient.macOSClientApp(...)`, which is
    /// itself a default parameter value on dozens of `SpacesDeviceClient` methods — Swift rejects a
    /// throwing expression in a default argument outright, so this can never become `throws` without
    /// threading an explicit installation id through every one of those call sites, most of which have
    /// nothing to do with this issue. It uses `currentOrNilLoggingRefusal()` rather than `try?`, so a
    /// test-host refusal reached from this widely-shared default is reported (see that function's doc
    /// comment) instead of looking identical to the genuine "no profile" case this function already
    /// degrades on by falling back to `NSHomeDirectory()`.
    public static func localMacClientInstallationID(profile: SpacesProfile? = nil) -> String {
        let profileRoot = (profile ?? SpacesProfile.currentOrNilLoggingRefusal())?.rootDirectory ?? NSHomeDirectory()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in profileRoot.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "macos-\(String(hash, radix: 16))"
    }

    /// The stable id a device's pinned certificate resolves to. The source string keeps the port, but the
    /// slug is truncated to 48 characters and a certificate fingerprint alone ("sha256-" plus 64 hex
    /// characters) is longer than that, so the truncation always lands inside the fingerprint hex and
    /// nothing after it can reach the output. That is why dropping the host from the historical
    /// "<fingerprint>|<host>|<port>" formula produces byte-identical ids and no stored id is ever
    /// rewritten.
    static func stablePairedDeviceID(certificateFingerprint: String, port: Int) -> String {
        let source = "\(certificateFingerprint)|\(port)"
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
        let pairCommand = try remotePairCommand(profile: profile)
        let result = try runSSH(destination: destination, port: port, remoteCommand: pairCommand.command, timeoutSeconds: 15)
        return try parseRemotePairingMetadataResult(result, destination: destination, probe: probe, appVersion: appVersion, pairCommand: pairCommand)
    }

    /// The `spaces device pair --json` command run on the remote device, named by the CLI that belongs to
    /// the profile being paired.
    ///
    /// A development profile pairs through ITS OWN deployed CLI, addressed by path inside that profile's
    /// root, with NO environment prefix: a deployed `spaces` binary states which profile it serves by
    /// where it lives, so it opens that profile's database and runtime by itself. Pointing the installed
    /// CLI at a development database with `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` instead only ever worked
    /// because a development deploy overwrote the installed binaries; a device now carries the installed
    /// profile and every development profile side by side, each with its own binaries and daemon.
    ///
    /// The command reaches that profile's CLI, whose `ensureRunning` starts that profile's own daemon unit
    /// — so pairing brings up a development daemon that is down without any pairing-specific code.
    ///
    /// The result also states which profile's CLI it names, because a missing binary means different things
    /// for the two: see `remotePairCommandBinaryMissingError`.
    static func remotePairCommand(profile: SpacesProfile?) throws -> RemotePairCommand {
        guard let profileName = try remoteDevelopmentProfileName(profile: profile) else {
            return RemotePairCommand(command: installedRemotePairCommand, developmentProfileName: nil)
        }
        let cliPath = "~/.spaces-dev/profiles/spaces/\(profileName)/daemon/current/bin/spaces"
        return RemotePairCommand(command: "\(remoteShellPathExpression(cliPath)) \(devicePairSubcommand)", developmentProfileName: profileName)
    }

    /// The name of the remote development profile this client pairs with, derived only from the local
    /// profile's own directory name: one worktree owns exactly one remote profile, named after it, at the
    /// single layout the installer creates (`~/.spaces-dev/profiles/spaces/<name>`). There is deliberately
    /// no way to name a root anywhere else — a root outside that layout has no unit instance and no CLI of
    /// its own, so pairing against it could not work.
    ///
    /// Falls back to `SpacesProfile.currentOrNilIfUnresolved()` — not `current()` swallowed with `try?`
    /// — when the caller passed no profile: a genuine "no profile could be resolved" still degrades to
    /// `nil` here (this function already treats `nil` as "no development profile, use the installed
    /// command"), but a test-host refusal is not that, and this whole call chain already `throws`, so
    /// there is no reason for it to be silenced instead of propagated like every other resolution error.
    private static func remoteDevelopmentProfileName(profile providedProfile: SpacesProfile?) throws -> String? {
        let profile = try providedProfile ?? SpacesProfile.currentOrNilIfUnresolved()
        guard let profile else { return nil }
        let marker = "/.spaces-dev/profiles/spaces/"
        let canonicalRoot = SpacesProfile.canonicalPath(profile.rootDirectory)
        guard canonicalRoot.contains(marker) else { return nil }
        let profileName = URL(fileURLWithPath: canonicalRoot, isDirectory: true).lastPathComponent
        guard normalized(profileName) != nil else { return nil }
        return profileName
    }

    /// `pairCommand` is the command that actually ran, so a failure message names the CLI the pairing
    /// attempt used — the installed one or a development profile's own — instead of a hardcoded path, and a
    /// missing binary is reported as whichever of the two is missing.
    private static func parseRemotePairingMetadataResult(
        _ result: SSHCommandResult, destination: String, probe: RemoteInstallProbe, appVersion: String?, pairCommand: RemotePairCommand
    ) throws -> RemotePairingMetadata {
        if result.timedOut { throw SpacesRemoteDevicePairingError.remotePairCommandTimedOut(destination) }
        // A successful `spaces device pair --json` exits 0 with pairing JSON on stdout; only a failed
        // command can indicate a missing install. Branch on the nonzero exit first so pairing JSON that
        // happens to contain "not found"/"no such file" (e.g. inside a device name) is never misread as
        // not-installed.
        if result.exitStatus != 0 {
            // A missing `spaces` binary (exit 127 / "not found") means the CLI this command named is not on
            // the device. The structured error carries the install command, so a caller can run the
            // installer over SSH itself (the Mac panel and the CLI do) and render the copyable command as
            // the fallback.
            if remoteSpacesNotInstalled(exitStatus: result.exitStatus, standardError: result.standardError, standardOutput: result.standardOutput) {
                throw remotePairCommandBinaryMissingError(destination: destination, pairCommand: pairCommand, probe: probe, appVersion: appVersion)
            }
            throw SpacesRemoteDevicePairingError.remotePairCommandFailed(
                remotePairCommandFailureMessage(
                    destination: destination, command: pairCommand.command, standardError: result.standardError,
                    standardOutput: result.standardOutput, exitStatus: result.exitStatus))
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
                throw remotePairCommandBinaryMissingError(destination: destination, pairCommand: pairCommand, probe: probe, appVersion: appVersion)
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

    /// The error for a pairing command whose `spaces` binary is not on the device.
    ///
    /// Which binary is missing decides what the user must do, so the two cases are different errors. A
    /// missing installed CLI (`~/.spaces/bin/spaces`) is a device without Spaces: it carries the install
    /// guidance and, for Linux, the pinned installer one-liner that backs the app's "Install Spaces over
    /// SSH" affordance. A missing development-profile CLI is not that at all — the device may well have
    /// Spaces installed, and what is absent is this worktree's deployed profile. Running the production
    /// installer would only ever create `~/.spaces` and could never make this pairing succeed, so this
    /// error names the deploy that would, and deliberately carries no install command.
    static func remotePairCommandBinaryMissingError(
        destination: String, pairCommand: RemotePairCommand, probe: RemoteInstallProbe, appVersion: String?
    ) -> SpacesRemoteDevicePairingError {
        guard let profileName = pairCommand.developmentProfileName else {
            return remoteSpacesNotInstalledError(
                lead: "SSH connected to \(destination), but Spaces is not installed for that user.", probe: probe, appVersion: appVersion)
        }
        return .remoteDevelopmentProfileNotDeployed(
            "SSH connected to \(destination), but the \(profileName) development profile is not deployed there. "
                + "Deploy this worktree to the device with scripts/dev-build-and-launch.sh, then pair again.")
    }

    /// Builds the actionable install/setup guidance shown when SSH reaches the remote but Spaces there
    /// cannot hand back a pairing window. `lead` states what went wrong; this appends platform-specific
    /// guidance without embedding any install command (the command travels separately on the structured
    /// `remoteSpacesNotInstalled` error). Linux guidance backs the client-initiated installer run over SSH
    /// and the copyable one-liner beside it; a remote Mac has no such path, so its guidance asks the user
    /// to install and open the Spaces app on the device.
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
    /// return 0 regardless of the remote command's real status — so a missing `spaces` binary can
    /// surface only as this stderr text under a reported exit 0. This content check backstops the exit
    /// code so a not-installed remote is still recognized.
    static func outputReportsMissingBinary(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("no such file") || lowered.contains("not found")
    }

    /// Message for a `spaces device pair` failure that is not the not-installed case (which is handled
    /// earlier with actionable install instructions). Covers a runnable-but-broken install: a permission
    /// problem, or any other nonzero exit. `command` is the command that ran, so the message names the
    /// CLI the user can reproduce the failure with.
    static func remotePairCommandFailureMessage(
        destination: String, command: String, standardError: String, standardOutput: String, exitStatus: Int32
    ) -> String {
        let detail = [standardError, standardOutput].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(
            separator: "\n")
        let lowercased = detail.lowercased()
        if lowercased.contains("permission denied") {
            return "SSH connected to \(destination), but Spaces cannot be run by that remote user. Fix the install permissions, then retry."
        }
        let suffix = detail.isEmpty ? "Exit status \(exitStatus)." : detail
        return "SSH connected to \(destination), but `\(command)` failed. \(suffix)"
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

/// The `spaces device pair --json` invocation sent to a device, together with which profile's CLI it
/// names. The profile matters after the fact: a missing binary means "Spaces is not installed here" for the
/// installed CLI and "this worktree is not deployed here" for a development profile's own CLI.
struct RemotePairCommand: Equatable, Sendable {
    let command: String
    /// The development profile whose deployed CLI `command` runs, or `nil` when it runs the installed CLI.
    let developmentProfileName: String?
}

struct RemoteInstallProbe: Equatable, Sendable {
    let operatingSystem: String
    let architecture: String?
    let linuxID: String?
    let linuxVersionID: String?
}

// Kept internal (not `private`) rather than `private` to this file: the JSON round-trip test in
// spacescliTests decodes real production output through this exact type — see
// `SpacesCommandTests.testPairingWindowPayloadRoundTripsThroughRemotePairingMetadata` — so the
// producer (`PairingWindowPayload` in spacescli) and this consumer can never again drift apart
// silently the way `host` (singular) vs `hosts` (plural) once did.
struct RemotePairingMetadata: Decodable, Sendable {
    let name: String
    /// Ordered candidate daemon addresses the remote daemon's own pairing link advertised (its LAN
    /// IPv4, then its Tailscale address). Decoded from the JSON `spaces device pair --json` prints —
    /// see `PairingWindowPayload` in spacescli, the producer of this exact shape.
    let hosts: [String]
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
        guard !hosts.isEmpty else {
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
