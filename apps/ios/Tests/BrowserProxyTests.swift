#if canImport(UIKit)
    import Foundation
    import Network
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    final class BrowserProxyTests: XCTestCase {

        // MARK: - HTTP head parsing

        func testHeadParsesHostAcrossChunks() throws {
            var parser = BrowserProxyHTTPHeadParser()
            try parser.append(Data("GET /index.html HTTP/1.1\r\nHo".utf8))
            XCTAssertFalse(parser.isComplete)
            XCTAssertNil(parser.host)
            try parser.append(Data("st: Web.Feature.localhost\r\nAccept: */*\r\n\r\n".utf8))
            XCTAssertTrue(parser.isComplete)
            XCTAssertEqual(parser.host, "web.feature.localhost")
        }

        func testHeadStripsPortAndLowercasesHost() throws {
            var parser = BrowserProxyHTTPHeadParser()
            try parser.append(Data("GET / HTTP/1.1\r\nHOST: API.Slug.LOCALHOST:47898\r\n\r\n".utf8))
            XCTAssertEqual(parser.host, "api.slug.localhost")
        }

        func testHeadHostWithoutPort() throws {
            var parser = BrowserProxyHTTPHeadParser()
            try parser.append(Data("GET / HTTP/1.1\r\nhost: web.feature.localhost\r\n\r\n".utf8))
            XCTAssertEqual(parser.host, "web.feature.localhost")
        }

        func testHeadPreservesConsumedBytesIncludingBody() throws {
            var parser = BrowserProxyHTTPHeadParser()
            let head = "POST /submit HTTP/1.1\r\nHost: web.feature.localhost\r\nContent-Length: 5\r\n\r\n"
            let body = "hello"
            try parser.append(Data(head.utf8))
            XCTAssertTrue(parser.isComplete)
            try parser.append(Data(body.utf8))
            XCTAssertEqual(parser.consumedBytes, Data((head + body).utf8))
        }

        func testHeadRejectsOversizeHeaderBlock() {
            var parser = BrowserProxyHTTPHeadParser()
            let filler = String(repeating: "a", count: BrowserProxyHTTPHeadParser.maxHeadBytes + 16)
            let bytes = Data("GET / HTTP/1.1\r\nX-Big: \(filler)".utf8)
            XCTAssertThrowsError(try parser.append(bytes)) { error in
                XCTAssertEqual(error as? BrowserProxyHTTPHeadParser.ParseError, .headTooLarge)
            }
        }

        func testHeadMissingHostReturnsNil() throws {
            var parser = BrowserProxyHTTPHeadParser()
            try parser.append(Data("GET / HTTP/1.1\r\nAccept: */*\r\n\r\n".utf8))
            XCTAssertTrue(parser.isComplete)
            XCTAssertNil(parser.host)
        }

        func testHeadReadsAndStripsProxyCookie() throws {
            var parser = BrowserProxyHTTPHeadParser()
            let request =
                "POST /submit HTTP/1.1\r\n"
                + "Host: web.feature.localhost\r\n"
                + "Cookie: app=keep; \(BrowserProxyRequest.cookieName)=secret-token; theme=dark\r\n"
                + "Content-Length: 5\r\n"
                + "\r\n"
                + "hello"

            try parser.append(Data(request.utf8))

            XCTAssertEqual(parser.cookieValue(named: BrowserProxyRequest.cookieName), "secret-token")
            let sanitized = String(
                decoding: parser.consumedBytes(droppingCookieNamed: BrowserProxyRequest.cookieName),
                as: UTF8.self)
            XCTAssertTrue(sanitized.contains("Cookie: app=keep; theme=dark"))
            XCTAssertFalse(sanitized.contains(BrowserProxyRequest.cookieName))
            XCTAssertTrue(sanitized.hasSuffix("\r\n\r\nhello"))
        }

        func testHeadForcesConnectionCloseWhenSanitizingNormalRequest() throws {
            var parser = BrowserProxyHTTPHeadParser()
            let request =
                "GET / HTTP/1.1\r\n"
                + "Host: web.feature.localhost\r\n"
                + "Connection: keep-alive\r\n"
                + "Proxy-Connection: keep-alive\r\n"
                + "Keep-Alive: timeout=60\r\n"
                + "Cookie: \(BrowserProxyRequest.cookieName)=secret-token; app=keep\r\n"
                + "\r\n"

            try parser.append(Data(request.utf8))

            XCTAssertFalse(parser.isUpgradeRequest)
            let sanitized = String(
                decoding: parser.consumedBytes(droppingCookieNamed: BrowserProxyRequest.cookieName, forcingConnectionClose: true),
                as: UTF8.self)
            XCTAssertTrue(sanitized.contains("Connection: close"))
            XCTAssertTrue(sanitized.contains("Cookie: app=keep"))
            XCTAssertFalse(sanitized.contains("Connection: keep-alive"))
            XCTAssertFalse(sanitized.contains("Proxy-Connection"))
            XCTAssertFalse(sanitized.contains("Keep-Alive"))
            XCTAssertFalse(sanitized.contains(BrowserProxyRequest.cookieName))
        }

        func testHeadPreservesUpgradeHeadersWhenSanitizingUpgradeRequest() throws {
            var parser = BrowserProxyHTTPHeadParser()
            let request =
                "GET /socket HTTP/1.1\r\n"
                + "Host: web.feature.localhost\r\n"
                + "Connection: keep-alive, Upgrade\r\n"
                + "Upgrade: websocket\r\n"
                + "Cookie: \(BrowserProxyRequest.cookieName)=secret-token; app=keep\r\n"
                + "\r\n"

            try parser.append(Data(request.utf8))

            XCTAssertTrue(parser.isUpgradeRequest)
            let sanitized = String(
                decoding: parser.consumedBytes(
                    droppingCookieNamed: BrowserProxyRequest.cookieName,
                    forcingConnectionClose: !parser.isUpgradeRequest),
                as: UTF8.self)
            XCTAssertTrue(sanitized.contains("Connection: keep-alive, Upgrade"))
            XCTAssertTrue(sanitized.contains("Upgrade: websocket"))
            XCTAssertTrue(sanitized.contains("Cookie: app=keep"))
            XCTAssertFalse(sanitized.contains("Connection: close"))
            XCTAssertFalse(sanitized.contains(BrowserProxyRequest.cookieName))
        }

        func testHeadLimitsChunkedBodyToTerminatingChunkWhenSanitizing() throws {
            var parser = BrowserProxyHTTPHeadParser()
            let chunkedBody = "5\r\nhello\r\n0\r\n\r\n"
            let request =
                "POST /upload HTTP/1.1\r\n"
                + "Host: web.feature.localhost\r\n"
                + "Transfer-Encoding: chunked\r\n"
                + "Cookie: \(BrowserProxyRequest.cookieName)=secret-token; app=keep\r\n"
                + "\r\n"
                + chunkedBody
                + "GET /second HTTP/1.1\r\n"
                + "Host: web.feature.localhost\r\n"
                + "Cookie: \(BrowserProxyRequest.cookieName)=secret-token\r\n"
                + "\r\n"

            try parser.append(Data(request.utf8))

            XCTAssertEqual(parser.bodyFraming, .chunked)
            let progress = try XCTUnwrap(parser.chunkedBodyProgress)
            XCTAssertTrue(progress.isComplete)
            XCTAssertEqual(progress.forwardedByteCount, Data(chunkedBody.utf8).count)
            let sanitized = String(
                decoding: parser.consumedBytes(
                    droppingCookieNamed: BrowserProxyRequest.cookieName,
                    forcingConnectionClose: true,
                    bodyLimit: progress.forwardedByteCount),
                as: UTF8.self)
            XCTAssertTrue(sanitized.contains("POST /upload"))
            XCTAssertTrue(sanitized.contains(chunkedBody))
            XCTAssertTrue(sanitized.contains("Cookie: app=keep"))
            XCTAssertFalse(sanitized.contains("GET /second"))
            XCTAssertFalse(sanitized.contains(BrowserProxyRequest.cookieName))
        }

        // MARK: - Routing table

        func testRoutingTableMergeExtractsServiceHosts() {
            var table = BrowserProxyRoutingTable()
            let replaced = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))

            XCTAssertTrue(replaced.isEmpty)
            let target = table.target(forHost: "WEB.FEATURE.LOCALHOST")
            XCTAssertEqual(target?.deviceID, "device-1")
            XCTAssertEqual(target?.host, "127.0.0.1")
            XCTAssertEqual(target?.port, 47_847)
            XCTAssertEqual(target?.certificateFingerprint, "fp-1")
            XCTAssertEqual(target?.workspaceID, "ws-1")
            XCTAssertEqual(target?.serviceName, "web")
            XCTAssertEqual(target?.workspaceName, "feature")
            XCTAssertEqual(target?.deviceName, "Studio")
            XCTAssertFalse(target?.proxyAuthToken.isEmpty ?? true)
        }

        func testRoutingTableCrossDeviceReplaceIsReported() {
            var table = BrowserProxyRoutingTable()
            _ = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))
            let replaced = table.merge(
                deviceID: "device-2", deviceName: "Laptop", host: "10.0.0.2", port: 47_847, certificateFingerprint: "fp-2",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-2"))

            XCTAssertEqual(replaced, ["web.feature.localhost"])
            XCTAssertEqual(table.target(forHost: "web.feature.localhost")?.deviceID, "device-2")
        }

        func testRoutingTableKeepsTokenForUnchangedRoute() {
            var table = BrowserProxyRoutingTable()
            _ = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))
            let firstToken = table.target(forHost: "web.feature.localhost")?.proxyAuthToken

            _ = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))

            XCTAssertEqual(table.target(forHost: "web.feature.localhost")?.proxyAuthToken, firstToken)
        }

        func testRoutingTableRemoveDeviceDropsItsRoutes() {
            var table = BrowserProxyRoutingTable()
            _ = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))
            _ = table.merge(
                deviceID: "device-2", deviceName: "Laptop", host: "10.0.0.2", port: 47_847, certificateFingerprint: "fp-2",
                overview: makeOverview(serviceName: "api", url: "http://api.other.localhost:47847", branch: "other", workspaceID: "ws-2"))

            table.removeDevice(deviceID: "device-1")

            XCTAssertNil(table.target(forHost: "web.feature.localhost"))
            XCTAssertEqual(table.target(forHost: "api.other.localhost")?.deviceID, "device-2")
        }

        // MARK: - End-to-end proxy over loopback

        func testProxyRelaysBytesBothWaysThroughTunnel() async throws {
            let service = try LocalHTTPTestService(responseBody: "hello-from-service")
            defer { service.stop() }
            let servicePort = try await service.start()
            // Sanity-check the fixture: the loopback test service must answer a direct request
            // before it is meaningful to assert on the proxy's relay behavior.
            let direct = try await sendRequest(port: servicePort, host: "direct.check", path: "/direct")
            XCTAssertTrue(direct.head.contains("200"), "test service not directly reachable: \(direct.head)")
            let dialer = FakeTunnelDialer(behavior: .connect(port: servicePort))

            var table = BrowserProxyRoutingTable()
            _ = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))
            let authToken = try XCTUnwrap(table.target(forHost: "web.feature.localhost")?.proxyAuthToken)

            let proxyPort = UInt16.random(in: 49_152...65_500)
            let proxy = SpacesMobileBrowserProxy(port: proxyPort, installationID: "install-1", dialer: dialer)
            await proxy.updateRoutes(table)
            await proxy.start()
            defer { Task { await proxy.stop() } }
            let status = await proxyStatus(proxy)
            XCTAssertEqual(status, .running(port: proxyPort))

            let response = try await sendRequest(
                port: proxyPort, host: "web.feature.localhost:\(proxyPort)", path: "/index.html",
                cookieHeader: "app=keep; \(BrowserProxyRequest.cookieName)=\(authToken)",
                connectionHeader: "keep-alive")

            XCTAssertTrue(response.head.contains("200"), "expected 200 status, got: \(response.head) body: \(response.body)")
            XCTAssertTrue(response.body.contains("hello-from-service"))

            let requestReachedService = String(decoding: service.received(), as: UTF8.self)
            XCTAssertTrue(requestReachedService.contains("GET /index.html"))
            XCTAssertTrue(requestReachedService.contains("Host: web.feature.localhost"))
            XCTAssertTrue(requestReachedService.contains("Connection: close"))
            XCTAssertTrue(requestReachedService.contains("Cookie: app=keep"))
            XCTAssertFalse(requestReachedService.contains("Connection: keep-alive"))
            XCTAssertFalse(requestReachedService.contains(BrowserProxyRequest.cookieName))

            XCTAssertEqual(dialer.targets().first?.serviceName, "web")
            XCTAssertEqual(dialer.targets().first?.workspaceID, "ws-1")
        }

        func testProxyDropsPipelinedKeepAliveRequestAfterSingleSanitizedRequest() async throws {
            let service = try LocalHTTPTestService(responseBody: "hello-from-service")
            defer { service.stop() }
            let servicePort = try await service.start()
            let dialer = FakeTunnelDialer(behavior: .connect(port: servicePort))

            var table = BrowserProxyRoutingTable()
            _ = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))
            let authToken = try XCTUnwrap(table.target(forHost: "web.feature.localhost")?.proxyAuthToken)

            let proxyPort = UInt16.random(in: 49_152...65_500)
            let proxy = SpacesMobileBrowserProxy(port: proxyPort, installationID: "install-1", dialer: dialer)
            await proxy.updateRoutes(table)
            await proxy.start()
            defer { Task { await proxy.stop() } }

            let rawRequest =
                "GET /first HTTP/1.1\r\n"
                + "Host: web.feature.localhost:\(proxyPort)\r\n"
                + "Cookie: app=keep; \(BrowserProxyRequest.cookieName)=\(authToken)\r\n"
                + "Connection: keep-alive\r\n"
                + "\r\n"
                + "GET /second HTTP/1.1\r\n"
                + "Host: web.feature.localhost:\(proxyPort)\r\n"
                + "Cookie: \(BrowserProxyRequest.cookieName)=\(authToken)\r\n"
                + "Connection: close\r\n"
                + "\r\n"

            let response = try await sendRawRequest(port: proxyPort, request: rawRequest)

            XCTAssertTrue(response.head.contains("200"), "expected 200 status, got: \(response.head) body: \(response.body)")
            let requestReachedService = String(decoding: service.received(), as: UTF8.self)
            XCTAssertTrue(requestReachedService.contains("GET /first"))
            XCTAssertTrue(requestReachedService.contains("Cookie: app=keep"))
            XCTAssertFalse(requestReachedService.contains("GET /second"))
            XCTAssertFalse(requestReachedService.contains(BrowserProxyRequest.cookieName))
        }

        func testProxyRelaysChunkedRequestBodyAndDropsPipelinedRequest() async throws {
            let service = try LocalHTTPTestService(responseBody: "uploaded", requestTerminator: Data("\r\n0\r\n\r\n".utf8))
            defer { service.stop() }
            let servicePort = try await service.start()
            let dialer = FakeTunnelDialer(behavior: .connect(port: servicePort))

            var table = BrowserProxyRoutingTable()
            _ = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))
            let authToken = try XCTUnwrap(table.target(forHost: "web.feature.localhost")?.proxyAuthToken)

            let proxyPort = UInt16.random(in: 49_152...65_500)
            let proxy = SpacesMobileBrowserProxy(port: proxyPort, installationID: "install-1", dialer: dialer)
            await proxy.updateRoutes(table)
            await proxy.start()
            defer { Task { await proxy.stop() } }

            let rawRequest =
                "POST /upload HTTP/1.1\r\n"
                + "Host: web.feature.localhost:\(proxyPort)\r\n"
                + "Transfer-Encoding: chunked\r\n"
                + "Cookie: app=keep; \(BrowserProxyRequest.cookieName)=\(authToken)\r\n"
                + "Connection: keep-alive\r\n"
                + "\r\n"
                + "5\r\nhello\r\n0\r\n\r\n"
                + "GET /second HTTP/1.1\r\n"
                + "Host: web.feature.localhost:\(proxyPort)\r\n"
                + "Cookie: \(BrowserProxyRequest.cookieName)=\(authToken)\r\n"
                + "Connection: close\r\n"
                + "\r\n"

            let response = try await sendRawRequest(port: proxyPort, request: rawRequest)

            XCTAssertTrue(response.head.contains("200"), "expected 200 status, got: \(response.head) body: \(response.body)")
            XCTAssertTrue(response.body.contains("uploaded"))
            let requestReachedService = String(decoding: service.received(), as: UTF8.self)
            XCTAssertTrue(requestReachedService.contains("POST /upload"))
            XCTAssertTrue(requestReachedService.contains("Transfer-Encoding: chunked"))
            XCTAssertTrue(requestReachedService.contains("5\r\nhello\r\n0\r\n\r\n"))
            XCTAssertTrue(requestReachedService.contains("Connection: close"))
            XCTAssertTrue(requestReachedService.contains("Cookie: app=keep"))
            XCTAssertFalse(requestReachedService.contains("GET /second"))
            XCTAssertFalse(requestReachedService.contains(BrowserProxyRequest.cookieName))
        }

        func testProxyStartupIsSingleFlightAcrossConcurrentCalls() async throws {
            let dialer = FakeTunnelDialer(behavior: .fail(BrowserTunnelError(code: nil, message: "unused")))
            let proxyPort = UInt16.random(in: 49_152...65_500)
            let proxy = SpacesMobileBrowserProxy(port: proxyPort, installationID: "install-1", dialer: dialer)

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { await proxy.start() }
                }
            }
            defer { Task { await proxy.stop() } }

            let status = await proxyStatus(proxy)
            XCTAssertEqual(status, .running(port: proxyPort))
            let response = try await sendRequest(port: proxyPort, host: "unknown.service.localhost:\(proxyPort)", path: "/")
            XCTAssertTrue(response.head.contains("502"))
        }

        func testProxyUnknownHostReturns502NamingHost() async throws {
            let dialer = FakeTunnelDialer(behavior: .fail(BrowserTunnelError(code: nil, message: "unused")))
            let proxyPort = UInt16.random(in: 49_152...65_500)
            let proxy = SpacesMobileBrowserProxy(port: proxyPort, installationID: "install-1", dialer: dialer)
            await proxy.start()
            defer { Task { await proxy.stop() } }

            let response = try await sendRequest(port: proxyPort, host: "unknown.service.localhost:\(proxyPort)", path: "/")

            XCTAssertTrue(response.head.contains("502"))
            XCTAssertTrue(response.body.contains("unknown.service.localhost"))
            XCTAssertTrue(dialer.targets().isEmpty)
        }

        func testProxyServiceNotRunningReturns503NamingService() async throws {
            let dialer = FakeTunnelDialer(behavior: .fail(BrowserTunnelError(code: .serviceNotRunning, message: "The service is not running.")))
            var table = BrowserProxyRoutingTable()
            _ = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))
            let authToken = try XCTUnwrap(table.target(forHost: "web.feature.localhost")?.proxyAuthToken)

            let proxyPort = UInt16.random(in: 49_152...65_500)
            let proxy = SpacesMobileBrowserProxy(port: proxyPort, installationID: "install-1", dialer: dialer)
            await proxy.updateRoutes(table)
            await proxy.start()
            defer { Task { await proxy.stop() } }

            let response = try await sendRequest(
                port: proxyPort, host: "web.feature.localhost:\(proxyPort)", path: "/",
                cookieHeader: "\(BrowserProxyRequest.cookieName)=\(authToken)")

            XCTAssertTrue(response.head.contains("503"), "expected 503 status, got: \(response.head)")
            XCTAssertTrue(response.body.contains("web"))
            XCTAssertTrue(response.body.contains("feature"))
        }

        func testProxyRejectsMatchedHostWithoutAuthCookieBeforeDialing() async throws {
            let dialer = FakeTunnelDialer(behavior: .fail(BrowserTunnelError(code: nil, message: "must not dial")))
            var table = BrowserProxyRoutingTable()
            _ = table.merge(
                deviceID: "device-1", deviceName: "Studio", host: "127.0.0.1", port: 47_847, certificateFingerprint: "fp-1",
                overview: makeOverview(serviceName: "web", url: "http://web.feature.localhost:47847", branch: "feature", workspaceID: "ws-1"))

            let proxyPort = UInt16.random(in: 49_152...65_500)
            let proxy = SpacesMobileBrowserProxy(port: proxyPort, installationID: "install-1", dialer: dialer)
            await proxy.updateRoutes(table)
            await proxy.start()
            defer { Task { await proxy.stop() } }

            let response = try await sendRequest(port: proxyPort, host: "web.feature.localhost:\(proxyPort)", path: "/")

            XCTAssertTrue(response.head.contains("403"), "expected 403 status, got: \(response.head)")
            XCTAssertTrue(response.body.contains("active Spaces browser session"))
            XCTAssertTrue(dialer.targets().isEmpty)
        }

        // MARK: - Fixtures

        private func makeOverview(serviceName: String, url: String, branch: String, workspaceID: String) -> SpacesDeviceOverviewPayload {
            let workspace = SpacesDeviceWorkspaceSummary(
                id: workspaceID, projectID: "project-1", projectName: "Project", branch: branch, baseBranch: "main",
                dir: "/repo/\(branch)", isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 0,
                assignedPorts: [SpacesDeviceAssignedPort(name: serviceName, port: 3_000, url: url)])
            return SpacesDeviceOverviewPayload(
                projects: [], workspaces: [workspace], sessions: [],
                daemonStatus: TerminalServiceDaemonStatus(
                    version: "1.0.0", artifactVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                    protocolVersion: SpacesWireProtocol.version))
        }

        private func proxyStatus(_ proxy: SpacesMobileBrowserProxy) async -> BrowserProxyStatus {
            await MainActor.run { proxy.runtimeState.status }
        }

        private func sendRequest(
            port: UInt16,
            host: String,
            path: String,
            cookieHeader: String? = nil,
            connectionHeader: String = "close"
        ) async throws -> (head: String, body: String) {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw XCTSkip("invalid port") }
            let connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "browser.proxy.test.client")
            try await BrowserProxyConnectionIO.withTimeout(.seconds(10)) {
                try await BrowserProxyConnectionIO.waitUntilReady(connection, queue: queue)
            }
            let cookieLine = cookieHeader.map { "Cookie: \($0)\r\n" } ?? ""
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\(cookieLine)Connection: \(connectionHeader)\r\n\r\n"
            try await BrowserProxyConnectionIO.send(Data(request.utf8), on: connection)

            let data = try await readResponse(from: connection)
            connection.cancel()
            return splitResponse(data)
        }

        private func sendRawRequest(port: UInt16, request: String) async throws -> (head: String, body: String) {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw XCTSkip("invalid port") }
            let connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "browser.proxy.test.raw.client")
            try await BrowserProxyConnectionIO.withTimeout(.seconds(10)) {
                try await BrowserProxyConnectionIO.waitUntilReady(connection, queue: queue)
            }
            try await BrowserProxyConnectionIO.send(Data(request.utf8), on: connection)

            let data = try await readResponse(from: connection)
            connection.cancel()
            return splitResponse(data)
        }

        private func readResponse(from connection: NWConnection) async throws -> Data {
            let data = try await BrowserProxyConnectionIO.withTimeout(.seconds(10)) { () -> Data in
                var buffer = Data()
                while true {
                    let chunk = try await BrowserProxyConnectionIO.receiveChunk(from: connection)
                    buffer.append(chunk.data)
                    if chunk.isComplete { break }
                }
                return buffer
            }
            return data
        }

        private func splitResponse(_ data: Data) -> (head: String, body: String) {
            let text = String(decoding: data, as: UTF8.self)
            if let range = text.range(of: "\r\n\r\n") {
                return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
            }
            return (text, "")
        }
    }

    /// A fake dialer that either connects to a local test service or fails with a typed error.
    private final class FakeTunnelDialer: BrowserTunnelDialing, @unchecked Sendable {
        enum Behavior {
            case connect(port: UInt16)
            case fail(BrowserTunnelError)
        }

        private let behavior: Behavior
        private let lock = NSLock()
        private var requested: [BrowserProxyRouteTarget] = []

        init(behavior: Behavior) { self.behavior = behavior }

        func targets() -> [BrowserProxyRouteTarget] {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }

        func openTunnel(to target: BrowserProxyRouteTarget) async throws -> OpenedTunnel {
            lock.lock()
            requested.append(target)
            lock.unlock()
            switch behavior {
            case .fail(let error):
                throw error
            case .connect(let port):
                guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw BrowserTunnelError(code: .invalidArgument, message: "bad port") }
                let connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
                do {
                    try await BrowserProxyConnectionIO.withTimeout(.seconds(3)) {
                        try await BrowserProxyConnectionIO.waitUntilReady(connection, queue: DispatchQueue(label: "fake.tunnel"))
                    }
                } catch {
                    connection.cancel()
                    throw BrowserTunnelError(code: nil, message: "fake dialer could not reach test service on \(port): \(error)")
                }
                return OpenedTunnel(connection: connection, residual: Data())
            }
        }
    }

    /// A minimal loopback HTTP server standing in for a workspace service: it captures the request
    /// head it receives and replies with a canned 200 response, half-closing so the proxy relays EOF.
    private final class LocalHTTPTestService: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "browser.proxy.test.service")
        private let responseBody: String
        private let requestTerminator: Data
        private let lock = NSLock()
        private var receivedBytes = Data()

        init(responseBody: String, requestTerminator: Data = Data("\r\n\r\n".utf8)) throws {
            self.responseBody = responseBody
            self.requestTerminator = requestTerminator
            listener = try NWListener(using: .tcp)
        }

        func received() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return receivedBytes
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = BrowserProxyOneShot(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resume.resume(returning: ())
                    case .failed(let error): resume.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            guard let port = listener.port?.rawValue else {
                throw BrowserTunnelError(code: nil, message: "service has no port")
            }
            return port
        }

        func stop() { listener.cancel() }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            receiveLoop(connection, accumulated: Data())
        }

        private func receiveLoop(_ connection: NWConnection, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
                guard let self else { return }
                var next = accumulated
                if let content, !content.isEmpty { next.append(content) }
                if next.range(of: requestTerminator) != nil {
                    lock.lock()
                    receivedBytes = next
                    lock.unlock()
                    let response =
                        "HTTP/1.1 200 OK\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
                    // `.finalMessage` sends a TCP FIN after the response so the relay observes EOF.
                    connection.send(
                        content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                    return
                }
                if isComplete || error != nil { return }
                receiveLoop(connection, accumulated: next)
            }
        }
    }
#endif
