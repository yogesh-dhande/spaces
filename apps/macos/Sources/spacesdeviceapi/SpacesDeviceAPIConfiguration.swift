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

    /// `profileSource` is injectable for testing; it defaults to the running process's resolved profile
    /// source. It decides whether this profile is allowed to bind the canonical Device API port.
    public init(
        fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment,
        profileSource: @escaping () throws -> SpacesProfileSource = { try SpacesProfile.current().source }
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.profileSource = profileSource
    }

    public func loadOrCreate() throws -> SpacesDeviceAPISettings {
        try applyingEnvironmentOverrides(to: normalizingCanonicalPort(loadStoredOrCreate()))
    }

    /// The fixed canonical Device API port belongs to the installed profile alone. Any other profile
    /// (dev worktree, explicit database) that would otherwise bind the canonical port instead binds an
    /// ephemeral port (0), so a leftover development daemon can't steal the well-known port from the
    /// installed daemon. Normalization happens at load only — the stored file keeps its canonical default,
    /// so existing stale dev-profile configs are covered without a migration. Env overrides are applied
    /// afterward and still win, which is how the Linux systemd install (SPACES_DEVICE_API_PORT together with
    /// SPACES_DB_PATH) keeps binding the canonical port. A non-canonical stored port is respected as-is.
    private func normalizingCanonicalPort(_ settings: SpacesDeviceAPISettings) throws -> SpacesDeviceAPISettings {
        guard settings.port == SpacesDeviceAPIDefaults.port, try profileSource() != .installedFallback else { return settings }
        var normalized = settings
        normalized.port = 0
        return normalized
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

    public static func pairingLinkHost(boundHost: String) -> String { pairingLinkHost(boundHost: boundHost, networkAddresses: ipv4Addresses()) }

    public static func pairingLinkHost(boundHost: String, networkAddresses: [String]) -> String {
        let host = boundHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !SpacesDeviceAPIDefaults.isWildcardHost(host) { return host }
        return networkAddresses.first ?? SpacesDeviceAPIDefaults.loopbackHost
    }

    static func sortedIPv4Addresses(from interfaceAddresses: [IPv4InterfaceAddress]) -> [String] {
        var seenAddresses = Set<String>()
        return interfaceAddresses.filter { $0.flags & upFlag != 0 && $0.flags & loopbackFlag == 0 && ipv4Octets($0.address) != nil }.sorted {
            lhs, rhs in
            let lhsRank = pairingPreferenceRank(lhs)
            let rhsRank = pairingPreferenceRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.discoveryIndex < rhs.discoveryIndex
        }.compactMap { interfaceAddress in
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
