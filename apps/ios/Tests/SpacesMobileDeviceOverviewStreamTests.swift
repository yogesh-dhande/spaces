#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// One paired device's fake overview stream: mirrors `DemoDeviceBackend`'s own subscriber bookkeeping
    /// (register on open, push to every subscriber, remove on cancel) so the model's stream lifecycle is
    /// driven the same way a real backend drives it, just without a network. `openError` is one-shot: it
    /// fails exactly the next `open()` call and then clears, so a test can fail a connect once and let the
    /// coordinator's own armed retry redial into a working stream, matching a real transient outage.
    private actor SpacesMobileFakeStreamHub {
        private(set) var openCount = 0
        private(set) var subscriberCount = 0
        private var openError: (any Error)?
        private var overview: SpacesDeviceOverviewPayload
        private var subscribers:
            [UUID: (onOverview: @Sendable (SpacesDeviceOverviewPayload) -> Void, onDisconnect: @Sendable ((any Error)?) -> Void)] = [:]
        /// Every `onOverview` callback `open()` has ever handed out, in call order, retained even after
        /// its subscriber is removed from `subscribers`. Lets a test reach a superseded attempt's own
        /// callback directly (`deliverToAttempt`), simulating a receive-loop line already in flight past
        /// that attempt's `cancel()`, so the hub's own subscriber removal never gets a chance to filter
        /// out a delivery that raced it that closely.
        private var onOverviewCallbacksInOpenOrder: [@Sendable (SpacesDeviceOverviewPayload) -> Void] = []

        init(initialOverview: SpacesDeviceOverviewPayload) { overview = initialOverview }

        /// Fails exactly the next `open()` call with `error`, then clears itself, so a test can fail one
        /// connect attempt and let the coordinator's own armed retry redial into a working stream.
        func setOpenError(_ error: any Error) { openError = error }

        /// Test-only: gates the *first* call to `currentResolvedHostForBrowserRoutes()` on `gate.wait()`,
        /// then clears itself, so a test can hold one stream frame's `applyFetchedOverview` suspended at
        /// its `updateBrowserRoutes` await while a second, newer frame for the same device runs to
        /// completion and publishes first. Every later call (the second frame's own) returns immediately:
        /// only the first frame is meant to be held.
        private var browserRouteGate: SpacesMobileAsyncGate?

        func setBrowserRouteGate(_ gate: SpacesMobileAsyncGate) { browserRouteGate = gate }

        func currentResolvedHostForBrowserRoutes() async -> String? {
            if let browserRouteGate {
                self.browserRouteGate = nil
                await browserRouteGate.wait()
            }
            return nil
        }

        /// Test-only: gates the *first* call to `open()` on `gate.wait()`, then clears itself, so a test
        /// can hold one connect attempt suspended mid-flight while a replacement attempt (superseding it
        /// via a background/foreground cycle) opens and completes. `openError` is still checked after the
        /// gate releases, so the test can set it while the held attempt is suspended and have it apply
        /// only to that attempt's resumed connect, never to the replacement's already-finished one.
        private var openGate: SpacesMobileAsyncGate?

        func setOpenGate(_ gate: SpacesMobileAsyncGate) { openGate = gate }

        func open(onOverview: @escaping @Sendable (SpacesDeviceOverviewPayload) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void)
            async throws -> SpacesDeviceAPIStreamHandle
        {
            if let openGate {
                self.openGate = nil
                await openGate.wait()
            }
            if let openError {
                self.openError = nil
                throw openError
            }
            openCount += 1
            let id = UUID()
            subscribers[id] = (onOverview, onDisconnect)
            subscriberCount = subscribers.count
            onOverviewCallbacksInOpenOrder.append(onOverview)
            onOverview(overview)
            return SpacesDeviceAPIStreamHandle { Task { await self.remove(id: id) } }
        }

        /// Delivers `overview` directly to the `index`-th `open()` call's `onOverview` callback (0 =
        /// first attempt), regardless of whether that attempt's subscriber is still registered.
        /// Test-only: simulates a payload from an attempt already abandoned and cancelled racing a
        /// replacement attempt's own delivery.
        func deliverToAttempt(atIndex index: Int, _ overview: SpacesDeviceOverviewPayload) { onOverviewCallbacksInOpenOrder[index](overview) }

        private func remove(id: UUID) {
            subscribers[id] = nil
            subscriberCount = subscribers.count
        }

        /// Pushes a fresh overview to every open subscriber, mirroring the daemon pushing on its own
        /// database change.
        func push(_ overview: SpacesDeviceOverviewPayload) {
            self.overview = overview
            for subscriber in subscribers.values { subscriber.onOverview(overview) }
        }

        /// Drops the stream out from under every open subscriber, as a real connection dying would.
        func disconnectAll(error: (any Error)?) {
            let toNotify = subscribers.values.map(\.onDisconnect)
            subscribers.removeAll()
            subscriberCount = 0
            for onDisconnect in toNotify { onDisconnect(error) }
        }
    }

    /// A `SpacesDeviceAPIBackend` whose overview stream is driven entirely by a `SpacesMobileFakeStreamHub`.
    /// The request path is unused by the streaming suite except for the compatibility handshake a stream
    /// failure falls back to (`SpacesMobileAppModel.refreshCompatibility`), so `requestHandler` defaults to
    /// a throw and a test only supplies one when it needs to shape that fallback.
    private struct SpacesMobileFakeStreamingBackend: SpacesDeviceAPIBackend {
        let hub: SpacesMobileFakeStreamHub
        var requestHandler: @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse = { _ in
            throw SpacesDeviceAPIClientError.requestFailed("This fake backend has no request transport.")
        }

        func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { SpacesMobileFakeStreamRequestTransport(handler: requestHandler) }

        func openSessionStream(
            request: SpacesDeviceAPIRequest, initialEventTimeout: Duration, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
            onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
        ) async throws -> SpacesDeviceAPIStreamHandle { throw SpacesDeviceAPIClientError.invalidEndpoint }

        func openOverviewStream(
            authToken: String?, clientApp: SpacesDeviceClientApp?, onOverview: @escaping @Sendable (SpacesDeviceOverviewPayload) -> Void,
            onDisconnect: @escaping @Sendable ((any Error)?) -> Void
        ) async throws -> SpacesDeviceAPIStreamHandle { try await hub.open(onOverview: onOverview, onDisconnect: onDisconnect) }

        // Overrides the protocol's default `nil` so a test can gate the `updateBrowserRoutes` await
        // inside `applyFetchedOverview` via `hub.setBrowserRouteGate`; every test that never sets a gate
        // sees the same immediate `nil` the default would have given.
        func currentResolvedHost() async -> String? { await hub.currentResolvedHostForBrowserRoutes() }
    }

    private struct SpacesMobileFakeStreamRequestTransport: SpacesDeviceAPIRequestTransport {
        let handler: @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse
        func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse { try await handler(request) }
        func close() async {}
    }

    /// Holds a fake request open until the test releases it, so a compatibility handshake started by an
    /// old failure can be kept in flight past a newer success landing, deterministically rather than by
    /// a fixed sleep.
    private actor SpacesMobileAsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    /// Lets the delayed-alert test cross `refreshFailureAlertDelay` by advancing time rather than sleeping
    /// past it, matching `SpacesMobileAppModelTests`' own `TestClock`.
    private final class SpacesMobileStreamTestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }
        func advance(by duration: Duration) {
            lock.lock()
            defer { lock.unlock() }
            instant = instant.advanced(by: duration)
        }
    }

    @MainActor final class SpacesMobileDeviceOverviewStreamTests: XCTestCase {
        /// Every literal device id this file's tests use, so `setUp`/`tearDown` can clear each one's
        /// Keychain token deterministically: a token `deviceRecord(id:)` seeds for one test must never
        /// leak into another test (in this file or another) that reuses the same literal id.
        private static let knownDeviceIDs = ["device-1", "device-a", "device-b", "device-no-token"]

        override func setUp() {
            super.setUp()
            for id in Self.knownDeviceIDs { SpacesMobileDeviceStore.deleteAuthTokenForTesting(deviceID: id) }
        }

        override func tearDown() {
            for id in Self.knownDeviceIDs { SpacesMobileDeviceStore.deleteAuthTokenForTesting(deviceID: id) }
            super.tearDown()
        }

        /// A paired device record whose Keychain token this helper also seeds, so
        /// `isDeviceCredentialedForStreaming` reads it as paired the same way a real pairing would.
        /// `testADeviceRecordWithNoStoredTokenGetsNoStreamWhileForeground` builds an uncredentialed
        /// record directly instead, to prove the negative.
        private func deviceRecord(id: String, hosts: [String] = ["127.0.0.1"]) -> SpacesMobilePairedDeviceRecord {
            SpacesMobileDeviceStore.saveAuthTokenForTesting("token-\(id)", deviceID: id)
            return SpacesMobilePairedDeviceRecord(
                id: id, name: id, hosts: hosts, port: 47_847, certificateFingerprint: "fp-\(id)", createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil)
        }

        /// The shared "workspace-feature" fixture, optionally with `status` swapped in for its inline
        /// daemon handshake (the shared `makeOverview()` in `SpacesMobileOverviewFixtures.swift` always
        /// bakes in a compatible one and takes no `daemonStatus` parameter of its own).
        private func overview(daemonStatus status: TerminalServiceDaemonStatus? = nil) -> SpacesDeviceOverviewPayload {
            let base = makeOverview()
            guard let status else { return base }
            return SpacesDeviceOverviewPayload(projects: base.projects, workspaces: base.workspaces, sessions: base.sessions, daemonStatus: status)
        }

        /// Lets a device's stream open and every already-queued push land, without pinning to a fixed
        /// sleep: `openDeviceStream` and the coordinator's own callbacks all hop through `Task { @MainActor
        /// ... }`, so draining the run loop a bounded number of times is what the rest of this file's
        /// async-gate helpers already do (`SpacesMobileAsyncGate` in `SpacesMobileAppModelTests`).
        private func settle() async { for _ in 0..<200 { await Task.yield() } }

        // MARK: - Active device

        func testActiveDeviceStreamFeedsModelOverview() async {
            let first = overview()
            let hub = SpacesMobileFakeStreamHub(initialOverview: first)
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]

            model.startDeviceStreams()
            await settle()

            XCTAssertEqual(model.overview, first, "the daemon pushes the current overview the moment the stream opens")

            let second = makeOverview(workspaces: [makeWorkspace(id: "workspace-second", branch: "second")])
            await hub.push(second)
            await settle()

            XCTAssertEqual(model.overview, second, "a later push lands through the same path a refresh would have")
        }

        // MARK: - Per-device lifecycle

        func testEveryPairedDeviceStreamsWhileForegroundAndClosesOnBackground() async {
            let hubA = SpacesMobileFakeStreamHub(initialOverview: overview())
            let hubB = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let clientA = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hubA))
            let clientB = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hubB))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: clientA, overviewStreamClientsForTesting: ["device-b": clientB])
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceRecord(id: "device-b")]

            model.startDeviceStreams()
            await settle()

            let openCountA = await hubA.openCount
            let openCountB = await hubB.openCount
            XCTAssertEqual(openCountA, 1)
            XCTAssertEqual(openCountB, 1)

            model.stopDeviceStreams()
            await settle()

            let subscriberCountA = await hubA.subscriberCount
            let subscriberCountB = await hubB.subscriberCount
            XCTAssertEqual(subscriberCountA, 0, "backgrounding closes every device's stream, not just the selected one")
            XCTAssertEqual(subscriberCountB, 0)
        }

        func testNonActiveDeviceOverviewDoesNotLeakIntoModelOverview() async {
            let activeOverview = overview()
            let hubA = SpacesMobileFakeStreamHub(initialOverview: activeOverview)
            let hubB = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let clientA = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hubA))
            let clientB = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hubB))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: clientA, overviewStreamClientsForTesting: ["device-b": clientB])
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceRecord(id: "device-b")]
            model.startDeviceStreams()
            await settle()
            XCTAssertEqual(model.overview, activeOverview)

            await hubB.push(makeOverview(workspaces: [makeWorkspace(id: "workspace-b", branch: "b")]))
            await settle()

            XCTAssertEqual(model.overview, activeOverview, "a background device's push must stay off the selected device's published overview")
        }

        func testSwitchingActiveDeviceRepublishesTheNewSelectionsCachedStreamOverview() async {
            let overviewA = overview()
            let overviewB = makeOverview(workspaces: [makeWorkspace(id: "workspace-b", branch: "b")])
            let hubA = SpacesMobileFakeStreamHub(initialOverview: overviewA)
            let hubB = SpacesMobileFakeStreamHub(initialOverview: overviewB)
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let clientA = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hubA))
            let clientB = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hubB))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: clientA, overviewStreamClientsForTesting: ["device-b": clientB])
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceRecord(id: "device-b")]
            model.startDeviceStreams()
            await settle()
            XCTAssertEqual(model.overview, overviewA, "precondition: device-a's stream is already feeding the model")

            // Drives the same path `selectDevice` runs internally after moving `activeDeviceID`; a test
            // cannot call `selectDevice` itself, since it always rebuilds `bridgeClient` against the real
            // network backend with no fake-backend seam.
            model.activeDeviceID = "device-b"
            model.reconcileDeviceStreamsAfterIdentityChange()
            await settle()

            XCTAssertEqual(model.overview, overviewB, "device-b's stream was already open and cached, so the switch republishes it immediately")
        }

        // MARK: - Failure handling

        func testStreamDisconnectThatBurnsTheAlertDelayBeforeFailingSurfacesConnectionError() async {
            let clock = SpacesMobileStreamTestClock()
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            // The failure streak's clock starts when the stream is marked offline; advancing it here,
            // inside the compatibility fallback `handleOverviewFailure` awaits, mirrors
            // `testFailureThatBurnsTheDelayBeforeThrowingSurfacesImmediately`'s "one attempt that already
            // spans the whole delay" case for an explicit refresh.
            let backend = SpacesMobileFakeStreamingBackend(
                hub: hub,
                requestHandler: { _ in
                    clock.advance(by: .milliseconds(60))
                    throw SpacesDeviceAPIClientError.requestFailed("still unreachable")
                })
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, refreshFailureAlertDelay: .milliseconds(50), now: { clock.now })
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()
            XCTAssertNil(model.errorMessage, "sanity: the stream is live before it drops")

            await hub.disconnectAll(error: SpacesDeviceAPIClientError.requestFailed("Socket is not connected"))
            await settle()

            XCTAssertEqual(model.errorMessage, "Socket is not connected", "a stream drop raises the same delayed alert a failed refresh would")
        }

        /// While the stream stays live, a lone refresh failure is suppressed outright, not merely delayed:
        /// the live connection already proves the device reachable, so nothing about a failed fetch is
        /// worth timing. Only the stream's own failure, once the coordinator has moved the device out of
        /// `.live`, starts a run, and that run still waits out its own delay measured from that point, not
        /// from either suppressed refresh failure before it.
        func testALiveStreamSuppressesALoneRefreshFailureButItsOwnDisconnectStillStartsTheRun() async {
            let clock = SpacesMobileStreamTestClock()
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let backend = SpacesMobileFakeStreamingBackend(
                hub: hub, requestHandler: { _ in throw SpacesDeviceAPIClientError.requestFailed("still unreachable") })
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, refreshFailureAlertDelay: .milliseconds(50), now: { clock.now })
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()
            XCTAssertNil(model.errorMessage, "sanity: the stream is live before anything fails")

            await model.refresh()
            XCTAssertNil(model.errorMessage, "a live stream is the authority: a single failed fetch must not be reported")

            // Crossing the delay changes nothing on its own: no run was ever started to time out.
            clock.advance(by: .milliseconds(60))
            await model.refresh()
            XCTAssertNil(model.errorMessage, "still nothing: the stream has not failed, so there is no run to have crossed the delay")

            // The stream itself fails: the coordinator moves the device out of `.live` before this reaches
            // `handleOverviewFailure`, so this is what actually starts the run, dated from this instant
            // rather than from either suppressed refresh failure above.
            await hub.disconnectAll(error: SpacesDeviceAPIClientError.requestFailed("Socket is not connected"))
            await settle()
            XCTAssertNil(model.errorMessage, "the run just started: it has not yet run out its own delay")

            // The device is no longer streaming, so this refresh failure reads and extends the same run;
            // once the delay has elapsed since the disconnect, it surfaces.
            clock.advance(by: .milliseconds(60))
            await model.refresh()
            XCTAssertEqual(
                model.errorMessage, "still unreachable", "the run the disconnect started surfaces once its own delay has passed since that point")
        }

        /// An authentication failure is decided and returned before the `isLive` check ever runs, so a
        /// live stream must not swallow it the way it swallows an ordinary connection failure.
        func testAuthenticationFailureFromARefreshStillRecoversWhileTheStreamIsLive() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let backend = SpacesMobileFakeStreamingBackend(
                hub: hub, requestHandler: { _ in throw SpacesDeviceAPIClientError.requestFailed("Invalid device auth token.", code: .unauthorized) })
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()

            await model.refresh()

            XCTAssertNotNil(model.connectionNotice, "an auth failure still raises recovery even though the stream is live")
            XCTAssertTrue(model.isShowingConnectionSettings)
            XCTAssertNil(model.errorMessage)
        }

        func testIncompatibleOverviewPushedByStreamBlocksTheActiveDevice() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()
            XCTAssertFalse(model.isActiveDeviceBlocked)

            let incompatible = overview(
                daemonStatus: TerminalServiceDaemonStatus(
                    version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                    protocolVersion: SpacesWireProtocol.version + 1))
            await hub.push(incompatible)
            await settle()

            XCTAssertTrue(model.isActiveDeviceBlocked, "an incompatible daemon reported inline on a pushed overview blocks like a refresh would")
            XCTAssertNil(model.overview, "blocked: no stale workspace data behind the update banner")
        }

        func testStreamConnectFailureFallsBackToCompatibilityHandshakeAndBlocksOnAnOldProtocolVersion() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            await hub.setOpenError(SpacesDeviceAPIClientError.requestFailed("dial failed"))
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let staleStatus = TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: 1)
            let backend = SpacesMobileFakeStreamingBackend(
                hub: hub, requestHandler: { _ in SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(staleStatus)) })
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]

            model.startDeviceStreams()
            await settle()

            XCTAssertTrue(model.isActiveDeviceBlocked, "the standalone handshake fallback still reports the old protocol version")
        }

        func testStreamConnectFailureWithAnUnauthorizedShapeRaisesTheSameRecoveryARefreshWould() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            await hub.setOpenError(SpacesDeviceAPIClientError.requestFailed("Invalid device auth token.", code: .unauthorized))
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]

            model.startDeviceStreams()
            await settle()

            XCTAssertNotNil(model.connectionNotice)
            XCTAssertTrue(model.isShowingConnectionSettings)
            XCTAssertNil(model.errorMessage)
        }

        /// The error above (`SpacesDeviceAPIClientError`) is the iOS command channel's own type, already
        /// coded; a real overview stream connect failure surfaces `spacesdevicecore`'s
        /// `SpacesDeviceAPIRequestClientError.requestRejected` instead (`streamDecodeError`), carrying the
        /// daemon's actual rejection text. Proves the production type, not a stand-in, drives the same
        /// recovery.
        func testStreamConnectFailureWithTheProductionRequestClientErrorRaisesTheSameRecovery() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            await hub.setOpenError(
                SpacesDeviceAPIRequestClientError.requestRejected(message: "The device auth token is invalid.", code: .unauthorized))
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]

            model.startDeviceStreams()
            await settle()

            XCTAssertNotNil(model.connectionNotice)
            XCTAssertTrue(model.isShowingConnectionSettings)
            XCTAssertNil(model.errorMessage)
        }

        // MARK: - Retry cadence

        func testSelectedDeviceRedialsOnTheFixedTwoSecondCadenceAfterAConnectFailure() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            await hub.setOpenError(SpacesDeviceAPIClientError.requestFailed("dial failed"))
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]

            model.startDeviceStreams()
            await settle()
            var openCount = await hub.openCount
            XCTAssertEqual(openCount, 0, "the one-shot failure consumed the first attempt without opening")

            // Awaits the coordinator's own armed retry task (real wall-clock ~2s for the selected device,
            // see `RemoteOverviewSubscriptionCoordinator.retryDelayPolicy`) instead of polling under a
            // ceiling: deterministic, at the cost of the suite actually spending that time.
            await model.drainPendingDeviceStreamRetryForTesting()
            await settle()

            openCount = await hub.openCount
            XCTAssertEqual(openCount, 1, "the armed retry redialed, and the one-shot failure had already cleared itself")
        }

        func testSwitchingToADeviceWaitingOutItsRetryBackoffRedialsAtOnce() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            await hub.setOpenError(SpacesDeviceAPIClientError.requestFailed("dial failed"))
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            // `bridgeClient` and the testing override both wrap this same hub, deliberately: the active
            // device always streams through `bridgeClient`, and this direct-mutation switch (the same seam
            // `testSwitchingActiveDeviceRepublishesTheNewSelectionsCachedStreamOverview` uses, not
            // `selectDevice`) never rebuilds it, so device-b's post-switch redial only lands on this hub
            // because both routes already point at it.
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, overviewStreamClientsForTesting: ["device-b": client])
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-b")]

            model.startDeviceStreams()
            await settle()
            var openCount = await hub.openCount
            XCTAssertEqual(openCount, 0, "the one-shot failure consumed the only attempt so far without opening")

            // device-b was not selected when its connect failed, so it is waiting out the coordinator's
            // default backoff (5 s floor), not the 2 s selected-device cadence. Switching to it must reset
            // that backoff and redial now instead of leaving the user with no Connection Error for up to
            // a minute.
            model.activeDeviceID = "device-b"
            model.reconcileDeviceStreamsAfterIdentityChange()
            await settle()

            openCount = await hub.openCount
            XCTAssertEqual(openCount, 1, "the switch reset the armed retry and redialed at once, well under its 5 s floor")
        }

        // MARK: - Attempt identity and delivery staleness

        /// A receive-loop line already in flight past a `cancel()` call can still deliver an abandoned
        /// attempt's payload after its replacement's own payload already landed (here, via a quick
        /// background/foreground cycle, which abandons the first attempt and opens a fresh one for the
        /// same device). `isCurrentAttempt` is what drops it instead of letting it overwrite newer state.
        func testStaleOverviewFromASupersededAttemptDoesNotOvertakeANewerAttemptsPayload() async {
            let overviewA = overview()
            let hub = SpacesMobileFakeStreamHub(initialOverview: overviewA)
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]

            model.startDeviceStreams()
            await settle()
            XCTAssertEqual(model.overview, overviewA, "precondition: the first attempt's stream is live")

            // Abandons the first attempt (its subscriber is cancelled) and opens a fresh second attempt
            // for the same device.
            model.stopDeviceStreams()
            model.startDeviceStreams()
            await settle()

            let overviewB = makeOverview(workspaces: [makeWorkspace(id: "workspace-b", branch: "b")])
            await hub.push(overviewB)
            await settle()
            XCTAssertEqual(model.overview, overviewB, "precondition: the second, current attempt's push landed")

            // The abandoned first attempt's own callback delivers a payload directly (bypassing the hub's
            // subscriber map, which already dropped it), simulating a line already in flight past its
            // `cancel()`.
            let overviewStale = makeOverview(workspaces: [makeWorkspace(id: "workspace-stale", branch: "stale")])
            await hub.deliverToAttempt(atIndex: 0, overviewStale)
            await settle()

            XCTAssertEqual(
                model.overview, overviewB, "a superseded attempt's late payload must not overwrite the current attempt's already-applied overview")
        }

        /// A superseded attempt's own connect failure landing late must read as an abandoned discard,
        /// never as the current attempt's own failure: a nil handle alone cannot tell an abandoned
        /// attempt's late failure apart from the current attempt's, so conflating them would raise a
        /// Connection Error or the re-pair screen over a replacement stream that had already connected and
        /// was already delivering.
        func testASupersededAttemptsLateConnectFailureRaisesNoFailureWhileTheReplacementStreamPublishes() async {
            let overviewA = overview()
            let hub = SpacesMobileFakeStreamHub(initialOverview: overviewA)
            let gate = SpacesMobileAsyncGate()
            await hub.setOpenGate(gate)
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]

            // The first attempt's connect suspends at the gate before it can either succeed or fail.
            model.startDeviceStreams()
            await settle()

            // Background then foreground: abandons the first attempt (still suspended) and opens a fresh
            // second attempt for the same device. The gate was already consumed by the first attempt, so
            // the second connects immediately and delivers.
            model.stopDeviceStreams()
            model.startDeviceStreams()
            await settle()
            XCTAssertEqual(model.overview, overviewA, "precondition: the replacement attempt's own connect already delivered")

            let overviewB = makeOverview(workspaces: [makeWorkspace(id: "workspace-b", branch: "b")])
            await hub.push(overviewB)
            await settle()
            XCTAssertEqual(
                model.overview, overviewB, "precondition: the replacement stream keeps delivering while the first attempt is still pending")

            // Releases the abandoned first attempt's connect, now as a failure, simulating one that
            // finally reached (or gave up on) the remote well after it stopped being wanted.
            await hub.setOpenError(SpacesDeviceAPIClientError.requestFailed("dial failed"))
            await gate.open()
            await settle()

            XCTAssertNil(model.errorMessage, "an abandoned attempt's late connect failure must not raise a Connection Error over a live replacement")
            XCTAssertNil(model.connectionNotice, "an abandoned attempt's late connect failure must not trigger auth recovery over a live replacement")
            XCTAssertFalse(model.isShowingConnectionSettings)
            XCTAssertEqual(model.overview, overviewB, "the replacement attempt's overview must still be showing")
        }

        /// An old failure's compatibility handshake resolving after a newer success already landed and
        /// cleared the streak must not report on top of it. The handshake is held open past the point
        /// where the selected device's armed retry reconnects and succeeds, then released well past the
        /// alert delay; `overviewDeliveryGeneration` is what keeps the stale failure's error message from
        /// surfacing even though the device is already known-good.
        func testStreamFailureHandshakeHeldOpenPastANewerSuccessDoesNotReportAfterwards() async {
            let clock = SpacesMobileStreamTestClock()
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let gate = SpacesMobileAsyncGate()
            let backend = SpacesMobileFakeStreamingBackend(
                hub: hub,
                requestHandler: { _ in
                    await gate.wait()
                    throw SpacesDeviceAPIClientError.requestFailed("still unreachable")
                })
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, refreshFailureAlertDelay: .milliseconds(50), now: { clock.now })
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()
            XCTAssertNil(model.errorMessage, "sanity: the stream is live before it drops")

            // The stream drops; `handleOverviewFailure`'s compatibility fallback starts and blocks on the
            // gate before it can decide anything.
            await hub.disconnectAll(error: SpacesDeviceAPIClientError.requestFailed("Socket is not connected"))
            await settle()
            XCTAssertNil(model.errorMessage, "the old failure has not resolved its handshake yet")

            // The selected device's armed retry (fixed 2 s) reopens the stream, and a fresh push succeeds,
            // landing newer state while the old failure's handshake is still held open.
            await model.drainPendingDeviceStreamRetryForTesting()
            await settle()
            let recovered = makeOverview(workspaces: [makeWorkspace(id: "workspace-recovered", branch: "recovered")])
            await hub.push(recovered)
            await settle()
            XCTAssertEqual(model.overview, recovered, "precondition: the newer push already landed")
            XCTAssertNil(model.errorMessage)

            // Past the alert delay, release the old failure's handshake.
            clock.advance(by: .milliseconds(60))
            await gate.open()
            await settle()

            XCTAssertNil(model.errorMessage, "an old failure must not report after a newer success already landed and cleared the streak")
        }

        /// A stream failure's compatibility fallback can still be in flight when the selected device's own
        /// armed retry reconnects and a fresh push already carries its own inline status, since nothing
        /// cancels the fallback early: it only answers the failure that started it. The fallback failing
        /// afterwards must not clear the `daemonStatus`/`compatibility` that fresher delivery already set.
        func testStreamFailureHandshakeFailingAfterAFreshPushDoesNotClearItsStatus() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let gate = SpacesMobileAsyncGate()
            let backend = SpacesMobileFakeStreamingBackend(
                hub: hub,
                requestHandler: { _ in
                    await gate.wait()
                    throw SpacesDeviceAPIClientError.requestFailed("still unreachable")
                })
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()

            // The stream drops; the compatibility fallback starts and blocks on the gate before it can
            // decide anything.
            await hub.disconnectAll(error: SpacesDeviceAPIClientError.requestFailed("Socket is not connected"))
            await settle()

            // The armed retry reconnects and a fresh push carries its own inline status, landing while the
            // old failure's fallback handshake is still held open.
            await model.drainPendingDeviceStreamRetryForTesting()
            await settle()
            let recoveredStatus = TerminalServiceDaemonStatus(
                version: "2.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                protocolVersion: SpacesWireProtocol.version)
            await hub.push(overview(daemonStatus: recoveredStatus))
            await settle()
            XCTAssertEqual(model.daemonStatus?.version, "2.0.0", "precondition: the fresh push's own status already landed")

            // Releases the old failure's fallback handshake, now as a failure of its own.
            await gate.open()
            await settle()

            XCTAssertEqual(model.daemonStatus?.version, "2.0.0", "the old failure's late fallback must not clear a fresher delivery's status")
            XCTAssertNotNil(model.compatibility, "compatibility must not be cleared alongside daemonStatus")
        }

        /// The same race, but the old failure's fallback handshake resolves with a status of its own
        /// rather than failing outright. A stale, incompatible verdict landing after a fresher, compatible
        /// delivery must not block the device on top of it.
        func testStreamFailureHandshakeSucceedingWithAStaleStatusAfterAFreshPushDoesNotOverwriteIt() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let gate = SpacesMobileAsyncGate()
            let staleStatus = TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: 1)
            let backend = SpacesMobileFakeStreamingBackend(
                hub: hub,
                requestHandler: { _ in
                    await gate.wait()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(staleStatus))
                })
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()

            await hub.disconnectAll(error: SpacesDeviceAPIClientError.requestFailed("Socket is not connected"))
            await settle()

            await model.drainPendingDeviceStreamRetryForTesting()
            await settle()
            let recoveredStatus = TerminalServiceDaemonStatus(
                version: "2.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                protocolVersion: SpacesWireProtocol.version)
            await hub.push(overview(daemonStatus: recoveredStatus))
            await settle()
            XCTAssertEqual(model.daemonStatus?.version, "2.0.0", "precondition: the fresh push's own status already landed")
            XCTAssertFalse(model.isActiveDeviceBlocked, "precondition: the fresh push's status is compatible")

            // Releases the old failure's fallback handshake, now as a success carrying a stale, incompatible status.
            await gate.open()
            await settle()

            XCTAssertEqual(model.daemonStatus?.version, "2.0.0", "the old failure's late fallback must not overwrite a fresher delivery's status")
            XCTAssertFalse(
                model.isActiveDeviceBlocked, "a stale, incompatible verdict must not block a device the fresher delivery already proved compatible")
        }

        // MARK: - Cached overview pruning

        /// `reconcileDeviceStreams()` prunes `deviceOverviews` for every device dropped from the desired
        /// set, not only the ones `outcome.removed` hands back a live client for. A device waiting out an
        /// armed retry (`.waitingToRetry`) returns no client when it is removed, so pruning keyed off
        /// `outcome.removed` alone would leave its stale cached overview behind for a later re-pair under
        /// the same id to republish.
        func testRemovingADeviceWaitingOutItsRetryPrunesItsCachedOverviewSoARePairPublishesNothingStale() async {
            let overviewA = overview()
            let staleOverviewB = makeOverview(workspaces: [makeWorkspace(id: "workspace-stale-b", branch: "stale-b")])
            let hubA = SpacesMobileFakeStreamHub(initialOverview: overviewA)
            let hubB = SpacesMobileFakeStreamHub(initialOverview: staleOverviewB)
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let clientA = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hubA))
            let clientB = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hubB))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: clientA, overviewStreamClientsForTesting: ["device-b": clientB])
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceRecord(id: "device-b")]

            model.startDeviceStreams()
            await settle()
            XCTAssertEqual(model.overview, overviewA, "precondition: device-a is selected and streaming")

            // device-b's stream connected and cached its own overview, just not selected; dropping it
            // arms its retry (default backoff, since it is not the selected device) but leaves that cached
            // overview in place, exactly like a real transient outage would.
            await hubB.disconnectAll(error: SpacesDeviceAPIClientError.requestFailed("dropped"))
            await settle()

            // Unpairing device-b while it is `.waitingToRetry` removes it with no client to cancel
            // (`reconcile`'s removal only reports one for a `.live` subscription), which is exactly the
            // case pruning keyed off `outcome.removed` alone would miss.
            model.pairedDevices = [deviceRecord(id: "device-a")]
            model.reconcileDeviceStreamsAfterIdentityChange()
            await settle()

            // Re-pairing fails its very next connect (one-shot), so this reopen cannot legitimately
            // repopulate the cache before the assertion below.
            await hubB.setOpenError(SpacesDeviceAPIClientError.requestFailed("dial failed"))
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceRecord(id: "device-b")]
            model.reconcileDeviceStreamsAfterIdentityChange()
            await settle()

            // Selecting device-b resets its armed retry and reopens it; fail that connect too, so the
            // switch itself cannot deliver fresh data either.
            await hubB.setOpenError(SpacesDeviceAPIClientError.requestFailed("dial failed"))
            model.activeDeviceID = "device-b"
            model.reconcileDeviceStreamsAfterIdentityChange()
            await settle()

            XCTAssertEqual(
                model.overview, overviewA,
                "device-b's overview from before the remove/re-pair cycle must not republish; only a fresh push from its own stream may")
        }

        // MARK: - Credential gating

        /// A paired record with no stored Keychain token is exactly the shape `SpacesMobileDeviceStore
        /// .settings(from:)` turns into an unpaired client, and the daemon rejects an unpaired
        /// connect's empty token; left in the desired set, the device would redial unauthorized every
        /// retry forever, since the coordinator's backoff only paces a failing connect, it never stops
        /// retrying on its own. `reconcileDeviceStreams()` must exclude it entirely.
        func testADeviceRecordWithNoStoredTokenGetsNoStreamWhileForeground() async {
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            // No token is ever saved for this id (unlike `deviceRecord(id:)`, which seeds one), so
            // `settings(from:)` reads it back unpaired.
            let uncredentialed = SpacesMobilePairedDeviceRecord(
                id: "device-no-token", name: "device-no-token", hosts: ["127.0.0.1"], port: 47_847, certificateFingerprint: "fp-device-no-token",
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil)
            // Both the active device and the uncredentialed one route through the same hub: if the
            // uncredentialed device were (wrongly) opened too, its own `openOverviewStream` call would
            // land on this same hub and bump `openCount` past what the active device alone accounts for.
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, overviewStreamClientsForTesting: ["device-no-token": client])
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-a"), uncredentialed]

            model.startDeviceStreams()
            await settle()

            let openCount = await hub.openCount
            XCTAssertEqual(openCount, 1, "only device-a's own stream opened; the uncredentialed device must never dial at all")
        }

        // MARK: - Per-device client reuse

        /// `overviewStreamClient(forDeviceID:)` caches a non-selected device's client per device id in
        /// `nonActiveDeviceStreamClients` rather than building a fresh `SpacesDeviceAPIClient` (and so a
        /// fresh resolver) on every call, which would throw away whatever that resolver had learned about
        /// which candidate host actually answers: two lookups for the same unchanged record return the
        /// same client, and so the same resolver. Calls the private method directly through a test-only
        /// accessor rather than driving a real reconnect: this is what the client-reuse contract itself
        /// promises, independent of when the coordinator happens to call it.
        func testNonSelectedDeviceReusesTheSameClientAcrossConsecutiveOpenAttempts() {
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(
                settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: SpacesMobileFakeStreamHub(initialOverview: overview())))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceRecord(id: "device-b")]

            let first = model.overviewStreamClientForTesting(deviceID: "device-b")
            let second = model.overviewStreamClientForTesting(deviceID: "device-b")

            let firstIdentity = first?.overviewStreamResolverIdentityForTesting
            XCTAssertNotNil(firstIdentity, "device-b is not overridden, so it must go through the real network backend this fix caches")
            XCTAssertEqual(
                firstIdentity, second?.overviewStreamResolverIdentityForTesting,
                "two consecutive open attempts for a non-selected device must reuse the same client, and so the same resolver's host-rotation state")
        }

        /// A record change (here, a rescan learning a different host) must invalidate the cache: reusing a
        /// client built from the old candidate list would never race the new one.
        func testNonSelectedDeviceCacheRebuildsWhenItsRecordsHostsChange() {
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(
                settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: SpacesMobileFakeStreamHub(initialOverview: overview())))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-a"
            var deviceB = deviceRecord(id: "device-b")
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceB]
            let beforeIdentity = model.overviewStreamClientForTesting(deviceID: "device-b")?.overviewStreamResolverIdentityForTesting

            deviceB.hosts = ["10.0.0.9"]
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceB]
            let afterIdentity = model.overviewStreamClientForTesting(deviceID: "device-b")?.overviewStreamResolverIdentityForTesting

            XCTAssertNotEqual(
                beforeIdentity, afterIdentity, "a changed hosts list must rebuild the cached client, not keep dialing the old candidates")
        }

        // MARK: - Foreground endpoint re-preference

        /// `resetDeviceStreamEndpointsForForeground()` must drop `nonActiveDeviceStreamClients` so a
        /// non-selected device's next stream lookup rebuilds a fresh client, whose resolver in turn
        /// re-seeds from the persisted `activeHost` `SpacesMobileDeviceStore.clearActiveHosts()` (called
        /// first, the same order `RootTabView`'s `.active` branch uses) already cleared. Without either
        /// half the cached client (and its warm-started resolver) survives foregrounding untouched, and
        /// the next connect goes straight back to the previously proven host instead of racing `hosts`
        /// from the top.
        func testForegroundStreamResetRebuildsANonSelectedDevicesClientFromTheTopOfHosts() throws {
            let fingerprint = "fp-device-b-foreground"
            var storedSettings = SpacesMobileConnectionSettings()
            storedSettings.hosts = ["10.0.0.1", "100.64.0.5"]
            storedSettings.port = 47_847
            storedSettings.certificateFingerprint = fingerprint
            storedSettings.authToken = "token-device-b-foreground"
            let persisted = SpacesMobileDeviceStore.upsert(settings: storedSettings, name: "device-b-foreground")
            let deviceB = try XCTUnwrap(persisted.devices.first(where: { $0.certificateFingerprint == fingerprint }))
            defer {
                _ = SpacesMobileDeviceStore.remove(deviceID: deviceB.id, fallbackSettings: SpacesMobileConnectionSettings())
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.paired-devices")
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.active-device-id")
            }
            // Simulates a previous session's stream having proven the Tailscale address the last time
            // this device was away from the LAN; `SpacesDeviceNetworkBackend.init` warm-starts a freshly
            // built resolver from exactly this persisted value.
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: fingerprint)

            var activeSettings = SpacesMobileConnectionSettings()
            activeSettings.authToken = "token"
            activeSettings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(
                settings: activeSettings, backend: SpacesMobileFakeStreamingBackend(hub: SpacesMobileFakeStreamHub(initialOverview: overview())))
            let model = SpacesMobileAppModel(settings: activeSettings, bridgeClient: client)
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceB]

            let firstClient = model.overviewStreamClientForTesting(deviceID: deviceB.id)
            XCTAssertEqual(
                firstClient?.overviewStreamResolverCachedHostForTesting, "100.64.0.5",
                "precondition: the cached client's resolver warm-started from the persisted proven host")

            // Foreground, in the order `RootTabView`'s `.active` branch runs it: clear the persisted store
            // first, then reset the streams.
            SpacesMobileDeviceStore.clearActiveHosts()
            model.resetDeviceStreamEndpointsForForeground()

            let secondClient = model.overviewStreamClientForTesting(deviceID: deviceB.id)
            XCTAssertNotEqual(
                firstClient?.overviewStreamResolverIdentityForTesting, secondClient?.overviewStreamResolverIdentityForTesting,
                "the foreground reset must drop the cached client so the next lookup rebuilds a fresh one")
            XCTAssertNil(
                secondClient?.overviewStreamResolverCachedHostForTesting,
                "the fresh resolver must carry no warm-started winner, since the persisted activeHost it would have seeded from was cleared first")
            XCTAssertEqual(
                secondClient?.overviewStreamResolverNextHostForTesting, "10.0.0.1",
                "with no cached winner, the next connect must walk `hosts` from the top rather than falling back to the previously proven address")
        }

        /// The selected device streams through `bridgeClient`, which the model keeps and reuses for the
        /// whole session rather than rebuilding on foreground, so its `overviewStreamResolver` keeps
        /// whatever it learned in memory regardless of what `clearActiveHosts()` does to the persisted
        /// store. `resetDeviceStreamEndpointsForForeground()` has to clear it directly, and must use
        /// `resetForNetworkChange()` rather than merely `clearCachedWinner()`: a candidate the stream
        /// already reported failed (here, the LAN address while away from it) stays skipped by
        /// `nextStreamHost()` even once its cached winner is forgotten, unless the failed-host set is
        /// cleared too.
        func testForegroundStreamResetForgetsTheSelectedDevicesCachedWinnerAndFailedCandidates() throws {
            let fingerprint = "fp-active-foreground"
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.1", "100.64.0.5"]
            settings.port = 47_847
            settings.certificateFingerprint = fingerprint
            settings.authToken = "token"
            let persisted = SpacesMobileDeviceStore.upsert(settings: settings, name: "device-a-foreground")
            let deviceA = try XCTUnwrap(persisted.devices.first(where: { $0.certificateFingerprint == fingerprint }))
            defer {
                _ = SpacesMobileDeviceStore.remove(deviceID: deviceA.id, fallbackSettings: SpacesMobileConnectionSettings())
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.paired-devices")
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.active-device-id")
            }
            // Simulates the shape a real background/foreground/roam cycle leaves behind: the stream failed
            // on the LAN address while away from it, then proved the tailnet address (warm-started here
            // from the persisted proven host, the same as a real reconnect would learn it).
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: fingerprint)
            let client = SpacesDeviceAPIClient(settings: settings)
            client.noteOverviewStreamFailedForTesting(host: "10.0.0.1")
            XCTAssertEqual(
                client.overviewStreamResolverNextHostForTesting, "100.64.0.5",
                "precondition: the resolver is warm-started onto the tailnet winner with the LAN candidate marked failed")

            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = deviceA.id
            model.pairedDevices = [deviceA]

            model.resetDeviceStreamEndpointsForForeground()

            XCTAssertEqual(
                client.overviewStreamResolverNextHostForTesting, "10.0.0.1",
                "the foreground reset must forget both the cached winner and any candidate a stream previously failed on, so the reopened "
                    + "stream can reach the LAN address again instead of walking straight back to the tailnet winner")
        }

        // MARK: - Advertised-host learning for non-selected devices: proven host without a hosts change

        /// `onProvenHost` -> `reportProvenHost` can persist a non-selected device's newly proven host
        /// without widening `hosts` at all (the address was already a known fallback candidate, not a
        /// freshly daemon-advertised one), so `mergeAdvertisedHosts` alone never notices it and never
        /// triggers `handleDeviceStreamOverview`'s `pairedDevices` reload. `ConnectionSettingsView` reads
        /// `pairedDevices`, not the persisted store directly, so without a reload keyed off the proven host
        /// too, it would keep showing the address this device left the previous connect on.
        func testANonSelectedDevicesStreamProvingADifferentHostReloadsPairedDevicesEvenWithoutHostsChanging() async throws {
            let fingerprint = "fp-device-b-provenhost"
            var storedSettings = SpacesMobileConnectionSettings()
            storedSettings.hosts = ["127.0.0.1", "100.64.0.9"]
            storedSettings.port = 47_847
            storedSettings.certificateFingerprint = fingerprint
            storedSettings.authToken = "token-device-b-provenhost"
            let persisted = SpacesMobileDeviceStore.upsert(settings: storedSettings, name: "device-b-provenhost")
            let deviceB = try XCTUnwrap(persisted.devices.first(where: { $0.certificateFingerprint == fingerprint }))
            defer {
                _ = SpacesMobileDeviceStore.remove(deviceID: deviceB.id, fallbackSettings: SpacesMobileConnectionSettings())
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.paired-devices")
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.active-device-id")
            }

            let hubA = SpacesMobileFakeStreamHub(initialOverview: overview())
            let hubB = SpacesMobileFakeStreamHub(initialOverview: overview())
            var activeSettings = SpacesMobileConnectionSettings()
            activeSettings.authToken = "token"
            activeSettings.certificateFingerprint = "fp-active"
            let clientA = SpacesDeviceAPIClient(settings: activeSettings, backend: SpacesMobileFakeStreamingBackend(hub: hubA))
            let clientB = SpacesDeviceAPIClient(settings: activeSettings, backend: SpacesMobileFakeStreamingBackend(hub: hubB))
            let model = SpacesMobileAppModel(settings: activeSettings, bridgeClient: clientA, overviewStreamClientsForTesting: [deviceB.id: clientB])
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceB]

            model.startDeviceStreams()
            await settle()
            XCTAssertNil(model.pairedDevices.first(where: { $0.id == deviceB.id })?.activeHost, "precondition: no proven host yet")

            // Simulates `onProvenHost` -> `reportProvenHost` already having persisted the stream's new
            // winner by the time this frame's own main-queue delivery runs (see
            // `handleDeviceStreamOverview`'s comment on that ordering guarantee); `deviceAPIAddresses`
            // below deliberately matches the record's already-stored `hosts`, so this push carries no
            // hosts change for `mergeAdvertisedHosts` to notice.
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.9", certificateFingerprint: fingerprint)
            let advertisedStatus = TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                protocolVersion: SpacesWireProtocol.version, deviceAPIAddresses: ["127.0.0.1", "100.64.0.9"])
            await hubB.push(overview(daemonStatus: advertisedStatus))
            await settle()

            XCTAssertEqual(
                model.pairedDevices.first(where: { $0.id == deviceB.id })?.activeHost, "100.64.0.9",
                "a non-selected device's newly proven host must reach the in-memory pairedDevices record on its next overview frame, "
                    + "even when nothing about its hosts list changed")
        }

        // MARK: - Stream-push ordering over a slower fetch

        /// A stream push is the ordered source of truth (the daemon pushes on every change), so a slower,
        /// in-flight `refresh()` completing afterwards with older content must not roll it back even
        /// though both share the same identity and mutation generation.
        func testAStreamPushThatLandsWhileAnOlderRefreshIsInFlightIsNotRolledBackByThatRefresh() async {
            let initial = overview()
            let pushed = makeOverview(workspaces: [makeWorkspace(id: "workspace-pushed", branch: "pushed")])
            let staleFetchResult = makeOverview(workspaces: [makeWorkspace(id: "workspace-stale-fetch", branch: "stale-fetch")])
            let hub = SpacesMobileFakeStreamHub(initialOverview: initial)
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let gate = SpacesMobileAsyncGate()
            let backend = SpacesMobileFakeStreamingBackend(
                hub: hub,
                requestHandler: { _ in
                    await gate.wait()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(staleFetchResult))
                })
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()
            XCTAssertEqual(model.overview, initial, "precondition: the stream's connect-time push already landed")

            // Starts an explicit refresh; its fetch blocks on the gate before it can resolve.
            let refreshTask = Task { await model.refresh() }
            await settle()

            // A stream push lands newer content while the refresh's fetch is still held open.
            await hub.push(pushed)
            await settle()
            XCTAssertEqual(model.overview, pushed, "precondition: the push applied before the slower refresh completed")

            // Release the refresh's fetch: it resolves with content older than what the push already applied.
            await gate.open()
            await refreshTask.value
            await settle()

            XCTAssertEqual(
                model.overview, pushed, "a stream push is the ordered source of truth; a slower fetch must not roll it back with older content")
        }

        // MARK: - Stream frame ordering

        /// Each stream frame applies in its own task, suspended at `applyFetchedOverview`'s
        /// `updateBrowserRoutes` await; a quick burst can let an older frame's task resume after a newer
        /// frame's task already published. Holds the first frame there via the same `SpacesMobileAsyncGate`
        /// technique the slower-refresh test above uses, gating `currentResolvedHost()` (which
        /// `updateBrowserRoutes` awaits) instead of the request path. Each frame carries its own assigned
        /// port, so the browser routing table (not just `model.overview`) can prove which frame's merge
        /// actually ran: `updateBrowserRoutes` itself takes the same `isStillCurrent` check, so a stale
        /// frame's merge must not run at all rather than merely lose the publish race.
        func testAnOlderStreamFrameResumingAfterANewerOnePublishedDoesNotOverwriteIt() async {
            let initial = overview()
            let frame1Workspace = SpacesDeviceWorkspaceSummary(
                id: "workspace-frame-1", projectID: "project-1", projectName: "Project", branch: "frame-1", baseBranch: "main",
                dir: "/repo/workspace-frame-1", isRunning: true, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false,
                assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.frame1.localhost:47847")])
            let frame2Workspace = SpacesDeviceWorkspaceSummary(
                id: "workspace-frame-2", projectID: "project-1", projectName: "Project", branch: "frame-2", baseBranch: "main",
                dir: "/repo/workspace-frame-2", isRunning: true, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false,
                assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.frame2.localhost:47847")])
            let frame1 = makeOverview(workspaces: [frame1Workspace])
            let frame2 = makeOverview(workspaces: [frame2Workspace])
            let hub = SpacesMobileFakeStreamHub(initialOverview: initial)
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()
            XCTAssertEqual(model.overview, initial, "precondition: the stream's connect-time push already landed")

            // Holds frame 1's task at its `updateBrowserRoutes` await; the gate is consumed by this one
            // call, so frame 2's own call below returns immediately instead of also blocking on it.
            let gate = SpacesMobileAsyncGate()
            await hub.setBrowserRouteGate(gate)
            await hub.push(frame1)
            await settle()
            XCTAssertEqual(model.overview, initial, "precondition: frame 1's task is suspended before it can publish")

            // A second, newer frame runs to completion and publishes while frame 1 is still held.
            await hub.push(frame2)
            await settle()
            XCTAssertEqual(model.overview, frame2, "precondition: the newer frame published while the older one was still suspended")

            // Release frame 1; it resumes and must not overwrite frame 2's already-published state.
            await gate.open()
            await settle()

            XCTAssertEqual(model.overview, frame2, "an older frame resuming after a newer one already published must not overwrite it")
            let routes = model.browserRoutingTableForTesting
            XCTAssertNotNil(routes.target(forHost: "web.frame2.localhost"), "frame 2's own route must still be present")
            XCTAssertNil(
                routes.target(forHost: "web.frame1.localhost"),
                "frame 1's merge must not have run at all once it was no longer the latest frame, so it never added its own route")
        }

        /// `hub.push` runs each `onOverview` call from the fake hub's own (non-main) actor executor, the
        /// same as a real stream's receive thread; five frames delivered back-to-back this way, with no
        /// `settle()` between them, exercise the callbacks' main-queue hop under the closest approximation
        /// of receive-thread pressure a test can produce without an actual data race. Executor reordering
        /// itself cannot be forced deterministically, so this passes whether or not the callbacks hop
        /// through the main queue; it documents the intended outcome (the model ends on the last frame
        /// delivered) rather than proving the fix.
        func testABurstOfStreamFramesEndsOnTheLastOneDelivered() async {
            let initial = overview()
            let hub = SpacesMobileFakeStreamHub(initialOverview: initial)
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]
            model.startDeviceStreams()
            await settle()

            let frames = (1...5).map { makeOverview(workspaces: [makeWorkspace(id: "workspace-burst-\($0)", branch: "burst-\($0)")]) }
            for frame in frames { await hub.push(frame) }
            await settle()

            XCTAssertEqual(model.overview, frames.last, "a back-to-back burst must end on the last frame delivered, not an earlier one")
        }

        // MARK: - Cached republish must not invalidate a fresher refresh

        /// A cached republish (`republishCachedStreamOverviewIfSelected`, e.g. on a device switch) and an
        /// explicit `refresh()` can both be in flight at once. Held at the browser-route await, the
        /// republish resumes and publishes its (older, cached) content first, while the refresh's own
        /// request is still held open. The republish must never be the one that advances
        /// `overviewDeliveryGeneration`: if it were, publishing there would move the refresh's own captured
        /// generation out from under it, so it no longer matched by the time its request finally returned,
        /// and its genuinely newer content would be discarded as stale.
        func testACachedRepublishNeverInvalidatesAFresherRefresh() async {
            let overviewOld = overview()
            let hub = SpacesMobileFakeStreamHub(initialOverview: overviewOld)

            let overviewNew = makeOverview(workspaces: [makeWorkspace(id: "workspace-new", branch: "new")])
            let requestGate = SpacesMobileAsyncGate()
            let backend = SpacesMobileFakeStreamingBackend(
                hub: hub,
                requestHandler: { _ in
                    await requestGate.wait()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewNew))
                })
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "fp-active"
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [deviceRecord(id: "device-1")]

            model.startDeviceStreams()
            await settle()
            XCTAssertEqual(model.overview, overviewOld, "precondition: the stream delivered the cached overview")

            // The gate is set only now, after the connect-time push already used the hub's first,
            // ungated browser-route call: it must hold the republish below, not the initial connect.
            let browserRouteGate = SpacesMobileAsyncGate()
            await hub.setBrowserRouteGate(browserRouteGate)

            // A device switch's republish: held at the browser-route await before it can publish.
            model.reconcileDeviceStreamsAfterIdentityChange()
            await settle()

            // An explicit refresh starts concurrently; its own request is held so it completes only after
            // the republish below has already resumed and published.
            let refreshTask = Task { await model.refresh() }
            await settle()

            // Releases the republish: it publishes the older, cached content and must not be the one that
            // advances the delivery generation.
            await browserRouteGate.open()
            await settle()

            // Releases the refresh's request: it completes with genuinely newer content.
            await requestGate.open()
            await refreshTask.value
            await settle()

            XCTAssertEqual(
                model.overview, overviewNew, "a cached republish must never invalidate a fresher refresh that started while it was suspended")
        }

        // MARK: - Advertised-host learning for non-selected devices

        /// `handleDeviceStreamOverview` merges a non-selected device's advertised hosts too, not only the
        /// selected device's own merge inside `applyFetchedOverview`. Persists the device via
        /// `SpacesMobileDeviceStore.upsert` first (unlike `deviceRecord(id:)`, which never writes to the
        /// on-disk store `mergeAdvertisedHosts` reads by certificate fingerprint), so the merge finds a
        /// real row to update.
        func testANonSelectedDevicesPushAdvertisingANewAddressPersistsIntoItsRecord() async throws {
            let fingerprint = "fp-device-b-item3"
            var storedSettings = SpacesMobileConnectionSettings()
            storedSettings.hosts = ["127.0.0.1"]
            storedSettings.port = 47_847
            storedSettings.certificateFingerprint = fingerprint
            storedSettings.authToken = "token-device-b-item3"
            let persisted = SpacesMobileDeviceStore.upsert(settings: storedSettings, name: "device-b")
            let deviceB = try XCTUnwrap(persisted.devices.first(where: { $0.certificateFingerprint == fingerprint }))
            // This is the only test in the file that persists a real record (`mergeAdvertisedHosts` reads
            // the on-disk store directly), so it must undo that itself: `remove` alone is not enough,
            // since `upsert` above also wrote `activeDeviceKey`, which every other test in this process
            // assumes is untouched.
            defer {
                _ = SpacesMobileDeviceStore.remove(deviceID: deviceB.id, fallbackSettings: SpacesMobileConnectionSettings())
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.paired-devices")
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.active-device-id")
            }

            let hubA = SpacesMobileFakeStreamHub(initialOverview: overview())
            let hubB = SpacesMobileFakeStreamHub(initialOverview: overview())
            var activeSettings = SpacesMobileConnectionSettings()
            activeSettings.authToken = "token"
            activeSettings.certificateFingerprint = "fp-active"
            let clientA = SpacesDeviceAPIClient(settings: activeSettings, backend: SpacesMobileFakeStreamingBackend(hub: hubA))
            let clientB = SpacesDeviceAPIClient(settings: activeSettings, backend: SpacesMobileFakeStreamingBackend(hub: hubB))
            let model = SpacesMobileAppModel(settings: activeSettings, bridgeClient: clientA, overviewStreamClientsForTesting: [deviceB.id: clientB])
            model.activeDeviceID = "device-a"
            model.pairedDevices = [deviceRecord(id: "device-a"), deviceB]

            model.startDeviceStreams()
            await settle()

            let advertisedStatus = TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                protocolVersion: SpacesWireProtocol.version, deviceAPIAddresses: ["127.0.0.1", "100.64.0.9"])
            await hubB.push(overview(daemonStatus: advertisedStatus))
            await settle()

            let reloaded = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())
            XCTAssertEqual(
                reloaded.devices.first(where: { $0.id == deviceB.id })?.hosts, ["127.0.0.1", "100.64.0.9"],
                "device-b was not selected, but its push must still persist the address its own daemon advertised")
            // `mergeAdvertisedHosts` only touches the persisted store; without reloading `pairedDevices`
            // too, the in-memory record stays stale and the next client built for this device
            // (`overviewStreamClient(forDeviceID:)`, keyed off `pairedDevices`) would still be built from
            // the old hosts list even though the cached client above was dropped.
            XCTAssertEqual(
                model.pairedDevices.first(where: { $0.id == deviceB.id })?.hosts, ["127.0.0.1", "100.64.0.9"],
                "the in-memory pairedDevices record must reload too, or the next reconnect rebuilds its client from the stale hosts list")
        }

        // MARK: - Re-pairing the selected device replaces its stream attempt

        /// `applyConnectionSettings` can re-pair the already-selected device: `SpacesMobileDeviceStore.upsert`
        /// matches by certificate fingerprint, so a rescanned QR code for a device already paired reuses its
        /// id with a new token and a new `bridgeClient`. The old client's connect attempt must not stay
        /// tracked as current when that happens: its late failure, arriving after the re-pair already
        /// replaced it, must not reopen re-pair recovery over a pairing that just succeeded.
        ///
        /// `applyConnectionSettings` always rebuilds `bridgeClient` from the default network backend, so
        /// the replacement attempt itself cannot be driven with a fake here. This drives the real function
        /// directly (the same seam `testDeviceSwitchDuringADeferredDeleteClearsItWithoutSurfacingAnError`
        /// uses) and proves the fix through the old attempt's late failure landing inert, holding it
        /// suspended at its connect the same way `testASupersededAttemptsLateConnectFailureRaisesNoFailureWhileTheReplacementStreamPublishes`
        /// does for a background/foreground supersession, rather than by observing the new (unfaked, real)
        /// attempt's own outcome.
        func testRePairingTheSelectedDeviceAbandonsItsOldAttemptsLateFailure() async throws {
            let fingerprint = "fp-repair-test"
            var oldSettings = SpacesMobileConnectionSettings()
            oldSettings.hosts = ["127.0.0.1"]
            oldSettings.port = 19_191
            oldSettings.certificateFingerprint = fingerprint
            oldSettings.authToken = "token-old"
            let hub = SpacesMobileFakeStreamHub(initialOverview: overview())
            let gate = SpacesMobileAsyncGate()
            await hub.setOpenGate(gate)
            let seeded = SpacesMobileDeviceStore.upsert(settings: oldSettings, name: "device-repair")
            let deviceID = try XCTUnwrap(seeded.devices.first(where: { $0.certificateFingerprint == fingerprint })?.id)
            defer {
                _ = SpacesMobileDeviceStore.remove(deviceID: deviceID, fallbackSettings: SpacesMobileConnectionSettings())
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.paired-devices")
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.active-device-id")
            }
            let client = SpacesDeviceAPIClient(settings: oldSettings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: oldSettings, bridgeClient: client)
            model.activeDeviceID = deviceID
            model.pairedDevices = seeded.devices

            // The old client's connect suspends at the gate before it can either succeed or fail.
            model.startDeviceStreams()
            await settle()

            var newSettings = oldSettings
            newSettings.authToken = "token-new"
            model.applyConnectionSettings(newSettings, deviceName: "device-repair")
            await settle()
            XCTAssertEqual(model.activeDeviceID, deviceID, "precondition: the re-pair reuses the same device id")

            // Releases the abandoned old attempt's connect, now as an unauthorized failure, simulating a
            // retired token finally being rejected well after the re-pair already replaced it with a new one.
            await hub.setOpenError(SpacesDeviceAPIClientError.requestFailed("Invalid device auth token.", code: .unauthorized))
            await gate.open()
            await settle()

            XCTAssertNil(model.connectionNotice, "the old attempt's late failure must not reopen re-pair recovery")
            XCTAssertFalse(model.isShowingConnectionSettings)
            XCTAssertNil(model.errorMessage)
        }

        /// A re-pair of the selected device must not republish whatever its old, now-invalid credentials
        /// last delivered: that payload can be arbitrarily stale (a re-pair usually follows a revoked or
        /// failed token), and left cached it would surface again through
        /// `reconcileDeviceStreamsAfterIdentityChange`'s own republish, showing stale rows until the new
        /// stream's first push (or indefinitely, if the new connection cannot connect) and merging its
        /// advertised addresses back into the persisted hosts.
        func testRePairingTheSelectedDeviceDropsItsCachedOverview() async throws {
            let fingerprint = "fp-repair-cache-test"
            var oldSettings = SpacesMobileConnectionSettings()
            oldSettings.hosts = ["127.0.0.1"]
            oldSettings.port = 19_192
            oldSettings.certificateFingerprint = fingerprint
            oldSettings.authToken = "token-old"
            let staleOverview = makeOverview(workspaces: [makeWorkspace(id: "workspace-stale-repair", branch: "stale")])
            let hub = SpacesMobileFakeStreamHub(initialOverview: staleOverview)
            let seeded = SpacesMobileDeviceStore.upsert(settings: oldSettings, name: "device-repair-cache")
            let deviceID = try XCTUnwrap(seeded.devices.first(where: { $0.certificateFingerprint == fingerprint })?.id)
            defer {
                _ = SpacesMobileDeviceStore.remove(deviceID: deviceID, fallbackSettings: SpacesMobileConnectionSettings())
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.paired-devices")
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.active-device-id")
            }
            let client = SpacesDeviceAPIClient(settings: oldSettings, backend: SpacesMobileFakeStreamingBackend(hub: hub))
            let model = SpacesMobileAppModel(settings: oldSettings, bridgeClient: client)
            model.activeDeviceID = deviceID
            model.pairedDevices = seeded.devices

            model.startDeviceStreams()
            await settle()
            XCTAssertEqual(model.overview, staleOverview, "precondition: the old stream delivered its payload")
            XCTAssertEqual(model.deviceOverviewForTesting(deviceID: deviceID), staleOverview, "precondition: the delivery is cached too")

            var newSettings = oldSettings
            newSettings.authToken = "token-new"
            model.applyConnectionSettings(newSettings, deviceName: "device-repair-cache")
            await settle()

            XCTAssertNil(model.overview, "the old payload must not be republished under the new pairing")
            XCTAssertNil(model.deviceOverviewForTesting(deviceID: deviceID), "the cache must be dropped, not just the published overview")
        }
    }
#endif
