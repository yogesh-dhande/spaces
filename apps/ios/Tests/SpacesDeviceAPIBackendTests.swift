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

    /// Answers every request and reports whether a second one was ever written while an earlier round
    /// trip was still outstanding. That interleave is exactly what the shared command channel must not
    /// allow: the wire under it is line framed with no request identifiers, so an overlapping write means
    /// the two callers read each other's replies.
    private actor OverlapDetectingTransport: SpacesDeviceAPIRequestTransport {
        private var inFlightCount = 0
        private var completedCount = 0
        private(set) var sawOverlappingRoundTrip = false
        private(set) var failNextSend = false

        func failNextRoundTrip() { failNextSend = true }

        func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
            inFlightCount += 1
            if inFlightCount > 1 { sawOverlappingRoundTrip = true }
            defer { inFlightCount -= 1 }
            // Suspends the way a real round trip does, between the write and the reply, which is the
            // window an unserialized channel lets a second caller write into.
            try? await Task.sleep(for: .milliseconds(20))
            if failNextSend {
                failNextSend = false
                throw SpacesDeviceAPIClientError.invalidEndpoint
            }
            completedCount += 1
            return SpacesDeviceAPIResponse(ok: true, message: "\(request.commandName)-\(completedCount)")
        }

        func close() async {}
    }

    /// Holds its first round trip open until the test releases it, and records the `timeout` every call
    /// received. Used to prove that `SpacesDeviceAPICommandChannel.send`'s `timeout` is a deadline over
    /// the whole round trip, including the wait for the channel's gate, not just the wire time after the
    /// gate is acquired.
    private actor HoldableTransport: SpacesDeviceAPIRequestTransport {
        private(set) var seenTimeouts: [Duration] = []
        private var holdRequested = false
        private var holdContinuation: CheckedContinuation<Void, Never>?

        /// Makes the next call to `send` suspend until `release()` is called, instead of answering
        /// immediately.
        func holdNextRoundTrip() { holdRequested = true }

        func release() {
            holdContinuation?.resume()
            holdContinuation = nil
        }

        func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
            seenTimeouts.append(timeout)
            if holdRequested {
                holdRequested = false
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in holdContinuation = continuation }
            }
            return SpacesDeviceAPIResponse(ok: true, message: "ok")
        }

        func close() async {}
    }

    /// Holds its first round trip open like `HoldableTransport`, but records each request's `authToken`
    /// (used here purely as a per-call marker, not a credential) in arrival order instead of just a
    /// count. Used to prove that requests queued behind a held one reach the transport in the order they
    /// were submitted, not the order they happened to reacquire the channel's gate.
    private actor OrderRecordingTransport: SpacesDeviceAPIRequestTransport {
        private(set) var order: [String] = []
        private var holdRequested = false
        private var holdContinuation: CheckedContinuation<Void, Never>?

        func holdNextRoundTrip() { holdRequested = true }

        func release() {
            holdContinuation?.resume()
            holdContinuation = nil
        }

        func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
            order.append(request.authToken ?? "")
            if holdRequested {
                holdRequested = false
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in holdContinuation = continuation }
            }
            return SpacesDeviceAPIResponse(ok: true, message: "ok")
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

        /// Every request an open terminal makes rides one command channel, so two of them can be issued
        /// together (the foreground heartbeat and the state read behind it are). One connection, line
        /// framed and without request identifiers, can only carry one round trip at a time.
        func testCommandChannelSerializesConcurrentRoundTrips() async throws {
            let transport = OverlapDetectingTransport()
            let channel = SpacesDeviceAPICommandChannel(transport: transport, authToken: "token", clientApp: Self.clientApp)

            async let first = channel.send(request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(2))
            async let second = channel.send(request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(2))
            let messages = try await [first.message, second.message]

            let sawOverlap = await transport.sawOverlappingRoundTrip
            XCTAssertFalse(sawOverlap, "a second request must not go on the wire while the first is unanswered")
            XCTAssertEqual(Set(messages), ["overview-1", "overview-2"], "each caller must get its own reply, not the other's")
        }

        /// A round trip that fails still hands the channel back: the transport under it drops its
        /// connection and the next request redials, so the caller after a failure must not be stuck
        /// waiting on a turn that never comes.
        func testFailedRoundTripDoesNotWedgeTheChannel() async throws {
            let transport = OverlapDetectingTransport()
            let channel = SpacesDeviceAPICommandChannel(transport: transport, authToken: "token", clientApp: Self.clientApp)
            await transport.failNextRoundTrip()

            do {
                _ = try await channel.send(request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(2))
                XCTFail("the failing round trip must throw")
            } catch {}

            let response = try await channel.send(
                request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(2))
            XCTAssertEqual(response.message, "overview-1")
        }

        /// A request's `timeout` covers the wait for the channel's gate as well as the wire round trip:
        /// queued behind a request the channel is still holding, it must time out on its own schedule
        /// instead of inheriting however long the held request takes, and it must never reach the
        /// transport at all since it never got a turn to send. The channel must still work once the held
        /// request releases the gate.
        func testQueuedRequestTimesOutWhileTheGateIsHeldAndTheChannelStillWorksAfterward() async throws {
            let transport = HoldableTransport()
            await transport.holdNextRoundTrip()
            let channel = SpacesDeviceAPICommandChannel(transport: transport, authToken: "token", clientApp: Self.clientApp)

            let held = Task {
                try await channel.send(request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(10))
            }
            // Gives the held request time to actually acquire the gate before the queued one is issued,
            // so the queued request is provably waiting on the gate rather than racing to acquire it first.
            try await Task.sleep(for: .milliseconds(50))

            let queuedStartedAt = ContinuousClock.now
            do {
                _ = try await channel.send(
                    request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .milliseconds(200))
                XCTFail("a request queued behind a held one must time out rather than wait indefinitely")
            } catch let error as SpacesDeviceAPIClientError {
                guard case .requestTimedOut = error else { return XCTFail("expected requestTimedOut, got \(error)") }
            }
            let queuedElapsed = ContinuousClock.now - queuedStartedAt
            XCTAssertLessThan(queuedElapsed, .seconds(2), "the queued request waited far longer than its own timeout")

            await transport.release()
            _ = try await held.value

            let response = try await channel.send(
                request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(2))
            XCTAssertTrue(response.ok, "the channel must still work after the held request released the gate")

            let seenTimeouts = await transport.seenTimeouts
            XCTAssertEqual(seenTimeouts.count, 2, "the timed-out queued request must never reach the transport")
        }

        /// The other side of the same deadline: a request that DOES get the gate before its timeout
        /// elapses is sent with the wait already deducted, not the timeout it originally asked for — so a
        /// slow gate wait cannot silently eat into what the transport treats as budget for the wire itself.
        func testQueuedRequestThatAcquiresTheGateInTimeIsSentWithTheRemainingTimeout() async throws {
            let transport = HoldableTransport()
            await transport.holdNextRoundTrip()
            let channel = SpacesDeviceAPICommandChannel(transport: transport, authToken: "token", clientApp: Self.clientApp)
            let originalTimeout = Duration.seconds(5)

            let held = Task {
                try await channel.send(request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(10))
            }
            try await Task.sleep(for: .milliseconds(50))

            // Releases the held request only after the queued one has been waiting a while, so the wait
            // this test measures is long enough to show up as a meaningfully reduced remaining timeout,
            // not just scheduling noise.
            let releaseAfterDelay = Task {
                try? await Task.sleep(for: .milliseconds(200))
                await transport.release()
            }

            let response = try await channel.send(
                request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: originalTimeout)
            XCTAssertTrue(response.ok)
            _ = try await held.value
            _ = await releaseAfterDelay.value

            let seenTimeouts = await transport.seenTimeouts
            XCTAssertEqual(seenTimeouts.count, 2)
            XCTAssertLessThan(seenTimeouts[1], originalTimeout, "a request that waited for the gate must be sent with a reduced timeout")
        }

        /// A waiter queued behind a held request must not stay queued until its own timeout once its
        /// caller loses interest: cancelling it (e.g. a takeover the user backed out of while a slow state
        /// read holds the gate) must fail it promptly, and the channel must still serve the request ahead
        /// of it and every request after it.
        func testCancellingAQueuedRequestFailsPromptlyAndTheChannelStillWorksAfterward() async throws {
            let transport = HoldableTransport()
            await transport.holdNextRoundTrip()
            let channel = SpacesDeviceAPICommandChannel(transport: transport, authToken: "token", clientApp: Self.clientApp)

            let held = Task {
                try await channel.send(request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(10))
            }
            // Gives the held request time to actually acquire the gate first, so the queued request below
            // is provably waiting on the gate rather than racing to acquire it.
            try await Task.sleep(for: .milliseconds(50))

            let queued = Task {
                try await channel.send(request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(30))
            }
            try await Task.sleep(for: .milliseconds(50))

            let cancelledAt = ContinuousClock.now
            queued.cancel()

            do {
                _ = try await queued.value
                XCTFail("a cancelled queued request must fail")
            } catch is CancellationError {} catch let error as SpacesDeviceAPIClientError { guard case .requestTimedOut = error else { throw error } }
            let elapsedSinceCancel = ContinuousClock.now - cancelledAt
            XCTAssertLessThan(elapsedSinceCancel, .seconds(5), "cancellation must not wait out the queued request's own 30 s timeout")

            await transport.release()
            _ = try await held.value

            let response = try await channel.send(
                request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(2))
            XCTAssertTrue(response.ok, "the channel must still work after a queued waiter was cancelled")
        }

        /// `endRoundTrip` must hand the gate directly to the queue's head instead of clearing it and
        /// letting whoever notices first reacquire it: otherwise a request arriving right as an earlier
        /// one releases can repeatedly cut in front of a longer-queued waiter. Looped because the race
        /// this guards against depends on how the release and the new arrival interleave on the actor,
        /// which does not reproduce on every run.
        func testQueuedRequestsResolveInFIFOOrderEvenAsANewRequestArrivesAtRelease() async throws {
            for iteration in 0..<25 {
                let transport = OrderRecordingTransport()
                await transport.holdNextRoundTrip()
                let channel = SpacesDeviceAPICommandChannel(transport: transport, authToken: "token", clientApp: Self.clientApp)

                func request(_ marker: String) -> SpacesDeviceAPIRequest {
                    SpacesDeviceAPIRequest(command: .overview, authToken: marker, clientApp: nil)
                }

                let first = Task { try await channel.send(request: request("first"), timeout: .seconds(10)) }
                try await Task.sleep(for: .milliseconds(20))
                let second = Task { try await channel.send(request: request("second"), timeout: .seconds(10)) }
                try await Task.sleep(for: .milliseconds(10))
                let third = Task { try await channel.send(request: request("third"), timeout: .seconds(10)) }
                try await Task.sleep(for: .milliseconds(10))

                // Fires the release and the fourth request's submission concurrently, so the fourth
                // reaches `beginRoundTrip` right as `endRoundTrip` is handing the gate to the queue's head
                // — the exact window a clear-then-race implementation loses FIFO order in.
                async let releaseFirst: Void = transport.release()
                let fourth = Task { try await channel.send(request: request("fourth"), timeout: .seconds(10)) }
                _ = await releaseFirst

                _ = try await first.value
                _ = try await second.value
                _ = try await third.value
                _ = try await fourth.value

                let order = await transport.order
                XCTAssertEqual(order, ["first", "second", "third", "fourth"], "iteration \(iteration): requests must resolve in submission order")
            }
        }

        private static let clientApp = SpacesDeviceClientApp(
            installationID: "install", bundleID: "dev.usespaces.spacesmobile", platform: "ios", deviceName: "Test Phone", appVersion: "1.0")

        func testSubscribeRoutesThroughBackendStreamAndDeliversPayload() async throws {
            let payload = GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.stateChange.rawValue, emittedAt: "2026-06-04T14:23:30Z",
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
