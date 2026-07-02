import XCTest

@testable import workspacecore

private final class LockedErrorMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ error: any Error) {
        lock.lock()
        messages.append(String(describing: error))
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return messages.isEmpty
    }
}

final class CaddyConfigBuilderTests: XCTestCase {
    func testMakeJSONProducesServerRoutesAndAdminSocket() throws {
        let routes = [
            CaddyRoute(host: "web.ws.localhost", upstream: "127.0.0.1:21001"), CaddyRoute(host: "backend.ws.localhost", upstream: "127.0.0.1:21002"),
        ]
        let data = CaddyConfigBuilder.makeJSON(routes: routes, listenPort: 8088, adminSocketPath: "/tmp/caddy-admin.sock")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let admin = try XCTUnwrap(root["admin"] as? [String: Any])
        XCTAssertEqual(admin["listen"] as? String, "unix//\("/tmp/caddy-admin.sock")")

        let servers = ((root["apps"] as? [String: Any])?["http"] as? [String: Any])?["servers"] as? [String: Any]
        let spaces = try XCTUnwrap(servers?["spaces"] as? [String: Any])
        let automaticHTTPS = try XCTUnwrap(spaces["automatic_https"] as? [String: Any])
        XCTAssertEqual(automaticHTTPS["disable"] as? Bool, true)
        XCTAssertEqual(spaces["listen"] as? [String], ["127.0.0.1:8088", "[::1]:8088"])

        let routeObjects = try XCTUnwrap(spaces["routes"] as? [[String: Any]])
        XCTAssertEqual(routeObjects.count, 2)
        let firstHosts = (routeObjects[0]["match"] as? [[String: Any]])?.first?["host"] as? [String]
        XCTAssertEqual(firstHosts, ["web.ws.localhost"])
        let firstHandler = (routeObjects[0]["handle"] as? [[String: Any]])?.first
        XCTAssertEqual(firstHandler?["handler"] as? String, "reverse_proxy")
        let dial = (firstHandler?["upstreams"] as? [[String: Any]])?.first?["dial"] as? String
        XCTAssertEqual(dial, "127.0.0.1:21001")
    }

    func testMakeJSONWithNoRoutesStillProducesServer() throws {
        let data = CaddyConfigBuilder.makeJSON(routes: [], listenPort: 9000, adminSocketPath: "/tmp/a.sock")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = ((root["apps"] as? [String: Any])?["http"] as? [String: Any])?["servers"] as? [String: Any]
        let spaces = try XCTUnwrap(servers?["spaces"] as? [String: Any])
        let automaticHTTPS = try XCTUnwrap(spaces["automatic_https"] as? [String: Any])
        XCTAssertEqual(automaticHTTPS["disable"] as? Bool, true)
        XCTAssertEqual(spaces["listen"] as? [String], ["127.0.0.1:9000", "[::1]:9000"])
        XCTAssertEqual((spaces["routes"] as? [[String: Any]])?.count, 0)
    }

    func testRouteRegistryUpsertsEntriesAndLoadsRoutes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-registry-\(UUID().uuidString)", isDirectory: true)
        let path = root.appendingPathComponent("routes.json").path

        try CaddyRouteRegistry.upsert(
            path: path,
            entry: CaddyRouteRegistryEntry(key: "remote:workspace:web", route: CaddyRoute(host: "web.remote.localhost", upstream: "127.0.0.1:31001")))
        try CaddyRouteRegistry.upsert(
            path: path,
            entry: CaddyRouteRegistryEntry(key: "remote:workspace:web", route: CaddyRoute(host: "web.remote.localhost", upstream: "127.0.0.1:31002")))

        XCTAssertEqual(try CaddyRouteRegistry.routes(path: path), [CaddyRoute(host: "web.remote.localhost", upstream: "127.0.0.1:31002")])
    }

    func testRouteRegistryUpsertEvictsStaleEntryForSameHostUnderDifferentKey() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-registry-\(UUID().uuidString)", isDirectory: true)
        let path = root.appendingPathComponent("routes.json").path

        // Same service host, but the registry key embeds the remote port, so a re-forward after a port
        // change arrives under a new key. The stale entry must be evicted so the registry keeps a
        // single upstream for the service host.
        try CaddyRouteRegistry.upsert(
            path: path,
            entry: CaddyRouteRegistryEntry(
                key: "remote-browser:device:workspace:web:31001", route: CaddyRoute(host: "web.remote.localhost", upstream: "127.0.0.1:41001")))
        try CaddyRouteRegistry.upsert(
            path: path,
            entry: CaddyRouteRegistryEntry(
                key: "remote-browser:device:workspace:web:31002", route: CaddyRoute(host: "web.remote.localhost", upstream: "127.0.0.1:41002")))

        XCTAssertEqual(try CaddyRouteRegistry.routes(path: path), [CaddyRoute(host: "web.remote.localhost", upstream: "127.0.0.1:41002")])
    }

    func testRouteRegistryRemovesEntriesByKey() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-registry-\(UUID().uuidString)", isDirectory: true)
        let path = root.appendingPathComponent("routes.json").path

        try CaddyRouteRegistry.upsert(
            path: path,
            entry: CaddyRouteRegistryEntry(key: "remote:web", route: CaddyRoute(host: "web.remote.localhost", upstream: "127.0.0.1:31001")))
        try CaddyRouteRegistry.upsert(
            path: path,
            entry: CaddyRouteRegistryEntry(key: "remote:api", route: CaddyRoute(host: "api.remote.localhost", upstream: "127.0.0.1:31002")))

        try CaddyRouteRegistry.remove(path: path, keys: ["remote:web"])

        XCTAssertEqual(try CaddyRouteRegistry.routes(path: path), [CaddyRoute(host: "api.remote.localhost", upstream: "127.0.0.1:31002")])
    }

    func testRouteRegistryRemoveWherePrunesPersistedRemoteBrowserEntriesByDevice() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-registry-\(UUID().uuidString)", isDirectory: true)
        let path = root.appendingPathComponent("routes.json").path

        let entries = [
            CaddyRouteRegistryEntry(
                key: "remote-browser:device-a:workspace-stopped:web:31001",
                route: CaddyRoute(host: "web.stopped.localhost", upstream: "127.0.0.1:41001")),
            CaddyRouteRegistryEntry(
                key: "remote-browser:device-a:workspace-running:web:31002",
                route: CaddyRoute(host: "web.running.localhost", upstream: "127.0.0.1:41002")),
            CaddyRouteRegistryEntry(
                key: "remote-browser:device-b:workspace-stopped:web:31003",
                route: CaddyRoute(host: "web.other-device.localhost", upstream: "127.0.0.1:41003")),
            CaddyRouteRegistryEntry(key: "local:web", route: CaddyRoute(host: "web.local.localhost", upstream: "127.0.0.1:21001")),
        ]
        for entry in entries { try CaddyRouteRegistry.upsert(path: path, entry: entry) }

        let didRemove = try CaddyRouteRegistry.removeWhere(path: path) { entry in
            entry.key.hasPrefix("remote-browser:device-a:") && !entry.key.hasPrefix("remote-browser:device-a:workspace-running:")
        }

        XCTAssertTrue(didRemove)
        XCTAssertEqual(
            try CaddyRouteRegistry.loadEntries(path: path).map(\.key).sorted(),
            ["local:web", "remote-browser:device-a:workspace-running:web:31002", "remote-browser:device-b:workspace-stopped:web:31003"])
    }

    func testRouteRegistryConcurrentUpsertsPreserveEntries() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-registry-\(UUID().uuidString)", isDirectory: true)
        let path = root.appendingPathComponent("routes.json").path
        let errors = LockedErrorMessages()

        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                try CaddyRouteRegistry.upsert(
                    path: path,
                    entry: CaddyRouteRegistryEntry(
                        key: "remote:workspace:service-\(index)",
                        route: CaddyRoute(host: "service-\(index).remote.localhost", upstream: "127.0.0.1:\(31000 + index)")))
            } catch { errors.append(error) }
        }

        XCTAssertTrue(errors.isEmpty)
        let routes = try CaddyRouteRegistry.routes(path: path)
        XCTAssertEqual(Set(routes.map(\.host)).count, 20)
        XCTAssertEqual(Set(routes.map(\.upstream)).count, 20)
    }

    func testRouteRegistryMergedRoutesLetsRegistryOverrideLocalPlaceholder() {
        let local = [
            CaddyRoute(host: "web.workspace.localhost", upstream: "127.0.0.1:21001"),
            CaddyRoute(host: "worker.workspace.localhost", upstream: "127.0.0.1:21003"),
        ]
        let registry = [
            CaddyRoute(host: "web.workspace.localhost", upstream: "127.0.0.1:31001"),
            CaddyRoute(host: "api.remote.localhost", upstream: "127.0.0.1:31002"),
        ]

        XCTAssertEqual(
            CaddyRouteRegistry.mergedRoutes(localRoutes: local, registryRoutes: registry),
            [
                CaddyRoute(host: "worker.workspace.localhost", upstream: "127.0.0.1:21003"),
                CaddyRoute(host: "web.workspace.localhost", upstream: "127.0.0.1:31001"),
                CaddyRoute(host: "api.remote.localhost", upstream: "127.0.0.1:31002"),
            ])
    }
}
