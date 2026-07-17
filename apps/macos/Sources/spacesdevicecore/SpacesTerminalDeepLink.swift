import Foundation

/// A clickable reference to a Spaces terminal session (`spaces://terminal/<session-id>`). Orchestration
/// surfaces render these so a human can jump straight to a coding agent's pane. An optional `deviceID`
/// (`?device=<id>`) qualifies the session as living on a specific paired device; omitting it means the
/// local device.
public struct SpacesTerminalDeepLink: Codable, Sendable, Equatable {
    public static let scheme = "spaces"
    public static let host = "terminal"

    public let sessionID: String
    public let deviceID: String?

    public init(sessionID: String, deviceID: String? = nil) {
        self.sessionID = sessionID
        self.deviceID = deviceID
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/\(sessionID)"
        if let deviceID, !deviceID.isEmpty { components.queryItems = [URLQueryItem(name: "device", value: deviceID)] }
        return components.url ?? URL(string: "\(Self.scheme)://\(Self.host)/\(sessionID)")!
    }

    public var absoluteString: String { url.absoluteString }

    public static func parse(_ value: String) -> SpacesTerminalDeepLink? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return parse(url)
    }

    /// Accepts exactly `spaces://terminal/<session-id>` with a single path component. Anything else
    /// (wrong scheme/host, missing or multi-segment path) is not a terminal deep link.
    public static func parse(_ url: URL) -> SpacesTerminalDeepLink? {
        guard url.scheme == Self.scheme, url.host == Self.host else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 1, let sessionID = trimmed(segments.first) else { return nil }
        let deviceID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "device" })?.value
        return SpacesTerminalDeepLink(sessionID: sessionID, deviceID: trimmed(deviceID))
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
