import Foundation

/// A single Caddy reverse-proxy route: a service hostname mapped to its local upstream.
public struct CaddyRoute: Equatable, Sendable {
    public let host: String
    public let upstream: String

    public init(host: String, upstream: String) {
        self.host = host
        self.upstream = upstream
    }
}

/// Builds the Caddy admin-API JSON config for the Spaces router: one HTTP server on the shared
/// router port whose host-matched routes reverse-proxy each service hostname to its local upstream.
/// Pure and deterministic so it can be unit-tested without a running Caddy binary.
public enum CaddyConfigBuilder {
    public static func makeJSON(routes: [CaddyRoute], listenPort: Int, adminSocketPath: String) -> Data {
        let routeObjects: [[String: Any]] = routes.map { route in
            ["match": [["host": [route.host]]], "handle": [["handler": "reverse_proxy", "upstreams": [["dial": route.upstream]]]]]
        }
        let config: [String: Any] = [
            "admin": ["listen": "unix//\(adminSocketPath)"],
            "apps": ["http": ["servers": ["spaces": ["listen": ["127.0.0.1:\(listenPort)", "[::1]:\(listenPort)"], "routes": routeObjects]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
}
