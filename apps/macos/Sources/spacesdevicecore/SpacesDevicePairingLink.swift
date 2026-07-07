import Foundation

/// One-time pairing link (`spaces://pair?...`). Version 3: trust is delivered as the daemon's
/// pinned TLS certificate fingerprint (`fp`); there is no transport key — the pairing code and
/// nonce authorize a single token issuance over the pinned channel. The link also advertises the
/// daemon's wire-protocol version (`pv`) and app version (`av`) so the redeeming client can refuse
/// an incompatible pairing before it burns the one-time window.
public struct SpacesDevicePairingLink: Codable, Sendable, Equatable {
    public static let scheme = "spaces"
    public static let host = "pair"
    public static let version = "3"

    public let host: String
    public let port: Int
    public let nonce: String
    public let code: String
    public let certificateFingerprint: String
    public let name: String
    /// The daemon's `SpacesWireProtocol.version`, used for the pairing-time compatibility gate.
    public let protocolVersion: Int
    /// The daemon's app version (`AppVersion.short`), surfaced in incompatible-version messaging.
    public let appVersion: String

    public init(
        host: String, port: Int, nonce: String, code: String, certificateFingerprint: String, name: String, protocolVersion: Int, appVersion: String
    ) {
        self.host = host
        self.port = port
        self.nonce = nonce
        self.code = code
        self.certificateFingerprint = certificateFingerprint
        self.name = name
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.version), URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "nonce", value: nonce), URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "fp", value: certificateFingerprint), URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "pv", value: String(protocolVersion)), URLQueryItem(name: "av", value: appVersion),
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
        guard let certificateFingerprint = trimmed(values["fp"]) else { throw SpacesDevicePairingLinkError.missingField("fp") }
        guard let protocolVersionValue = trimmed(values["pv"]), let protocolVersion = Int(protocolVersionValue) else {
            throw SpacesDevicePairingLinkError.missingField("pv")
        }
        guard let appVersion = trimmed(values["av"]) else { throw SpacesDevicePairingLinkError.missingField("av") }
        let name = trimmed(values["name"]) ?? "Spaces"
        return Self(
            host: host, port: port, nonce: nonce, code: code, certificateFingerprint: certificateFingerprint, name: name,
            protocolVersion: protocolVersion, appVersion: appVersion)
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
        case .unsupportedVersion: "The pairing link version is not supported. Update Spaces on both devices and pair again."
        case .missingField(let name): "The pairing link is missing \(name)."
        }
    }
}
