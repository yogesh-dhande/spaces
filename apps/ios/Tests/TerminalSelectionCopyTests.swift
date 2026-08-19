#if canImport(UIKit)
    import UIKit
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// The daemon owns one shared terminal selection; iOS never creates one (#514), it only clears the
    /// daemon's selection for every viewer or copies its full text (including any part scrolled out of
    /// view) to this device's pasteboard. Covers the device-API client's request shapes and
    /// `TerminalViewerModel`'s clear/copy flows built on top of them.
    private actor SelectionControlRequestRecorder {
        private var requests: [SpacesDeviceAPIRequest] = []
        private let response: SpacesDeviceAPIResponse

        init(response: SpacesDeviceAPIResponse) { self.response = response }

        func handle(_ request: SpacesDeviceAPIRequest) -> SpacesDeviceAPIResponse {
            requests.append(request)
            return response
        }

        func snapshot() -> [SpacesDeviceAPIRequest] { requests }
    }

    final class SpacesDeviceAPIClientSelectionControlTests: XCTestCase {
        func testClearSelectionSendsClearSelectionRequest() async throws {
            let recorder = SelectionControlRequestRecorder(response: SpacesDeviceAPIResponse(ok: true, message: "cleared"))
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in await recorder.handle(request) }

            try await client.clearSelection(sessionID: "session-shell", clientID: "client-ios")

            guard case .terminalControl(let payload)? = await recorder.snapshot().first?.command else {
                XCTFail("Expected a terminalControl request.")
                return
            }
            XCTAssertEqual(payload.action, .clearSelection)
            XCTAssertEqual(payload.sessionID, "session-shell")
            XCTAssertEqual(payload.clientID, "client-ios")
        }

        func testClearSelectionThrowsWhenResponseNotOK() async {
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { _ in
                SpacesDeviceAPIResponse(ok: false, message: "denied")
            }

            do {
                try await client.clearSelection(sessionID: "session-shell", clientID: "client-ios")
                XCTFail("Expected clearSelection to throw when the response is not ok.")
            } catch let error as SpacesDeviceAPIClientError {
                guard case .requestFailed(let message, _) = error else {
                    XCTFail("Expected requestFailed, got \(error).")
                    return
                }
                XCTAssertEqual(message, "denied")
            } catch { XCTFail("Expected SpacesDeviceAPIClientError, got \(error).") }
        }

        func testReadSelectionTextSendsReadSelectionTextRequestAndReturnsTheFullText() async throws {
            let response = SpacesDeviceAPIResponse(
                ok: true, message: "ok", result: .terminalSelectionText(SpacesDeviceTerminalOutputResult(text: "the full selection")))
            let recorder = SelectionControlRequestRecorder(response: response)
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in await recorder.handle(request) }

            let text = try await client.readSelectionText(sessionID: "session-shell", clientID: "client-ios")

            XCTAssertEqual(text, "the full selection")
            guard case .terminalControl(let payload)? = await recorder.snapshot().first?.command else {
                XCTFail("Expected a terminalControl request.")
                return
            }
            XCTAssertEqual(payload.action, .readSelectionText)
            XCTAssertEqual(payload.sessionID, "session-shell")
            XCTAssertEqual(payload.clientID, "client-ios")
        }

        func testReadSelectionTextThrowsWhenTheResponseCarriesNoSelectionText() async {
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }

            do {
                _ = try await client.readSelectionText(sessionID: "session-shell", clientID: "client-ios")
                XCTFail("Expected readSelectionText to throw when the response carries no selection text.")
            } catch let error as SpacesDeviceAPIClientError {
                guard case .requestFailed = error else {
                    XCTFail("Expected requestFailed, got \(error).")
                    return
                }
            } catch { XCTFail("Expected SpacesDeviceAPIClientError, got \(error).") }
        }
    }

    @MainActor final class TerminalSelectionCopyFlowTests: XCTestCase {
        private func settings() -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = 12345
            settings.authToken = "token"
            settings.certificateFingerprint = "SHA256:test"
            return settings
        }

        private func session() -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: "terminal-session", title: "terminal", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, state: .running,
                backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: 200, workspaceID: "workspace-1",
                workspaceTitle: nil, projectID: nil, projectName: nil, createdAt: "2026-07-28T00:00:00Z", updatedAt: "2026-07-28T00:00:01Z",
                isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .process,
                rowSourceID: "process-row", hasFinalRender: false)
        }

        private func withPasteboard(_ body: (UIPasteboard) async throws -> Void) async rethrows {
            let pasteboard = UIPasteboard.withUniqueName()
            defer { UIPasteboard.remove(withName: pasteboard.name) }
            try await body(pasteboard)
        }

        /// Neither flow is owner-gated: the model is left in its default (non-owner) state, matching a
        /// plain viewer that has never taken input ownership, to prove clear/copy still reach the daemon.
        private func makeModel(_ pasteboard: UIPasteboard, bridgeClient: SpacesDeviceAPIClient) -> TerminalViewerModel {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            model.pasteboardOverrideForTesting = pasteboard
            return model
        }

        func testClearSelectionSendsClearSelectionForANonOwnerViewer() async throws {
            try await withPasteboard { pasteboard in
                let recorder = SelectionControlRequestRecorder(response: SpacesDeviceAPIResponse(ok: true, message: "cleared"))
                let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
                let model = makeModel(pasteboard, bridgeClient: bridgeClient)

                await model.clearSelection()

                guard case .terminalControl(let payload)? = await recorder.snapshot().first?.command else {
                    XCTFail("Expected a terminalControl request.")
                    return
                }
                XCTAssertEqual(payload.action, .clearSelection)
                XCTAssertEqual(payload.sessionID, "terminal-session")
            }
        }

        func testCopySelectionWritesTheFullSelectionTextToThePasteboardAndReportsSuccess() async throws {
            try await withPasteboard { pasteboard in
                let response = SpacesDeviceAPIResponse(
                    ok: true, message: "ok",
                    result: .terminalSelectionText(SpacesDeviceTerminalOutputResult(text: "selected text, including scrolled-off lines")))
                let recorder = SelectionControlRequestRecorder(response: response)
                let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
                let model = makeModel(pasteboard, bridgeClient: bridgeClient)

                let succeeded = await model.copySelection()

                XCTAssertTrue(succeeded)
                XCTAssertEqual(pasteboard.string, "selected text, including scrolled-off lines")
                guard case .terminalControl(let payload)? = await recorder.snapshot().first?.command else {
                    XCTFail("Expected a terminalControl request.")
                    return
                }
                XCTAssertEqual(payload.action, .readSelectionText)
            }
        }

        /// A failed read leaves the pasteboard untouched and reports failure, so the pill (owned by
        /// `TerminalDetailView`) stays on "Copy" rather than showing a false "Copied".
        func testCopySelectionLeavesThePasteboardAloneAndReportsFailureWhenTheRequestFails() async throws {
            try await withPasteboard { pasteboard in
                pasteboard.string = "what the user had"
                let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { _ in SpacesDeviceAPIResponse(ok: false, message: "denied") }
                let model = makeModel(pasteboard, bridgeClient: bridgeClient)

                let succeeded = await model.copySelection()

                XCTAssertFalse(succeeded)
                XCTAssertEqual(pasteboard.string, "what the user had")
            }
        }
    }
#endif
