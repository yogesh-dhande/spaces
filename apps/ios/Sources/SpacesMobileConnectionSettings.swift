import Foundation
import spacesdevicecore

struct SpacesMobileConnectionSettings: Codable, Equatable, Sendable {
    static let legacyDefaultPort = 47_071
    static let defaultPort = SpacesDeviceAPIEndpointDefaults.port

    /// Ordered candidate daemon addresses, most-preferred first (typically the Mac's LAN IPv4
    /// followed by its Tailscale `100.x` address). A record written by a pre-multi-address build
    /// stored a single `host` string; decoding that legacy shape wraps it as a one-element list so
    /// old local stores keep working without a migration step.
    var hosts: [String] = [defaultHost]
    var port: Int = defaultPort
    var authToken: String = ""
    var certificateFingerprint: String = ""
    var installationID: String = UUID().uuidString.uppercased()

    var trimmedHosts: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for host in hosts {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
    /// The most-preferred candidate, for display and for call sites that legitimately need a single
    /// address (e.g. constructing a `BrowserProxyRouteTarget`). Connection logic that should try
    /// every candidate must use `trimmedHosts` directly instead.
    var primaryHost: String { trimmedHosts.first ?? "" }
    var trimmedAuthToken: String? {
        let trimmed = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    var trimmedCertificateFingerprint: String? {
        let trimmed = certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isValid: Bool { !trimmedHosts.isEmpty && (1...65535).contains(port) }
    var isPaired: Bool { trimmedAuthToken != nil && trimmedCertificateFingerprint != nil }

    static var defaultHost: String { SpacesDeviceAPIEndpointDefaults.loopbackHost }

    private enum CodingKeys: String, CodingKey {
        case hosts
        /// Pre-multi-address key. Read-only: `encode(to:)` never writes it.
        case legacyHost = "host"
        case port
        case authToken
        case certificateFingerprint
        case installationID
    }

    init() {}

    func migratedToCurrentDefaults() -> Self {
        var migrated = self
        if migrated.port == Self.legacyDefaultPort { migrated.port = Self.defaultPort }
        if migrated.trimmedCertificateFingerprint == nil { migrated.authToken = "" }
        return migrated
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedHosts = try container.decodeIfPresent([String].self, forKey: .hosts) {
            hosts = decodedHosts
        } else if let legacyHost = try container.decodeIfPresent(String.self, forKey: .legacyHost) {
            hosts = [legacyHost]
        } else {
            hosts = [Self.defaultHost]
        }
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken) ?? ""
        certificateFingerprint = try container.decodeIfPresent(String.self, forKey: .certificateFingerprint) ?? ""
        installationID = try container.decodeIfPresent(String.self, forKey: .installationID) ?? UUID().uuidString.uppercased()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(port, forKey: .port)
        try container.encode(authToken, forKey: .authToken)
        try container.encode(certificateFingerprint, forKey: .certificateFingerprint)
        try container.encode(installationID, forKey: .installationID)
    }
}
