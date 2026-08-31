import Foundation
import XCTest
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

/// What a listener that arrives mid-stream is handed.
///
/// The model caches the session's state so a late subscriber — a pane's render host, created after the
/// model has already been streaming — renders immediately instead of waiting for the next payload. The
/// cache is the wire payload, and in steady state the render update on the wire is a delta: absolute
/// values for the cells that changed and nothing for the rest. A delta means nothing to a listener that
/// holds no baseline to apply it to — it cannot paint, it can only fail and cost the resync round trip
/// that failure buys. These tests pin the rule: the replay hands over a full frame or no frame at all.
final class DeviceTerminalSessionStateModelListenerReplayTests: XCTestCase {
    @MainActor func testLateListenerIsReplayedTheCachedFullFrame() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        let generation = model.installStreamClientForTesting(FakeReplayStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        model.applyStreamEvent(
            try payload(sessionID: sessionID, emittedAt: "2026-08-09T00:00:00Z", update: .full(frame(text: "alpha", sessionRevision: 1))),
            generation: generation)

        var replayed: [GhosttyRemoteSessionStatePayload] = []
        model.startStateStream(onUpdate: { replayed.append($0) }, onDisconnect: { _ in })

        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed.first?.renderText, "alpha", "a cached full frame is exactly what a late listener needs to paint")
    }

    @MainActor func testLateListenerIsNotReplayedARawDelta() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        let generation = model.installStreamClientForTesting(FakeReplayStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        let firstFrame = frame(text: "alpha", sessionRevision: 1)
        let secondFrame = frame(text: "bravo", sessionRevision: 2)
        let delta = GhosttyRenderUpdateFactory.makeUpdate(target: secondFrame, baseline: GhosttyRenderUpdateBaseline(frame: firstFrame))
        XCTAssertEqual(delta.kind, .delta)
        model.applyStreamEvent(
            try payload(sessionID: sessionID, emittedAt: "2026-08-09T00:00:00Z", update: .full(firstFrame)), generation: generation)
        model.applyStreamEvent(try payload(sessionID: sessionID, emittedAt: "2026-08-09T00:00:01Z", update: delta), generation: generation)

        var replayed: [GhosttyRemoteSessionStatePayload] = []
        model.startStateStream(onUpdate: { replayed.append($0) }, onDisconnect: { _ in })

        let replayedPayload = try XCTUnwrap(replayed.first)
        XCTAssertFalse(replayedPayload.hasRenderUpdate, "a delta on the wire is unusable to a listener with no baseline; it must not be replayed")
        // The rest of the state still reaches the listener: it is what tells the pane who owns the
        // session and whether it is still running, and none of it depends on holding a baseline.
        XCTAssertEqual(replayedPayload.title, "live")
        XCTAssertEqual(replayedPayload.workingDirectory, "/tmp/live")
    }

    /// Withholding the delta from the replay must not throw the model's own cache away: the delta is
    /// still the state every later payload merges onto, and the listeners already on the stream have the
    /// baseline it applies to.
    @MainActor func testWithholdingTheDeltaLeavesTheCachedStateIntact() throws {
        let sessionID = "session-\(UUID().uuidString)"
        let model = try makeModel(sessionID: sessionID)
        let generation = model.installStreamClientForTesting(FakeReplayStreamClient())
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        let firstFrame = frame(text: "alpha", sessionRevision: 1)
        let secondFrame = frame(text: "bravo", sessionRevision: 2)
        let delta = GhosttyRenderUpdateFactory.makeUpdate(target: secondFrame, baseline: GhosttyRenderUpdateBaseline(frame: firstFrame))
        model.applyStreamEvent(
            try payload(sessionID: sessionID, emittedAt: "2026-08-09T00:00:00Z", update: .full(firstFrame)), generation: generation)
        model.applyStreamEvent(try payload(sessionID: sessionID, emittedAt: "2026-08-09T00:00:01Z", update: delta), generation: generation)

        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })

        XCTAssertEqual(model.latestRemoteStatePayload?.decodedRenderUpdate?.kind, .delta)
    }

    // MARK: Fixtures

    private func frame(text: String, sessionRevision: UInt64) -> GhosttyRenderFrame {
        GhosttyRenderFrame(sessionRevision: sessionRevision, ownerEpoch: 0, snapshot: snapshot(text: text))
    }

    private func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let cells = text.unicodeScalars.map { scalar in
            GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
        }
        return GhosttyTerminalSnapshot(
            columns: cells.count, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000, cells: cells)
    }

    private func payload(sessionID: String, emittedAt: String, update: GhosttyRenderUpdate) throws -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: emittedAt, sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: "live",
            workingDirectory: "/tmp/live", outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(update))
    }

    /// A model pointed at a device on port 1, an address these tests never dial: a stream client is
    /// installed before any listener registers, which is what keeps `ensureSubscriptionStarted` from
    /// connecting. Mirrors `DeviceTerminalSessionStateModelStreamConnectionTests`.
    @MainActor private func makeModel(sessionID: String) throws -> DeviceTerminalSessionStateModel {
        let device = SpacesPairedDeviceRecord(
            id: "remote-\(UUID().uuidString)", name: "Remote", platform: "linux", hosts: ["127.0.0.1"], port: 1,
            certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), createdAt: "2026-08-09T00:00:00Z",
            updatedAt: "2026-08-09T00:00:00Z", lastSelectedAt: "2026-08-09T00:00:00Z")
        return try DeviceTerminalSessionStateModel(
            device: device, sessionID: sessionID,
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-08-09T00:00:00Z",
                workspaceID: "workspace", kind: .shell),
            clientApp: SpacesDeviceClientApp(
                installationID: "INSTALLATION-REPLAY-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), authToken: "token"))
    }
}

/// `TerminalRemoteStateStreamClient` requires only `stop()`; the model treats any conforming object as
/// an installed stream, which is all these tests need.
private final class FakeReplayStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable { func stop() {} }
