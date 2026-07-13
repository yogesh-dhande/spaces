import Foundation
import Testing
import spacesdevicecore

@Suite struct SpacesDeviceBrowserSessionRouteTests {
    private let assignedPorts = [
        SpacesDeviceAssignedPort(name: "web", port: 8080, url: "http://web.myslug.localhost:9000"),
        SpacesDeviceAssignedPort(name: "api", port: 8081, url: "http://api.myslug.localhost:9000"),
    ]

    @Test func identityURLSessionMatches() {
        let sessions = [SpacesDeviceBrowserSession(name: "Web", url: "http://web.myslug.localhost:9000/dash")]
        let routes = SpacesDeviceBrowserSessionRoute.routes(resolvedBrowserSessions: sessions, assignedPorts: assignedPorts)
        #expect(routes.count == 1)
        #expect(routes[0].sessionName == "Web")
        #expect(routes[0].serviceName == "web")
        #expect(routes[0].identityHost == "web.myslug.localhost")
        #expect(routes[0].pathQueryFragment == "/dash")
    }

    @Test func localhostLoopbackSessionMatchesByAssignedPort() {
        let sessions = [SpacesDeviceBrowserSession(name: nil, url: "http://localhost:8080/")]
        let routes = SpacesDeviceBrowserSessionRoute.routes(resolvedBrowserSessions: sessions, assignedPorts: assignedPorts)
        #expect(routes.count == 1)
        #expect(routes[0].serviceName == "web")
        #expect(routes[0].identityHost == "web.myslug.localhost")
    }

    @Test func loopbackIPSessionMatchesByAssignedPort() {
        let sessions = [SpacesDeviceBrowserSession(name: nil, url: "http://127.0.0.1:8081")]
        let routes = SpacesDeviceBrowserSessionRoute.routes(resolvedBrowserSessions: sessions, assignedPorts: assignedPorts)
        #expect(routes.count == 1)
        #expect(routes[0].serviceName == "api")
        #expect(routes[0].pathQueryFragment == "")
    }

    @Test func bracketedIPv6LoopbackSessionMatchesByAssignedPort() {
        let sessions = [SpacesDeviceBrowserSession(name: nil, url: "http://[::1]:8081/v1")]
        let routes = SpacesDeviceBrowserSessionRoute.routes(resolvedBrowserSessions: sessions, assignedPorts: assignedPorts)
        #expect(routes.count == 1)
        #expect(routes[0].serviceName == "api")
        #expect(routes[0].identityHost == "api.myslug.localhost")
        #expect(routes[0].pathQueryFragment == "/v1")
    }

    @Test func proxyURLPreservesPathQueryAndFragment() {
        let sessions = [SpacesDeviceBrowserSession(name: "Web", url: "http://web.myslug.localhost:9000/dash?tab=1#frag")]
        let routes = SpacesDeviceBrowserSessionRoute.routes(resolvedBrowserSessions: sessions, assignedPorts: assignedPorts)
        #expect(routes.count == 1)
        #expect(routes[0].pathQueryFragment == "/dash?tab=1#frag")
        let proxied = routes[0].proxyURL(proxyPort: 4000)
        #expect(proxied?.absoluteString == "http://web.myslug.localhost:4000/dash?tab=1#frag")
    }

    @Test func nonMatchingSessionIsDropped() {
        let sessions = [SpacesDeviceBrowserSession(name: "Other", url: "http://other.host.com:1234/")]
        let routes = SpacesDeviceBrowserSessionRoute.routes(resolvedBrowserSessions: sessions, assignedPorts: assignedPorts)
        #expect(routes.isEmpty)
    }

    @Test func nilURLSessionIsDropped() {
        let sessions = [SpacesDeviceBrowserSession(name: "No URL", url: nil)]
        let routes = SpacesDeviceBrowserSessionRoute.routes(resolvedBrowserSessions: sessions, assignedPorts: assignedPorts)
        #expect(routes.isEmpty)
    }

    @Test func multipleSessionsRouteToDifferentServicesInOrder() {
        let sessions = [
            SpacesDeviceBrowserSession(name: "Web", url: "http://web.myslug.localhost:9000/"),
            SpacesDeviceBrowserSession(name: "API", url: "http://api.myslug.localhost:9000/v1"),
        ]
        let routes = SpacesDeviceBrowserSessionRoute.routes(resolvedBrowserSessions: sessions, assignedPorts: assignedPorts)
        #expect(routes.map(\.serviceName) == ["web", "api"])
        #expect(routes.map(\.sessionName) == ["Web", "API"])
    }

    @Test func portMismatchLoopbackSessionIsDropped() {
        let sessions = [SpacesDeviceBrowserSession(name: nil, url: "http://localhost:9999/")]
        let routes = SpacesDeviceBrowserSessionRoute.routes(resolvedBrowserSessions: sessions, assignedPorts: assignedPorts)
        #expect(routes.isEmpty)
    }
}
