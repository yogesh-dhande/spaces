import Foundation
import spacesdevicecore
import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum SpacesDeviceAPIDefaults {
    public static let host = SpacesDeviceAPIEndpointDefaults.host
    public static let loopbackHost = SpacesDeviceAPIEndpointDefaults.loopbackHost
    public static let port = SpacesDeviceAPIEndpointDefaults.port
    public static let bonjourServiceType = SpacesDeviceAPIEndpointDefaults.bonjourServiceType
    public static let bonjourBrowserServiceType = SpacesDeviceAPIEndpointDefaults.bonjourBrowserServiceType

    /// Ports development profiles assign themselves from. The canonical `port` belongs to the installed
    /// profile alone and is excluded by construction — the range starts one above it — so an assigned
    /// development port can never collide with the installed daemon a client already paired with.
    public static let developmentPortRange: ClosedRange<Int> = 47_848...47_947

    public static let disabledEnvironmentVariable = "SPACES_DEVICE_API_DISABLED"
    public static let hostEnvironmentVariable = "SPACES_DEVICE_API_HOST"
    public static let portEnvironmentVariable = "SPACES_DEVICE_API_PORT"

    public static func isWildcardHost(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedHost.isEmpty || trimmedHost == "0.0.0.0" || trimmedHost == "::"
    }

    /// True when the Device API is turned off for this process via the `SPACES_DEVICE_API_DISABLED`
    /// environment override (`1`/`true`). The daemon never creates the control socket in this case, so a
    /// relaunch that inherits the same environment cannot bring it up — callers use this to distinguish a
    /// deliberately disabled endpoint from a transiently unreachable one.
    public static func isDisabledByEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let value = environment[disabledEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value == "1" || value.localizedCaseInsensitiveCompare("true") == .orderedSame
    }
}

public struct SpacesDeviceAPISettings: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String = SpacesDeviceAPIDefaults.host, port: Int = SpacesDeviceAPIDefaults.port) {
        self.host = host
        self.port = port
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
    }

    /// Tolerates settings files written by earlier versions: missing keys fall back to defaults and
    /// extra keys (e.g. the retired transport-key identity fields) are ignored.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? SpacesDeviceAPIDefaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? SpacesDeviceAPIDefaults.port
    }
}

public struct SpacesDeviceAPIStatus: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let bonjourServiceName: String
    public let bonjourServiceType: String
    public let networkAddresses: [String]
    public let certificateFingerprint: String

    public init(
        host: String, port: Int, bonjourServiceName: String, bonjourServiceType: String, networkAddresses: [String], certificateFingerprint: String
    ) {
        self.host = host
        self.port = port
        self.bonjourServiceName = bonjourServiceName
        self.bonjourServiceType = bonjourServiceType
        self.networkAddresses = networkAddresses
        self.certificateFingerprint = certificateFingerprint
    }
}

public final class SpacesDeviceAPISettingsStore {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let profileSource: () throws -> SpacesProfileSource
    private let profileRoot: () throws -> String
    private let portsClaimedByOtherProfiles: (String) -> Set<Int>

    /// `profileSource`, `profileRoot`, and `portsClaimedByOtherProfiles` are injectable for testing; they
    /// default to the running process's resolved profile and the real on-disk sibling profiles. The source
    /// decides whether this profile is allowed to bind the canonical Device API port, and the root plus the
    /// claimed ports decide which port it assigns itself when it is not.
    public init(
        fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment,
        profileSource: @escaping () throws -> SpacesProfileSource = { try SpacesProfile.current().source },
        profileRoot: @escaping () throws -> String = { try SpacesProfile.current().rootDirectory },
        portsClaimedByOtherProfiles: @escaping (String) -> Set<Int> = SpacesDeviceAPISettingsStore.portsClaimedBySiblingProfiles(profileRoot:)
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.profileSource = profileSource
        self.profileRoot = profileRoot
        self.portsClaimedByOtherProfiles = portsClaimedByOtherProfiles
    }

    public func loadOrCreate() throws -> SpacesDeviceAPISettings {
        try applyingEnvironmentOverrides(to: assigningDevelopmentPort(loadStoredOrCreate()))
    }

    /// The fixed canonical Device API port belongs to the installed profile alone. Any other profile (dev
    /// worktree, deployed dev profile, explicit database) that still carries the canonical port has never
    /// been assigned one, so it is given a port from `developmentPortRange` and that assignment is PERSISTED.
    ///
    /// Persisting is the point. A development daemon has to be reachable at a fixed address: a paired client
    /// stores one host:port for the device, so a profile whose port moved between starts would silently
    /// orphan every client already paired with it. That is also why a stored port other than the canonical
    /// default is respected verbatim and never reassigned — once a profile has a port, it keeps it. For a
    /// development profile `device-api.json` therefore records the port that will actually be bound, with one
    /// exception: an environment override is applied after this and never written back, so a profile started
    /// with `SPACES_DEVICE_API_PORT` set (the E2E profiles, which pin a port or ask for an ephemeral one)
    /// binds the overridden port while the file still holds its own assignment.
    ///
    /// The choice is deterministic (profile-root hash, stepped past ports other profiles already recorded)
    /// rather than a bind probe: a probe would let anything transiently holding the derived port move this
    /// profile off it permanently. Genuine runtime occupancy needs no help here — the Device API supervisor's
    /// restart timer keeps retrying the bind, so the listener comes up as soon as the port is free again.
    ///
    /// Env overrides are applied afterward and still win, which is how the Linux systemd install
    /// (SPACES_DEVICE_API_PORT together with SPACES_DB_PATH) keeps binding the canonical port.
    private func assigningDevelopmentPort(_ settings: SpacesDeviceAPISettings) throws -> SpacesDeviceAPISettings {
        guard settings.port == SpacesDeviceAPIDefaults.port, try profileSource() != .installedFallback else { return settings }
        let root = try profileRoot()
        var assigned = settings
        assigned.port = Self.assignedDevelopmentPort(profileRoot: root, claimedPorts: portsClaimedByOtherProfiles(root))
        try save(assigned)
        return assigned
    }

    /// The port a development profile with `profileRoot` assigns itself: the profile root's stable hash maps
    /// into `developmentPortRange`, then steps forward with wraparound while the candidate is already claimed
    /// by another profile. Hashing the root means the same profile derives the same port on every machine and
    /// every start; stepping only resolves the rare case of two profile roots hashing into the same slot.
    ///
    /// With every port in the range claimed there is no unclaimed choice left to make, so the profile keeps
    /// its derived port and shares it with whichever profile also holds it.
    static func assignedDevelopmentPort(profileRoot: String, claimedPorts: Set<Int>) -> Int {
        let range = SpacesDeviceAPIDefaults.developmentPortRange
        let hash = UInt64(SpacesProfile.shortStableHash(SpacesProfile.canonicalPath(profileRoot)), radix: 16) ?? 0
        let derivedIndex = Int(hash % UInt64(range.count))
        let candidates = (0..<range.count).map { range.lowerBound + (derivedIndex + $0) % range.count }
        return candidates.first { !claimedPorts.contains($0) } ?? candidates[0]
    }

    /// The Device API ports other profiles on this device have already recorded for themselves, read from
    /// each sibling profile's own `device-api.json`. A sibling is another directory beside this profile root,
    /// which for a development profile is another profile under `.spaces-dev/profiles/spaces/`.
    ///
    /// Best effort by design: a sibling directory with no settings file, an unreadable one, or a malformed
    /// one contributes nothing instead of failing this profile's load. The consequence of missing a claim is
    /// only that two profiles may derive the same port, which the sticky assignment above then keeps stable
    /// rather than making worse. A sibling that moved its runtime directory elsewhere with SPACES_RUNTIME_DIR
    /// is invisible here for the same reason: the layout below mirrors `settingsPath()` for the default
    /// runtime root, and there is nothing on disk beside the profile root to point anywhere else.
    public static func portsClaimedBySiblingProfiles(profileRoot: String) -> Set<Int> {
        let rootURL = URL(fileURLWithPath: SpacesProfile.canonicalPath(profileRoot), isDirectory: true)
        let siblingURLs =
            (try? FileManager.default.contentsOfDirectory(
                at: rootURL.deletingLastPathComponent(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var claimedPorts = Set<Int>()
        for siblingURL in siblingURLs where SpacesProfile.canonicalPath(siblingURL.path) != rootURL.path {
            let settingsURL = siblingURL.appendingPathComponent("runtime", isDirectory: true).appendingPathComponent("terminal", isDirectory: true)
                .appendingPathComponent("device-api.json", isDirectory: false)
            guard let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(SpacesDeviceAPISettings.self, from: data)
            else { continue }
            claimedPorts.insert(settings.port)
        }
        return claimedPorts
    }

    private func loadStoredOrCreate() throws -> SpacesDeviceAPISettings {
        let path = try settingsPath()
        let storedSettings: SpacesDeviceAPISettings
        if fileManager.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            storedSettings = try JSONDecoder().decode(SpacesDeviceAPISettings.self, from: data)
        } else {
            storedSettings = SpacesDeviceAPISettings()
            try save(storedSettings)
        }
        return storedSettings
    }

    public func status(certificateFingerprint: String) throws -> SpacesDeviceAPIStatus {
        let settings = try loadOrCreate()
        return SpacesDeviceAPIStatus(
            host: settings.host, port: settings.port, bonjourServiceName: try Self.bonjourServiceName(),
            bonjourServiceType: SpacesDeviceAPIDefaults.bonjourServiceType, networkAddresses: SpacesDeviceAPINetworkInterfaces.ipv4Addresses(),
            certificateFingerprint: certificateFingerprint)
    }

    public static func bonjourServiceName() throws -> String {
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let profile = try SpacesProfile.current()
        if let branchSlug = profile.branchSlug, let worktreeHash = profile.worktreeHash { return "\(hostName) \(branchSlug)-\(worktreeHash)" }
        return hostName
    }

    private func save(_ settings: SpacesDeviceAPISettings) throws {
        let path = try settingsPath()
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: [.atomic])
    }

    private func settingsPath() throws -> String {
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager)
        return root.appendingPathComponent("device-api.json", isDirectory: false).path
    }

    private func applyingEnvironmentOverrides(to settings: SpacesDeviceAPISettings) -> SpacesDeviceAPISettings {
        var resolved = settings
        if let host = trimmed(environment[SpacesDeviceAPIDefaults.hostEnvironmentVariable]) { resolved.host = host }
        if let port = trimmed(environment[SpacesDeviceAPIDefaults.portEnvironmentVariable]).flatMap(Int.init), (0...65_535).contains(port) {
            resolved.port = port
        }
        return resolved
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

}

public enum SpacesDeviceAPINetworkInterfaces {
    struct IPv4InterfaceAddress: Equatable, Sendable {
        let name: String
        let address: String
        let flags: Int32
        let discoveryIndex: Int

        init(name: String, address: String, flags: Int32, discoveryIndex: Int) {
            self.name = name
            self.address = address
            self.flags = flags
            self.discoveryIndex = discoveryIndex
        }
    }

    public static func ipv4Addresses() -> [String] { sortedIPv4Addresses(from: ipv4InterfaceAddresses()) }

    /// Convenience overload that walks the live network interfaces itself; production callers use this.
    public static func pairingLinkHosts(boundHost: String) -> [String] {
        pairingLinkHosts(boundHost: boundHost, interfaceAddresses: ipv4InterfaceAddresses())
    }

    /// The ordered set of addresses a pairing link should advertise, most-preferred first. A pinned
    /// (non-wildcard) bind address is returned verbatim: an operator who chose a specific address gets
    /// exactly that and nothing else. Otherwise the top-ranked LAN candidate is offered first, followed
    /// by the top-ranked tailnet candidate (if any) as a fallback path a client can retry when the LAN
    /// address is unreachable — e.g. the pairing device is off the same network but on the same tailnet.
    /// Takes the `IPv4InterfaceAddress` struct (rather than the flattened `[String]` `ipv4Addresses()`
    /// returns) because picking out the tailnet candidate needs the interface flags and name, not just
    /// the address text.
    static func pairingLinkHosts(boundHost: String, interfaceAddresses: [IPv4InterfaceAddress]) -> [String] {
        let host = boundHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !SpacesDeviceAPIDefaults.isWildcardHost(host) { return [host] }

        let ranked = rankedIPv4InterfaceAddresses(from: interfaceAddresses)
        let lanAddress = ranked.first { !isTailnetInterfaceAddress($0) }?.address
        let tailnetAddress = ranked.first { isTailnetInterfaceAddress($0) }?.address

        var seenAddresses = Set<String>()
        let hosts = [lanAddress, tailnetAddress].compactMap { $0 }.filter { !$0.isEmpty && seenAddresses.insert($0).inserted }
        return hosts.isEmpty ? [SpacesDeviceAPIDefaults.loopbackHost] : hosts
    }

    /// True when the address is in the Tailscale/CGNAT range (`100.64.0.0/10`) *and* bound to an
    /// interface that looks like a tunnel (point-to-point, or a known virtual/peer interface name).
    /// A CGNAT-range address on a tunnel interface is the Tailscale signature on both macOS (`utunN`)
    /// and Linux (`tailscale0`): detecting it this way needs no `tailscale` CLI call or LocalAPI socket,
    /// so it works from a headless Linux daemon and inside the sandboxed Tailscale build. Requiring the
    /// tunnel interface (rather than the address range alone) stops a genuine carrier-CGNAT LAN address
    /// from being mislabelled as a tailnet address.
    static func isTailnetInterfaceAddress(_ interfaceAddress: IPv4InterfaceAddress) -> Bool {
        guard let octets = ipv4Octets(interfaceAddress.address), octets[0] == 100, (64...127).contains(octets[1]) else { return false }
        return interfaceAddress.flags & pointToPointFlag != 0 || isVirtualOrPeerInterfaceName(interfaceAddress.name.lowercased())
    }

    /// Interfaces filtered to those eligible for a pairing address, ranked most-preferred first. Shared
    /// by `sortedIPv4Addresses(from:)` (which flattens to addresses for `SpacesDeviceAPIStatus.networkAddresses`)
    /// and `pairingLinkHosts(boundHost:interfaceAddresses:)` (which needs the interface metadata to split
    /// out the tailnet fallback candidate).
    private static func rankedIPv4InterfaceAddresses(from interfaceAddresses: [IPv4InterfaceAddress]) -> [IPv4InterfaceAddress] {
        interfaceAddresses.filter { $0.flags & upFlag != 0 && $0.flags & loopbackFlag == 0 && ipv4Octets($0.address) != nil }.sorted { lhs, rhs in
            let lhsRank = pairingPreferenceRank(lhs)
            let rhsRank = pairingPreferenceRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.discoveryIndex < rhs.discoveryIndex
        }
    }

    static func sortedIPv4Addresses(from interfaceAddresses: [IPv4InterfaceAddress]) -> [String] {
        var seenAddresses = Set<String>()
        return rankedIPv4InterfaceAddresses(from: interfaceAddresses).compactMap { interfaceAddress in
            guard seenAddresses.insert(interfaceAddress.address).inserted else { return nil }
            return interfaceAddress.address
        }
    }

    private static func ipv4InterfaceAddresses() -> [IPv4InterfaceAddress] {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0, let firstAddress = interfaceAddresses else { return [] }
        defer { freeifaddrs(interfaceAddresses) }

        var addresses: [IPv4InterfaceAddress] = []
        var discoveryIndex = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & upFlag != 0, flags & loopbackFlag == 0 else { continue }
            guard let interfaceAddress = current.pointee.ifa_addr else { continue }
            guard interfaceAddress.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            #if canImport(Darwin)
                let addressLength = socklen_t(interfaceAddress.pointee.sa_len)
            #else
                let addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            #endif
            let result = getnameinfo(interfaceAddress, addressLength, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let addressBytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let address = String(decoding: addressBytes, as: UTF8.self)
            let name = current.pointee.ifa_name.map { String(cString: $0) } ?? ""
            addresses.append(IPv4InterfaceAddress(name: name, address: address, flags: flags, discoveryIndex: discoveryIndex))
            discoveryIndex += 1
        }
        return addresses
    }

    /// Point-to-point and virtual/peer (tunnel) interfaces are penalized here, but that is no longer an
    /// exclusion — it expresses fallback preference. `pairingLinkHosts` deliberately offers the
    /// top-ranked tailnet address as a secondary candidate, so pushing tunnel interfaces to the bottom
    /// of this ranking is exactly what makes the LAN address the first choice and the tailnet address
    /// the fallback.
    private static func pairingPreferenceRank(_ interfaceAddress: IPv4InterfaceAddress) -> Int {
        let name = interfaceAddress.name.lowercased()
        var rank = 0
        if interfaceAddress.flags & runningFlag == 0 { rank += 1_000 }
        if interfaceAddress.flags & pointToPointFlag != 0 { rank += 500 }
        if isVirtualOrPeerInterfaceName(name) { rank += 400 }
        if isPreferredLANInterfaceName(name) { rank -= 200 }
        rank += ipv4AddressPreferencePenalty(interfaceAddress.address)
        return rank
    }

    private static func isPreferredLANInterfaceName(_ name: String) -> Bool { name.hasPrefix("en") }

    private static func isVirtualOrPeerInterfaceName(_ name: String) -> Bool {
        ["awdl", "bridge", "docker", "gif", "ipsec", "llw", "p2p", "ppp", "stf", "tap", "tailscale", "tun", "utun", "vboxnet", "vmnet", "wg", "zt"]
            .contains { name.hasPrefix($0) }
    }

    private static func ipv4AddressPreferencePenalty(_ address: String) -> Int {
        guard let octets = ipv4Octets(address) else { return 1_000 }
        if octets[0] == 10 { return 0 }
        if octets[0] == 172, (16...31).contains(octets[1]) { return 0 }
        if octets[0] == 192, octets[1] == 168 { return 0 }
        if octets[0] == 169, octets[1] == 254 { return 50 }
        if octets[0] == 0 || octets[0] == 127 || octets[0] >= 224 { return 1_000 }
        return 100
    }

    private static func ipv4Octets(_ address: String) -> [UInt8]? {
        var parsedAddress = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &parsedAddress) }) == 1 else { return nil }
        let value = UInt32(bigEndian: parsedAddress.s_addr)
        return [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static var upFlag: Int32 { Int32(IFF_UP) }
    private static var loopbackFlag: Int32 { Int32(IFF_LOOPBACK) }
    private static var runningFlag: Int32 { Int32(IFF_RUNNING) }
    private static var pointToPointFlag: Int32 { Int32(IFF_POINTOPOINT) }
}
