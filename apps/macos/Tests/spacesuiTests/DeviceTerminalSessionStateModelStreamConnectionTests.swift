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

    /// A stream whose transport died without closing reports itself stalled instead of never reporting
    /// anything. The pane must treat that exactly like a socket that closed — raise the notice, retry —
    /// because the frozen render it would otherwise keep is indistinguishable from a live idle terminal.
    @MainActor func testStalledStreamIsReportedAndRetriedLikeAnyOtherDrop() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        // Far beyond this test's own runtime: what is asserted is that a retry is armed, not what it does
        // when it runs, and a retry that fired here would dial the unreachable fixture device.
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        var notifiedSessionIDs: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalStateStreamConnectionDidChange, object: nil, queue: .main) {
            notification in
            let notifiedSessionID = TerminalSessionNotification.sessionID(from: notification)
            MainActor.assumeIsolated { notifiedSessionIDs.append(notifiedSessionID ?? "") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        model.handleStreamDisconnect(SpacesDeviceAPIRequestClientError.streamStalled, generation: generation)

        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertEqual(notifiedSessionIDs, [sessionID])
        XCTAssertTrue(model.hasArmedReconnectForTesting, "a stalled stream is only recoverable by replacing it")
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

    /// Stage 1 hides the banner during a short grace window: a redial that heals within it must never
    /// have painted anything. The grace itself is caller-owned (`DeviceTerminalSessionStateModel`), so
    /// this drives it through `graceDelayForTesting` instead of waiting out the real one-second grace.
    @MainActor func testStreamLossHidesTheBannerUntilTheGraceElapses() async throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")
        model.graceDelayForTesting = .milliseconds(20)
        let generation = model.installStreamClientForTesting(FakeStreamClient())

        model.handleStreamDisconnect(nil, generation: generation)

        XCTAssertEqual(model.connectionStageTracker.stage, .reconnecting)
        XCTAssertFalse(model.connectionStageTracker.isBannerVisible, "a blip must not paint anything before the grace elapses")

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(model.connectionStageTracker.stage, .reconnecting)
        XCTAssertTrue(model.connectionStageTracker.isBannerVisible, "the grace elapsing without a frame is what raises the banner")
    }

    /// A redial that succeeds inside the grace window must never have shown the banner at all: the
    /// whole point of the grace is to keep ordinary blips invisible, and a frame arriving is what the
    /// tracker's contract means by the connection being proven healthy again.
    @MainActor func testStreamHealingWithinTheGraceNeverShowsTheBanner() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.graceDelayForTesting = .milliseconds(50)
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.handleStreamDisconnect(nil, generation: generation)
        XCTAssertFalse(model.connectionStageTracker.isBannerVisible)

        let newGeneration = model.installStreamClientForTesting(FakeStreamClient())
        model.applyStreamEvent(runningStatePayload(sessionID: sessionID), generation: newGeneration)

        XCTAssertEqual(model.connectionStageTracker.stage, .connected)
        XCTAssertFalse(model.connectionStageTracker.isBannerVisible)

        // Outlive what would have been the grace, to prove the cancelled timer never fires late.
        try await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(model.connectionStageTracker.stage, .connected)
        XCTAssertFalse(model.connectionStageTracker.isBannerVisible)
    }

    /// A frame from a retired stream must never clear the outage it was retired out of. `applyStreamEvent`
    /// used to guard on `streamClientGeneration`, the ever-increasing counter `openStateStream` bumps on
    /// every install: `handleStreamDisconnect` clears `streamClient`/`installedStreamClientGeneration` but
    /// never retires that counter, so a frame the old client already had in flight on the main actor still
    /// carried a generation equal to it and passed the guard after the disconnect, clearing the banner
    /// and resetting backoff while no stream was installed, exactly as if the old client were still live.
    /// The guard must instead be the same one `handleStreamDisconnect` already uses
    /// (`installedStreamClientGeneration`), which the disconnect path does retire.
    @MainActor func testFrameFromARetiredStreamCannotClearTheOutage() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.graceDelayForTesting = .milliseconds(20)
        let oldGeneration = model.installStreamClientForTesting(FakeStreamClient())

        model.handleStreamDisconnect(nil, generation: oldGeneration)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.connectionStageTracker.stage, .reconnecting)
        XCTAssertTrue(model.connectionStageTracker.isBannerVisible, "the grace elapsing without a frame is what raises the banner")

        // A frame the retired client already had in flight lands after the disconnect. It must not clear
        // the outage: no stream is installed for it to be evidence about.
        model.applyStreamEvent(runningStatePayload(sessionID: sessionID), generation: oldGeneration)

        XCTAssertEqual(model.connectionStageTracker.stage, .reconnecting, "a frame from a retired stream must not resurrect it")
        XCTAssertTrue(model.connectionStageTracker.isBannerVisible, "a frame from a retired stream must not hide the banner")

        // The replacement client's own frame is real evidence and clears it.
        let newGeneration = model.installStreamClientForTesting(FakeStreamClient())
        model.applyStreamEvent(runningStatePayload(sessionID: sessionID), generation: newGeneration)

        XCTAssertEqual(model.connectionStageTracker.stage, .connected)
        XCTAssertFalse(model.connectionStageTracker.isBannerVisible)
    }

    /// Stage 2 is entered only on hard evidence (every candidate address refused to dial), with the
    /// banner visible immediately (no grace) and the next automatic redial paced off the tracker's own
    /// (slower) ladder instead of the ordinary stage 1 backoff. Retry is the escape hatch: it redials
    /// immediately and resets the ladder, so the automatic redial that follows a retry starts from the
    /// ladder's shortest rung again instead of continuing to back off.
    @MainActor func testAllCandidatesUnreachableEntersStage2ImmediatelyAndRetryResetsTheLadder() async throws {
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
                installationID: "INSTALLATION-UNREACHABLE-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID,
                platform: "macos", deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))
        // Pin the resolver's only candidate as already failed, reproducing the bookkeeping a real
        // exhausted dial would have left behind, and capture the verdict `noteStreamFailed(host:)`
        // returns into the testing seam that stands in for `client.lastDialExhaustedAllCandidates`:
        // `stateStreamConnectOverrideForTesting` bypasses `client.start()` entirely, so nothing else would
        // populate it.
        let resolver = SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: identity.certificateFingerprint)
        model.lastDialExhaustedAllCandidatesForTesting = resolver.noteStreamFailed(host: "127.0.0.1")
        model.stateStreamConnectOverrideForTesting = { false }

        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        await model.drainPendingConnectForTesting()

        XCTAssertEqual(model.connectionStageTracker.stage, .unreachable)
        XCTAssertTrue(model.connectionStageTracker.isBannerVisible, "stage 2 shows the banner immediately, with no grace")
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .seconds(TerminalUnreachableBackoff.ladderSeconds[0]),
            "the first stage 2 redial paces off the ladder's shortest rung")

        model.retryStateStreamConnection()
        await model.drainPendingConnectForTesting()

        XCTAssertEqual(model.connectionStageTracker.stage, .unreachable, "still unreachable: the stubbed connect fails again")
        XCTAssertTrue(model.connectionStageTracker.isBannerVisible)
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .seconds(TerminalUnreachableBackoff.ladderSeconds[0]),
            "Retry resets the ladder, so the redial it triggers is the shortest rung again, not the next one up")
    }

    /// The stage 2 verdict has to come from the failed dial itself, not from a fresh read of the
    /// resolver's live failed-host set: with one resolver shared per device across every pane's stream, a
    /// concurrent pane's own `nextStreamHost()` call can reset that set in the gap between this dial's
    /// failure and a later query, which would wrongly read "not every candidate has failed" even though
    /// the dial that just failed genuinely was the last one standing. Reproduces exactly that gap (the
    /// reset lands before `openStateStream` ever looks) and asserts stage 2 is still reached, proving the
    /// escalation used the verdict captured atomically at failure time rather than re-deriving it later.
    @MainActor func testEscalatesToStage2FromTheCapturedVerdictEvenAfterTheResolverSetHasSinceReset() async throws {
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
                installationID: "INSTALLATION-UNREACHABLE-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID,
                platform: "macos", deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))
        let resolver = SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: identity.certificateFingerprint)
        // The verdict at the moment this (simulated) dial failed: the resolver's only candidate, so true.
        model.lastDialExhaustedAllCandidatesForTesting = resolver.noteStreamFailed(host: "127.0.0.1")
        // A concurrent pane's reconnect attempt lands here, before `openStateStream` looks at anything:
        // this is the exact race window G1 fixes. A query against the resolver made after this point
        // would wrongly say "not every candidate has failed", because the walk hands the candidate back
        // out instead of continuing to skip it.
        XCTAssertEqual(resolver.nextStreamHost(), "127.0.0.1", "sanity: the reset already happened")
        model.stateStreamConnectOverrideForTesting = { false }

        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        await model.drainPendingConnectForTesting()

        XCTAssertEqual(
            model.connectionStageTracker.stage, .unreachable,
            "the captured verdict from the failed dial itself must decide this, not a fresh (and by now reset) resolver query")
    }

    /// `SpacesDeviceEndpointResolver.nextStreamHost()` self-resets its failed-host set once every
    /// candidate has failed (so it can never wedge on a permanently dead one), which means a two-host
    /// device's very next stream attempt after the one that reached stage 2 can read
    /// `allCandidatesUnreachable: false` even though nothing has actually improved. That attempt must
    /// still pace on the stage 2 ladder, not fall back to the ordinary `reconnectBackoff` cadence
    /// (`scheduleReconnect(after:)`'s `connectionStageTracker.stage == .unreachable` check exists for
    /// exactly this).
    @MainActor func testStillUnreachableAttemptWithResetFailedSetStaysOnTheLadder() async throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedStreamConnectionPairingStore()
        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let sessionID = "session-\(UUID().uuidString)"
        let subscriptionServer = try startLiveSession(sessionID: sessionID)
        defer { subscriptionServer.stop() }
        let device = SpacesPairedDeviceRecord(
            id: "remote-\(UUID().uuidString)", name: "Remote", platform: "linux", hosts: ["127.0.0.1", "127.0.0.2"],
            port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint, createdAt: "2026-07-24T00:00:00Z",
            updatedAt: "2026-07-24T00:00:00Z", lastSelectedAt: "2026-07-24T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: device, sessionID: sessionID,
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-24T00:00:00Z",
                workspaceID: "workspace", kind: .shell),
            clientApp: SpacesDeviceClientApp(
                installationID: "INSTALLATION-UNREACHABLE-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID,
                platform: "macos", deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))
        // A `reconnectBackoff` this far from the ladder's values (1/2/4/8/15s) makes a fixed-cadence
        // fallback unmistakable in the assertion below, distinct from every rung the ladder could land on.
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        // Pin both candidates as already failed, reproducing the bookkeeping a real exhausted dial cycle
        // would have left behind (mirrors the single-host test above); the verdict only reads true once
        // the second candidate is also marked.
        let resolver = SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: identity.certificateFingerprint)
        resolver.noteStreamFailed(host: "127.0.0.1")
        model.lastDialExhaustedAllCandidatesForTesting = resolver.noteStreamFailed(host: "127.0.0.2")
        model.stateStreamConnectOverrideForTesting = { false }

        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        await model.drainPendingConnectForTesting()

        XCTAssertEqual(model.connectionStageTracker.stage, .unreachable, "both candidates already failed: straight to stage 2")
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .seconds(TerminalUnreachableBackoff.ladderSeconds[0]),
            "the first stage 2 redial paces off the ladder's shortest rung")

        // `nextStreamHost()` is what a real `client.start()` calls before dialing, and self-resets the
        // failed set once every candidate is in it; the stub connect never reaches that call, so it is
        // reproduced here directly, the same way `noteStreamFailed(host:)` above stands in for the failed
        // dial itself. This attempt's own dial (against the freshly reset set) would fail on only the
        // first candidate, so its verdict reads false.
        _ = resolver.nextStreamHost()
        model.lastDialExhaustedAllCandidatesForTesting = false

        model.retryStateStreamConnection()
        await model.drainPendingConnectForTesting()

        XCTAssertEqual(
            model.connectionStageTracker.stage, .unreachable,
            "nothing has actually improved: the stubbed connect still fails, this attempt just has a freshly reset failed set")
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .seconds(TerminalUnreachableBackoff.ladderSeconds[0]),
            "this attempt's own allCandidatesUnreachable reads false (the failed set just reset), but the "
                + "tracker is still unreachable, so it must stay on the ladder rather than fall back to reconnectBackoff")
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

    /// The cached runtime state is not evidence that a dropped stream needs no replacement. The stream
    /// that just died is the only thing that keeps that cache current, so a cache reading `.exited` for a
    /// session the device still has running used to end the reconnect path for good: no stream, no retry,
    /// no notice, and nothing left that could correct any of it — the pane stayed frozen until it was
    /// closed and reopened (issue #537). The drop asks the device instead of ruling on the cache, and the
    /// device's answer re-arms both the notice and the retry.
    @MainActor func testADropAgainstAStaleEndedCacheRecoversWhenTheDeviceReportsTheSessionRunning() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        // Far beyond this test's own runtime: what is asserted is that a retry is armed, not what it does
        // when it runs, and a retry that fired here would dial the unreachable fixture device.
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        let script = LivenessFetchScript(repeating: .success(runningStatePayload(sessionID: sessionID)))
        model.livenessStateFetchOverrideForTesting = { await script.answer() }
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        // The last thing the (now dead) stream said about this session was that its process had exited.
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))

        model.handleStreamDisconnect(nil, generation: generation)

        // Nothing is claimed on the cache's word alone: a session that really ended needs no stream and
        // gets no outage notice, so the drop is neither reported nor retried until the device has answered.
        XCTAssertFalse(model.isStateStreamDisconnected)
        XCTAssertFalse(model.hasArmedReconnectForTesting)
        XCTAssertTrue(model.hasArmedLivenessRecheckForTesting, "the drop must leave the liveness question open, not drop it")

        // The device answers: the session is running after all, and the cache was stale.
        await waitForLivenessRecheckToSettle(model)

        XCTAssertTrue(model.isStateStreamDisconnected, "the device's answer must surface the outage the stale cache hid")
        XCTAssertTrue(model.hasArmedReconnectForTesting, "the device's answer must re-arm the reconnect the stale cache turned away")
    }

    /// A `.state` request that never reaches the device is the likeliest outcome of the very outage that
    /// dropped the stream, and it answers nothing — so it must not end the recheck. An unreachable device
    /// is itself an outage the pane has to show, and the question stays open on the paced cadence until the
    /// device settles it. Going quiescent here would reproduce issue #537 through this path: a live session
    /// frozen behind a stale `.exited` cache, with no notice and nothing left to ask again.
    @MainActor func testAnUnreachableDeviceRaisesTheNoticeAndKeepsAskingUntilItAnswers() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.reconnectBackoff.retryDelay = .milliseconds(1)
        model.reconnectBackoff.maxRetryDelay = .milliseconds(1)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        // A second attempt is what proves the first failure was re-asked rather than swallowed; bounding the
        // wait on it makes a recheck that goes quiescent fail here instead of hanging the suite.
        let askedTwice = expectation(description: "the recheck asked again after an unreachable attempt")
        askedTwice.expectedFulfillmentCount = 2
        askedTwice.assertForOverFulfill = false
        let script = LivenessFetchScript(
            repeating: .failure(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")), onAttempt: { _ in askedTwice.fulfill() })
        model.livenessStateFetchOverrideForTesting = { await script.answer() }
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))

        model.handleStreamDisconnect(nil, generation: generation)

        await fulfillment(of: [askedTwice], timeout: 5)
        XCTAssertTrue(model.isStateStreamDisconnected, "a device that cannot answer is an outage the pane must report")
        XCTAssertTrue(model.hasArmedLivenessRecheckForTesting, "a failed request must leave the question open")
        XCTAssertFalse(model.hasArmedReconnectForTesting, "nothing is worth reconnecting to until the device says the session is live")

        // The device comes back and answers. Stretch the shared cadence first: the reconnect that answer
        // arms is what this asserts on, and at the 1ms cadence above it would fire (and dial the
        // unreachable fixture device) before the assertion could read it.
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        await script.setRepeating(.success(runningStatePayload(sessionID: sessionID)))
        await waitForLivenessRecheckToSettle(model)

        XCTAssertTrue(model.hasArmedReconnectForTesting, "the device's answer must re-arm the reconnect")
        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertFalse(model.hasArmedLivenessRecheckForTesting, "an answered question must close")
    }

    /// The recheck is settled by the answer to its OWN request and by nothing else. Any other payload
    /// reaching the model — a control response, a catch-up `.state` that was already in flight when the
    /// stream dropped, a coalesced older read — describes some earlier moment, so accepting one as the
    /// answer would settle the question on evidence that predates the drop.
    @MainActor func testAnUnrelatedPayloadDoesNotSettleTheOpenLivenessQuestion() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        // Holds the recheck's request open, so the payload below lands while the question is unanswered.
        let heldRequest = HeldLivenessFetch()
        model.livenessStateFetchOverrideForTesting = { await heldRequest.request() }
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))

        model.handleStreamDisconnect(nil, generation: generation)
        await heldRequest.waitUntilAsked()

        // A payload saying the session is running arrives from somewhere else entirely.
        model.applyControlResponseState(runningStatePayload(sessionID: sessionID))

        XCTAssertFalse(model.hasArmedReconnectForTesting, "an applied payload must not stand in for the recheck's own answer")
        XCTAssertTrue(model.hasArmedLivenessRecheckForTesting, "the question is still open until this recheck's request answers")

        // Only this recheck's own answer settles it.
        await heldRequest.answer(.success(runningStatePayload(sessionID: sessionID)))
        await waitForLivenessRecheckToSettle(model)

        XCTAssertTrue(model.hasArmedReconnectForTesting)
    }

    /// A device that confirms the session ended settles the question for good: the daemon streams live
    /// sessions only, so there is nothing to reconnect to and nothing to report — the pane's notice for
    /// this session is the ended one, not an outage. That includes clearing a notice an earlier
    /// unreachable attempt put up, and leaving no poll running behind a pane that is done.
    @MainActor func testAConfirmedEndedSessionQuiescesAndClearsTheNotice() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.reconnectBackoff.retryDelay = .milliseconds(1)
        model.reconnectBackoff.maxRetryDelay = .milliseconds(1)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        // One unreachable attempt first, so the notice this test watches get cleared was really raised.
        let script = LivenessFetchScript(
            queued: [.failure(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused"))],
            repeating: .success(endedStatePayload(sessionID: sessionID)))
        model.livenessStateFetchOverrideForTesting = { await script.answer() }
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))

        model.handleStreamDisconnect(nil, generation: generation)
        await waitForLivenessRecheckToSettle(model)

        XCTAssertFalse(model.isStateStreamDisconnected, "an ended session's refused stream is the expected answer, not an outage")
        XCTAssertFalse(model.hasArmedReconnectForTesting, "there is nothing to reconnect to")
        XCTAssertFalse(model.hasArmedLivenessRecheckForTesting, "a settled question must leave no poll running")
        let attempts = await script.attemptCount
        XCTAssertEqual(attempts, 2, "the device's answer must end the asking, not start another round")
    }

    /// A recheck answer describes a request that was in flight, and the pane can have been rescued while it
    /// flew — another listener registering is enough to install a stream and clear the notice. A failure
    /// that lands afterwards says nothing about the stream that now exists, so acting on it would leave an
    /// outage notice standing over a healthy pane with the loop exiting (a stream is installed) and nothing
    /// left that would ever take the notice down.
    @MainActor func testAFailureThatLandsAfterAStreamIsInstalledRaisesNoNotice() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        let heldRequest = HeldLivenessFetch()
        model.livenessStateFetchOverrideForTesting = { await heldRequest.request() }
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))

        model.handleStreamDisconnect(nil, generation: generation)
        await heldRequest.waitUntilAsked()

        // A second listener's connect lands while the recheck's request is still out: the session has a
        // live stream again, and the notice is down.
        model.installStreamClientForTesting(FakeStreamClient())

        await heldRequest.answer(.failure(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))
        await waitForLivenessRecheckToSettle(model)

        XCTAssertFalse(model.isStateStreamDisconnected, "a failure from a request the pane has already outlived must not put a notice over it")
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "the stream that rescued the pane must be left alone")
    }

    /// Only the daemon refusing this session answers the liveness question. A pinned identity that did not
    /// match, an `ok` response carrying no state, a request that never arrived — none of them is the device
    /// saying the session is gone, so quiescing on one strands a live session behind a stale `.exited` cache
    /// exactly the way issue #537 did.
    @MainActor func testAnUnclassifiableFailureKeepsAskingInsteadOfSettling() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.reconnectBackoff.retryDelay = .milliseconds(1)
        model.reconnectBackoff.maxRetryDelay = .milliseconds(1)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        let askedAgain = expectation(description: "the recheck asked again after failures it cannot read as an answer")
        askedAgain.expectedFulfillmentCount = 3
        askedAgain.assertForOverFulfill = false
        let script = LivenessFetchScript(
            queued: [
                .failure(TerminalServiceTLSError.certificatePinMismatch(expected: "SHA256:aa", actual: "SHA256:bb")),
                .failure(DeviceTerminalSessionStateModel.StateFetchError.missingState),
            ], repeating: .failure(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")), onAttempt: { _ in askedAgain.fulfill() }
        )
        model.livenessStateFetchOverrideForTesting = { await script.answer() }
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))

        model.handleStreamDisconnect(nil, generation: generation)

        await fulfillment(of: [askedAgain], timeout: 5)
        XCTAssertTrue(model.isStateStreamDisconnected, "a pane that cannot reach its session must say so")
        XCTAssertTrue(model.hasArmedLivenessRecheckForTesting, "no unreadable failure may close the question")

        // The device answers properly, and the question closes on that.
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        await script.setRepeating(.success(runningStatePayload(sessionID: sessionID)))
        await waitForLivenessRecheckToSettle(model)

        XCTAssertTrue(model.hasArmedReconnectForTesting, "the device's answer must re-arm the reconnect")
    }

    /// The one failure that IS an answer: a reachable, authenticated daemon refusing the session. It says
    /// the session is not there, so the pane stops asking and carries its ended notice rather than an
    /// outage — including clearing an outage an earlier unreachable attempt put up.
    @MainActor func testADaemonRefusingTheSessionSettlesTheRecheck() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.reconnectBackoff.retryDelay = .milliseconds(1)
        model.reconnectBackoff.maxRetryDelay = .milliseconds(1)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        let script = LivenessFetchScript(
            queued: [.failure(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused"))],
            repeating: .failure(
                DeviceTerminalSessionStateModel.StateFetchError.rejected(message: "Session is not running.", code: .sessionNotRunning)))
        model.livenessStateFetchOverrideForTesting = { await script.answer() }
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))

        model.handleStreamDisconnect(nil, generation: generation)
        await waitForLivenessRecheckToSettle(model)

        XCTAssertFalse(model.isStateStreamDisconnected, "a daemon that answered about this session is not an outage")
        XCTAssertFalse(model.hasArmedReconnectForTesting, "there is nothing to reconnect to")
        let attempts = await script.attemptCount
        XCTAssertEqual(attempts, 2, "the refusal must end the asking")
    }

    /// A refusal is not automatically an answer about the session. `SpacesDeviceAPIRequestSessionClient`
    /// returns an unauthorized reply as an ordinary `ok == false` response, so a revoked or rotated token
    /// arrives in the same shape as "this session is gone". Reading it as the session ending would clear the
    /// notice, stop the asking, and leave a pane holding a stale non-interactive cache frozen there — never
    /// reaching the credential and endpoint recovery each retry runs.
    @MainActor func testAnUnauthorizedRefusalKeepsAskingInsteadOfSettling() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.reconnectBackoff.retryDelay = .milliseconds(1)
        model.reconnectBackoff.maxRetryDelay = .milliseconds(1)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        let askedAgain = expectation(description: "the recheck asked again after an unauthorized refusal")
        askedAgain.expectedFulfillmentCount = 3
        askedAgain.assertForOverFulfill = false
        let script = LivenessFetchScript(
            queued: [], repeating: .failure(DeviceTerminalSessionStateModel.StateFetchError.rejected(message: "Unauthorized.", code: .unauthorized)),
            onAttempt: { _ in askedAgain.fulfill() })
        model.livenessStateFetchOverrideForTesting = { await script.answer() }
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))

        model.handleStreamDisconnect(nil, generation: generation)

        await fulfillment(of: [askedAgain], timeout: 5)
        XCTAssertTrue(model.isStateStreamDisconnected, "a pane whose credentials were refused still cannot reach its session")
        XCTAssertTrue(model.hasArmedLivenessRecheckForTesting, "a refusal about credentials must not close the question")

        // Re-authorized, the device answers about the session, and that settles it.
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        await script.setRepeating(.success(runningStatePayload(sessionID: sessionID)))
        await waitForLivenessRecheckToSettle(model)

        XCTAssertTrue(model.hasArmedReconnectForTesting, "the device's answer must re-arm the reconnect")
    }

    /// A recheck cancelled with its request still out (its pane's last listener left) can resume long after
    /// a replacement recheck has been armed for the same session. It must not release the slot on its way
    /// out: the replacement would be left running with nothing referring to it, so the next listener removal
    /// could not cancel it and the next drop would arm a second recheck alongside it.
    @MainActor func testAnAbandonedRecheckDoesNotReleaseItsReplacementsSlot() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        let heldRequest = HeldLivenessFetch()
        model.livenessStateFetchOverrideForTesting = { await heldRequest.request() }
        let subscriber = model.makeHostStateStreamSubscriber()

        // A pane opens, its stream drops against a stale `.exited` cache, and the recheck's request goes out.
        let firstGeneration = model.installStreamClientForTesting(FakeStreamClient())
        var firstHandle: (any TerminalRemoteStateStreamClient)? = try subscriber(sessionID, { _ in }, { _ in })
        model.applyControlResponseState(endedStatePayload(sessionID: sessionID))
        model.handleStreamDisconnect(nil, generation: firstGeneration)
        await heldRequest.waitUntilAsked(count: 1)

        // The pane goes away with that request still out, which cancels the recheck.
        firstHandle?.stop()
        firstHandle = nil
        await Task { @MainActor in }.value
        XCTAssertFalse(model.hasArmedLivenessRecheckForTesting, "a pane with no listeners must not keep asking")

        // A new pane opens on the same session and its own stream drops the same way.
        let secondGeneration = model.installStreamClientForTesting(FakeStreamClient())
        let secondHandle = try subscriber(sessionID, { _ in }, { _ in })
        model.handleStreamDisconnect(nil, generation: secondGeneration)
        await heldRequest.waitUntilAsked(count: 2)
        XCTAssertTrue(model.hasArmedLivenessRecheckForTesting, "the new pane's drop must open its own question")

        // Both requests answer at once: the abandoned one and the live one.
        await heldRequest.answer(.failure(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))
        await waitForLivenessRecheckToRaiseTheNotice(model)
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value

        XCTAssertTrue(model.hasArmedLivenessRecheckForTesting, "the abandoned recheck must not release the live recheck's slot")
        secondHandle.stop()
    }

    /// The 500ms subscribe throttle paces attempts; it must never be the reason a session is left with
    /// listeners and nothing arranging a stream for them. A pane replaced inside that window — its last
    /// listener leaving cancels the liveness recheck, and its replacement registers immediately — used to
    /// land exactly there: listeners present, no stream, no connect, no reconnect, nothing scheduled.
    @MainActor func testASubscribeTheThrottleTurnsAwayStillArmsRecovery() async throws {
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
                installationID: "INSTALLATION-THROTTLE-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID,
                platform: "macos", deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))
        model.reconnectBackoff.retryDelay = .seconds(600)
        model.reconnectBackoff.maxRetryDelay = .seconds(600)
        model.reconnectBackoff.retryJitterFraction = { 0 }
        // Only the stream connect is stubbed; the catch-up `.state` this registration fires reaches the real
        // server, so the session reads as running for the rest of the test.
        model.stateStreamConnectOverrideForTesting = { true }
        let subscriber = model.makeHostStateStreamSubscriber()

        // A pane subscribes, which stamps the throttle.
        var handle: (any TerminalRemoteStateStreamClient)? = try subscriber(sessionID, { _ in }, { _ in })
        await model.drainPendingConnectForTesting()
        XCTAssertTrue(model.hasActiveStreamClientForTesting)

        // It goes away, and its stream drops: no listener, so nothing is armed for it.
        handle?.stop()
        handle = nil
        await Task { @MainActor in }.value
        let generation = model.installStreamClientForTesting(FakeStreamClient())
        model.handleStreamDisconnect(nil, generation: generation)
        XCTAssertFalse(model.hasActiveStreamClientForTesting)
        XCTAssertFalse(model.hasArmedReconnectForTesting, "with no listener there is nothing to arm a retry for")

        // Its replacement registers immediately — well inside the throttle window.
        let replacementHandle = try subscriber(sessionID, { _ in }, { _ in })

        XCTAssertTrue(model.hasArmedReconnectForTesting, "a subscribe the throttle turned away must leave a retry armed behind it")
        replacementHandle.stop()
    }

    /// Which client a disconnect came from is what decides whether the model reacts to it — not how many
    /// stream generations have been issued since. A superseded client's late drop must still not tear down
    /// the stream that replaced it, but a drop from the client the model is actually holding must never be
    /// turned away: `ensureSubscriptionStarted` reads any installed client as a live subscription, so a
    /// dead one left installed strands the pane on a stream that will never carry another payload, with no
    /// notice and no retry (issue #537).
    ///
    /// Drives a real in-process `SpacesDeviceAPIServer` with the session registered as genuinely live
    /// (`startLiveSession`), so the retry armed by the honored drop actually reconnects — proving the model
    /// is left able to resubscribe, not merely that it cleared a field.
    @MainActor func testADropFromTheInstalledStreamIsHonoredAndLeavesTheModelAbleToResubscribe() async throws {
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
                installationID: "INSTALLATION-GUARD-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))
        model.reconnectBackoff.retryDelay = .milliseconds(5)
        model.reconnectBackoff.maxRetryDelay = .milliseconds(5)
        model.reconnectBackoff.retryJitterFraction = { 0 }

        // Installing a client before any listener registers keeps registration from dialing: the model
        // treats an installed stream as a live subscription.
        let supersededClient = StoppableFakeStreamClient()
        let supersededGeneration = model.installStreamClientForTesting(supersededClient)
        let installedClient = StoppableFakeStreamClient()
        let installedGeneration = model.installStreamClientForTesting(installedClient)
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyControlResponseState(runningStatePayload(sessionID: sessionID))

        // The superseded client's late drop says nothing about the stream that replaced it.
        model.handleStreamDisconnect(nil, generation: supersededGeneration)
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "a superseded client's drop must not tear down the stream that replaced it")
        XCTAssertFalse(model.isStateStreamDisconnected)

        // The installed client's own drop is honored: cleared, stopped (a pinned-TLS connection is released
        // only by an explicit cancel), reported, and retried.
        model.handleStreamDisconnect(nil, generation: installedGeneration)
        XCTAssertFalse(model.hasActiveStreamClientForTesting)
        XCTAssertEqual(installedClient.stopCount, 1, "a dropped stream must be stopped, not merely dereferenced")
        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertTrue(model.hasArmedReconnectForTesting)

        // Nothing dead is left installed, so the armed retry reaches the device and resubscribes.
        await model.drainPendingReconnectForTesting()

        XCTAssertTrue(model.hasActiveStreamClientForTesting, "the armed retry must reconnect the session")
        // `openStateStream` deliberately leaves the connection-stage tracker alone on a bare `start()`
        // success: the link is declared healthy only once a frame actually arrives over the new stream
        // (`applyStreamEvent`), not merely because the reconnect's blocking connect returned. A stub
        // stream client delivers no such frame, so the notice is still up here.
        XCTAssertTrue(model.isStateStreamDisconnected, "a reconnect alone is not proof of a healthy link; only a frame is")
    }

    /// A subscriber's handle is the only thing that takes its listener back out of the shared fan-out, and
    /// a handle can be released without anyone calling `stop()` — `RemoteGhosttySessionHost.deinit` returns
    /// without stopping anything when it runs off the main thread. A listener stranded by a released handle
    /// keeps every payload fanning out to a subscriber that is gone, and keeps `listeners` from ever
    /// falling empty, which is itself a guard the reconnect path reads (issue #537).
    @MainActor func testAListenerHandleReleasedWithoutStoppingLeavesTheFanOut() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.installStreamClientForTesting(FakeStreamClient())
        let deliveries = PayloadDeliveryCounter()
        var handle: (any TerminalRemoteStateStreamClient)? = try model.makeHostStateStreamSubscriber()(
            sessionID, { _ in deliveries.increment() }, { _ in })
        XCTAssertNotNil(handle)

        model.applyControlResponseState(
            statePayload(sessionID: sessionID, reason: TerminalRemoteSessionStateReason.runtimeState.rawValue, emittedAt: "2026-07-28T00:00:01Z"))
        XCTAssertEqual(deliveries.count, 1, "the listener must be attached while its handle is held")

        handle = nil
        // The detach hops to the main actor, and a main-actor task enqueued after it runs after it.
        await Task { @MainActor in }.value

        model.applyControlResponseState(
            statePayload(sessionID: sessionID, reason: TerminalRemoteSessionStateReason.runtimeState.rawValue, emittedAt: "2026-07-28T00:00:02Z"))
        XCTAssertEqual(deliveries.count, 1, "a released handle must take its listener out of the fan-out")
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

    /// F3: an input send is a different connection than the state subscription, and the racing
    /// command-channel connect it uses can exhaust every one of this device's candidate addresses on its
    /// own, the same hard evidence `openStateStream`'s `StateStreamConnectResult.failed(true)` already
    /// escalates on (`testAllCandidatesUnreachableEntersStage2ImmediatelyAndRetryResetsTheLadder` above).
    /// Before the fix, `reportFailedInputSend` routed every conclusive input failure through
    /// `tearDownStreamAndScheduleReconnect()` with no way to carry that evidence, so this always landed at
    /// stage 1 no matter how conclusive the input failure was.
    @MainActor func testInputSendFailingOnEveryCandidateEscalatesStraightToStage2() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceEndpointResolverError.allCandidatesUnreachable(hosts: ["127.0.0.1"])))

        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertEqual(model.connectionStageTracker.stage, .unreachable)
        XCTAssertTrue(model.connectionStageTracker.isBannerVisible, "stage 2 shows the banner immediately, with no grace")
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .seconds(TerminalUnreachableBackoff.ladderSeconds[0]),
            "every candidate refusing this input send is stage 2 evidence and paces off the unreachable ladder")
    }

    /// Negative case for the same evidence: a failure pinned to a single address (the ordinary shape every
    /// other conclusive input failure takes, e.g. a refused connection) is not the "every candidate"
    /// evidence stage 2 requires, and must keep the paced stage 1 cadence, proving the escalation above is
    /// driven specifically by `allCandidatesUnreachable`, not by every conclusive input failure.
    @MainActor func testInputSendRefusedOnOneAddressStaysAtStage1() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))

        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertEqual(model.connectionStageTracker.stage, .reconnecting)
        XCTAssertFalse(model.connectionStageTracker.isBannerVisible, "a single-address refusal is stage 1 evidence only")
    }

    /// Before the fix, `reportFailedInputSend`'s `guard !isStateStreamDisconnected else { return true }` sat
    /// ahead of the `allCandidatesUnreachable` classification, so a conclusive stage 2 input failure that
    /// arrived while a reconnect was already armed at stage 1 (a link the model already suspects, but has
    /// not yet confirmed unreachable) was discarded unread: the guard returned `true` before the error's
    /// shape was ever looked at, and the tracker stayed at `.reconnecting` no matter how conclusive the new
    /// evidence was. Every candidate refusing this send is the same hard evidence that escalates straight
    /// from `.connected` in `testInputSendFailingOnEveryCandidateEscalatesStraightToStage2`, and arriving
    /// mid-reconnect does not make it any less conclusive.
    @MainActor func testInputSendFailingOnEveryCandidateEscalatesFromStage1EvenWithAReconnectAlreadyArmed() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        // A single-address refusal first, landing the model at stage 1 with a reconnect already armed:
        // the same setup as `testInputSendRefusedOnOneAddressStaysAtStage1`.
        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))
        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertEqual(model.connectionStageTracker.stage, .reconnecting)
        XCTAssertFalse(model.connectionStageTracker.isBannerVisible)

        // A second, conclusive failure while still disconnected must escalate rather than being discarded
        // as merely a repeat of already-known news.
        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceEndpointResolverError.allCandidatesUnreachable(hosts: ["127.0.0.1"])))

        XCTAssertTrue(model.isStateStreamDisconnected)
        XCTAssertEqual(model.connectionStageTracker.stage, .unreachable)
        XCTAssertTrue(
            model.connectionStageTracker.isBannerVisible,
            "conclusive stage 2 evidence must escalate immediately even when a reconnect is already in flight")
    }

    /// Escalating to stage 2 from `reportFailedInputSend` has to retire the stale stage 1 timer that was
    /// already armed (`reconnectTask`, paced by the ordinary `reconnectBackoff` cadence) and rearm on the
    /// fresh delay the escalation itself computed: `scheduleReconnect(delay:)` no-ops while `reconnectTask
    /// != nil`, so leaving the stale timer running would waste the ladder's freshly computed rung and
    /// leave the redial pacing off the wrong cadence entirely until the stale timer eventually fires on
    /// its own schedule.
    @MainActor func testAllCandidatesInputFailureRetiresTheStaleStage1TimerAndRearmsOnTheLadder() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        // A distinct, short-but-not-ladder delay makes the stale stage 1 timer unmistakable below: none
        // of the stage 2 ladder's rungs (1/2/4/8/15s) land on it.
        model.reconnectBackoff.retryDelay = .seconds(3)
        model.reconnectBackoff.maxRetryDelay = .seconds(3)
        model.reconnectBackoff.retryJitterFraction = { 0 }

        // A single-address refusal first: stage 1, with a reconnect armed on the stale cadence.
        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))
        XCTAssertEqual(model.connectionStageTracker.stage, .reconnecting)
        XCTAssertEqual(model.lastReconnectDelayForTesting, .seconds(3), "the stale stage 1 timer is armed on the ordinary cadence")

        // Every candidate now refuses this send: conclusive stage 2 evidence, arriving while the stale
        // stage 1 timer above is still armed.
        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceEndpointResolverError.allCandidatesUnreachable(hosts: ["127.0.0.1"])))

        XCTAssertEqual(model.connectionStageTracker.stage, .unreachable)
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .seconds(TerminalUnreachableBackoff.ladderSeconds[0]),
            "escalating to stage 2 must retire the stale stage 1 timer and rearm on the ladder's first rung, "
                + "not leave the 3s stage 1 timer running underneath it")

        // Let the freshly armed retry fire and fail again with the same conclusive evidence. The next rung
        // must be the ladder's second one, proving the escalation above consumed the ladder exactly once,
        // not twice.
        model.stateStreamConnectOverrideForTesting = { false }
        model.lastDialExhaustedAllCandidatesForTesting = true
        await model.drainPendingReconnectForTesting()

        XCTAssertEqual(model.connectionStageTracker.stage, .unreachable)
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .seconds(TerminalUnreachableBackoff.ladderSeconds[1]),
            "the rung after the one the escalation consumed, not the one after that: the ladder must not be double-consumed")
    }

    /// The escalation in `reportFailedInputSend`'s `isStateStreamDisconnected` branch can fire while an
    /// automatic redial is already racing: `openStateStream` installs `streamClient` before its blocking
    /// dial resolves, so a client that dialed but has delivered no frame yet leaves the tracker at
    /// `.reconnecting`, indistinguishable here from no redial being in flight at all. Before the fix, the
    /// escalation armed the ladder's fresh redial without retiring that in-flight attempt first, so the
    /// new `reconnectTask` fired straight into either `ensureSubscriptionStarted()`'s own in-flight guard
    /// (`streamClient != nil || subscriptionConnectTask != nil`) or the reconnect timer's own
    /// `streamClient == nil` guard, and returned without ever dialing again: the pane was stuck waiting on
    /// the stream watchdog, or forever if keepalives kept arriving with no frame.
    @MainActor func testAllCandidatesInputFailureDuringAnInFlightRedialRetiresItSoTheLadderRedialRuns() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        model.installStreamClientForTesting(FakeStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        // A single-address refusal first: stage 1, with a reconnect armed.
        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))
        XCTAssertEqual(model.connectionStageTracker.stage, .reconnecting)

        // Simulate the automatic redial that stage 1 armed having already installed a client that has
        // delivered no frame: installing a client through this seam does not itself clear the outage, so
        // the tracker stays exactly where a real in-flight, frame-less redial would leave it.
        model.installStreamClientForTesting(FakeStreamClient())
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "the in-flight redial's client is installed")
        XCTAssertEqual(model.connectionStageTracker.stage, .reconnecting, "installing the client alone is not a frame, so the tracker does not clear")
        XCTAssertTrue(model.isStateStreamDisconnected)

        // Every candidate now refuses this send: conclusive stage 2 evidence, arriving while the in-flight
        // redial's own client above is still installed.
        XCTAssertTrue(model.reportFailedInputSend(SpacesDeviceEndpointResolverError.allCandidatesUnreachable(hosts: ["127.0.0.1"])))

        XCTAssertEqual(model.connectionStageTracker.stage, .unreachable)
        XCTAssertFalse(model.hasActiveStreamClientForTesting, "the escalation must retire the in-flight redial's stale client")
        XCTAssertEqual(
            model.lastReconnectDelayForTesting, .seconds(TerminalUnreachableBackoff.ladderSeconds[0]),
            "the ladder redial armed by the escalation, not a leftover stage 1 delay")

        // Let the ladder's fresh redial actually run: before the fix it returns without ever calling the
        // connect override below, because the retired attempt's client (or connect task) was still
        // occupying the in-flight guard(s) that turn a redial away.
        var connectOverrideInvoked = false
        model.stateStreamConnectOverrideForTesting = {
            connectOverrideInvoked = true
            return false
        }
        await model.drainPendingReconnectForTesting()

        XCTAssertTrue(connectOverrideInvoked, "the ladder redial must actually dial instead of being turned away by a stale in-flight attempt")
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
        // See the matching comment in `testADropFromTheInstalledStreamIsHonoredAndLeavesTheModelAbleToResubscribe`:
        // a bare reconnect is deliberately not treated as proof the link is healthy, only a frame is.
        XCTAssertTrue(model.isStateStreamDisconnected, "a reconnect alone is not proof of a healthy link; only a frame is")
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

    /// `ensureSubscriptionStarted`'s in-flight guard (`streamClient != nil || subscriptionConnectTask !=
    /// nil`) exists so a second automatic attempt cannot stack on top of one already running. But an
    /// automatic reconnect timer can start an attempt moments before the user taps Retry, and that same
    /// guard then makes Retry itself a no-op: nothing happens until the stale attempt's own connect
    /// timeout or stream watchdog eventually resolves it. Retry must instead retire that attempt and start
    /// its own immediately.
    @MainActor func testRetryDuringAnInFlightConnectStartsAFreshAttemptRatherThanNoOpping() async throws {
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
                installationID: "INSTALLATION-RETRY-INFLIGHT-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID,
                platform: "macos", deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))

        var connectCount = 0
        var resumeFirstConnect: ((Bool) -> Void)?
        let reachedFirstConnect = expectation(description: "the first connect reached the controlled resolution point")
        model.stateStreamConnectOverrideForTesting = { [weak model] in
            connectCount += 1
            guard connectCount == 1 else {
                // Retry's own fresh attempt (and anything after it) resolves immediately, against the real
                // server, so recovery can be observed rather than just that a second attempt got started.
                model?.stateStreamConnectOverrideForTesting = nil
                return true
            }
            return await withCheckedContinuation { continuation in
                resumeFirstConnect = { continuation.resume(returning: $0) }
                reachedFirstConnect.fulfill()
            }
        }

        // An automatic reconnect timer's attempt is already in flight when Retry is tapped: this is
        // reproduced directly (skipping the timer itself) since that is the only fact this test depends
        // on, not how the attempt was started.
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        await fulfillment(of: [reachedFirstConnect], timeout: 5)
        XCTAssertEqual(connectCount, 1)
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "the in-flight connect must have installed its stream client")

        model.retryStateStreamConnection()
        await model.drainPendingConnectForTesting()

        XCTAssertEqual(connectCount, 2, "Retry must start a new connect attempt rather than waiting out the one already in flight")
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "Retry's own connect must have installed a fresh stream client")

        // The stale first attempt finally resolves, long after Retry's own connect already installed a
        // healthy client: it must not be able to act on that installation.
        resumeFirstConnect?(true)
        // There is nothing to await the stale task's resumption directly (it is not the current
        // `subscriptionConnectTask`), so give its continuation a turn to run before asserting nothing
        // changed as a result.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(connectCount, 2, "the stale attempt's belated completion must not trigger another connect")
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "the stale attempt's belated completion must not disturb Retry's healthy client")
    }

    /// A superseded attempt's belated completion must be dropped, not just harmless to observe once: this
    /// pins the two consequences a missing `connectAttemptGeneration` gate would have. First, the
    /// replacement must be free to fully recover (deliver a frame, hide the banner) while the stale
    /// attempt is still hung. Second, the stale attempt resolving afterward as a hard failure must not
    /// retroactively drag the tracker into `.unreachable` over that already-healthy stream, and the
    /// reconnect machinery `ensureSubscriptionStarted`/`retryStateStreamConnection` share must still work
    /// afterward (a later real stream loss still arms a reconnect).
    @MainActor func testStaleAttemptResolvingAfterRetryDoesNotClobberTheReplacementsRecoveredState() async throws {
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
                installationID: "INSTALLATION-STALE-COMPLETE-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID,
                platform: "macos", deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))

        var connectCount = 0
        var resumeFirstConnect: ((Bool) -> Void)?
        let reachedFirstConnect = expectation(description: "the first connect reached the controlled resolution point")
        model.stateStreamConnectOverrideForTesting = { [weak model] in
            connectCount += 1
            guard connectCount == 1 else {
                model?.stateStreamConnectOverrideForTesting = nil
                return true
            }
            return await withCheckedContinuation { continuation in
                resumeFirstConnect = { continuation.resume(returning: $0) }
                reachedFirstConnect.fulfill()
            }
        }

        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        await fulfillment(of: [reachedFirstConnect], timeout: 5)
        XCTAssertEqual(connectCount, 1)

        model.retryStateStreamConnection()
        await model.drainPendingConnectForTesting()
        XCTAssertEqual(connectCount, 2, "Retry must start a fresh attempt rather than waiting out the hung one")
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "Retry's own connect must have installed a fresh stream client")

        // Prove the replacement can fully recover while the first attempt is still hung: deliver a frame
        // over it, which is what actually clears the banner (`openStateStream` succeeding is not enough,
        // see its doc comment).
        guard let replacementGeneration = model.installedStreamClientGenerationForTesting else {
            return XCTFail("Retry's connect must have installed a stream client with a generation")
        }
        model.applyStreamEvent(runningStatePayload(sessionID: sessionID), generation: replacementGeneration)
        XCTAssertEqual(model.connectionStageTracker.stage, .connected, "a delivered frame must clear the banner")
        XCTAssertFalse(model.connectionStageTracker.isBannerVisible)

        // The stale first attempt finally resolves as the strongest possible failure evidence (every
        // candidate address unreachable). Without the generation gate this reaches
        // `establishStateStreamConnection`'s `scheduleReconnect(after:)` and drags the tracker to
        // `.unreachable` over the replacement's already-healthy stream.
        model.lastDialExhaustedAllCandidatesForTesting = true
        resumeFirstConnect?(false)
        // Nothing awaits the stale task directly (it is not the current `subscriptionConnectTask`), so
        // give its continuation's resumption a turn to run to completion before asserting nothing changed.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            model.connectionStageTracker.stage, .connected,
            "the stale attempt's belated failure must not clobber the replacement's recovered stage")
        XCTAssertFalse(
            model.connectionStageTracker.isBannerVisible,
            "the stale attempt's belated failure must not bring the banner back over a healthy stream")
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "the replacement's stream client must still be installed")

        // The reconnect machinery `subscriptionConnectTask` feeds into must still work afterward: a real
        // stream loss on the (still current) replacement still arms a reconnect.
        model.handleStreamDisconnect(nil, generation: replacementGeneration)
        XCTAssertTrue(model.hasArmedReconnectForTesting, "a real disconnect on the replacement must still arm a reconnect")
    }

    /// A connect attempt's dial can succeed after it has already been superseded (Retry, or a newer
    /// attempt that already installed its own client): the client it produced is a real, connected
    /// subscription that must be stopped rather than left connected and forgotten, or installed over the
    /// replacement that has already taken its place. Exercises `finishSuccessfulConnect` directly (the
    /// concrete stream client offers no seam to race a real connect's success against supersession), the
    /// same way `applyStreamEvent`/`handleStreamDisconnect` are tested elsewhere in this file.
    @MainActor func testSuccessfulConnectSupersededWhileInFlightStopsItsClientInsteadOfInstalling() throws {
        let model = try makeModel(sessionID: "session-\(UUID().uuidString)")

        let replacement = FakeStreamClient()
        model.installStreamClientForTesting(replacement)

        let staleFromSupersededAttempt = FakeStreamClient()
        model.finishSuccessfulConnect(staleFromSupersededAttempt, connectedHost: "203.0.113.5")

        XCTAssertEqual(staleFromSupersededAttempt.stopCount, 1, "a superseded attempt's connected client must be stopped, not left connected")
        XCTAssertEqual(replacement.stopCount, 0, "the replacement client already installed must be left alone")
        XCTAssertTrue(model.hasActiveStreamClientForTesting, "only the replacement must remain installed")
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
        model.linkCorroborationProbeForTesting = { _ in TerminalServiceTLSError.certificatePinMismatch(expected: "SHA256:aa", actual: "SHA256:bb") }

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
            let deviceRequest = try TerminalPaneService.deviceTerminalControlRequest(sessionID: sessionID, controlRequest: controlRequest)
            XCTAssertEqual(
                Model.controlRequestTimeoutSeconds(for: controlRequest, command: .terminalControl(deviceRequest)),
                Model.interactiveControlRequestTimeoutSeconds, "'\(controlRequest.command)' must use the shortened interactive deadline")
        }
        for controlRequest in nonInteractiveRequests {
            let deviceRequest = try TerminalPaneService.deviceTerminalControlRequest(sessionID: sessionID, controlRequest: controlRequest)
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
        model.applyControlResponseState(
            statePayload(sessionID: sessionID, reason: TerminalRemoteSessionStateReason.runtimeState.rawValue, emittedAt: "2026-07-28T00:00:09Z"))
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
            statePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.runtimeState.rawValue, emittedAt: "2026-07-28T00:00:01Z",
                title: "before"))
        model.applyStreamEvent(
            clipboardPayload(sessionID: sessionID, emittedAt: "2026-07-28T00:00:09Z", targetClientID: "owner", text: "copied", title: "clipboard"),
            generation: generation)
        model.applyControlResponseState(
            statePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.runtimeState.rawValue, emittedAt: "2026-07-28T00:00:05Z",
                title: "after"))

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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.clipboardWrite.rawValue, emittedAt: emittedAt, sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: title, workingDirectory: "/tmp",
            outputByteCount: nil, clipboardWrite: TerminalClipboardWritePayload(targetClientID: targetClientID, text: text))
    }

    /// Waits for the open liveness question to raise the disconnected notice, bounded so a recheck that
    /// never acts fails the test rather than hanging it.
    @MainActor private func waitForLivenessRecheckToRaiseTheNotice(
        _ model: DeviceTerminalSessionStateModel, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !model.isStateStreamDisconnected { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.isStateStreamDisconnected, "the recheck never reported the unreachable device", file: file, line: line)
    }

    /// Waits for the open liveness question to close, bounded so a recheck that never settles fails the
    /// test rather than hanging it. `hasArmedLivenessRecheckForTesting` is cleared only after the answer
    /// has been acted on, so everything the settle decided is readable once this returns.
    @MainActor private func waitForLivenessRecheckToSettle(
        _ model: DeviceTerminalSessionStateModel, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, model.hasArmedLivenessRecheckForTesting { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.hasArmedLivenessRecheckForTesting, "the liveness recheck never settled", file: file, line: line)
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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.runtimeState.rawValue, emittedAt: "2026-07-24T00:00:02Z",
            sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                state: .running, updatedAt: "2026-07-24T00:00:01Z", title: "t", workingDirectory: "/tmp"), attachmentSnapshot: nil, title: "t",
            workingDirectory: "/tmp", outputByteCount: nil)
    }

    /// The device's report that this session's process exited — the state that makes a live stream
    /// unwanted, so no drop against it is an outage.
    private func endedStatePayload(sessionID: String) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.runtimeState.rawValue, emittedAt: "2026-07-24T00:00:01Z",
            sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .exited, updatedAt: "2026-07-24T00:00:01Z",
                exitedAt: "2026-07-24T00:00:01Z"), attachmentSnapshot: nil, title: "t", workingDirectory: "/tmp", outputByteCount: nil)
    }

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair
    /// only needs a stable certificate to pin. Mirrors `DeviceTerminalSessionStateModelRecoveryTests`.
    private static let tlsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "device-terminal-session-state-model-stream-connection-tests-tls-\(UUID().uuidString)", isDirectory: true)

    /// `tlsRoot` is process-lifetime, shared across every test method in this class, so it is cleaned up
    /// once here rather than per-test in `tearDownWithError`.
    override class func tearDown() {
        try? FileManager.default.removeItem(at: tlsRoot)
        super.tearDown()
    }
}

/// `TerminalRemoteStateStreamClient` requires only `stop()`; the model treats any conforming object as
/// an installed stream, which is all these tests need. Counts `stop()` calls so a test can tell a
/// superseded client was released rather than left connected and forgotten.
private final class FakeStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable {
    private(set) var stopCount = 0
    func stop() { stopCount += 1 }
}

/// Scripts the answers the liveness recheck's own `.state` request comes back with, so a test can drive
/// that state machine through unreachable attempts and device answers without a device. It also counts how
/// many times it was asked, which is how a test observes that a failed attempt was re-asked rather than
/// swallowed.
private actor LivenessFetchScript {
    private var queued: [Result<GhosttyRemoteSessionStatePayload, any Error>]
    private var repeating: Result<GhosttyRemoteSessionStatePayload, any Error>
    private var attempts = 0
    private let onAttempt: @Sendable (Int) -> Void

    init(
        queued: [Result<GhosttyRemoteSessionStatePayload, any Error>] = [], repeating: Result<GhosttyRemoteSessionStatePayload, any Error>,
        onAttempt: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.queued = queued
        self.repeating = repeating
        self.onAttempt = onAttempt
    }

    var attemptCount: Int { attempts }

    func answer() -> Result<GhosttyRemoteSessionStatePayload, any Error> {
        attempts += 1
        onAttempt(attempts)
        return queued.isEmpty ? repeating : queued.removeFirst()
    }

    /// What every attempt from now on answers with — the device coming back, or going away.
    func setRepeating(_ result: Result<GhosttyRemoteSessionStatePayload, any Error>) { repeating = result }
}

/// Holds one liveness request open until the test answers it, so a test can act while the question is
/// unanswered — which is the only window in which something else could wrongly settle it.
private actor HeldLivenessFetch {
    private var pendingRequests: [CheckedContinuation<Result<GhosttyRemoteSessionStatePayload, any Error>, Never>] = []
    private var pendingAnswer: Result<GhosttyRemoteSessionStatePayload, any Error>?
    private var askedCount = 0
    private var askedWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func request() async -> Result<GhosttyRemoteSessionStatePayload, any Error> {
        askedCount += 1
        let reached = askedWaiters.filter { $0.threshold <= askedCount }
        askedWaiters.removeAll { $0.threshold <= askedCount }
        for waiter in reached { waiter.continuation.resume() }
        if let pendingAnswer {
            self.pendingAnswer = nil
            return pendingAnswer
        }
        return await withCheckedContinuation { pendingRequests.append($0) }
    }

    func waitUntilAsked(count: Int = 1) async {
        guard askedCount < count else { return }
        await withCheckedContinuation { askedWaiters.append((count, $0)) }
    }

    /// Answers every request being held, so a test can release an abandoned recheck's request and its
    /// replacement's together — which is the ordering that decides who owns the recheck slot.
    func answer(_ result: Result<GhosttyRemoteSessionStatePayload, any Error>) {
        guard !pendingRequests.isEmpty else {
            pendingAnswer = result
            return
        }
        let held = pendingRequests
        pendingRequests.removeAll()
        for continuation in held { continuation.resume(returning: result) }
    }
}

/// A stream client that records being stopped, so a test can prove a dropped subscription was cancelled
/// rather than merely dereferenced.
private final class StoppableFakeStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0

    var stopCount: Int { lock.withLock { stops } }

    func stop() { lock.withLock { stops += 1 } }
}

/// Counts payloads delivered to a fan-out listener. The model's host-facing subscriber takes a `@Sendable`
/// event callback, so the count lives behind a lock rather than in a captured local.
private final class PayloadDeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries = 0

    var count: Int { lock.withLock { deliveries } }

    func increment() { lock.withLock { deliveries += 1 } }
}

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
