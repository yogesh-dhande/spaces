#if canImport(UIKit)
    import XCTest
    @testable import SpacesMobile

    /// Answers every request with a canned response and keeps the last request body.
    private final class StubRelayProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var lastBody: Data?
        nonisolated(unsafe) static var lastPath: String?
        nonisolated(unsafe) static var status = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastPath = request.url?.path
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                stream.close()
                Self.lastBody = data
            } else {
                Self.lastBody = request.httpBody
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"capability":"cap-1"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    final class PushRelayClientTests: XCTestCase {
        private func makeClient() -> URLSessionPushRelayClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubRelayProtocol.self]
            StubRelayProtocol.status = 200
            return URLSessionPushRelayClient(session: URLSession(configuration: configuration))
        }

        func testRegisterPostsTheTokenEnvironmentInstallIDAndPairedDeviceList() async throws {
            let capability = try await makeClient().register(
                apnsToken: "abcd", environment: .sandbox, installID: "INSTALL-1", deviceIDs: ["device-a", "device-b"])

            XCTAssertEqual(capability, "cap-1")
            XCTAssertEqual(StubRelayProtocol.lastPath, "/v1/register")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubRelayProtocol.lastBody)) as? [String: Any])
            XCTAssertEqual(body["apnsToken"] as? String, "abcd")
            XCTAssertEqual(body["environment"] as? String, "sandbox")
            XCTAssertEqual(body["installID"] as? String, "INSTALL-1")
            XCTAssertEqual(body["deviceIDs"] as? [String], ["device-a", "device-b"])
        }

        func testARejectedRegistrationThrows() async {
            let client = makeClient()
            StubRelayProtocol.status = 400

            do {
                _ = try await client.register(apnsToken: "ab", environment: .production, installID: "I", deviceIDs: [])
                XCTFail("a 400 must throw")
            } catch {}
        }
    }
#endif
