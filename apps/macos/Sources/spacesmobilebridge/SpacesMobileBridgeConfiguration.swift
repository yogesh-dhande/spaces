import Darwin
import Foundation
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
    public static let pairingCodeEnvironmentVariable = "SPACES_MOBILE_PAIRING_CODE"
}

public struct SpacesMobileBridgeSettings: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var pairingCode: String

    public init(
        host: String = SpacesMobileBridgeDefaults.host, port: Int = SpacesMobileBridgeDefaults.port,
        pairingCode: String = SpacesMobileBridgeServer.generatePairingCode()
    ) {
        self.host = host
        self.port = port
        self.pairingCode = pairingCode
    }
}

public struct SpacesMobileBridgeStatus: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let pairingCode: String
    public let bonjourServiceName: String
    public let bonjourServiceType: String
    public let networkAddresses: [String]

    public init(host: String, port: Int, pairingCode: String, bonjourServiceName: String, bonjourServiceType: String, networkAddresses: [String]) {
        self.host = host
        self.port = port
        self.pairingCode = pairingCode
        self.bonjourServiceName = bonjourServiceName
        self.bonjourServiceType = bonjourServiceType
        self.networkAddresses = networkAddresses
    }
}

public final class SpacesMobileBridgeSettingsStore {
    private let fileManager: FileManager
    private let environment: [String: String]

    public init(fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileManager = fileManager
        self.environment = environment
    }

    public func loadOrCreate() throws -> SpacesMobileBridgeSettings {
        let path = try settingsPath()
        let storedSettings: SpacesMobileBridgeSettings
        if fileManager.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            storedSettings = try JSONDecoder().decode(SpacesMobileBridgeSettings.self, from: data)
        } else {
            storedSettings = SpacesMobileBridgeSettings()
            try save(storedSettings)
        }
        return applyingEnvironmentOverrides(to: storedSettings)
    }

    public func status() throws -> SpacesMobileBridgeStatus {
        let settings = try loadOrCreate()
        return SpacesMobileBridgeStatus(
            host: settings.host, port: settings.port, pairingCode: settings.pairingCode, bonjourServiceName: try Self.bonjourServiceName(),
            bonjourServiceType: SpacesMobileBridgeDefaults.bonjourServiceType, networkAddresses: SpacesMobileBridgeNetworkInterfaces.ipv4Addresses())
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
        if let pairingCode = trimmed(environment[SpacesMobileBridgeDefaults.pairingCodeEnvironmentVariable]) { resolved.pairingCode = pairingCode }
        return resolved
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public enum SpacesMobileBridgeNetworkInterfaces {
    public static func ipv4Addresses() -> [String] {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0, let firstAddress = interfaceAddresses else { return [] }
        defer { freeifaddrs(interfaceAddresses) }

        var addresses: [String] = []
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
            if !addresses.contains(address) { addresses.append(address) }
        }
        return addresses
    }
}
