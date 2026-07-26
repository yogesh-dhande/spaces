#if canImport(UIKit)
    import XCTest
    import Network
    import spacesdevicecore
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
            } catch {
                XCTFail("unexpected error: \(error)")
            }
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
            } catch SpacesDeviceAPIClientError.allCandidatesUnreachable(let hosts) {
                XCTAssertEqual(hosts, ["192.0.2.1", "198.51.100.1"])
            } catch {
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
        /// A bare TCP listener cannot complete a pinned-TLS handshake — there is no certificate to
        /// present — so the loopback candidate cannot actually *win* here; the resolver correctly reports
        /// it as a pin mismatch (a real peer answered at the transport level, but the pinned handshake
        /// never completed), exactly the signal a genuinely re-paired daemon would produce. That is the
        /// one true thing this test can assert without standing up a real pinned-TLS daemon:
        /// `transportAuthenticationFailed` — not `allCandidatesUnreachable`, which would mean the
        /// loopback listener was never reached at all — and that the whole race finishes near the
        /// concurrent budget instead of the sequential one (proving the unreachable first candidate did
        /// not starve the second of a turn).
        func testReachableCandidateGetsATurnDespiteAnUnreachablePreferredCandidate() async throws {
            let listener = try LoopbackConnectionSink()
            let port = try await listener.start()
            defer { listener.stop() }

            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["192.0.2.1", "127.0.0.1"]
            settings.port = Int(port)
            settings.certificateFingerprint = "SHA256:unreachable"
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            let start = ContinuousClock.now
            do {
                _ = try await resolver.connect(timeout: .milliseconds(500), queue: .main)
                XCTFail("expected transportAuthenticationFailed")
            } catch SpacesDeviceAPIClientError.transportAuthenticationFailed {
                // Expected: the loopback candidate answered at the TCP level but never completed the
                // pinned handshake, which is exactly what a real pin mismatch looks like.
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            let elapsed = start.duration(to: .now)
            // Sequential worst case would be roughly two full per-candidate passes (each a ~500ms TLS
            // wait plus a 750ms plain-TCP mismatch probe) — near 2.5s. The 250ms stagger keeps the raced
            // version well under that even though both candidates still have to be probed.
            XCTAssertLessThan(elapsed, .seconds(2))
        }

        /// The common shape of a real pin mismatch: the verify block rejects the certificate outright and
        /// the `NWConnection` fails immediately (an `NWError.tls`-shaped failure), not a timeout. Uses a
        /// genuine pinned-TLS listener (`PinnedTLSLoopbackServer`) with a deliberately wrong
        /// `certificateFingerprint`, so the mismatch is real rather than simulated. Must classify as a pin
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
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            let elapsed = start.duration(to: .now)
            // An immediate certificate rejection must be classified without waiting out the per-candidate
            // timeout budget — that is the whole point of checking
            // `SpacesDeviceAPIAuthentication.isTransportAuthenticationFailure` before falling through to
            // the timeout-plus-plain-TCP-probe path.
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
            let disconnected = expectation(description: "stream disconnected with an error")
            _ = try await backend.openSessionStream(
                request: request, onEvent: { _ in },
                onDisconnect: { error in
                    XCTAssertNotNil(error)
                    disconnected.fulfill()
                })

            await fulfillment(of: [disconnected], timeout: 15)
            let cachedHostAfterFailure = await backend.resolver.currentCachedHost()
            XCTAssertNil(cachedHostAfterFailure)
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
                onDisconnect: { error in
                    XCTAssertNil(error)
                    disconnected.fulfill()
                })
            handle.cancel()

            await fulfillment(of: [disconnected], timeout: 5)
            let cachedHostAfterCleanClose = await backend.resolver.currentCachedHost()
            XCTAssertEqual(cachedHostAfterCleanClose, "127.0.0.1")
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
