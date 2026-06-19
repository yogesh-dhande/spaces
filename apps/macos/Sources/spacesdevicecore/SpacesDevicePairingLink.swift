import Foundation

public struct SpacesDevicePairingLink: Codable, Sendable, Equatable {
    public static let scheme = "spaces"
    public static let host = "pair"
    public static let version = "1"

    public let host: String
    public let port: Int
    public let nonce: String
    public let code: String
    public let transportKey: String
    public let certificateFingerprint: String
    public let name: String

    public init(host: String, port: Int, nonce: String, code: String, transportKey: String, certificateFingerprint: String, name: String) {
        self.host = host
        self.port = port
        self.nonce = nonce
        self.code = code
        self.transportKey = transportKey
        self.certificateFingerprint = certificateFingerprint
        self.name = name
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.version), URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "nonce", value: nonce), URLQueryItem(name: "code", value: code), URLQueryItem(name: "psk", value: transportKey),
            URLQueryItem(name: "fp", value: certificateFingerprint), URLQueryItem(name: "name", value: name),
        ]
        return components.url ?? URL(string: "\(Self.scheme)://\(Self.host)")!
    }

    public var absoluteString: String { url.absoluteString }

    public static func parse(_ value: String) throws -> Self {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SpacesDevicePairingLinkError.invalidLink }
        return try parse(url)
    }

    public static func parse(_ url: URL) throws -> Self {
        guard url.scheme == Self.scheme, url.host == Self.host else { throw SpacesDevicePairingLinkError.invalidLink }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw SpacesDevicePairingLinkError.invalidLink }
        var values: [String: String] = [:]
        var seenNames = Set<String>()
        for item in components.queryItems ?? [] {
            guard seenNames.insert(item.name).inserted else { throw SpacesDevicePairingLinkError.invalidLink }
            guard let value = item.value else { continue }
            values[item.name] = value
        }
        guard values["v"] == Self.version else { throw SpacesDevicePairingLinkError.unsupportedVersion }
        guard let host = trimmed(values["host"]) else { throw SpacesDevicePairingLinkError.missingField("host") }
        guard let portValue = trimmed(values["port"]), let port = Int(portValue), (1...65_535).contains(port) else {
            throw SpacesDevicePairingLinkError.missingField("port")
        }
        guard let nonce = trimmed(values["nonce"]) else { throw SpacesDevicePairingLinkError.missingField("nonce") }
        guard let code = trimmed(values["code"]) else { throw SpacesDevicePairingLinkError.missingField("code") }
        guard let transportKey = trimmed(values["psk"]) else { throw SpacesDevicePairingLinkError.missingField("psk") }
        guard let certificateFingerprint = trimmed(values["fp"]) else { throw SpacesDevicePairingLinkError.missingField("fp") }
        let name = trimmed(values["name"]) ?? "Spaces"
        return Self(
            host: host, port: port, nonce: nonce, code: code, transportKey: transportKey, certificateFingerprint: certificateFingerprint, name: name)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public enum SpacesDevicePairingLinkError: LocalizedError, Equatable {
    case invalidLink
    case unsupportedVersion
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLink: "The pairing link is invalid."
        case .unsupportedVersion: "The pairing link version is not supported."
        case .missingField(let name): "The pairing link is missing \(name)."
        }
    }
}
