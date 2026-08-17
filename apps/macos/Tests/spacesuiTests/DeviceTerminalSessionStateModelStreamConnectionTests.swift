import Foundation
import XCTest
import spacesclientcore
import spacesterminalcore

@testable import spacesdeviceapi
// Testable for `SpacesDeviceAPIRequestSessionClient.openedConnectionCountForTesting`, which is how the
// corroboration-probe test proves the probe never dials through the shared session client.
@testable import spacesdevicecore
@testable import spacesui

/// Guards how a device-backed session publishes the health of its state subscription.
///
/// A pane survives its device going away — pruning is gated on an authoritative overview — so during
/// an outage it keeps a frozen render that looks live. The model is the only place that knows the
/// stream is gone, and it deliberately does not tell its listeners (the render host would re-register
/// and pile up duplicate listeners on the one shared subscription), so it publishes the drop as
/// observable state plus a session-scoped notification instead. These tests pin that contract: the
/// flag flips, the notification carries the session, and a superseded stream cannot flip it.
///
/// The model is also fed the other evidence about the link — a terminal input send that failed — since
/// input rides its own connection and fails long before a dead subscription is noticed. Which failures
/// count is pinned here too, because reporting a reachable daemon's rejection as a lost link would put a
/// false notice on the pane and dial a device that is answering.
///
/// The model is driven through its install-for-testing seam rather than a real connect: the concrete
/// stream client offers no way to force callback orderings, and installing a client first also keeps
/// listener registration from dialing the network at all (`ensureSubscriptionStarted` returns early
/// while a stream is installed), which keeps the suite hermetic.
///
/// XCTest (serial within the class), matching `DeviceTerminalSessionStateModelRecoveryTests`. Two tests
/// below drive a real in-process `SpacesDeviceAPIServer`, which re-resolves `SPACES_DB_PATH`/
/// `SPACES_RUNTIME_DIR` from the process environment at request time — the same reason
/// `DeviceTerminalSessionStateModelRecoveryTests` stays XCTest rather than Swift Testing.
final class DeviceTerminalSessionStateModelStreamConnectionTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var profileRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profileRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        if let profileRoot { try? FileManager.default.removeItem(at: profileRoot) }
        try super.tearDownWithError()
    }

    @MainActor func testDroppedStreamPublishesDisconnectedStateAndNotifiesForTheSession() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        var notifiedSessionIDs: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalStateStreamConnectionDidChange, object: nil, queue: .main) {
            notification in
            let notifiedSessionID = TerminalSessionNotification.sessionID(from: notification)
            MainActor.assumeIsolated { notifiedSessionIDs.append(notifiedSessionID ?? "") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // A pane's render host is attached, and the stream it is fed by drops.
        let client = FakeStreamClient()
        let generation = model.installStreamClientForTesting(client)
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        XCTAssertFalse(model.isStateStreamDisconnected)

        model.handleStreamDisconnect(nil, generation: generation)

        XCTAssertTrue(model.isStateStreamDisconnected, "a dropped stream must be observable, or the pane has nothing to report")
        XCTAssertEqual(notifiedSessionIDs, [sessionID])
    }

    /// The flip is published on change only: a device that stays down retries for the whole outage,
    /// and a notification per retry would wake every observing pane into a full refresh for a fact
    /// that has not moved.
    @MainActor func testRepeatedDropsNotifyOnlyOnTheFlip() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalStateStreamConnectionDidChange, object: nil, queue: .main) {
            _ in MainActor.assumeIsolated { notificationCount += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        for _ in 0..<3 {
            let generation = model.installStreamClientForTesting(FakeStreamClient())
            model.handleStreamDisconnect(nil, generation: generation)
        }

        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertEqual(notificationCount, 1)
    }

    /// A superseded client's late disconnect says nothing about the stream that replaced it, so it
    /// must not put the pane's disconnected notice up over a healthy link.
    @MainActor func testSupersededStreamDisconnectDoesNotReportTheLinkAsDown() throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        let staleGeneration = model.installStreamClientForTesting(FakeStreamClient())
        _ = model.installStreamClientForTesting(FakeStreamClient())

        model.handleStreamDisconnect(nil, generation: staleGeneration)

        XCTAssertFalse(model.isStateStreamDisconnected)
    }

    /// An ended session is not streamable — the daemon refuses to subscribe to one — so its dropped
    /// stream is the expected answer, not an outage. Reporting it would replace the notice that
    /// explains why the pane is read-only with one implying the session might come back.
    @MainActor func testEndedSessionsDroppedStreamIsNotReportedAsDisconnected() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))
        let generation = model.installStreamClientForTesting(FakeStreamClient())

        model.handleStreamDisconnect(nil, generation: generation)

        XCTAssertFalse(model.isStateStreamDisconnected)
    }

    /// Input rides a different connection than the state subscription, so a send that cannot reach the
    /// device is the earliest evidence the link is gone: a silently dead network path leaves the
    /// subscription's socket looking healthy until TCP keepalive gives up a minute or more later, while the
    /// very next keystroke fails at once. That evidence must reach the same link state the pane reads, and
    /// must drop the subscription so the paced reconnect either clears the notice or proves it right.
    @MainActor func testAFailedInputSendReportsTheLostLinkBeforeTheSubscriptionNotices() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        var notifiedSessionIDs: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalStateStreamConnectionDidChange, object: nil, queue: .main) {
            notification in
            let notifiedSessionID = TerminalSessionNotification.sessionID(from: notification)
            MainActor.assumeIsolated { notifiedSessionIDs.append(notifiedSessionID ?? "") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        // A reachable daemon that refuses the send answered, so the link is fine: reporting it would put a
        // false notice on the pane and dial a device that is responding.
        model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.requestRejected(message: "Session is not running.", code: .sessionNotAvailable))
        XCTAssertFalse(model.isStateStreamDisconnected)
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "a coded rejection must not tear down a healthy subscription")

        // The request never arrived: the link is down, and the subscription it shares a device with is dead
        // whatever its socket still looks like.
        model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused"))
        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertFalse(model.hasActiveStreamClientForTesting)
        XCTAssertEqual(notifiedSessionIDs, [sessionID])

        // Typing produces one failure per keystroke for the whole outage; a link already reported down has
        // a retry armed, so re-reporting it must add no notice and no reconnect.
        model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out."))
        XCTAssertEqual(notifiedSessionIDs, [sessionID])
    }

    /// An ended session wants no stream at all, so a failed send against one reports no outage: its pane
    /// already carries the read-only notice, and replacing it with a reconnecting one would imply the
    /// process might come back.
    @MainActor func testAFailedInputSendOnAnEndedSessionReportsNoOutage() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))

        model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused"))

        XCTAssertFalse(model.isStateStreamDisconnected)
    }

    /// Which failures are evidence about the link at all. Only a transport failure is: the request never
    /// reached the daemon. Every coded rejection means a reachable daemon answered — and the render host
    /// flattens a rejection into an opaque message-carrying error before it reaches here, so the rule holds
    /// by type rather than by matching that message.
    @MainActor func testOnlyATransportFailureIsEvidenceTheLinkIsGone() {
        typealias Model = DeviceTerminalSessionStateModel
        XCTAssertTrue(Model.isTransportFailureEvidenceOfLostLink(SpacesDeviceAPIRequestClientError.timeout("Timed out.")))
        XCTAssertTrue(Model.isTransportFailureEvidenceOfLostLink(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))
        XCTAssertTrue(Model.isTransportFailureEvidenceOfLostLink(SpacesDeviceAPIRequestClientError.emptyResponse))
        XCTAssertTrue(Model.isTransportFailureEvidenceOfLostLink(SpacesPinnedTLSConnectionError.connectionClosed))
        XCTAssertTrue(Model.isTransportFailureEvidenceOfLostLink(POSIXError(.ECONNRESET)))

        // The daemon answered: the session is gone, this client is not the owner, or its token was revoked.
        XCTAssertFalse(
            Model.isTransportFailureEvidenceOfLostLink(
                SpacesDeviceAPIRequestClientError.requestRejected(message: "Session is not running.", code: .sessionNotAvailable)))
        XCTAssertFalse(
            Model.isTransportFailureEvidenceOfLostLink(
                SpacesDeviceAPIRequestClientError.requestRejected(message: "Unauthorized.", code: .unauthorized)))
        XCTAssertFalse(
            Model.isTransportFailureEvidenceOfLostLink(
                NSError(
                    domain: "RemoteGhosttySessionHost", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Only the active owner can send terminal input."])))
        // A pin mismatch is a reachable daemon presenting the wrong identity, which no reconnect fixes.
        XCTAssertFalse(
            Model.isTransportFailureEvidenceOfLostLink(TerminalServiceTLSError.certificatePinMismatch(expected: "SHA256:aa", actual: "SHA256:bb")))
    }

    /// The race: a keystroke fails while a connect is in flight, `reportFailedInputSend`'s retry is
    /// dropped by `ensureSubscriptionStarted`'s in-flight guard because the original connect is still
    /// running, and that connect then finishes reporting success (`start()` can return true even for a
    /// client that was concurrently stopped — stopping it does not abort a low-level connect already past
    /// that point) while `streamClient` is still nil. Before the fix nothing is left to retry: the pane
    /// stays connected to nothing until it is reopened or the app restarts. Drives a real in-process
    /// `SpacesDeviceAPIServer` so the retry's own connect, once armed, actually reconnects — proving
    /// recovery, not just that a flag got set — and controls the first connect's resolution through
    /// `stateStreamConnectOverrideForTesting` so the race is reproduced deterministically instead of
    /// racing real network timing.
    ///
    /// The session is registered as genuinely live (`startLiveSession`) so the retry's subscribe is
    /// ACCEPTED. An unregistered session's subscribe is rejected asynchronously by the server after
    /// `start()` has returned, and that rejection reaches `handleStreamDisconnect` at an unpredictable
    /// moment — on a loaded runner, before these assertions rather than after, which is issue #406.
    @MainActor func testAFailedInputSendDuringAnInFlightConnectStillArmsAReconnectAndRecovers() async throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedStreamConnectionPairingStore()
        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let sessionID = "session-\(UUID().uuidString)"
        let subscriptionServer = try startLiveSession(sessionID: sessionID)
        defer { subscriptionServer.stop() }
        let device = SpacesPairedDeviceRecord(
            id: "remote-\(UUID().uuidString)", name: "Remote", platform: "linux", hosts: ["127.0.0.1"], port: server.listeningPort,
            certificateFingerprint: identity.certificateFingerprint, createdAt: "2026-07-24T00:00:00Z", updatedAt: "2026-07-24T00:00:00Z",
            lastSelectedAt: "2026-07-24T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: device, sessionID: sessionID,
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-24T00:00:00Z",
                workspaceID: "workspace", kind: .shell),
            clientApp: SpacesDeviceClientApp(
                installationID: "INSTALLATION-RACE-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))
        model.reconnectBackoff.retryDelay = .milliseconds(5)
        model.reconnectBackoff.maxRetryDelay = .milliseconds(5)
        model.reconnectBackoff.retryJitterFraction = { 0 }

        // Fires once for the initial connect `startStateStream` triggers, and again when the retry
        // `reportFailedInputSend` arms below actually runs (and is eaten by the in-flight guard, since
        // the controlled connect below is still pending at that point). Awaiting a second fulfillment
        // proves that retry ran its course for real, instead of guessing how long a real delay takes.
        let ensureSubscriptionStartedInvoked = expectation(description: "ensureSubscriptionStarted ran for the initial connect and the eaten retry")
        ensureSubscriptionStartedInvoked.expectedFulfillmentCount = 2
        model.ensureSubscriptionStartedInvokedForTesting = { ensureSubscriptionStartedInvoked.fulfill() }

        // Holds the first connect open until the test resumes it, reproducing `streamClient` being
        // cleared while that connect is still in flight without racing real network timing.
        let reachedConnect = expectation(description: "the first connect reached the controlled resolution point")
        var resumeConnect: ((Bool) -> Void)?
        model.stateStreamConnectOverrideForTesting = { [weak model] in
            await withCheckedContinuation { continuation in
                resumeConnect = { continuation.resume(returning: $0) }
                // Only the first connect is controlled; the retry this test drives afterward must reach
                // the real server so recovery can be observed, not just that a retry got armed.
                model?.stateStreamConnectOverrideForTesting = nil
                reachedConnect.fulfill()
            }
        }

        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        await fulfillment(of: [reachedConnect], timeout: 5)
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "the stream client must be installed before its blocking connect resolves")

        // A keystroke fails while the connect above is still in flight: the model's own evidence the
        // link is down, arriving before the subscription itself would notice.
        model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused"))
        XCTAssertFalse(model.hasActiveStreamClientForTesting, "the failed send must clear the stream client immediately")

        // Let the retry the failed send armed actually fire — and be dropped by the in-flight guard,
        // because the connect above is still running. This is the exact ordering the bug depends on.
        await fulfillment(of: [ensureSubscriptionStartedInvoked], timeout: 5)
        // Detach the hook now that both fulfillments it needs have landed: the retry the armed reconnect
        // below fires calls `ensureSubscriptionStarted` too, and firing into an already-satisfied
        // expectation crashes XCTest's bookkeeping instead of just failing the assertion.
        model.ensureSubscriptionStartedInvokedForTesting = nil
        XCTAssertFalse(model.hasArmedReconnectForTesting, "the eaten retry must have cleared its own armed state")

        // Resolve the connect as successful now that the client backing it has already been cleared and
        // its own retry already spent.
        resumeConnect?(true)
        await model.drainPendingConnectForTesting()

        XCTAssertTrue(model.hasArmedReconnectForTesting, "a connect that finished without installing a client must leave a retry armed")

        // Let the armed retry run its course against the real server; it must actually reconnect.
        await model.drainPendingReconnectForTesting()
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "the armed retry must reconnect the session")
        XCTAssertFalse(model.isStateStreamDisconnected, "a successful reconnect must clear the disconnected notice")
    }

    /// `establishStateStreamConnection`'s own failure path (a connect that reports failure) already calls
    /// `scheduleReconnect()` before returning; the connect-completion check in `ensureSubscriptionStarted`
    /// then finds `streamClient` still nil and calls it again. Without idempotency this doubles the
    /// backoff on top of the retry already armed; asserting the armed delay stays at the floor proves
    /// only one of the two calls actually armed anything.
    ///
    /// Drives a real, reachable in-process `SpacesDeviceAPIServer` — not an unreachable port — because
    /// `ensureSubscriptionStarted` unconditionally fires the catch-up `.state` request first, on a
    /// separate request client `stateStreamConnectOverrideForTesting` does not reach; against an
    /// unreachable device that catch-up blocks for the request client's own connect timeout, which is not
    /// guaranteed to be fast. The session is registered as genuinely live (`startLiveSession`) so that
    /// catch-up is served from its subscription socket and answers at once, rather than failing on a
    /// session the server knows nothing about. Only the stream connect itself is made to fail,
    /// deterministically, through the override.
    ///
    /// The armed delay is the assertion, so the retry must not have fired by the time it is read: the
    /// backoff floor is set far beyond the test's own runtime, which makes the armed value the one the
    /// single `scheduleReconnect` computed rather than whatever a retry that already ran re-armed.
    @MainActor func testScheduleReconnectDoesNotStackConcurrentRetries() async throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedStreamConnectionPairingStore()
        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let sessionID = "session-\(UUID().uuidString)"
        let subscriptionServer = try startLiveSession(sessionID: sessionID)
        defer { subscriptionServer.stop() }
        let device = SpacesPairedDeviceRecord(
            id: "remote-\(UUID().uuidString)", name: "Remote", platform: "linux", hosts: ["127.0.0.1"], port: server.listeningPort,
            certificateFingerprint: identity.certificateFingerprint, createdAt: "2026-07-24T00:00:00Z", updatedAt: "2026-07-24T00:00:00Z",
            lastSelectedAt: "2026-07-24T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: device, sessionID: sessionID,
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-24T00:00:00Z",
                workspaceID: "workspace", kind: .shell),
            clientApp: SpacesDeviceClientApp(
                installationID: "INSTALLATION-STACK-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(3600)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        model.stateStreamConnectOverrideForTesting = { false }

        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        await model.drainPendingConnectForTesting()

        XCTAssertTrue(model.hasArmedReconnectForTesting, "the failed connect must arm a retry")
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .seconds(600),
            "a second, redundant scheduleReconnect() call must not recompute the backoff and double the armed delay")
    }

    /// `reportFailedInputSend`'s return value is the `RemoteGhosttyInputFailureHandler` contract: whether
    /// this particular failure proves the link is gone, not whether the call did fresh work. A reachable
    /// daemon's coded rejection must answer false (nothing to drop). The first transport failure of an
    /// outage does fresh work (tears the stream down) and must answer true. A second transport failure
    /// during the same outage does no fresh work — a retry is already armed — but the link is still gone,
    /// so it must still answer true: getting this branch backwards would silently stop the render host
    /// from dropping every keystroke after the first one typed into a pane whose link is already down.
    @MainActor func testReportFailedInputSendReturnValueTracksWhetherTheLinkIsGoneNotWhetherItDidFreshWork() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        XCTAssertFalse(
            model.reportFailedInputSend(
                SpacesDeviceAPIRequestClientError.requestRejected(message: "Session is not running.", code: .sessionNotAvailable)))
        XCTAssertFalse(model.isStateStreamDisconnected)

        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))
        XCTAssertTrue(model.isStateStreamDisconnected)

        XCTAssertTrue(
            model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out.")),
            "a repeat failure during an outage already reported down must still say the link is gone")
    }

    /// Issue #491: a FRESH request timeout must not be acted on as an outage. The daemon's serial
    /// terminal-engine queue saturates under heavy streaming, so a keystroke's answer routinely misses the
    /// 5s interactive deadline on a link that is perfectly alive — and the old behavior tore the state
    /// subscription down and put "Connection lost. Reconnecting…" over a working pane every time it did.
    /// Instead the timeout is corroborated: the stream stays installed, no notice is raised, and a `.ping`
    /// probe decides. While that probe is pending and when it comes back with the daemon answering,
    /// nothing about the pane changes. The return value stays `false` either way, which is what keeps
    /// `RemoteGhosttySessionHost` from discarding the pane's queued input.
    @MainActor func testFreshRequestTimeoutKeepsTheStreamWhileACorroborationProbeDecides() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalStateStreamConnectionDidChange, object: nil, queue: .main) {
            _ in MainActor.assumeIsolated { notificationCount += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Hold the probe open so the pane's state can be read while the verdict is still unknown.
        let probeStarted = expectation(description: "the corroboration probe started")
        var resumeProbe: (((any Error)?) -> Void)?
        model.linkCorroborationProbeForTesting = { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<(any Error)?, Never>) in
                resumeProbe = { continuation.resume(returning: $0) }
                probeStarted.fulfill()
            }
        }

        XCTAssertFalse(
            model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out.")),
            "a bare request timeout alone is not conclusive proof the link is down")
        await fulfillment(of: [probeStarted], timeout: 5)
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "an uncorroborated timeout must not tear the subscription down")
        XCTAssertFalse(model.isStateStreamDisconnected, "an uncorroborated timeout must not put the disconnected notice on the pane")
        XCTAssertFalse(model.hasArmedReconnectForTesting, "an uncorroborated timeout must not start reconnect churn")

        // The daemon answered the probe: the timeout was engine saturation, and the pane keeps its stream.
        resumeProbe?(nil)
        await model.drainPendingLinkCorroborationProbeForTesting()
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "a probe the daemon answered proves the link is up")
        XCTAssertFalse(model.isStateStreamDisconnected)
        XCTAssertFalse(model.hasArmedReconnectForTesting)
        XCTAssertEqual(notificationCount, 0, "a corroborated-live timeout must not wake observers with a link-state change")

        // `SpacesPinnedTLSConnectionError.timeout` is what the production request path actually throws on
        // a deadline (see `SpacesDeviceClient.isDeviceAPIRequestTimeout`'s doc); it must take the same
        // corroborated path as the declared `SpacesDeviceAPIRequestClientError.timeout` case above.
        let secondModel = try makeModel(sessionID: "session-\(UUID().uuidString)")
        secondModel.installStreamClientForTesting(FakeStreamClient())
        secondModel.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        secondModel.linkCorroborationProbeForTesting = { _ in nil }
        XCTAssertFalse(
            secondModel.reportFailedInputSend(SpacesPinnedTLSConnectionError.timeout),
            "the pinned-TLS timeout the production request path actually throws must classify the same as the declared timeout case")
        await secondModel.drainPendingLinkCorroborationProbeForTesting()
        XCTAssertTrue(secondModel.hasActiveStreamClientForTesting)
        XCTAssertFalse(secondModel.isStateStreamDisconnected)
    }

    /// The other side of the corroboration: a timeout on a link that really is gone. The probe cannot
    /// reach the daemon either, which is the conclusive evidence the timeout was not — so the pane takes
    /// exactly the disconnect reaction a connection-level failure takes, and the notice the user sees is
    /// backed by two independent failures instead of one ambiguous one.
    @MainActor func testACorroborationProbeThatAlsoFailsTearsTheStreamDownAndArmsAReconnect() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(3600)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        var notifiedSessionIDs: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalStateStreamConnectionDidChange, object: nil, queue: .main) {
            notification in
            let notifiedSessionID = TerminalSessionNotification.sessionID(from: notification)
            MainActor.assumeIsolated { notifiedSessionIDs.append(notifiedSessionID ?? "") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        model.linkCorroborationProbeForTesting = { _ in SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused") }

        XCTAssertFalse(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out.")))
        await model.drainPendingLinkCorroborationProbeForTesting()

        XCTAssertFalse(model.hasActiveStreamClientForTesting, "a corroborated outage must drop the subscription")
        XCTAssertTrue(model.isStateStreamDisconnected, "a corroborated outage must surface the disconnected notice")
        XCTAssertTrue(model.hasArmedReconnectForTesting, "a corroborated outage must arm the paced reconnect")
        XCTAssertEqual(notifiedSessionIDs, [sessionID])
    }

    /// A probe that cannot authenticate the daemon it reached — a rotated certificate, or the only
    /// reachable candidate presenting a different identity — brought back no answer from THIS daemon, so
    /// it is a failed probe even though the pin mismatch is deliberately not classified as a transport
    /// failure (nothing about the link is broken, and no reconnect fixes the identity). Reading the
    /// verdict through that classification instead would leave the pane looking live and streaming
    /// nothing until the subscription's own socket timeout eventually noticed.
    @MainActor func testACorroborationProbeThatCannotAuthenticateTheDaemonTearsTheStreamDown() async throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(3600)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.linkCorroborationProbeForTesting = { _ in
            TerminalServiceTLSError.certificatePinMismatch(expected: "SHA256:aa", actual: "SHA256:bb")
        }

        XCTAssertFalse(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out.")))
        await model.drainPendingLinkCorroborationProbeForTesting()

        XCTAssertFalse(model.hasActiveStreamClientForTesting, "an unanswered probe must drop the subscription")
        XCTAssertTrue(model.isStateStreamDisconnected, "an unanswered probe must surface the disconnected notice")
        XCTAssertTrue(model.hasArmedReconnectForTesting, "an unanswered probe must arm the paced reconnect")
    }

    /// A probe the daemon answers with a coded rejection still proves the link: something on the other end
    /// received the request and replied. Reading only "the probe threw" would tear down a healthy pane
    /// whenever the daemon's answer happened to be a rejection.
    @MainActor func testACorroborationProbeRejectedByTheDaemonIsTreatedAsALiveLink() async throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.linkCorroborationProbeForTesting = { _ in
            SpacesDeviceAPIRequestClientError.requestRejected(message: "Unauthorized.", code: .unauthorized)
        }

        model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out."))
        await model.drainPendingLinkCorroborationProbeForTesting()

        XCTAssertTrue(model.hasActiveStreamClientForTesting)
        XCTAssertFalse(model.isStateStreamDisconnected)
    }

    /// On a device reachable at several addresses, the corroboration has to ask about the address this
    /// pane's stream is actually on, not about the device. Here that address died (the Mac left the LAN)
    /// while the device still answers over the tailnet: the ping is pinned to the stream's address, fails
    /// there, and that failure is the evidence the pane's link is gone — the stream would otherwise sit
    /// frozen on a dead socket until TCP keepalive gave up a minute or more later, while typing recovered
    /// immediately through the input path's own failover.
    @MainActor func testACorroborationProbePinnedToTheStreamsAddressTearsItDownWhenThatAddressIsDead() async throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(3600)
        model.installStreamClientForTesting(FakeStreamClient(), connectedHost: "192.168.1.20")
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        var pinnedHosts: [String?] = []
        model.linkCorroborationProbeForTesting = { pinnedHost in
            pinnedHosts.append(pinnedHost)
            return SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")
        }

        XCTAssertFalse(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out.")))
        await model.drainPendingLinkCorroborationProbeForTesting()

        XCTAssertEqual(pinnedHosts, ["192.168.1.20"], "the probe must ask about the address the stream is on, not race the candidates")
        XCTAssertFalse(model.hasActiveStreamClientForTesting, "a stream on an address that stopped answering must be dropped")
        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertTrue(model.hasArmedReconnectForTesting, "the redial is what moves the stream onto a candidate that still answers")
    }

    /// The pinned ping being answered is the ordinary saturated-daemon case the corroboration exists for,
    /// and it stays that way when a second address is also up: the answer came back on the stream's own
    /// address, so the pane keeps its stream. A raced ping could have been answered by the other address
    /// and proved nothing about this one, in either direction.
    @MainActor func testACorroborationProbeAnsweredOnTheStreamsOwnAddressLeavesItAlone() async throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.installStreamClientForTesting(FakeStreamClient(), connectedHost: "192.168.1.20")
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        var pinnedHosts: [String?] = []
        model.linkCorroborationProbeForTesting = { pinnedHost in
            pinnedHosts.append(pinnedHost)
            return nil
        }

        XCTAssertFalse(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out.")))
        await model.drainPendingLinkCorroborationProbeForTesting()

        XCTAssertEqual(pinnedHosts, ["192.168.1.20"])
        XCTAssertTrue(model.hasActiveStreamClientForTesting)
        XCTAssertFalse(model.isStateStreamDisconnected)
        XCTAssertFalse(model.hasArmedReconnectForTesting)
    }

    /// With no address recorded for the stream there is nothing to pin to, so the ping races the
    /// candidates as any other request does and the verdict rests on the error alone.
    @MainActor func testACorroborationProbeForAStreamWithNoRecordedAddressRacesTheCandidates() async throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        var pinnedHosts: [String?] = []
        model.linkCorroborationProbeForTesting = { pinnedHost in
            pinnedHosts.append(pinnedHost)
            return nil
        }

        XCTAssertFalse(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out.")))
        await model.drainPendingLinkCorroborationProbeForTesting()

        XCTAssertEqual(pinnedHosts, [String?.none], "an unknown stream address pins to nothing")
        XCTAssertTrue(model.hasActiveStreamClientForTesting)
        XCTAssertFalse(model.isStateStreamDisconnected)
        XCTAssertFalse(model.hasArmedReconnectForTesting)
    }

    /// Typing into a stalled pane produces one timeout per keystroke. One probe answers for all of them,
    /// so a second timeout arriving while the first probe is in flight must add nothing — otherwise a
    /// stall would be answered with a burst of `.ping` requests aimed at the very daemon that is already
    /// behind on its work.
    @MainActor func testASecondTimeoutDuringAnInFlightProbeDoesNotStartASecondProbe() async throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        var probeInvocations = 0
        let probeStarted = expectation(description: "the corroboration probe started")
        probeStarted.assertForOverFulfill = false
        var resumeProbe: (((any Error)?) -> Void)?
        model.linkCorroborationProbeForTesting = { _ in
            probeInvocations += 1
            return await withCheckedContinuation { (continuation: CheckedContinuation<(any Error)?, Never>) in
                resumeProbe = { continuation.resume(returning: $0) }
                probeStarted.fulfill()
            }
        }

        model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out."))
        XCTAssertTrue(model.hasInFlightLinkCorroborationProbeForTesting)
        XCTAssertFalse(
            model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out again.")),
            "a repeat timeout while the link is still being corroborated is no more conclusive than the first")
        await fulfillment(of: [probeStarted], timeout: 5)

        XCTAssertEqual(probeInvocations, 1, "one in-flight probe answers for every keystroke that timed out behind it")
        resumeProbe?(nil)
        await model.drainPendingLinkCorroborationProbeForTesting()
        XCTAssertFalse(model.hasInFlightLinkCorroborationProbeForTesting, "a finished probe must release its slot for the next stall")
        XCTAssertTrue(model.hasActiveStreamClientForTesting)
    }

    /// A probe's verdict is about the stream it was started under. If that stream was replaced while the
    /// probe was out, its failure says nothing about the replacement — tearing that one down would turn a
    /// stale verdict into a fresh outage on a link that just proved itself by reconnecting.
    @MainActor func testALateCorroborationVerdictAgainstASupersededStreamIsIgnored() async throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        let probeStarted = expectation(description: "the corroboration probe started")
        var resumeProbe: (((any Error)?) -> Void)?
        model.linkCorroborationProbeForTesting = { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<(any Error)?, Never>) in
                resumeProbe = { continuation.resume(returning: $0) }
                probeStarted.fulfill()
            }
        }

        model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out."))
        await fulfillment(of: [probeStarted], timeout: 5)
        // The stream the probe was started for is replaced while the probe is still out.
        model.installStreamClientForTesting(FakeStreamClient())

        resumeProbe?(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused"))
        await model.drainPendingLinkCorroborationProbeForTesting()

        XCTAssertTrue(model.hasActiveStreamClientForTesting, "a superseded stream's verdict must not tear down the stream that replaced it")
        XCTAssertFalse(model.isStateStreamDisconnected)
    }

    /// Corroboration is only for the ambiguous shape. A connection-level failure is already conclusive —
    /// the transport itself gave up — so it takes the disconnect reaction immediately, with no probe and
    /// no extra round trip standing between the user and the notice.
    @MainActor func testAConnectionLevelFailureTearsDownImmediatelyWithoutProbing() throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        var probeInvocations = 0
        model.linkCorroborationProbeForTesting = { _ in
            probeInvocations += 1
            return nil
        }

        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))

        XCTAssertFalse(model.hasActiveStreamClientForTesting)
        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertFalse(model.hasInFlightLinkCorroborationProbeForTesting)
        XCTAssertEqual(probeInvocations, 0, "a conclusive failure needs no second opinion")
    }

    /// The probe's whole value is arriving while the input path is stuck, so it must not queue behind that
    /// path. Input rides the session's shared `SpacesDeviceAPIRequestSessionClient`, which serializes every
    /// send behind one lock and starts its deadline only after taking it — so on a dead link the backlog
    /// still draining behind the timeout holds that lock for a full deadline per keystroke, and a probe
    /// sharing the client could wait out the entire outage with the pane still looking live.
    ///
    /// Runs the REAL probe (no override) against a live in-process server, so this also proves the actual
    /// `.ping` path answers, and asserts the shared client never opened a connection: the probe dialed its
    /// own.
    @MainActor func testTheCorroborationProbeDialsItsOwnConnectionInsteadOfTheInputPathsClient() async throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedStreamConnectionPairingStore()
        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let sessionID = "session-\(UUID().uuidString)"
        let subscriptionServer = try startLiveSession(sessionID: sessionID)
        defer { subscriptionServer.stop() }
        let device = SpacesPairedDeviceRecord(
            id: "remote-\(UUID().uuidString)", name: "Remote", platform: "linux", hosts: ["127.0.0.1"], port: server.listeningPort,
            certificateFingerprint: identity.certificateFingerprint, createdAt: "2026-07-24T00:00:00Z", updatedAt: "2026-07-24T00:00:00Z",
            lastSelectedAt: "2026-07-24T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: device, sessionID: sessionID,
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-24T00:00:00Z",
                workspaceID: "workspace", kind: .shell),
            clientApp: SpacesDeviceClientApp(
                installationID: "INSTALLATION-PROBE-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))
        // Installing a stream keeps listener registration from dialing anything, so every connection the
        // shared client opens from here on would have to have come from the probe.
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        XCTAssertEqual(model.requestClientBox.current.client.openedConnectionCountForTesting, 0, "nothing has sent on the shared client yet")

        XCTAssertFalse(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out.")))
        await model.drainPendingLinkCorroborationProbeForTesting()

        XCTAssertTrue(model.hasActiveStreamClientForTesting, "the daemon answered the real ping, so the pane keeps its stream")
        XCTAssertFalse(model.isStateStreamDisconnected)
        XCTAssertEqual(
            model.requestClientBox.current.client.openedConnectionCountForTesting, 0,
            "the probe must dial its own connection rather than queue behind the input path's shared client")
    }

    /// The single-flight rule is per stream, not per model. A probe still out for a stream that has since
    /// been replaced can no longer answer for anything — its verdict is discarded by the generation guard —
    /// so a timeout on the replacement must get a probe of its own instead of being silently covered by it.
    @MainActor func testATimeoutOnAReplacementStreamGetsItsOwnProbe() async throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(3600)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        var probeInvocations = 0
        var resumeProbes: [((any Error)?) -> Void] = []
        let firstProbeStarted = expectation(description: "the first stream's probe started")
        let secondProbeStarted = expectation(description: "the replacement stream's probe started")
        model.linkCorroborationProbeForTesting = { _ in
            probeInvocations += 1
            let isFirst = probeInvocations == 1
            return await withCheckedContinuation { (continuation: CheckedContinuation<(any Error)?, Never>) in
                resumeProbes.append { continuation.resume(returning: $0) }
                if isFirst { firstProbeStarted.fulfill() } else { secondProbeStarted.fulfill() }
            }
        }

        model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out."))
        await fulfillment(of: [firstProbeStarted], timeout: 5)

        // The stream is replaced (a reconnect landed) while that first probe is still out.
        model.installStreamClientForTesting(FakeStreamClient())
        XCTAssertFalse(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.timeout("Timed out again.")))
        await fulfillment(of: [secondProbeStarted], timeout: 5)
        XCTAssertEqual(probeInvocations, 2, "the replacement stream's timeout must be corroborated rather than answered by a stale probe")

        // The stale probe reports the outage it saw; it is about a stream that no longer exists.
        resumeProbes[0](SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused"))
        // The replacement's own probe reports the same, and that one does decide the pane.
        resumeProbes[1](SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused"))
        await model.drainPendingLinkCorroborationProbeForTesting()

        XCTAssertFalse(model.hasActiveStreamClientForTesting, "the replacement stream's own probe confirmed the outage")
        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertTrue(model.hasArmedReconnectForTesting)
    }

    /// The interactive control commands on the hot per-keystroke path (typed input, key, scroll, resize,
    /// clear-screen) get the shortened deadline; every other control command — session-management calls
    /// like attach/detach/heartbeat/takeover/appearance, off that path — keeps the Device API's own
    /// default. Asserted directly against the pure decision function `sendTerminalServiceRequest` sends
    /// through, so the split is provable without a real send waiting out either deadline to reveal which
    /// one was chosen.
    func testControlRequestTimeoutSecondsUsesTheShortenedDeadlineOnlyForInteractiveCommands() throws {
        typealias Model = DeviceTerminalSessionStateModel
        let sessionID = "session-\(UUID().uuidString)"
        let interactiveRequests: [TerminalControlRequest] = [
            TerminalControlRequest(command: .send(.init(text: "a", bytes: nil, clientID: "client", ownerEpoch: 0, appendNewline: false))),
            TerminalControlRequest(command: .key(.init(key: "enter", clientID: "client", ownerEpoch: 0))),
            TerminalControlRequest(command: .clearScreen(.init(clientID: "client", ownerEpoch: 0))),
            TerminalControlRequest(command: .resize(.init(clientID: "client", columns: 80, rows: 24, ownerEpoch: 0, resizeSerial: 1))),
            TerminalControlRequest(
                command: .scroll(.init(clientID: "client", ownerEpoch: 0, scrollHorizontal: 0, scrollVertical: 1, scrollMods: nil))),
        ]
        let nonInteractiveRequests: [TerminalControlRequest] = [
            TerminalControlRequest(command: .attach(.init(client: nil, attachmentMode: .owner, appearance: nil))),
            TerminalControlRequest(command: .detach(.init(clientID: "client"))),
            TerminalControlRequest(command: .heartbeat(.init(clientID: "client"))),
            TerminalControlRequest(command: .takeover(.init(clientID: "client"))),
            TerminalControlRequest(command: .setAppearance(.init(clientID: "client", appearance: .dark))),
        ]

        for controlRequest in interactiveRequests {
            let deviceRequest = try AppKitController.deviceTerminalControlRequest(sessionID: sessionID, controlRequest: controlRequest)
            XCTAssertEqual(
                Model.controlRequestTimeoutSeconds(for: controlRequest, command: .terminalControl(deviceRequest)),
                Model.interactiveControlRequestTimeoutSeconds, "'\(controlRequest.command)' must use the shortened interactive deadline")
        }
        for controlRequest in nonInteractiveRequests {
            let deviceRequest = try AppKitController.deviceTerminalControlRequest(sessionID: sessionID, controlRequest: controlRequest)
            let command = SpacesDeviceAPICommand.terminalControl(deviceRequest)
            XCTAssertEqual(
                Model.controlRequestTimeoutSeconds(for: controlRequest, command: command), SpacesDeviceClient.requestTimeoutSeconds(for: command),
                "'\(controlRequest.command)' must keep the default deadline")
        }
        XCTAssertEqual(Model.interactiveControlRequestTimeoutSeconds, 5, "healthy sends measure 0.7-1.5s; re-measure before tightening this")
    }

    // MARK: Fixtures

    /// A model pointed at a device on port 1, an address nothing in these tests actually dials: each
    /// test either installs a stream client before any listener registers, or overrides the connect
    /// through `stateStreamConnectOverrideForTesting`. A real connect's failure timing is not something
    /// to depend on here — a refused port is not guaranteed to fail before the pinned-TLS connector's own
    /// connect timeout.
    // MARK: - One-shot clipboard writes

    /// A clipboard write is an event, not state, and losing one loses the user's copy with nothing to
    /// redeliver it. The catch-up `.state` request runs on its own connection alongside the live
    /// subscription, so a response served AFTER the event was emitted can be installed before the event
    /// arrives — and the emission-time guard that (correctly) keeps that catch-up from regressing
    /// render/runtime/ownership must not swallow the copy riding the older event.
    @MainActor func testClipboardWriteFromAnOlderEventStillReachesListeners() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        var received: [GhosttyRemoteSessionStatePayload] = []
        model.startStateStream(onUpdate: { received.append($0) }, onDisconnect: { _ in })

        // The catch-up response lands first and installs the newer emission time.
        model.applyControlResponseState(statePayload(sessionID: sessionID, reason: "runtime_state", emittedAt: "2026-07-28T00:00:09Z"))
        // The stream event carrying the copy was emitted earlier and arrives after it.
        model.applyStreamEvent(
            clipboardPayload(sessionID: sessionID, emittedAt: "2026-07-28T00:00:01Z", targetClientID: "owner", text: "copied text"),
            generation: generation)

        let clipboardWrites = received.compactMap(\.clipboardWrite)
        XCTAssertEqual(clipboardWrites.map(\.text), ["copied text"])
        XCTAssertEqual(clipboardWrites.map(\.targetClientID), ["owner"])
    }

    /// The one-shot skips the staleness guard, not the generation guard: an event from a stream client
    /// that has already been replaced says nothing about the session this model is now serving, so its
    /// copy must not be pushed onto the user's clipboard.
    @MainActor func testClipboardWriteFromASupersededStreamIsIgnored() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        let staleGeneration = model.installStreamClientForTesting(FakeStreamClient())
        _ = model.installStreamClientForTesting(FakeStreamClient())
        var received: [GhosttyRemoteSessionStatePayload] = []
        model.startStateStream(onUpdate: { received.append($0) }, onDisconnect: { _ in })

        model.applyStreamEvent(
            clipboardPayload(sessionID: sessionID, emittedAt: "2026-07-28T00:00:01Z", targetClientID: "owner", text: "from a dead stream"),
            generation: staleGeneration)

        XCTAssertEqual(received.compactMap(\.clipboardWrite), [])
    }

    /// A clipboard write carries no state worth caching — its reason exports no screen state and repeats
    /// the snapshot the output turn before it already delivered — so it neither advances the emission
    /// watermark nor becomes the model's cached payload. Were it to advance the watermark, an event that
    /// legitimately arrived out of order would start discarding the real state payloads behind it.
    @MainActor func testClipboardWriteDoesNotBecomeCachedState() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        model.applyControlResponseState(
            statePayload(sessionID: sessionID, reason: "runtime_state", emittedAt: "2026-07-28T00:00:01Z", title: "before"))
        model.applyStreamEvent(
            clipboardPayload(sessionID: sessionID, emittedAt: "2026-07-28T00:00:09Z", targetClientID: "owner", text: "copied", title: "clipboard"),
            generation: generation)
        model.applyControlResponseState(
            statePayload(sessionID: sessionID, reason: "runtime_state", emittedAt: "2026-07-28T00:00:05Z", title: "after"))

        XCTAssertEqual(model.latestRemoteStatePayload?.title, "after")
        XCTAssertNil(model.latestRemoteStatePayload?.clipboardWrite)
    }

    private func statePayload(sessionID: String, reason: String, emittedAt: String, title: String = "t") -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: reason, emittedAt: emittedAt, sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
            runtimeState: nil, attachmentSnapshot: nil, title: title, workingDirectory: "/tmp", outputByteCount: nil)
    }

    private func clipboardPayload(sessionID: String, emittedAt: String, targetClientID: String, text: String, title: String = "t")
        -> GhosttyRemoteSessionStatePayload
    {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.clipboardWrite, emittedAt: emittedAt, sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: title, workingDirectory: "/tmp",
            outputByteCount: nil, clipboardWrite: TerminalClipboardWritePayload(targetClientID: targetClientID, text: text))
    }

    @MainActor private func makeModel(sessionID: String) throws -> DeviceTerminalSessionStateModel {
        let device = SpacesPairedDeviceRecord(
            id: "remote-\(UUID().uuidString)", name: "Remote", platform: "linux", hosts: ["127.0.0.1"], port: 1,
            certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), createdAt: "2026-07-24T00:00:00Z",
            updatedAt: "2026-07-24T00:00:00Z", lastSelectedAt: "2026-07-24T00:00:00Z")
        return try DeviceTerminalSessionStateModel(
            device: device, sessionID: sessionID,
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-24T00:00:00Z",
                workspaceID: "workspace", kind: .shell),
            clientApp: SpacesDeviceClientApp(
                installationID: "INSTALLATION-STREAM-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), authToken: "token"))
    }

    /// Registers `sessionID` with the profile the in-process `SpacesDeviceAPIServer` reads (the temporary
    /// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` this class sets up) as a genuinely live session, and starts
    /// the subscription socket that makes its subscribe servable.
    ///
    /// Both halves are needed for the server to accept rather than reject: the persisted runtime state is
    /// what keeps it off the ended-session branch, and the listening socket is what it relays. A test that
    /// skips this gets a subscribe the server rejects asynchronously, and the rejection lands on
    /// `handleStreamDisconnect` at an unpredictable moment.
    @MainActor private func startLiveSession(sessionID: String) throws -> LiveSubscriptionSocketServer {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                state: .running, updatedAt: "2026-07-24T00:00:01Z", title: "t", workingDirectory: "/tmp"), paths: paths)
        let server = try LiveSubscriptionSocketServer(socketPath: paths.subscriptionSocketPath, payload: runningStatePayload(sessionID: sessionID))
        try server.start()
        return server
    }

    /// The payload a live session's subscription socket serves: an interactive runtime state and no render
    /// update, which is everything these tests need the catch-up `.state` and the stream to carry.
    private func runningStatePayload(sessionID: String) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: "runtime_state", emittedAt: "2026-07-24T00:00:02Z", sessionStateRevision: nil, sessionStateFlags: nil,
            screenStateRevision: nil,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                state: .running, updatedAt: "2026-07-24T00:00:01Z", title: "t", workingDirectory: "/tmp"), attachmentSnapshot: nil, title: "t",
            workingDirectory: "/tmp", outputByteCount: nil)
    }

    /// The device's report that this session's process exited — the state that makes a live stream
    /// unwanted, so no drop against it is an outage.
    private func endedStatePayload(sessionID: String) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: "runtime_state", emittedAt: "2026-07-24T00:00:01Z", sessionStateRevision: nil, sessionStateFlags: nil,
            screenStateRevision: nil,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .exited, updatedAt: "2026-07-24T00:00:01Z",
                exitedAt: "2026-07-24T00:00:01Z"), attachmentSnapshot: nil, title: "t", workingDirectory: "/tmp", outputByteCount: nil)
    }

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair
    /// only needs a stable certificate to pin. Mirrors `DeviceTerminalSessionStateModelRecoveryTests`.
    private static let tlsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "device-terminal-session-state-model-stream-connection-tests-tls-\(UUID().uuidString)", isDirectory: true)
}

/// `TerminalRemoteStateStreamClient` requires only `stop()`; the model treats any conforming object as
/// an installed stream, which is all these tests need.
private final class FakeStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable { func stop() {} }

/// A live subscription socket for one terminal session: binds and listens on that session's
/// subscription socket path, accepts every connection the Device API server opens against it, and hands
/// each one the session's current state payload.
///
/// This is what makes a subscribe ACCEPTED. `SpacesDeviceAPIServer.handleSubscribeRequest` decides a
/// session is streamable by finding this socket and relaying it; without one the server answers
/// `sessionNotAvailable` and cancels the connection asynchronously, after `start()` has already returned
/// — so a test asserting on the resulting stream is racing that rejection rather than observing a
/// reconnect. The catch-up `.state` request reads through the same socket on its own connection, which
/// is why every connection is accepted and served, not just the first.
///
/// Deliberately duplicated from the equivalent fixture in `spacescliTests`: a shared cross-target test
/// support module for one small socket fixture would cost more than these few lines.
private final class LiveSubscriptionSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let payloadLine: Data
    private let queue = DispatchQueue(label: "spaces.ui.tests.live.subscription")
    private let accepted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listenSocketFD: Int32 = -1
    private var clientSocketFDs: [Int32] = []
    private var isStopped = false

    init(socketPath: String, payload: GhosttyRemoteSessionStatePayload) throws {
        self.socketPath = socketPath
        var line = try GhosttyRemoteSessionStateCodec.encodeLine(payload)
        line.append(0x0A)
        payloadLine = line
    }

    func start() throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var address = try Self.makeSocketAddress(path: socketPath)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard listen(socketFD, 8) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            lock.withLock { listenSocketFD = socketFD }
            queue.async { [weak self] in self?.acceptLoop(listenSocketFD: socketFD) }
        } catch {
            close(socketFD)
            throw error
        }
    }

    /// Waits for one connection to have been accepted and served. Each accepted connection signals, so a
    /// caller that needs to know the subscribe itself landed can wait again.
    @discardableResult func waitForAccepted(timeout: TimeInterval) -> Bool { accepted.wait(timeout: .now() + timeout) == .success }

    func stop() {
        let (listenFD, clientFDs): (Int32, [Int32]) = lock.withLock {
            isStopped = true
            let listenFD = listenSocketFD
            let clientFDs = clientSocketFDs
            listenSocketFD = -1
            clientSocketFDs = []
            return (listenFD, clientFDs)
        }
        for clientFD in clientFDs {
            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
        }
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptLoop(listenSocketFD: Int32) {
        while true {
            let clientFD = accept(listenSocketFD, nil, nil)
            guard clientFD >= 0 else { return }
            let refused: Bool = lock.withLock {
                guard !isStopped else { return true }
                clientSocketFDs.append(clientFD)
                return false
            }
            if refused {
                close(clientFD)
                return
            }
            payloadLine.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                _ = Darwin.write(clientFD, baseAddress, buffer.count)
            }
            accepted.signal()
        }
    }

    private static func makeSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            _ = utf8Path.withUnsafeBufferPointer { buffer in memcpy(pointer, buffer.baseAddress, buffer.count) }
        }
        return address
    }
}

/// A pairing store that authorizes any request carrying its fixed token. Mirrors the file-private
/// fixture `DeviceTerminalSessionStateModelRecoveryTests` defines for the same purpose — the connect
/// race test just needs the real server reachable, not any particular pairing behavior.
private final class AlwaysAuthorizedStreamConnectionPairingStore: SpacesDevicePairingStoreProtocol {
    let authToken = "valid-token"

    func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
    func listDevices() throws -> [SpacesDevicePairedClient] { [] }
    func revoke(installationID _: String) throws {}
    func removeAll() throws {}
    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
        guard clientApp != nil, authToken == self.authToken else {
            throw NSError(
                domain: "DeviceTerminalSessionStateModelStreamConnectionTests", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
        }
    }
    func validate(clientApp _: SpacesDeviceClientApp) throws {}
}
