#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// Records every request a stub backend transport receives, from any isolation domain.
    private actor StubDeviceAPIRequestRecorder {
        private var requests: [SpacesDeviceAPIRequest] = []

        func append(_ request: SpacesDeviceAPIRequest) { requests.append(request) }
        func snapshot() -> [SpacesDeviceAPIRequest] { requests }
    }

    /// Captures the single subscribe request `openSessionStream` receives. The stream entry point is
    /// synchronous, so a lock-guarded box lets the test read it back without awaiting an actor.
    private final class StubSubscribeRequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SpacesDeviceAPIRequest?

        func set(_ request: SpacesDeviceAPIRequest) {
            lock.lock()
            self.request = request
            lock.unlock()
        }

        func get() -> SpacesDeviceAPIRequest? {
            lock.lock()
            defer { lock.unlock() }
            return request
        }
    }

    private struct StubRequestTransport: SpacesDeviceAPIRequestTransport {
        let recorder: StubDeviceAPIRequestRecorder
        let respond: @Sendable (SpacesDeviceAPIRequest) -> SpacesDeviceAPIResponse

        func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
            await recorder.append(request)
            return respond(request)
        }

        func close() async {}
    }

    private struct StubDeviceAPIBackend: SpacesDeviceAPIBackend {
        let recorder: StubDeviceAPIRequestRecorder
        let respond: @Sendable (SpacesDeviceAPIRequest) -> SpacesDeviceAPIResponse
        let subscribeRequestBox: StubSubscribeRequestBox
        let streamPayload: GhosttyRemoteSessionStatePayload?

        func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { StubRequestTransport(recorder: recorder, respond: respond) }

        func openSessionStream(
            request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
            onDisconnect: @escaping @MainActor (Error?) -> Void
        ) async throws -> SpacesDeviceAPIStreamHandle {
            subscribeRequestBox.set(request)
            if let streamPayload { Task { @MainActor in onEvent(streamPayload) } }
            return SpacesDeviceAPIStreamHandle {}
        }
    }

    @MainActor final class SpacesDeviceAPIBackendTests: XCTestCase {
        private func settings() -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = 12_345
            settings.authToken = "token"
            settings.certificateFingerprint = "SHA256:test"
            return settings
        }

        private func backend(
            recorder: StubDeviceAPIRequestRecorder = StubDeviceAPIRequestRecorder(),
            subscribeRequestBox: StubSubscribeRequestBox = StubSubscribeRequestBox(), streamPayload: GhosttyRemoteSessionStatePayload? = nil,
            respond: @escaping @Sendable (SpacesDeviceAPIRequest) -> SpacesDeviceAPIResponse = { _ in SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
        ) -> StubDeviceAPIBackend {
            StubDeviceAPIBackend(recorder: recorder, respond: respond, subscribeRequestBox: subscribeRequestBox, streamPayload: streamPayload)
        }

        func testOneShotRequestRoutesThroughBackendTransport() async throws {
            let recorder = StubDeviceAPIRequestRecorder()
            let client = SpacesDeviceAPIClient(
                settings: settings(), backend: backend(recorder: recorder, respond: { _ in SpacesDeviceAPIResponse(ok: true, message: "launched") }))

            _ = try await client.launchWorkspace(workspaceID: "workspace-1")

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["launchWorkspace"])
        }

        func testCommandChannelSendRoutesThroughBackendTransport() async throws {
            let recorder = StubDeviceAPIRequestRecorder()
            let client = SpacesDeviceAPIClient(settings: settings(), backend: backend(recorder: recorder))

            let channel = client.makeCommandChannel()
            let response = try await channel.send(
                request: SpacesDeviceAPIRequest(command: .overview, authToken: "token", clientApp: nil), timeout: .seconds(1))
            await channel.close()

            XCTAssertTrue(response.ok)
            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["overview"])
        }

        func testSubscribeRoutesThroughBackendStreamAndDeliversPayload() async throws {
            let payload = GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-06-04T14:23:30Z",
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0)
            let subscribeRequestBox = StubSubscribeRequestBox()
            let client = SpacesDeviceAPIClient(
                settings: settings(), backend: backend(subscribeRequestBox: subscribeRequestBox, streamPayload: payload))

            let received = XCTestExpectation(description: "onEvent delivers the recorded payload")
            let handle = try await client.subscribe(
                sessionID: "terminal-session", clientID: "client-ios",
                onEvent: { delivered in
                    XCTAssertEqual(delivered.sessionID, "terminal-session")
                    received.fulfill()
                }, onDisconnect: { _ in })

            await fulfillment(of: [received], timeout: 2)
            handle.cancel()

            let subscribeRequest = subscribeRequestBox.get()
            XCTAssertEqual(subscribeRequest?.commandName, "subscribe")
            guard case .subscribe(let subscribePayload)? = subscribeRequest?.command else {
                XCTFail("Expected the client to route a subscribe request through the backend stream.")
                return
            }
            XCTAssertEqual(subscribePayload.sessionID, "terminal-session")
            XCTAssertEqual(subscribePayload.clientID, "client-ios")
        }
    }
#endif
