import Darwin
import Foundation
import Security
import spacesmobilecore
import spacesterminalcore

public enum SpacesMobileBridgeDefaults {
    public static let host = SpacesMobileBridgeEndpointDefaults.host
    public static let loopbackHost = SpacesMobileBridgeEndpointDefaults.loopbackHost
    public static let port = SpacesMobileBridgeEndpointDefaults.port
    public static let bonjourServiceType = SpacesMobileBridgeEndpointDefaults.bonjourServiceType
    public static let bonjourBrowserServiceType = SpacesMobileBridgeEndpointDefaults.bonjourBrowserServiceType

    public static let disabledEnvironmentVariable = "SPACES_MOBILE_BRIDGE_DISABLED"
    public static let hostEnvironmentVariable = "SPACES_MOBILE_BRIDGE_HOST"
    public static let portEnvironmentVariable = "SPACES_MOBILE_BRIDGE_PORT"
    public static let transportKeyEnvironmentVariable = "SPACES_MOBILE_TRANSPORT_KEY"

    public static func isWildcardHost(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedHost.isEmpty || trimmedHost == "0.0.0.0" || trimmedHost == "::"
    }
}

public struct SpacesMobileBridgeSettings: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var transportKey: String

    public init(
        host: String = SpacesMobileBridgeDefaults.host, port: Int = SpacesMobileBridgeDefaults.port,
        transportKey: String = SpacesMobileBridgeSettings.generateTransportKey()
    ) {
        self.host = host
        self.port = port
        self.transportKey = transportKey
    }

    public static func generateTransportKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess { return SpacesMobileBridgeTransport.encodeTransportKey(Data(bytes)) }
        let fallbackBytes = Array((UUID().uuidString + UUID().uuidString).utf8.prefix(32))
        return SpacesMobileBridgeTransport.encodeTransportKey(Data(fallbackBytes))
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case pairingCode
        case transportKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? SpacesMobileBridgeDefaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? SpacesMobileBridgeDefaults.port
        transportKey = try container.decodeIfPresent(String.self, forKey: .transportKey) ?? Self.generateTransportKey()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(transportKey, forKey: .transportKey)
    }
}

public struct SpacesMobileBridgeStatus: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let bonjourServiceName: String
    public let bonjourServiceType: String
    public let networkAddresses: [String]

    public init(host: String, port: Int, bonjourServiceName: String, bonjourServiceType: String, networkAddresses: [String]) {
        self.host = host
        self.port = port
        self.bonjourServiceName = bonjourServiceName
        self.bonjourServiceType = bonjourServiceType
        self.networkAddresses = networkAddresses
    }
}

public final class SpacesMobileBridgeSettingsStore {
    public static let stableFallbackPortBase = 47_848
    public static let stableFallbackPortCount = 512

    private let fileManager: FileManager
    private let environment: [String: String]

    public init(fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileManager = fileManager
        self.environment = environment
    }

    public func loadOrCreate() throws -> SpacesMobileBridgeSettings { try applyingEnvironmentOverrides(to: loadStoredOrCreate()) }

    @discardableResult public func updatePort(_ port: Int) throws -> SpacesMobileBridgeSettings {
        guard (1...65_535).contains(port) else {
            throw NSError(
                domain: "SpacesMobileBridgeSettingsStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mobile bridge port must be between 1 and 65535."])
        }
        var settings = try loadStoredOrCreate()
        settings.port = port
        try save(settings)
        return applyingEnvironmentOverrides(to: settings)
    }

    public func stableFallbackPorts(limit: Int = 32) throws -> [Int] {
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager).path
        let offset = Int(Self.stableHash(root) % UInt64(Self.stableFallbackPortCount))
        let count = max(1, min(limit, Self.stableFallbackPortCount))
        return (0..<count).map { index in Self.stableFallbackPortBase + ((offset + index) % Self.stableFallbackPortCount) }
    }

    private func loadStoredOrCreate() throws -> SpacesMobileBridgeSettings {
        let path = try settingsPath()
        let storedSettings: SpacesMobileBridgeSettings
        if fileManager.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            storedSettings = try JSONDecoder().decode(SpacesMobileBridgeSettings.self, from: data)
            if try !storedSettingsFileHasTransportKey(data: data) { try save(storedSettings) }
        } else {
            storedSettings = SpacesMobileBridgeSettings()
            try save(storedSettings)
        }
        return storedSettings
    }

    public func status() throws -> SpacesMobileBridgeStatus {
        let settings = try loadOrCreate()
        return SpacesMobileBridgeStatus(
            host: settings.host, port: settings.port, bonjourServiceName: try Self.bonjourServiceName(),
            bonjourServiceType: SpacesMobileBridgeDefaults.bonjourServiceType, networkAddresses: SpacesMobileBridgeNetworkInterfaces.ipv4Addresses())
    }

    @discardableResult public func rotateTransportKey() throws -> SpacesMobileBridgeSettings {
        var settings = try loadStoredOrCreate()
        settings.transportKey = SpacesMobileBridgeSettings.generateTransportKey()
        try save(settings)
        return applyingEnvironmentOverrides(to: settings)
    }

    public static func bonjourServiceName() throws -> String {
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let profile = try SpacesProfile.current()
        if let branchSlug = profile.branchSlug, let worktreeHash = profile.worktreeHash { return "Spaces \(hostName) \(branchSlug)-\(worktreeHash)" }
        return "Spaces \(hostName)"
    }

    private func save(_ settings: SpacesMobileBridgeSettings) throws {
        let path = try settingsPath()
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: [.atomic])
    }

    private func storedSettingsFileHasTransportKey(data: Data) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let value = object["transportKey"] as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func settingsPath() throws -> String {
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager)
        return root.appendingPathComponent("mobile-bridge.json", isDirectory: false).path
    }

    private func applyingEnvironmentOverrides(to settings: SpacesMobileBridgeSettings) -> SpacesMobileBridgeSettings {
        var resolved = settings
        if let host = trimmed(environment[SpacesMobileBridgeDefaults.hostEnvironmentVariable]) { resolved.host = host }
        if let port = trimmed(environment[SpacesMobileBridgeDefaults.portEnvironmentVariable]).flatMap(Int.init), (1...65_535).contains(port) {
            resolved.port = port
        }
        if let transportKey = trimmed(environment[SpacesMobileBridgeDefaults.transportKeyEnvironmentVariable]) {
            resolved.transportKey = transportKey
        }
        return resolved
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

public enum SpacesMobileBridgeNetworkInterfaces {
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
        if !SpacesMobileBridgeDefaults.isWildcardHost(host) { return host }
        return networkAddresses.first ?? SpacesMobileBridgeDefaults.loopbackHost
    }

    static func sortedIPv4Addresses(from interfaceAddresses: [IPv4InterfaceAddress]) -> [String] {
        var seenAddresses = Set<String>()
        return interfaceAddresses.filter { $0.flags & IFF_UP != 0 && $0.flags & IFF_LOOPBACK == 0 && ipv4Octets($0.address) != nil }.sorted {
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
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let interfaceAddress = current.pointee.ifa_addr else { continue }
            guard interfaceAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interfaceAddress, socklen_t(interfaceAddress.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
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
        if interfaceAddress.flags & IFF_RUNNING == 0 { rank += 1_000 }
        if interfaceAddress.flags & IFF_POINTOPOINT != 0 { rank += 500 }
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
}
