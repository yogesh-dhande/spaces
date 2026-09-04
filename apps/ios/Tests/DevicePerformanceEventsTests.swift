#if canImport(UIKit)
    import Foundation
    import UIKit
    import XCTest
    import spacesdevicecore
    @testable import spacesterminalcore
    @testable import SpacesMobile

    /// The on-device performance baseline (see `DevicePerformanceLog` and the events `TerminalViewerModel`
    /// emits directly) is measure-only and has no user-visible behavior to assert on, so these tests
    /// intercept `SpacesDeviceTerminalPerformanceLogger.emit` through its `sinkForTesting` seam instead of
    /// reading a log file, and assert on the events that land.
    @MainActor final class DevicePerformanceEventsTests: XCTestCase {
        override func tearDown() {
            SpacesDeviceTerminalPerformanceLogger.sinkForTesting = nil
            super.tearDown()
        }

        /// Mirrors `TerminalViewerOpenPaintTests.testOpenHoldsTheSessionsGridAndPaintsOnceTheViewportGridArrives`:
        /// a frame at the viewport's own grid is what ends the open hold and paints, and that is exactly
        /// the moment `terminal_first_paint` means to capture.
        func testFirstPaintIsLoggedOnceWhenTheMatchingFrameArrives() async throws {
            let events = EventCollector()
            SpacesDeviceTerminalPerformanceLogger.sinkForTesting = { events.record($0) }

            let model = makeModel()
            defer { model.stop() }
            model.start()
            model.updateViewportSize(columns: 40, rows: 30)

            // The first payload establishes ownership at a grid the viewport has already moved past
            // (a barrier, so it applies even while the open hold is on); it must not itself release the
            // hold or log a first paint. The second, at the viewport's own grid, is the one that does.
            await model.applyLatestState(
                try Self.framedState(
                    columns: 80, rows: 24, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)
            XCTAssertTrue(events.recorded.filter { $0.name == "terminal_first_paint" }.isEmpty, "a frame at a grid the viewport moved past must not paint")

            await model.applyLatestState(
                try Self.framedState(columns: 40, rows: 30, revision: 2, emittedAt: "2026-06-04T14:23:32Z", owner: model.remoteClientForTesting),
                isOutOfBand: false)

            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 40, "sanity: the matching frame must have painted")
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting, "sanity: the hold must have released")

            let openBeginEvents = events.recorded.filter { $0.name == "terminal_open_begin" }
            XCTAssertEqual(openBeginEvents.count, 1, "start() must log exactly one open begin")
            XCTAssertEqual(openBeginEvents.first?.attributes["source"], "list", "the default open source is list")

            // The release itself (openScreenHold.releasePendingAfterSubmit(), which flips
            // setHoldsScreenUpdates) runs synchronously off the main actor from the pipeline's `didSubmit`
            // hook, and `await applyLatestState` above only guarantees that the frame's own `apply` has
            // run on the main actor, not that the perf-log hop `didSubmit` schedules alongside it has
            // landed yet (see the `didSubmit` closure's own comment). So this polls rather than asserting
            // immediately.
            await waitUntil("terminal_first_paint to be logged") { events.recorded.contains { $0.name == "terminal_first_paint" } }
            let firstPaintEvents = events.recorded.filter { $0.name == "terminal_first_paint" }
            XCTAssertEqual(firstPaintEvents.count, 1, "the matching frame must log exactly one first paint")
            XCTAssertEqual(firstPaintEvents.first?.attributes["hold_released_by"], "matching_frame")
            XCTAssertEqual(firstPaintEvents.first?.attributes["columns"], "40")
            XCTAssertEqual(firstPaintEvents.first?.attributes["rows"], "30")
            XCTAssertNotNil(firstPaintEvents.first?.elapsedMS, "elapsed time since terminal_open_begin must be recorded")
        }

        /// Mirrors `TerminalViewerOpenPaintTests.testViewportReportReleasesTheHoldAndPaintsTheFrameTheGateSuppressed`:
        /// a barrier frame arrives before the surface has reported a grid, so nothing can match it yet;
        /// reporting the viewport afterward at that same grid is what releases the hold, from the frame
        /// already stored rather than a newly reduced one. This is the reopen path for a retained viewer.
        func testFirstPaintIsLoggedWithStoredFrameWhenTheViewportReportMatchesAnAlreadyStoredFrame() async throws {
            let events = EventCollector()
            SpacesDeviceTerminalPerformanceLogger.sinkForTesting = { events.record($0) }

            let model = makeModel()
            defer { model.stop() }
            model.start()

            await model.applyLatestState(
                try Self.framedState(
                    columns: 40, rows: 30, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)
            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting, "no viewport has been reported yet, so nothing can match")

            model.updateViewportSize(columns: 40, rows: 30)
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting, "the report matches the already-stored frame")

            await waitUntil("terminal_first_paint to be logged") { events.recorded.contains { $0.name == "terminal_first_paint" } }
            let firstPaintEvents = events.recorded.filter { $0.name == "terminal_first_paint" }
            XCTAssertEqual(firstPaintEvents.count, 1)
            XCTAssertEqual(firstPaintEvents.first?.attributes["hold_released_by"], "stored_frame")
            XCTAssertEqual(firstPaintEvents.first?.attributes["columns"], "40")
            XCTAssertEqual(firstPaintEvents.first?.attributes["rows"], "30")
        }

        /// Mirrors `TerminalViewerOpenPaintTests.testHoldReleasesWhenItsBoundedWaitExpires`: past the
        /// bounded wait, whatever is newest paints, and that release is the other named path (besides a
        /// matched frame) the baseline must account for.
        func testFirstPaintIsLoggedWithTimeoutWhenTheBoundedWaitExpires() async throws {
            let events = EventCollector()
            SpacesDeviceTerminalPerformanceLogger.sinkForTesting = { events.record($0) }

            let model = makeModel()
            defer { model.stop() }
            model.openScreenHoldTimeoutForTesting = .milliseconds(50)
            model.start()
            model.updateViewportSize(columns: 40, rows: 30)

            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting)
            await waitUntil("the bounded wait to expire") { !model.isHoldingOpenScreenUpdatesForTesting }

            await waitUntil("terminal_first_paint to be logged") { events.recorded.contains { $0.name == "terminal_first_paint" } }
            let firstPaintEvents = events.recorded.filter { $0.name == "terminal_first_paint" }
            XCTAssertEqual(firstPaintEvents.count, 1)
            XCTAssertEqual(firstPaintEvents.first?.attributes["hold_released_by"], "timeout")
            XCTAssertEqual(firstPaintEvents.first?.attributes["columns"], "40")
            XCTAssertEqual(firstPaintEvents.first?.attributes["rows"], "30")
        }

        /// `terminal_back` measures the user leaving a terminal through the back control, so only that
        /// path logs it: `stop()` also runs for forced teardowns (`onDisappear` after a device switch or a
        /// revoked pairing), and those must not count as a dwell-before-back sample.
        func testTerminalBackIsLoggedOnlyForBackNavigation() async throws {
            let events = EventCollector()
            SpacesDeviceTerminalPerformanceLogger.sinkForTesting = { events.record($0) }

            let stopped = makeModel()
            stopped.start()
            stopped.stop()
            XCTAssertTrue(events.recorded.filter { $0.name == "terminal_back" }.isEmpty, "a plain stop is not a back navigation")

            let backed = makeModel()
            backed.start()
            await backed.prepareForBackNavigation()
            backed.stop()
            let backEvents = events.recorded.filter { $0.name == "terminal_back" }
            XCTAssertEqual(backEvents.count, 1, "the back control's path must log exactly one terminal_back")
            XCTAssertNotNil(backEvents.first?.elapsedMS, "dwell since terminal_open_begin must be recorded")
        }

        /// A connect that dials, subscribes, and delivers a frame logs a `stream_first_frame` (the first
        /// payload the stream ever delivers, the moment the connection is actually proven up) and no
        /// `stream_connect_end`: that event's success branch was removed because `subscribe` returning is
        /// only proof the dial and TLS handshake completed, not that the connection is usable, so it can
        /// no longer misreport a near-zero "success" for an attempt that then fails; `stream_connect_end`
        /// now fires only from the failure branch in `handleConnectError`.
        func testFirstFrameIsLoggedAndConnectEndIsNotForAConnectThatDeliversAFrame() async throws {
            let events = EventCollector()
            SpacesDeviceTerminalPerformanceLogger.sinkForTesting = { events.record($0) }

            let payload = Self.bareState(emittedAt: "2026-06-04T14:23:31Z")
            let backend = FrameDeliveringBackend(payload: payload, host: "127.0.0.1")
            let model = makeModel(backend: backend)
            defer { model.stop() }
            model.start()

            await waitUntil("stream_first_frame to be logged") { events.recorded.contains { $0.name == "stream_first_frame" } }

            let firstFrameEvents = events.recorded.filter { $0.name == "stream_first_frame" }
            XCTAssertEqual(firstFrameEvents.count, 1, "the stream's first payload must log exactly one stream_first_frame")
            XCTAssertEqual(firstFrameEvents.first?.attributes["host"], "127.0.0.1")
            XCTAssertNotNil(firstFrameEvents.first?.elapsedMS, "elapsed time since the connect attempt began must be recorded")

            XCTAssertTrue(
                events.recorded.filter { $0.name == "stream_connect_end" }.isEmpty,
                "a successful connect must not log stream_connect_end; only the failure branch does")
        }

        /// The keyboard animation can settle at a grid only after passing through an earlier one, and a
        /// frame at that earlier grid can arrive before the surface reports the final one. This drives that
        /// sequence through `TerminalViewerModel`'s quiet window and asserts only the settled grid logs.
        func testKeyboardResizeSkipsAnIntermediateGridAndLogsOnlyTheSettledOne() async throws {
            let events = EventCollector()
            SpacesDeviceTerminalPerformanceLogger.sinkForTesting = { events.record($0) }

            let model = makeModel()
            defer { model.stop() }
            model.start()

            model.noteKeyboardToggled(visible: true)
            model.updateViewportSize(columns: 40, rows: 20)
            await model.applyLatestState(
                try Self.framedState(columns: 40, rows: 20, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: model.remoteClientForTesting),
                isOutOfBand: false)

            // Before the 500 ms quiet window can close out the 40x20 candidate above, the keyboard settles
            // at a different grid: this must discard that candidate, not let it log alongside (or instead
            // of) the grid the transition actually ends at.
            model.updateViewportSize(columns: 40, rows: 18)
            await model.applyLatestState(
                try Self.framedState(columns: 40, rows: 18, revision: 2, emittedAt: "2026-06-04T14:23:32Z", owner: model.remoteClientForTesting),
                isOutOfBand: false)

            await waitUntil("viewport_resize_frame_visible to be logged") { events.recorded.contains { $0.name == "viewport_resize_frame_visible" } }
            let resizeEvents = events.recorded.filter { $0.name == "viewport_resize_frame_visible" }
            XCTAssertEqual(resizeEvents.count, 1, "only the settled grid must be logged, not the intermediate one")
            XCTAssertEqual(resizeEvents.first?.attributes["columns"], "40")
            XCTAssertEqual(resizeEvents.first?.attributes["rows"], "18")
        }

        // MARK: - Fixtures

        /// Collects emitted events under a lock: `emit` can run from `Task { ... }` bodies scheduled onto
        /// the main actor from other contexts (the stream's `onEvent` closure), so a plain array captured
        /// by a closure is not safely readable from the test body without one.
        private final class EventCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [SpacesDeviceTerminalPerformanceEvent] = []

            func record(_ event: SpacesDeviceTerminalPerformanceEvent) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }

            var recorded: [SpacesDeviceTerminalPerformanceEvent] {
                lock.lock()
                defer { lock.unlock() }
                return events
            }
        }

        /// Hands back one payload through `onEvent` before returning its stream handle, reproducing the
        /// real backend's race where a subscription can start delivering frames before `subscribe()`
        /// itself returns (see `StageTrackerTestBackend.setDeliverInitialFrameBeforeReturningHandle` in
        /// `TerminalViewerModelTests.swift` for the same pattern). Every request is answered `ok`.
        private final class FrameDeliveringBackend: SpacesDeviceAPIBackend, @unchecked Sendable {
            private let payload: GhosttyRemoteSessionStatePayload
            private let host: String?

            init(payload: GhosttyRemoteSessionStatePayload, host: String?) {
                self.payload = payload
                self.host = host
            }

            func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { AlwaysOKTransport() }

            func openSessionStream(
                request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                await MainActor.run { onEvent(payload) }
                return SpacesDeviceAPIStreamHandle(host: host) {}
            }
        }

        private struct AlwaysOKTransport: SpacesDeviceAPIRequestTransport {
            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            func close() async {}
        }

        private func makeModel(backend: (any SpacesDeviceAPIBackend)? = nil) -> TerminalViewerModel {
            let bridgeClient: SpacesDeviceAPIClient
            if let backend {
                bridgeClient = SpacesDeviceAPIClient(settings: Self.settings, backend: backend)
            } else {
                bridgeClient = SpacesDeviceAPIClient(settings: Self.settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            }
            return TerminalViewerModel(
                session: Self.session, settings: Self.settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
        }

        /// A payload carrying a full frame at `columns`x`rows`, mirroring `TerminalViewerOpenPaintTests
        /// .framedState`: `reason` decides whether it is a barrier that applies even while the open hold
        /// is on, and `owner`, when given, hands this viewer ownership.
        private nonisolated static func framedState(
            columns: Int, rows: Int, revision: UInt64, emittedAt: String, owner: TerminalClient? = nil,
            reason: String = TerminalRemoteSessionStateReason.stateChange.rawValue
        ) throws -> GhosttyRemoteSessionStatePayload {
            let frame = GhosttyRenderFrame(sessionRevision: revision, ownerEpoch: 1, snapshot: gridSnapshot(columns: columns, rows: rows))
            return GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: reason, emittedAt: emittedAt, sessionStateRevision: revision, sessionStateFlags: 1,
                screenStateRevision: revision,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, servicePID: 100, childPID: 200, state: .running, updatedAt: emittedAt, columns: columns, rows: rows),
                attachmentSnapshot: owner.map { client in
                    TerminalSessionAttachmentSnapshot(
                        clients: [client],
                        attachments: [TerminalAttachment(sessionID: sessionID, clientID: client.id, mode: .owner, attachedAt: emittedAt)])
                }, title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
        }

        /// A payload with no render update at all, enough to prove a live stream delivered *something*
        /// (which is all `registerLiveStreamFrame`/`stream_first_frame` cares about) without needing a
        /// decodable frame.
        private nonisolated static func bareState(emittedAt: String) -> GhosttyRemoteSessionStatePayload {
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, emittedAt: emittedAt,
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(sessionID: sessionID, servicePID: 100, childPID: 200, state: .running, updatedAt: emittedAt),
                attachmentSnapshot: nil, title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0)
        }

        private nonisolated static func gridSnapshot(columns: Int, rows: Int) -> GhosttyTerminalSnapshot {
            let cells = (0..<(columns * rows)).map { index in
                GhosttyTerminalSnapshot.Cell(
                    codepoint: index == 0 ? UInt32(UnicodeScalar("x").value) : 32, foregroundRGB: 0xFFFFFF, backgroundRGB: 0, flags: 0)
            }
            return GhosttyTerminalSnapshot(
                columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
                defaultBackgroundRGB: 0, cells: cells)
        }

        private static let sessionID = "terminal-session"

        private static var settings: SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = 12_345
            settings.authToken = "token"
            settings.certificateFingerprint = "SHA256:test"
            return settings
        }

        private static var session: SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: sessionID, title: "terminal", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, state: .running,
                backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: 200, workspaceID: "workspace-1",
                workspaceTitle: nil, projectID: nil, projectName: nil, createdAt: "2026-06-04T14:23:10Z", updatedAt: "2026-06-04T14:23:23Z",
                isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .process,
                rowSourceID: "process-row", hasFinalRender: false)
        }

        private func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
            let deadline = ContinuousClock().now + timeout
            while ContinuousClock().now < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Timed out waiting for \(description).")
        }
    }
#endif
