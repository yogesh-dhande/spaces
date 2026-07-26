#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor final class DemoDeviceBackendTests: XCTestCase {
        private func loadLibrary(now: Date = Date()) throws -> DemoRecordingLibrary { try DemoRecordingLibrary.load(bundle: .main, now: now) }

        private func settings() -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["demo"]
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

            let hasWaitingAgent = overview.workspaces.contains { workspace in workspace.codingAgentRows.contains { $0.activityState == .waiting } }
            XCTAssertTrue(hasWaitingAgent, "The demo overview should contain a coding agent waiting on input.")

            let hasExitedProcess = overview.workspaces.contains { workspace in workspace.processRows.contains { $0.runState == .exited } }
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
            let handle = try await client.subscribe(
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

        // MARK: - Synthesizing sessions for not-started rows

        /// The atlas workspace and its not-started "frontend" process row (nil process/session ids).
        private func notStartedProcessRow(in library: DemoRecordingLibrary, named name: String = "frontend") throws -> (
            workspace: SpacesDeviceWorkspaceSummary, row: SpacesDeviceWorkspaceProcessRow
        ) {
            try XCTUnwrap(
                library.overview.workspaces.lazy.compactMap { workspace -> (SpacesDeviceWorkspaceSummary, SpacesDeviceWorkspaceProcessRow)? in
                    guard let row = workspace.processRows.first(where: { $0.name == name && $0.runState == .notStarted && $0.sessionID == nil })
                    else { return nil }
                    return (workspace, row)
                }.first, "Expected a not-started \(name) process row.")
        }

        func testRunningNotStartedProcessRowSynthesizesConsistentSession() async throws {
            let library = try loadLibrary()
            let backend = DemoDeviceBackend(library: library)
            let (workspace, row) = try notStartedProcessRow(in: library)

            let response = await backend.serve(
                SpacesDeviceAPIRequest(
                    command: .runWorkspaceProcess(.init(workspaceID: workspace.id, processKey: row.name, processTemplateID: row.templateID ?? row.id))
                ))
            XCTAssertTrue(response.ok)

            let mutated = try XCTUnwrap(response.overview?.workspaces.first { $0.id == workspace.id }?.processRows.first { $0.id == row.id })
            XCTAssertEqual(mutated.runState, .running)
            let processID = try XCTUnwrap(mutated.processID, "A started row must carry a synthetic process id so it can be stopped.")
            let sessionID = try XCTUnwrap(mutated.sessionID, "A started row must carry a synthetic session id so it can be opened.")

            let summary = try XCTUnwrap(
                response.overview?.sessions.first { $0.id == sessionID }, "overview.sessions must carry the synthesized session summary.")
            XCTAssertEqual(summary.workspaceID, workspace.id)
            XCTAssertEqual(summary.state, .running)
            XCTAssertEqual(summary.title, row.name)

            // Opening the synthesized session replays a recorded frame.
            let state = await backend.serve(SpacesDeviceAPIRequest(command: .state(.init(sessionID: sessionID))))
            XCTAssertTrue(state.ok)
            XCTAssertNotNil(state.sessionState?.renderSnapshot, "The synthesized session must replay a recorded terminal frame.")

            // Stopping the synthesized row through the normal process path flips it to exited.
            let stop = await backend.serve(
                SpacesDeviceAPIRequest(command: .stopWorkspaceProcess(.init(workspaceID: workspace.id, processID: processID, processKey: row.name))))
            XCTAssertTrue(stop.ok)
            let stopped = try XCTUnwrap(stop.overview?.workspaces.first { $0.id == workspace.id }?.processRows.first { $0.id == row.id })
            XCTAssertEqual(stopped.runState, .exited)
        }

        func testWorkspaceLaunchSynthesizesEveryNotStartedRow() async throws {
            let library = try loadLibrary()
            let backend = DemoDeviceBackend(library: library)
            let (workspace, _) = try notStartedProcessRow(in: library)

            let response = await backend.serve(SpacesDeviceAPIRequest(command: .launchWorkspace(.init(workspaceID: workspace.id))))
            XCTAssertTrue(response.ok)

            let startedRows = try XCTUnwrap(response.overview?.workspaces.first { $0.id == workspace.id }?.processRows)
            let sessionIDs = startedRows.compactMap(\.sessionID)
            XCTAssertEqual(startedRows.count, sessionIDs.count, "Launching the workspace must synthesize a session for every process row.")
            XCTAssertEqual(Set(sessionIDs).count, sessionIDs.count, "Each synthesized session id must be distinct.")
            for row in startedRows {
                XCTAssertEqual(row.runState, .running)
                XCTAssertNotNil(row.processID)
                let sessionID = try XCTUnwrap(row.sessionID)
                let state = await backend.serve(SpacesDeviceAPIRequest(command: .state(.init(sessionID: sessionID))))
                XCTAssertNotNil(state.sessionState?.renderSnapshot)
            }
        }

        // MARK: - Viewport-appropriate grid

        func testResizeServesNearestGridRecording() async throws {
            let library = try loadLibrary()
            let backend = DemoDeviceBackend(library: library)
            let sessionID = "demo-harbor-backend"
            // The recorder captures whatever grid the terminal actually settled on, which can differ by a
            // cell from the manifest's requested grid — so expectations come from the recordings
            // themselves, and the assertion is grid *selection*, not exact dimensions.
            let phoneRecording = try XCTUnwrap(library.payload(forSessionSlug: sessionID, requested: nil)?.renderSnapshot)
            let padRecording = try XCTUnwrap(
                library.payload(forSessionSlug: sessionID, requested: DemoRecordingGrid(columns: 116, rows: 78))?.renderSnapshot)
            XCTAssertNotEqual(
                [phoneRecording.columns, phoneRecording.rows], [padRecording.columns, padRecording.rows],
                "The two grid recordings must be distinguishable for this test to prove selection.")

            // Without any resize the smallest (phone) recording is served.
            let phone = await backend.serve(SpacesDeviceAPIRequest(command: .state(.init(sessionID: sessionID))))
            let phoneSnapshot = try XCTUnwrap(phone.sessionState?.renderSnapshot)
            XCTAssertEqual(phoneSnapshot.columns, phoneRecording.columns)
            XCTAssertEqual(phoneSnapshot.rows, phoneRecording.rows)

            // After a resize toward the iPad grid, the iPad recording is served.
            let resize = await backend.serve(
                SpacesDeviceAPIRequest(command: .terminalControl(.init(action: .resize, sessionID: sessionID, clientID: "c", columns: 116, rows: 78)))
            )
            XCTAssertTrue(resize.ok)
            let pad = await backend.serve(SpacesDeviceAPIRequest(command: .state(.init(sessionID: sessionID))))
            let padSnapshot = try XCTUnwrap(pad.sessionState?.renderSnapshot)
            XCTAssertEqual(padSnapshot.columns, padRecording.columns)
            XCTAssertEqual(padSnapshot.rows, padRecording.rows)
        }

        func testDemoViewportResizeSwapsInNearestGridFrame() async throws {
            let library = try loadLibrary()
            let backend = DemoDeviceBackend(library: library)
            let padRecording = try XCTUnwrap(
                library.payload(forSessionSlug: "demo-harbor-backend", requested: DemoRecordingGrid(columns: 116, rows: 78))?.renderSnapshot)
            let client = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let session = SpacesDeviceTerminalSessionSummary(
                id: "demo-harbor-backend", title: "backend", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, state: .running,
                backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 0, childPID: nil, workspaceID: "workspace", workspaceTitle: nil,
                projectID: nil, projectName: nil, createdAt: "2026-06-04T14:23:10Z", updatedAt: "2026-06-04T14:23:23Z", isControlAvailable: true,
                isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .process, rowSourceID: nil,
                hasFinalRender: false)
            let model = TerminalViewerModel(
                session: session, settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in }, bridgeClient: client,
                isDemoMode: true)

            // In Demo Mode a viewport change sends a resize and refreshes; the backend then serves the
            // recording captured nearest that viewport (the iPad grid here), which the model applies.
            model.updateViewportSize(columns: 116, rows: 78)
            for _ in 0..<200 {
                if model.snapshotColumns == padRecording.columns { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.snapshotColumns, padRecording.columns)
            XCTAssertEqual(model.snapshotRows, padRecording.rows)
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
