#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor final class DemoDeviceBackendTests: XCTestCase {
        private func loadLibrary(now: Date = Date()) throws -> DemoRecordingLibrary {
            try DemoRecordingLibrary.load(bundle: .main, now: now)
        }

        private func settings() -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.host = "demo"
            settings.port = 1
            settings.authToken = "demo"
            settings.certificateFingerprint = "SHA256:demo"
            return settings
        }

        // MARK: - Bundle decoding

        func testBundleDecodesIntoStorytellingOverview() throws {
            let library = try loadLibrary()
            let overview = library.overview

            XCTAssertGreaterThanOrEqual(overview.projects.count, 1)
            XCTAssertGreaterThanOrEqual(overview.workspaces.count, 3)

            let hasWaitingAgent = overview.workspaces.contains { workspace in
                workspace.codingAgentRows.contains { $0.activityState == .waiting }
            }
            XCTAssertTrue(hasWaitingAgent, "The demo overview should contain a coding agent waiting on input.")

            let hasExitedProcess = overview.workspaces.contains { workspace in
                workspace.processRows.contains { $0.runState == .exited }
            }
            XCTAssertTrue(hasExitedProcess, "The demo overview should contain an exited process.")

            let events = SpacesMobileAttention.events(in: overview)
            XCTAssertFalse(events.isEmpty, "The loaded overview should derive at least one attention event.")
            XCTAssertTrue(events.contains { $0.kind == .waitingForInput })
            XCTAssertTrue(events.contains { $0.kind == .exited })
        }

        func testEveryRecordedFrameDecodesAndApplies() throws {
            let library = try loadLibrary()
            XCTAssertFalse(library.recordings.isEmpty)

            for (grid, framesBySlug) in library.recordings {
                XCTAssertFalse(framesBySlug.isEmpty, "Grid \(grid) should have recorded frames.")
                for (slug, payload) in framesBySlug {
                    guard let update = payload.decodedRenderUpdate else {
                        XCTFail("Session \(slug) at grid \(grid) had no decodable render update.")
                        continue
                    }
                    let baseline = try GhosttyRenderUpdateApplier.apply(update, to: nil)
                    let text = GhosttyTerminalSnapshotLayout.plainText(for: baseline.snapshot)
                    XCTAssertFalse(
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Session \(slug) at grid \(grid) rendered empty text.")
                }
            }
        }

        // MARK: - Timestamp rebasing

        func testTimestampsRebaseToLoadTimeNow() throws {
            // Load with a "now" far from the recording's fixed reference date so the assertion cannot be
            // satisfied by the machine clock happening to sit near the reference date.
            let now = Date().addingTimeInterval(100_000)
            let library = try loadLibrary(now: now)

            let agentTimestamps = library.overview.workspaces.flatMap { $0.codingAgentRows.compactMap(\.updatedAt) }
            XCTAssertFalse(agentTimestamps.isEmpty, "Expected at least one agent timestamp to rebase.")
            for value in agentTimestamps {
                guard let date = GhosttyRemoteSessionStateTimestamp.date(from: value) else {
                    XCTFail("Rebased timestamp \(value) did not parse as ISO-8601.")
                    continue
                }
                XCTAssertLessThan(abs(date.timeIntervalSince(now)), 120, "Rebased timestamp should sit near load-time now.")
            }
        }

        // MARK: - Read-only terminal input

        func testSendAndKeyRejectedWithDemoNotice() async throws {
            let backend = DemoDeviceBackend(library: try loadLibrary())
            let sessionID = "demo-harbor-backend"

            let sendResponse = await backend.serve(
                SpacesDeviceAPIRequest(command: .terminalControl(.init(action: .send, sessionID: sessionID, clientID: "c", text: "ls"))))
            XCTAssertFalse(sendResponse.ok)
            XCTAssertEqual(sendResponse.message, DemoDeviceBackend.terminalInputRejection)

            let keyResponse = await backend.serve(
                SpacesDeviceAPIRequest(command: .terminalControl(.init(action: .key, sessionID: sessionID, clientID: "c", key: "enter"))))
            XCTAssertFalse(keyResponse.ok)
            XCTAssertEqual(keyResponse.message, DemoDeviceBackend.terminalInputRejection)
        }

        // MARK: - Subscribe

        func testSubscribeDeliversRecordedFrame() async throws {
            let backend = DemoDeviceBackend(library: try loadLibrary())
            let client = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let sessionID = "demo-harbor-backend"

            let received = XCTestExpectation(description: "subscribe delivers the recorded frame")
            let deliveredText = TextBox()
            let handle = try client.subscribe(
                sessionID: sessionID, clientID: "client-ios",
                onEvent: { payload in
                    XCTAssertEqual(payload.sessionID, sessionID)
                    deliveredText.set(payload.renderText ?? "")
                    received.fulfill()
                }, onDisconnect: { _ in })

            await fulfillment(of: [received], timeout: 3)
            handle.cancel()
            XCTAssertFalse(deliveredText.get().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        // MARK: - Resize ack

        func testResizeAckPatchesRuntimeSize() async throws {
            let backend = DemoDeviceBackend(library: try loadLibrary())
            let sessionID = "demo-harbor-backend"

            let resize = await backend.serve(
                SpacesDeviceAPIRequest(command: .terminalControl(.init(action: .resize, sessionID: sessionID, clientID: "c", columns: 61, rows: 41))))
            XCTAssertTrue(resize.ok)

            let state = await backend.serve(SpacesDeviceAPIRequest(command: .state(.init(sessionID: sessionID))))
            XCTAssertTrue(state.ok)
            let runtimeState = try XCTUnwrap(state.sessionState?.runtimeState)
            XCTAssertEqual(runtimeState.columns, 61)
            XCTAssertEqual(runtimeState.rows, 41)
        }

        // MARK: - Mutations

        func testProcessStopFlipsRowAndRefreshedOverview() async throws {
            let library = try loadLibrary()
            let backend = DemoDeviceBackend(library: library)

            let running = try XCTUnwrap(
                library.overview.workspaces.lazy.flatMap { workspace in
                    workspace.processRows.filter { $0.runState == .running && $0.processID != nil }
                }.first, "Expected a running process to stop.")

            let response = await backend.serve(
                SpacesDeviceAPIRequest(
                    command: .stopWorkspaceProcess(.init(workspaceID: running.workspaceID, processID: running.processID, processKey: running.name))))
            XCTAssertTrue(response.ok)

            let mutatedRow = try XCTUnwrap(
                response.overview?.workspaces.first { $0.id == running.workspaceID }?.processRows.first { $0.id == running.id })
            XCTAssertEqual(mutatedRow.runState, .exited)
            XCTAssertNotNil(mutatedRow.exitedAt)

            // A follow-up overview read reflects the same session-lifetime mutation.
            let refreshed = await backend.serve(SpacesDeviceAPIRequest(command: .overview))
            let refreshedRow = try XCTUnwrap(
                refreshed.overview?.workspaces.first { $0.id == running.workspaceID }?.processRows.first { $0.id == running.id })
            XCTAssertEqual(refreshedRow.runState, .exited)
        }
    }

    /// Lock-guarded string box so the synchronous subscribe callback can hand text back to the test.
    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""

        func set(_ text: String) {
            lock.lock()
            value = text
            lock.unlock()
        }

        func get() -> String {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
#endif
