import Foundation

/// A single Caddy reverse-proxy route: a service hostname mapped to its local upstream.
public struct CaddyRoute: Codable, Equatable, Sendable {
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
            "apps": [
                "http": [
                    "servers": [
                        "spaces": [
                            "automatic_https": ["disable": true], "listen": ["127.0.0.1:\(listenPort)", "[::1]:\(listenPort)"],
                            "routes": routeObjects,
                        ]
                    ]
                ]
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
}

public struct CaddyRouteRegistryEntry: Codable, Equatable, Sendable {
    public let key: String
    public let route: CaddyRoute

    public init(key: String, route: CaddyRoute) {
        self.key = key
        self.route = route
    }
}

/// Stores client-owned Caddy routes, such as SSH-forwarded remote workspace services, in the
/// profile runtime directory so the macOS daemon can merge them with daemon-owned local routes.
public enum CaddyRouteRegistry {
    private static let mutationLock = NSLock()

    public static func loadEntries(path: String) throws -> [CaddyRouteRegistryEntry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([CaddyRouteRegistryEntry].self, from: data)
    }

    public static func upsert(path: String, entry: CaddyRouteRegistryEntry) throws { try replace(path: path, removingKeys: [], upserting: [entry]) }

    // Entries are compared and stored in canonical key order because callers (e.g.
    // BrowserSSHForwardManager.publishCaddyRoutes) each publish only their own workspace's subset of
    // the registry; an order-sensitive guard made 2+ forwarded workspaces rewrite and reload Caddy
    // every second, since each publish moved its subset to the end of the array (#613).
    private static func canonicalized(_ entries: [CaddyRouteRegistryEntry]) -> [CaddyRouteRegistryEntry] { entries.sorted { $0.key < $1.key } }

    /// Returns true when the stored entries changed and the file was rewritten; an identical
    /// result leaves the file untouched so callers can skip notifying the daemon.
    @discardableResult public static func replace(path: String, removingKeys: Set<String>, upserting newEntries: [CaddyRouteRegistryEntry]) throws
        -> Bool
    {
        guard !removingKeys.isEmpty || !newEntries.isEmpty else { return false }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        // Evict any prior entry for the same registry key *and* any prior entry that routes the same
        // host. A route host (`<service>.<slug>.localhost`) maps to exactly one upstream, but the key
        // embeds the daemon-local remote port, so a re-forwarded service whose port changed would
        // otherwise leave a stale entry under the old key. Dropping it keeps one registry entry per
        // host with the newest upstream winning.
        let loaded = try loadEntries(path: path)
        var entries = loaded.filter { !removingKeys.contains($0.key) }
        for entry in newEntries {
            entries.removeAll { $0.key == entry.key || $0.route.host == entry.route.host }
            entries.append(entry)
        }
        let canonicalEntries = canonicalized(entries)
        guard canonicalEntries != canonicalized(loaded) else { return false }
        try write(canonicalEntries, path: path)
        return true
    }

    public static func remove(path: String, keys: Set<String>) throws { try replace(path: path, removingKeys: keys, upserting: []) }

    @discardableResult public static func removeWhere(path: String, shouldRemove: (CaddyRouteRegistryEntry) -> Bool) throws -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let entries = try loadEntries(path: path)
        let kept = entries.filter { !shouldRemove($0) }
        guard kept.count != entries.count else { return false }
        try write(canonicalized(kept), path: path)
        return true
    }

    public static func routes(path: String) throws -> [CaddyRoute] { try loadEntries(path: path).map(\.route) }

    public static func mergedRoutes(localRoutes: [CaddyRoute], registryRoutes: [CaddyRoute]) -> [CaddyRoute] {
        var routes: [CaddyRoute] = []
        var seenHosts = Set<String>()
        let registryHosts = Set(registryRoutes.map(\.host))
        for route in localRoutes where !registryHosts.contains(route.host) && seenHosts.insert(route.host).inserted { routes.append(route) }
        for route in registryRoutes where seenHosts.insert(route.host).inserted { routes.append(route) }
        return routes
    }

    private static func write(_ entries: [CaddyRouteRegistryEntry], path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url, options: .atomic)
    }
}
