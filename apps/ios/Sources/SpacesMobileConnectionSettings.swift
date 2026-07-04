import Foundation
import spacesdevicecore

struct SpacesMobileConnectionSettings: Codable, Equatable, Sendable {
    static let legacyDefaultPort = 47_071
    static let defaultPort = SpacesDeviceAPIEndpointDefaults.port

    var host: String = defaultHost
    var port: Int = defaultPort
    var authToken: String = ""
    var certificateFingerprint: String = ""
    var installationID: String = UUID().uuidString.uppercased()

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAuthToken: String? {
        let trimmed = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    var trimmedCertificateFingerprint: String? {
        let trimmed = certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isValid: Bool { !trimmedHost.isEmpty && (1...65535).contains(port) }
    var isPaired: Bool { trimmedAuthToken != nil && trimmedCertificateFingerprint != nil }

    static var defaultHost: String {
        SpacesDeviceAPIEndpointDefaults.loopbackHost
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case authToken
        case certificateFingerprint
        case installationID
    }

    init() {}

    func migratedToCurrentDefaults() -> Self {
        var migrated = self
        if migrated.port == Self.legacyDefaultPort {
            migrated.port = Self.defaultPort
        }
        if migrated.trimmedCertificateFingerprint == nil {
            migrated.authToken = ""
        }
        return migrated
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? Self.defaultHost
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken) ?? ""
        certificateFingerprint = try container.decodeIfPresent(String.self, forKey: .certificateFingerprint) ?? ""
        installationID = try container.decodeIfPresent(String.self, forKey: .installationID) ?? UUID().uuidString.uppercased()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(authToken, forKey: .authToken)
        try container.encode(certificateFingerprint, forKey: .certificateFingerprint)
        try container.encode(installationID, forKey: .installationID)
    }
}
