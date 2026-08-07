import Foundation
import XCTest
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesdeviceapi
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
    @MainActor func testAFailedInputSendDuringAnInFlightConnectStillArmsAReconnectAndRecovers() async throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedStreamConnectionPairingStore()
        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let sessionID = "session-\(UUID().uuidString)"
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
    /// guaranteed to be fast. Only the stream connect itself is made to fail, deterministically, through
    /// the override.
    @MainActor func testScheduleReconnectDoesNotStackConcurrentRetries() async throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedStreamConnectionPairingStore()
        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let sessionID = "session-\(UUID().uuidString)"
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
        model.reconnectBackoff.retryDelay = .milliseconds(10)
        model.reconnectBackoff.maxRetryDelay = .seconds(10)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        model.stateStreamConnectOverrideForTesting = { false }

        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        await model.drainPendingConnectForTesting()

        XCTAssertTrue(model.hasArmedReconnectForTesting, "the failed connect must arm a retry")
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .milliseconds(10),
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
