import Foundation
import XCTest
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

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
/// XCTest (serial within the class), matching `DeviceTerminalSessionStateModelRecoveryTests`.
final class DeviceTerminalSessionStateModelStreamConnectionTests: XCTestCase {
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

    // MARK: Fixtures

    /// A model pointed at a device that cannot be reached (port 1 refuses immediately). Nothing in
    /// these tests lets it dial: a stream client is installed before any listener registers.
    @MainActor private func makeModel(sessionID: String) throws -> DeviceTerminalSessionStateModel {
        let device = SpacesPairedDeviceRecord(
            id: "remote-\(UUID().uuidString)", name: "Remote", platform: "linux", host: "127.0.0.1", port: 1,
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
}

/// `TerminalRemoteStateStreamClient` requires only `stop()`; the model treats any conforming object as
/// an installed stream, which is all these tests need.
private final class FakeStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable { func stop() {} }
