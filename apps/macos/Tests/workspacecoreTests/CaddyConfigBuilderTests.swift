import XCTest

@testable import workspacecore

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
        XCTAssertEqual(spaces["listen"] as? [String], ["127.0.0.1:9000", "[::1]:9000"])
        XCTAssertEqual((spaces["routes"] as? [[String: Any]])?.count, 0)
    }
}
