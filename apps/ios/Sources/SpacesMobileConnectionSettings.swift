import Foundation
import Darwin

struct SpacesMobileConnectionSettings: Codable, Equatable, Sendable {
    static let defaultPort = 47071

    var host: String = defaultHost
    var port: Int = defaultPort
    var authToken: String = ""
    var installationID: String = UUID().uuidString.uppercased()

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAuthToken: String? {
        let trimmed = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isValid: Bool { !trimmedHost.isEmpty && (1...65535).contains(port) }
    var isPaired: Bool { trimmedAuthToken != nil }

    static var defaultHost: String {
        #if targetEnvironment(simulator)
        SimulatorHostAddressResolver.primaryIPv4Address() ?? "127.0.0.1"
        #else
        "127.0.0.1"
        #endif
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case authToken
        case installationID
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? Self.defaultHost
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken) ?? ""
        installationID = try container.decodeIfPresent(String.self, forKey: .installationID) ?? UUID().uuidString.uppercased()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(authToken, forKey: .authToken)
        try container.encode(installationID, forKey: .installationID)
    }
}

private enum SimulatorHostAddressResolver {
    static func primaryIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let name = String(cString: interface.pointee.ifa_name)
            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, !isLoopback, name.hasPrefix("en"), let address = interface.pointee.ifa_addr else { continue }
            guard address.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let hostBytes = hostBuffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
            let host = String(decoding: hostBytes, as: UTF8.self)
            if !host.isEmpty { return host }
        }

        return nil
    }
}
