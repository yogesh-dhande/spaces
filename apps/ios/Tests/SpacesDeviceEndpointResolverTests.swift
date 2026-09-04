#if canImport(UIKit)
    import XCTest
    import Network
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// `SpacesDeviceEndpointResolver` opens real `NWConnection`s. Most of what's covered here doesn't
    /// depend on a live daemon: the up-front validation guard, and the shape of the error thrown when
    /// every candidate is unreachable. `PinnedTLSLoopbackServer` (below) additionally stands up a genuine
    /// pinned-TLS listener — using a fixed, pre-generated self-signed identity rather than
    /// `TerminalServiceTLSIdentityStore` (macOS/Linux-only: it shells out to `openssl`, which iOS has no
    /// `Process` to run) — so a handful of tests can drive the resolver to an actual cached-winner success
    /// without a real daemon, covering the multi-address failover invalidation paths that need one.
    final class SpacesDeviceEndpointResolverTests: XCTestCase {
        // Seeding-from-persisted-`activeHost` and `nextStreamHost()`/`noteStreamFailed(host:)` tests
        // below read and write `SpacesMobileDeviceStore`'s real `UserDefaults.standard` persistence —
        // reset it around every test the same way `SpacesMobileDeviceStoreTests` does, so a fingerprint
        // used by one test can never leak a seeded cache into another.
        override func setUp() {
            super.setUp()
            resetDeviceStorePersistedState()
        }

        override func tearDown() {
            resetDeviceStorePersistedState()
            super.tearDown()
        }

        /// An empty `hosts` list is rejected before any connection attempt.
        func testConnectThrowsInvalidEndpointForEmptyHosts() async {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = []
            settings.port = 47_900
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            do {
                _ = try await resolver.connect(timeout: .seconds(1), queue: .main)
                XCTFail("expected invalidEndpoint")
            } catch SpacesDeviceAPIClientError.invalidEndpoint {
                // expected
            } catch { XCTFail("unexpected error: \(error)") }
        }

        /// Every candidate that never answers (and never even resets the connection, so there is no pin
        /// mismatch to report) surfaces as `allCandidatesUnreachable`, naming every host that was tried —
        /// which is what proves the resolver walked the whole list rather than giving up on the first.
        /// Uses RFC 5737 TEST-NET addresses (`192.0.2.1`, `198.51.100.1`) — guaranteed non-routable to a
        /// live host — instead of a live daemon, so the failure is deterministic. The short `timeout`
        /// becomes the per-candidate cap (`min(timeout, 5s)`), keeping a test that has to wait out two
        /// real connect attempts near two seconds instead of the ten a production-sized budget would cost.
        func testAllCandidatesUnreachableNamesEveryHostTried() async throws {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["192.0.2.1", "198.51.100.1"]
            settings.port = 47_900
            settings.certificateFingerprint = "SHA256:unreachable"
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            do {
                _ = try await resolver.connect(timeout: .milliseconds(300), queue: .main)
                XCTFail("expected allCandidatesUnreachable")
            } catch SpacesDeviceAPIClientError.allCandidatesUnreachable(let hosts) { XCTAssertEqual(hosts, ["192.0.2.1", "198.51.100.1"]) } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        /// The error message names the unreachable addresses and points at Tailscale, since the most
        /// common real-world cause is being away from the paired Mac's LAN with Tailscale not connected.
        /// Asserted on the error value directly: the message is a property of the case, so proving its
        /// content needs no connection attempt.
        func testAllCandidatesUnreachableDescriptionNamesHostsAndTailscale() throws {
            let error = SpacesDeviceAPIClientError.allCandidatesUnreachable(hosts: ["192.168.1.24", "100.86.197.104"])
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(description.contains("192.168.1.24"))
            XCTAssertTrue(description.contains("100.86.197.104"))
            XCTAssertTrue(description.contains("Tailscale"))
        }

        /// Proves the happy-eyeballs race actually races rather than walking `hosts` in order: an
        /// unreachable candidate listed first (`192.0.2.1`, RFC 5737 TEST-NET, guaranteed non-routable)
        /// must not force the resolver to wait out that candidate's full timeout before the reachable
        /// loopback candidate downstream even gets a turn.
        ///
        /// The second candidate is a genuine pinned-TLS listener carrying the fingerprint this device
        /// pinned, so a race that gives it a turn resolves to it winning outright rather than to any
        /// failure verdict, which is what proves the unreachable first candidate did not starve it.
        func testReachableCandidateGetsATurnDespiteAnUnreachablePreferredCandidate() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["192.0.2.1", "127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            let start = ContinuousClock.now
            let resolved = try await resolver.connect(timeout: .seconds(3), queue: .main)
            resolved.connection.cancel()

            XCTAssertEqual(resolved.host, "127.0.0.1")
            let elapsed = start.duration(to: .now)
            // Walking the list in order would spend the first candidate's whole budget (capped at
            // `perCandidateTimeoutCap`) before starting the second; racing costs only the 250ms stagger
            // plus a loopback handshake.
            XCTAssertLessThan(elapsed, .seconds(2))
        }

        /// A candidate that accepts TCP and then never completes the pinned handshake is unreachable, not
        /// a pin mismatch. Nothing there ever presented a certificate, so nothing about the daemon's
        /// identity was established. That is the same shape a captive portal, or a stored LAN address
        /// that now belongs to some other box, produces on a foreground resume. Reporting it as a mismatch is what
        /// sent the app to the re-pair screen for a network that had simply not settled yet;
        /// `allCandidatesUnreachable` is treated as transient and retried upstream, which is correct here.
        func testOpenPortThatNeverCompletesTheHandshakeIsNotAPinMismatch() async throws {
            let listener = try LoopbackConnectionSink()
            let port = try await listener.start()
            defer { listener.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = "SHA256:" + String(repeating: "0", count: 64)
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            do {
                _ = try await resolver.connect(timeout: .milliseconds(500), queue: .main)
                XCTFail("expected allCandidatesUnreachable")
            } catch SpacesDeviceAPIClientError.allCandidatesUnreachable(let hosts) { XCTAssertEqual(hosts, ["127.0.0.1"]) } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        /// A real pin mismatch: the peer presents a certificate and the verify block rejects it. Uses a
        /// genuine pinned-TLS listener (`PinnedTLSLoopbackServer`) with a deliberately wrong
        /// `certificateFingerprint`, so the rejection is real rather than simulated. Must classify as a pin
        /// mismatch and make the race throw `transportAuthenticationFailed` — not `allCandidatesUnreachable`,
        /// which is treated as a transient, silently-retried error upstream and would never surface the
        /// re-pair prompt this failure needs to reach.
        func testImmediateCertificateMismatchClassifiesAsPinMismatch() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = "SHA256:" + String(repeating: "0", count: 64)
            XCTAssertNotEqual(settings.certificateFingerprint, server.certificateFingerprint, "sanity: must be a genuine mismatch")
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            let start = ContinuousClock.now
            do {
                _ = try await resolver.connect(timeout: .seconds(3), queue: .main)
                XCTFail("expected transportAuthenticationFailed")
            } catch SpacesDeviceAPIClientError.transportAuthenticationFailed {
                // Expected.
            } catch { XCTFail("unexpected error: \(error)") }
            let elapsed = start.duration(to: .now)
            // A certificate rejection must surface without waiting out the per-candidate timeout budget:
            // Network.framework parks a rejected pin in `.waiting` and keeps redialing, so `waitUntilReady`
            // has to end the wait on the verify block's recorded verdict rather than idle out the budget.
            XCTAssertLessThan(elapsed, .seconds(2))
        }

        /// `SpacesDeviceAPIClient.resetEndpointResolution()` — the foreground LAN re-preference — must
        /// reach all the way down to the resolver's actual cached winner, not just some intermediate
        /// layer. Seeds a genuine cached winner via a real pinned-TLS handshake against
        /// `PinnedTLSLoopbackServer`, then proves the client-level call clears it.
        func testResetEndpointResolutionClearsResolverCachedWinner() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let backend = SpacesDeviceNetworkBackend(settings: settings)
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)

            _ = try await backend.resolver.connect(timeout: .seconds(3), queue: .main)
            let resolvedBeforeReset = await client.currentResolvedHost()
            XCTAssertEqual(resolvedBeforeReset, "127.0.0.1")

            await client.resetEndpointResolution()

            let resolvedAfterReset = await client.currentResolvedHost()
            XCTAssertNil(resolvedAfterReset)
        }

        /// The core of symptom 1's fix: a session stream that disconnects with an error must clear the
        /// resolver's cached winner, so the caller's own reconnect (which rebuilds the stream from
        /// `resolver.currentCachedHost()`) re-races every candidate instead of retrying the same dead
        /// address forever. Seeds a real cached winner, kills the server out from under it, then opens a
        /// stream against that now-dead cached address and confirms the resulting disconnect clears it.
        ///
        /// A closed loopback port does not always fail an `NWConnection` promptly: Network.framework can
        /// sit in `.waiting` retrying before giving up, rather than jumping straight to `.failed`. This is
        /// exactly the case `StreamSubscription`'s own `initialEventTimeout` fallback (12s) exists to
        /// bound, so the wait below has to clear that budget rather than the couple of seconds a fast
        /// `.failed` transition would otherwise need.
        func testStreamDisconnectWithErrorClearsCachedWinner() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let backend = SpacesDeviceNetworkBackend(settings: settings)

            _ = try await backend.resolver.connect(timeout: .seconds(3), queue: .main)
            let cachedHostBeforeFailure = await backend.resolver.currentCachedHost()
            XCTAssertEqual(cachedHostBeforeFailure, "127.0.0.1")
            server.stop()

            let request = SpacesDeviceAPIRequest(
                command: .subscribe(.init(sessionID: "session-1", clientID: "client-1")), authToken: nil, clientApp: nil)
            let sentinelBox = WeakStreamSentinelBox()
            let disconnected = expectation(description: "stream disconnected with an error")
            _ = try await backend.openSessionStream(
                request: request, onEvent: makeSentinelEventCallback(recordingInto: sentinelBox),
                onDisconnect: { disconnect in
                    XCTAssertNotNil(disconnect.error)
                    disconnected.fulfill()
                })

            await fulfillment(of: [disconnected], timeout: 15)
            let cachedHostAfterFailure = await backend.resolver.currentCachedHost()
            XCTAssertNil(cachedHostAfterFailure)
            // A stream that ends badly must also leave nothing behind: an outage retries for as long as it
            // lasts, so a connection and its queue orphaned per attempt accumulate for the whole outage.
            try await waitForSubscriptionRelease(sentinelBox)
        }

        /// The other half of symptom 1's contract: a `nil` disconnect error is a clean, caller-initiated
        /// cancellation (e.g. the viewer was dismissed), not evidence the address stopped working, and
        /// must leave the cached winner alone.
        func testStreamCleanDisconnectDoesNotClearCachedWinner() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let backend = SpacesDeviceNetworkBackend(settings: settings)

            _ = try await backend.resolver.connect(timeout: .seconds(3), queue: .main)
            let cachedHostBeforeClose = await backend.resolver.currentCachedHost()
            XCTAssertEqual(cachedHostBeforeClose, "127.0.0.1")

            let request = SpacesDeviceAPIRequest(
                command: .subscribe(.init(sessionID: "session-1", clientID: "client-1")), authToken: nil, clientApp: nil)
            let disconnected = expectation(description: "stream disconnected cleanly")
            let handle = try await backend.openSessionStream(
                request: request, onEvent: { _ in },
                onDisconnect: { disconnect in
                    XCTAssertNil(disconnect.error)
                    disconnected.fulfill()
                })
            handle.cancel()

            await fulfillment(of: [disconnected], timeout: 5)
            let cachedHostAfterCleanClose = await backend.resolver.currentCachedHost()
            XCTAssertEqual(cachedHostAfterCleanClose, "127.0.0.1")
        }

        /// K3 regression: a stream that ends because the daemon decoded the frame and declined it (the
        /// session already ended, say) proves the address itself is fine, so it must not be recorded
        /// against the resolver's shared per-host failure count the way a genuine transport failure is
        /// (`testStreamDisconnectWithErrorClearsCachedWinner`, above). Mirrors Mac's
        /// `SpacesDeviceAPIStreamEndpoint.isHostTransportFailure`, which excludes a decoded rejection from
        /// its transport-failure allowlist for the same reason. Before the fix, every non-nil disconnect
        /// error, rejection included, was recorded via `noteStreamFailed(host:)`; with the resolver shared
        /// across every pane's stream, a rejection on this host plus a real dial failure on a second
        /// candidate would read as "every candidate is down" even though this one plainly answered.
        /// A broken pipe while writing the subscribe request means the peer vanished underneath the
        /// connection, the same lost-link evidence as a reset. The input path already classifies `EPIPE`
        /// that way; the stream classifier must agree so the reconnect records the failed candidate and
        /// is free to try another address instead of redialing the same broken one.
        func testBrokenPipeCountsAsAStreamHostTransportFailure() {
            XCTAssertTrue(SpacesDeviceAPIClientError.isStreamHostTransportFailure(NWError.posix(.EPIPE)))
            XCTAssertTrue(SpacesDeviceAPIClientError.isStreamHostTransportFailure(POSIXError(.EPIPE)))
            XCTAssertTrue(SpacesDeviceAPIClientError.isStreamHostTransportFailure(NWError.posix(.ECONNRESET)))
            XCTAssertFalse(
                SpacesDeviceAPIClientError.isStreamHostTransportFailure(NWError.posix(.EINVAL)),
                "a local argument error says nothing about the address")
        }

        /// A name that fails to resolve (the tailnet MagicDNS name a paired host was recorded under, with
        /// Tailscale off) and a handshake the path reset or aborted are both evidence about this address,
        /// the same as a refused dial: left uncounted, the resolver keeps redialing the same broken
        /// candidate instead of recording it as failed and trying another one.
        func testDNSAndNonPinTLSFailuresCountAsAStreamHostTransportFailure() {
            XCTAssertTrue(SpacesDeviceAPIClientError.isStreamHostTransportFailure(NWError.dns(-65554)))
            XCTAssertTrue(SpacesDeviceAPIClientError.isStreamHostTransportFailure(NWError.tls(-9806)))
        }

        /// The command path's sibling to the DNS/TLS classifier test above: a peer that closes the
        /// command connection before answering (accepted the TCP/TLS handshake, then hung up with no
        /// response line) must surface as `SpacesDeviceAPIClientError.connectionClosed`, the typed EOF
        /// shape `readLineAccumulating` throws, not `.requestFailed`, which is reserved for a decoded
        /// daemon answer.
        func testCommandConnectionClosedByThePeerWithoutAnsweringThrowsConnectionClosed() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let resolver = SpacesDeviceEndpointResolver(settings: settings)
            let transport = SpacesDeviceNetworkRequestTransport(resolver: resolver)

            async let response = transport.send(
                request: SpacesDeviceAPIRequest(command: .overview, authToken: nil, clientApp: nil), timeout: .seconds(5))

            // The server never speaks the application protocol, so there is nothing to wait on besides
            // the TCP/TLS handshake completing: give it a moment past the accept to land, then hang up
            // without ever writing a response line.
            try await waitForAcceptedConnection(on: server)
            try await Task.sleep(for: .milliseconds(200))
            server.stop()

            do {
                _ = try await response
                XCTFail("expected connectionClosed when the peer hangs up without answering")
            } catch SpacesDeviceAPIClientError.connectionClosed {
                // Expected.
            } catch {
                XCTFail("expected connectionClosed, got \(error)")
            }
        }

        func testStreamRejectionDoesNotRecordAFailedCandidateOrExhaustDialCandidates() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let backend = SpacesDeviceNetworkBackend(settings: settings)

            _ = try await backend.resolver.connect(timeout: .seconds(3), queue: .main)
            let cachedHostBeforeRejection = await backend.resolver.currentCachedHost()
            XCTAssertEqual(cachedHostBeforeRejection, "127.0.0.1")

            let request = SpacesDeviceAPIRequest(
                command: .subscribe(.init(sessionID: "session-1", clientID: "client-1")), authToken: nil, clientApp: nil)
            let disconnected = expectation(description: "stream disconnected with a decoded rejection")
            let errorBox = StreamDisconnectErrorBox()
            _ = try await backend.openSessionStream(
                request: request, onEvent: { _ in },
                onDisconnect: { disconnect in
                    errorBox.record(disconnect.error, dialExhaustedAllCandidates: disconnect.dialExhaustedAllCandidates)
                    disconnected.fulfill()
                })

            // The resolver `connect` above is the server's first accepted connection; the stream's is the
            // second, and the rejection must not go out until that one exists.
            try await waitForAcceptedConnection(on: server, count: 2)
            server.broadcast(try Self.rejectionLine())

            await fulfillment(of: [disconnected], timeout: 10)
            guard case SpacesDeviceAPIClientError.streamRejected? = errorBox.error() as? SpacesDeviceAPIClientError else {
                return XCTFail("expected streamRejected, got \(String(describing: errorBox.error()))")
            }
            XCTAssertFalse(
                errorBox.dialExhaustedAllCandidates(),
                "a decoded rejection proves the daemon answered and must not read as dial exhaustion")

            let cachedHostAfterRejection = await backend.resolver.currentCachedHost()
            XCTAssertEqual(cachedHostAfterRejection, "127.0.0.1", "a rejection must not clear the cached winner or record a failed candidate")
        }

        /// One newline-framed daemon rejection, as a decoded-but-declined subscribe response would arrive.
        private static func rejectionLine() throws -> Data {
            try SpacesDeviceAPICodec.encodeResponseLine(
                SpacesDeviceAPIResponse(ok: false, message: "This terminal session ended.", errorCode: .sessionNotAvailable))
        }

        /// Nothing a stream leaves behind may outlive it. An `NWConnection` holds its handler blocks,
        /// and those blocks hold `StreamSubscription`, its decode buffer, and the per-stream
        /// `DispatchQueue` — until the connection is cancelled, so cancelling is the only thing that
        /// releases the graph. Every way a stream ends therefore cancels, and this pins the mechanism the
        /// callers depend on: both clients drop their stream handle on disconnect with no cleanup of their
        /// own, which is only correct because the connection cancels itself here.
        ///
        /// The sentinel is owned by the event callback and by nothing else, so its deallocation is a direct
        /// read of whether the subscription behind it was released.
        func testCancellingAStreamReleasesItsSubscription() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let backend = SpacesDeviceNetworkBackend(settings: settings)

            let sentinelBox = WeakStreamSentinelBox()
            let request = SpacesDeviceAPIRequest(
                command: .subscribe(.init(sessionID: "session-1", clientID: "client-1")), authToken: nil, clientApp: nil)
            let disconnected = expectation(description: "stream disconnected cleanly")
            let handle = try await backend.openSessionStream(
                request: request, onEvent: makeSentinelEventCallback(recordingInto: sentinelBox), onDisconnect: { _ in disconnected.fulfill() })
            handle.cancel()

            await fulfillment(of: [disconnected], timeout: 5)
            try await waitForSubscriptionRelease(sentinelBox)
        }

        /// The bug the stream keepalive exists for: the peer's transport dies without closing the socket,
        /// so nothing arrives and nothing fails. The viewer used to keep a frozen screen indefinitely,
        /// with keystrokes still "succeeding" on the separate request channel. Silence past the timeout
        /// now ends the stream as `streamStalled`, and (like every other ending) releases it.
        func testASilentConnectionStallsTheStreamAndReleasesItsSubscription() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            // Compressed from the production timeout so the suite does not wait out a real one; the check
            // cadence scales with it, so this exercises the same code path at the same ratios.
            let backend = SpacesDeviceNetworkBackend(settings: settings, streamSilenceTimeout: 1)

            let sentinelBox = WeakStreamSentinelBox()
            let receivedPayload = expectation(description: "the stream decoded a payload")
            receivedPayload.assertForOverFulfill = false
            let stalled = expectation(description: "the stream reported itself stalled")
            let stallErrorBox = StreamDisconnectErrorBox()
            let request = SpacesDeviceAPIRequest(
                command: .subscribe(.init(sessionID: "session-1", clientID: "client-1")), authToken: nil, clientApp: nil)
            _ = try await backend.openSessionStream(
                request: request,
                onEvent: makeSentinelEventCallback(recordingInto: sentinelBox, fulfilling: receivedPayload),
                onDisconnect: { disconnect in
                    stallErrorBox.record(disconnect.error)
                    stalled.fulfill()
                })

            try await waitForAcceptedConnection(on: server)
            server.broadcast(try Self.payloadLine())
            await fulfillment(of: [receivedPayload], timeout: 10)

            // Nothing more is written: the connection stays open and carries nothing, exactly like a link
            // that died between the two peers.
            await fulfillment(of: [stalled], timeout: 10)
            guard case SpacesDeviceAPIClientError.streamStalled? = stallErrorBox.error() as? SpacesDeviceAPIClientError else {
                return XCTFail("expected streamStalled, got \(String(describing: stallErrorBox.error()))")
            }
            try await waitForSubscriptionRelease(sentinelBox)
        }

        /// The daemon's half of the contract, from the client's side: an idle terminal produces no state
        /// payloads for as long as the user leaves it alone, so the empty-line keepalives are the only
        /// thing separating it from a dead link. They carry no state — the framing loop drops empty lines
        /// before decoding — yet they must hold the stream open indefinitely.
        func testKeepaliveFramesKeepAnIdleStreamConnected() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let backend = SpacesDeviceNetworkBackend(settings: settings, streamSilenceTimeout: 1)

            let receivedPayload = expectation(description: "the stream decoded a payload")
            receivedPayload.assertForOverFulfill = false
            let disconnected = expectation(description: "the stream must not disconnect while keepalives arrive")
            disconnected.isInverted = true
            let eventCount = StreamEventCounterBox()
            let request = SpacesDeviceAPIRequest(
                command: .subscribe(.init(sessionID: "session-1", clientID: "client-1")), authToken: nil, clientApp: nil)
            let handle = try await backend.openSessionStream(
                request: request,
                onEvent: { _ in
                    eventCount.increment()
                    receivedPayload.fulfill()
                }, onDisconnect: { _ in disconnected.fulfill() })
            defer { handle.cancel() }

            try await waitForAcceptedConnection(on: server)
            server.broadcast(try Self.payloadLine())
            await fulfillment(of: [receivedPayload], timeout: 10)

            // Three timeouts' worth of keepalives, at the cadence the daemon uses relative to its own
            // timeout (one keepalive per third of the silence budget).
            for _ in 0..<12 {
                server.broadcast(TerminalStreamLiveness.keepaliveFrame)
                try await Task.sleep(for: .milliseconds(250))
            }

            await fulfillment(of: [disconnected], timeout: 0.1)
            XCTAssertEqual(eventCount.value(), 1, "keepalives carry no state and must never reach the viewer as payloads")
        }

        /// One newline-framed terminal state payload, as the daemon's relay would write it.
        private static func payloadLine() throws -> Data {
            try GhosttyRemoteSessionStateCodec.encodeLine(
                GhosttyRemoteSessionStatePayload(
                    sessionID: "session-1", reason: "state", emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
                    sessionStateRevision: 1, sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil,
                    title: "zsh", workingDirectory: "/tmp", outputByteCount: 0))
        }

        /// Waits until the loopback server has the stream's connection in hand, so bytes written next
        /// actually reach it rather than being broadcast to nobody.
        /// `count` is the number of accepted connections the test expects once the connection it is about
        /// to talk to has arrived: a test that already opened a connection of its own (a resolver
        /// `connect`, for instance) must ask for one more than that, or this returns on the earlier
        /// connection and the bytes the test then broadcasts go out before the one it meant them for exists.
        private func waitForAcceptedConnection(
            on server: PinnedTLSLoopbackServer, count: Int = 1, file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, server.acceptedConnectionCount() < count { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertGreaterThanOrEqual(server.acceptedConnectionCount(), count, "the stream never connected", file: file, line: line)
        }

        /// Builds an event callback owning a freshly created sentinel, recorded weakly in `box`. Written as
        /// a function so the only strong reference lives inside the returned callback — a strong local in
        /// the test's own frame would keep the sentinel alive no matter what the subscription does.
        private func makeSentinelEventCallback(recordingInto box: WeakStreamSentinelBox) -> @MainActor (GhosttyRemoteSessionStatePayload) -> Void {
            let sentinel = StreamLifetimeSentinel()
            box.object = sentinel
            XCTAssertNotNil(box.object, "the sentinel must be recorded before the callback escapes")
            return { _ in sentinel.noteEvent() }
        }

        /// As above, and fulfills `expectation` for every payload. Separate from the callback-only
        /// variant for the same reason that one is a function: a test that composed the two would have to
        /// hold the sentinel-owning callback in a local, and that local alone would keep the sentinel
        /// alive past any release the subscription performs.
        private func makeSentinelEventCallback(recordingInto box: WeakStreamSentinelBox, fulfilling expectation: XCTestExpectation)
            -> @MainActor (GhosttyRemoteSessionStatePayload) -> Void
        {
            let sentinel = StreamLifetimeSentinel()
            box.object = sentinel
            XCTAssertNotNil(box.object, "the sentinel must be recorded before the callback escapes")
            return { _ in
                sentinel.noteEvent()
                expectation.fulfill()
            }
        }

        /// Waits for the subscription behind `box` to be released. The release happens on the stream's own
        /// queue as the cancelled connection drops its handler blocks, so it is observed rather than
        /// assumed — with a bound short enough that a subscription still alive means nothing cancelled it.
        private func waitForSubscriptionRelease(_ box: WeakStreamSentinelBox, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, box.object != nil { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertNil(
                box.object, "a stream that ended must have cancelled its connection, or its handler blocks keep the whole subscription alive",
                file: file, line: line)
        }

        // MARK: - Single warm-start mechanism (item 3)

        /// The resolver seeds its cached winner from the persisted `activeHost` at construction, so a
        /// freshly built resolver (e.g. after `SpacesMobileAppModel.rebuildLiveClientAfterHostsBackfill`
        /// swaps in a new client) starts already knowing the last address that worked instead of having
        /// to re-race every candidate on its very first use.
        func testInitSeedsCachedWinnerFromPersistedActiveHost() async {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5", "100.64.0.5"]
            settings.certificateFingerprint = "SHA256:seed-from-active-host"
            _ = SpacesMobileDeviceStore.upsert(settings: settings, name: "Mac")
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: "SHA256:seed-from-active-host")

            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            let seeded = await resolver.currentCachedHost()
            XCTAssertEqual(seeded, "100.64.0.5")
        }

        /// A persisted `activeHost` that is not a member of *this* resolver's own `hosts` (e.g. a rescan
        /// narrowed the candidate list since the value was recorded) must never be adopted as a seed —
        /// mirrors the re-validation `connect(timeout:queue:)` already performs on a cached winner.
        func testInitDoesNotSeedActiveHostMissingFromItsOwnHosts() async {
            var pairedSettings = SpacesMobileConnectionSettings()
            pairedSettings.hosts = ["10.0.0.5", "100.64.0.5"]
            pairedSettings.certificateFingerprint = "SHA256:seed-narrowed-hosts"
            _ = SpacesMobileDeviceStore.upsert(settings: pairedSettings, name: "Mac")
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: "SHA256:seed-narrowed-hosts")

            var narrowedSettings = pairedSettings
            narrowedSettings.hosts = ["10.0.0.5"]
            let resolver = SpacesDeviceEndpointResolver(settings: narrowedSettings)

            let seeded = await resolver.currentCachedHost()
            XCTAssertNil(seeded)
        }

        // MARK: - Stream-host rotation (item 2)

        /// With no cached winner, `nextStreamHost()` starts at the top of `hosts`, same as a fresh
        /// `connect` race would prefer the first candidate.
        func testNextStreamHostStartsAtFirstCandidateWithNoCachedWinner() async {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5", "100.64.0.5"]
            settings.certificateFingerprint = "SHA256:rotate-no-cache"
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            let host = await resolver.nextStreamHost()

            XCTAssertEqual(host, "10.0.0.5")
        }

        /// The core of item 2's fix: a viewer reconnecting an already-attached owner subscribes again
        /// with no intervening command request, so the resolver has no fresh cached winner to hand back.
        /// `noteStreamFailed` on the dead candidate must move the *next* stream attempt to the other
        /// candidate instead of retrying the same dead LAN address forever.
        func testNextStreamHostMovesToNextCandidateAfterNotedFailure() async {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5", "100.64.0.5"]
            settings.certificateFingerprint = "SHA256:rotate-after-failure"
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            let first = await resolver.nextStreamHost()
            XCTAssertEqual(first, "10.0.0.5")
            await resolver.noteStreamFailed(host: "10.0.0.5")

            let second = await resolver.nextStreamHost()
            XCTAssertEqual(second, "100.64.0.5")
        }

        /// Bounded and self-resetting: once every candidate has been noted as failed, the next call
        /// clears the failed set and restarts the walk from the top rather than returning `nil` and
        /// dead-ending a viewer that keeps trying to reconnect.
        func testNextStreamHostResetsOnceEveryCandidateHasFailed() async {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5", "100.64.0.5"]
            settings.certificateFingerprint = "SHA256:rotate-full-reset"
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            await resolver.noteStreamFailed(host: "10.0.0.5")
            await resolver.noteStreamFailed(host: "100.64.0.5")

            let afterFullReset = await resolver.nextStreamHost()

            XCTAssertEqual(afterFullReset, "10.0.0.5")
        }

        /// A live query made after the fact can disagree with what was true the instant the last
        /// candidate failed: with several panes on the same device reconnecting concurrently, another
        /// pane's own `nextStreamHost()` call can reset the failed set in the gap between this dial's
        /// failure and a later query, so a caller re-deriving the verdict from the resolver's current
        /// state would wrongly read "not every candidate has failed". `noteStreamFailed(host:)`'s return
        /// value is what a caller must use instead, because it is captured atomically with the recording
        /// it describes and so cannot be raced out from under the caller that way. Mirrors the Mac
        /// resolver's `testNoteStreamFailedReturnsTheVerdictAtTheMomentOfRecordingNotAtALaterQuery`.
        func testNoteStreamFailedReturnsTheVerdictAtTheMomentOfRecordingNotAtALaterQuery() async {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5"]
            settings.certificateFingerprint = "SHA256:atomic-verdict"
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            // The single candidate just failed: every candidate has now failed, so the verdict is true.
            let exhausted = await resolver.noteStreamFailed(host: "10.0.0.5")
            XCTAssertTrue(exhausted)

            // A concurrent pane's own reconnect attempt calls `nextStreamHost()` in the meantime, which
            // self-resets the failed set now that every candidate was in it. Proven here by the walk
            // offering "10.0.0.5" again instead of continuing to skip it, meaning the failed set a query
            // would see right now is empty, not "every candidate".
            let next = await resolver.nextStreamHost()
            XCTAssertEqual(next, "10.0.0.5", "the reset handed the candidate back out: a query made now would find nothing failed")
        }

        /// `nextStreamHost()` prefers a cached winner over the failed-candidate walk, and
        /// `noteStreamFailed` clears that cache when the failure was on the cached address itself — so a
        /// command-channel request racing right after does not trust the same now-suspect address.
        func testNoteStreamFailedClearsCachedWinnerWhenItMatchesAndFallsThroughToNextCandidate() async {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5", "100.64.0.5"]
            settings.certificateFingerprint = "SHA256:rotate-clears-cache"
            _ = SpacesMobileDeviceStore.upsert(settings: settings, name: "Mac")
            SpacesMobileDeviceStore.recordActiveHost("10.0.0.5", certificateFingerprint: "SHA256:rotate-clears-cache")
            let resolver = SpacesDeviceEndpointResolver(settings: settings)
            let cachedBeforeFailure = await resolver.currentCachedHost()
            XCTAssertEqual(cachedBeforeFailure, "10.0.0.5", "sanity: seeded from the persisted activeHost at construction")

            await resolver.noteStreamFailed(host: "10.0.0.5")

            let cachedAfterFailure = await resolver.currentCachedHost()
            XCTAssertNil(cachedAfterFailure)
            let nextHost = await resolver.nextStreamHost()
            XCTAssertEqual(nextHost, "100.64.0.5")
        }

        /// A host `noteStreamFailed` marked dead is not permanently disqualified: a later successful
        /// connect on that same address (the racing command-channel `connect(timeout:queue:)`, exercised
        /// here against a genuine pinned-TLS listener) proves the address reachable again just as much as
        /// a stream's own successful dial would, so it must clear the stream-failure evidence too, or
        /// `noteStreamFailed(host:)` would keep reporting the whole device unreachable for an address a
        /// request just proved otherwise. A second, never-dialed candidate makes that observable through
        /// `noteStreamFailed(host:)`'s own return value without needing a direct query: once the proven
        /// host is cleared, re-marking only the other candidate failed can no longer read "every
        /// candidate has failed".
        func testSuccessfulConnectClearsStreamFailedEvidenceForTheProvenHost() async throws {
            let server = try PinnedTLSLoopbackServer()
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1", "192.0.2.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            let firstCandidateProof = await resolver.noteStreamFailed(host: "127.0.0.1")
            XCTAssertFalse(firstCandidateProof, "sanity: the other candidate has not failed yet")
            let beforeProof = await resolver.noteStreamFailed(host: "192.0.2.1")
            XCTAssertTrue(beforeProof, "sanity: both of the device's candidates are now marked stream-failed")

            let resolved = try await resolver.connect(timeout: .seconds(3), queue: .main)
            resolved.connection.cancel()
            XCTAssertEqual(resolved.host, "127.0.0.1")

            // Re-marking the OTHER candidate failed (already true, so this is a no-op on it) reads back
            // whether "127.0.0.1" is still in the failed set: the connect above must have cleared it, so
            // this reports "not every candidate has failed" even though the untouched candidate is still
            // down.
            let afterProof = await resolver.noteStreamFailed(host: "192.0.2.1")
            XCTAssertFalse(afterProof, "a successful connect on the same host is proof it is reachable again")
        }

        // MARK: - sendPinnedPing single deadline

        /// `sendPinnedPing` must spend one end-to-end deadline across connect, send, and read, not a
        /// fresh `timeout` budget reissued to each stage. A connect that succeeds only after consuming
        /// most of `timeout` (`PinnedTLSLoopbackServer(acceptDelay:)`, see its doc comment), paired with
        /// a server that then never answers, is the shape of a half-alive link: the dial finally goes
        /// through, but nothing useful happens after. The bug this guards against handed connect, send,
        /// and read each their own full `timeout`, so a connect that used most of one budget still let
        /// the read that follows burn an entire second one: roughly `connectDelay + timeout` in total.
        /// Honoring a single deadline instead leaves read almost nothing once connect has spent most of
        /// it, so the whole call returns close to one `timeout`. A plain "accepts and never answers"
        /// server with no connect delay cannot distinguish the two: on a fast loopback link connect and
        /// send both finish near-instantly either way, and the read stage alone (which always uses a
        /// full `timeout` to fail, bug or no bug) already stays under any generous multiple of `timeout`.
        /// The connect delay is what makes the pre-fix "fresh budget per stage" behavior actually cost
        /// something extra.
        func testSendPinnedPingHonorsOneEndToEndDeadlineNotAFreshBudgetPerStage() async throws {
            let timeout = Duration.milliseconds(400)
            let acceptDelay = Duration.milliseconds(280)
            let server = try PinnedTLSLoopbackServer(acceptDelay: acceptDelay)
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let backend = SpacesDeviceNetworkBackend(settings: settings)

            let request = SpacesDeviceAPIRequest(command: .ping, authToken: nil, clientApp: nil)
            let start = ContinuousClock.now
            let failure = await backend.sendPinnedPing(request: request, host: "127.0.0.1", timeout: timeout)
            let elapsed = ContinuousClock.now - start

            XCTAssertNotNil(failure, "the server never answers, so the probe must report a failure rather than hang forever")
            // One end-to-end deadline keeps the whole call within about `timeout` (connect ate most of
            // it, so read only gets whatever remained); three independent budgets would add a second,
            // separate `timeout` on top of the connect delay. `1.5x` sits clearly between the two
            // (~1.0x fixed, ~1.7x buggy) with margin on both sides for scheduling jitter.
            XCTAssertLessThan(
                elapsed, timeout + timeout / 2,
                "sendPinnedPing spent more than one end-to-end deadline: \(elapsed) for a \(timeout) timeout plus a \(acceptDelay) connect delay")
        }

        /// Cancelling a pinned ping mid-flight (the caller lost interest before the daemon answered) must
        /// not poison the host it was probing: the probe never learned anything about `host`, so recording
        /// a stream failure for it would distrust a perfectly healthy address, and could even manufacture
        /// a false "every candidate has failed" verdict alongside one genuinely failed candidate.
        ///
        /// The cancellation lands during `resolver.connect` (a long `acceptDelay` holds the TLS handshake
        /// open, well past the short sleep before `pingTask.cancel()`), the harder of the two stages to get
        /// right: `SpacesDeviceEndpointResolver.attempt` catches every failure inside `connect`, including a
        /// cancellation, and reduces it to a bare pin-mismatch bit, so `connect(host:timeout:queue:)`
        /// rethrows a generic `requestFailed` that no longer carries any trace of `CancellationError`. A fix
        /// that only checked `error is CancellationError` would still poison the host here; catching this
        /// gap requires also checking `Task.isCancelled`.
        func testCancellingAPinnedPingDuringConnectRecordsNothingAgainstTheHost() async throws {
            let server = try PinnedTLSLoopbackServer(acceptDelay: .seconds(5))
            let port = try await server.start()
            defer { server.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1", "192.0.2.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = server.certificateFingerprint
            let backend = SpacesDeviceNetworkBackend(settings: settings)

            let request = SpacesDeviceAPIRequest(command: .ping, authToken: nil, clientApp: nil)
            let pingTask = Task {
                await backend.sendPinnedPing(request: request, host: "127.0.0.1", timeout: .seconds(10))
            }
            // Well before the 5s accept delay elapses, so the cancellation is guaranteed to land while the
            // probe is still inside `resolver.connect`, waiting on the handshake.
            try await Task.sleep(for: .milliseconds(150))
            pingTask.cancel()
            _ = await pingTask.value

            // Nothing was recorded against "127.0.0.1": with a second, never-dialed candidate and no
            // cached winner, `nextStreamHost()` still hands out the first host rather than skipping past
            // it, which is what proves the cancelled probe left no stream-failure evidence behind.
            let nextHost = await backend.resolver.nextStreamHost()
            XCTAssertEqual(nextHost, "127.0.0.1", "a probe cancelled mid-connect must not record anything against the host it was probing")
        }

        private func resetDeviceStorePersistedState() {
            for device in SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings()).devices {
                _ = SpacesMobileDeviceStore.remove(deviceID: device.id, fallbackSettings: SpacesMobileConnectionSettings())
            }
            let defaults = UserDefaults.standard
            for key in ["spaces.mobile.paired-devices", "spaces.mobile.active-device-id"] { defaults.removeObject(forKey: key) }
        }
    }

    /// A bare TCP listener with no TLS behind it: stands in for "something answered at the transport
    /// level" so a test can exercise the pin-mismatch path without a real pinned-TLS daemon. Accepts and
    /// immediately parks every incoming connection (never sends a TLS handshake), which is what makes a
    /// pinned-TLS `NWConnection` against it time out rather than succeed or fail outright.
    /// Stands in for everything a live `StreamSubscription` keeps alive. Held only by the event callback
    /// the subscription owns, so its deallocation is a direct read of whether that subscription was
    /// released. `noteEvent` exists so the capture is an unambiguous use rather than a discardable one.
    private final class StreamLifetimeSentinel: @unchecked Sendable {
        private let lock = NSLock()
        private var events = 0

        func noteEvent() { lock.withLock { events += 1 } }
    }

    /// Weak handle to a `StreamLifetimeSentinel`, so a test can observe its deallocation without holding it.
    private final class WeakStreamSentinelBox: @unchecked Sendable { weak var object: StreamLifetimeSentinel? }

    /// Carries the disconnect event's error (and, when relevant, its dial-exhaustion verdict) out of the
    /// stream's main-actor callback to the test, which reads it from its own (non-main) frame once the
    /// expectation has been fulfilled.
    private final class StreamDisconnectErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (any Error)?
        private var storedDialExhaustedAllCandidates = false

        func record(_ error: (any Error)?, dialExhaustedAllCandidates: Bool = false) {
            lock.withLock {
                stored = error
                storedDialExhaustedAllCandidates = dialExhaustedAllCandidates
            }
        }

        func error() -> (any Error)? { lock.withLock { stored } }

        func dialExhaustedAllCandidates() -> Bool { lock.withLock { storedDialExhaustedAllCandidates } }
    }

    /// Counts payloads delivered to the viewer callback, to prove keepalives are not among them.
    private final class StreamEventCounterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0

        func increment() { lock.withLock { stored += 1 } }

        func value() -> Int { lock.withLock { stored } }
    }

    private final class LoopbackConnectionSink: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "spaces.device.api.resolver-test.sink")
        private let lock = NSLock()
        private var acceptedConnections: [NWConnection] = []

        init() throws { listener = try NWListener(using: .tcp) }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                self?.lock.lock()
                self?.acceptedConnections.append(connection)
                self?.lock.unlock()
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = LoopbackConnectionSinkOneShot(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resume.resume(returning: ())
                    case .failed(let error): resume.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            guard let port = listener.port?.rawValue else { throw NSError(domain: "LoopbackConnectionSink", code: 1) }
            return port
        }

        func stop() {
            listener.cancel()
            lock.lock()
            let connections = acceptedConnections
            acceptedConnections.removeAll()
            lock.unlock()
            for connection in connections { connection.cancel() }
        }
    }
#endif
