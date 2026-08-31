#if canImport(UIKit)
    import XCTest
    import spacesterminalcore
    import spacesdevicecore
    @testable import SpacesMobile

    private actor SpacesDeviceAPIClientPasteImageRequestRecorder {
        private var requests: [SpacesDeviceAPIRequest] = []

        func append(_ request: SpacesDeviceAPIRequest) { requests.append(request) }
        func snapshot() -> [SpacesDeviceAPIRequest] { requests }
    }

    final class SpacesDeviceAPIClientPasteImageTests: XCTestCase {
        func testPasteImageSendsTerminalPasteImageRequestWithExpectedFields() async throws {
            let recorder = SpacesDeviceAPIClientPasteImageRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let imageData = Data([0x89, 0x50, 0x4E, 0x47])
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "pasted")
            }

            try await client.pasteImage(
                context: TerminalCommandContext(sessionID: "session-shell", clientID: "client-ios", ownerEpoch: 7), fileExtension: "png",
                imageData: imageData)

            let request = await recorder.snapshot().first
            XCTAssertEqual(request?.commandName, "terminalPasteImage")
            guard case .terminalPasteImage(let payload)? = request?.command else {
                XCTFail("Expected terminalPasteImage request.")
                return
            }
            XCTAssertEqual(payload.sessionID, "session-shell")
            XCTAssertEqual(payload.clientID, "client-ios")
            XCTAssertEqual(payload.ownerEpoch, 7)
            XCTAssertEqual(payload.fileExtension, "png")
            XCTAssertEqual(payload.imageData, imageData)
        }

        /// A viewer with no owner epoch to send must send none, not epoch 0: the daemon reads an absent
        /// epoch as "not epoch-gated" and epoch 0 as a real generation to compare against, which rejects
        /// the paste of an owner whose generation is anything else.
        func testPasteImageSendsNoOwnerEpochWhenTheViewerHasNone() async throws {
            let recorder = SpacesDeviceAPIClientPasteImageRequestRecorder()
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "pasted")
            }

            try await client.pasteImage(
                context: TerminalCommandContext(sessionID: "session-shell", clientID: "client-ios", ownerEpoch: nil), fileExtension: "png",
                imageData: Data([0x01]))

            guard case .terminalPasteImage(let payload)? = await recorder.snapshot().first?.command else {
                XCTFail("Expected terminalPasteImage request.")
                return
            }
            XCTAssertNil(payload.ownerEpoch)
        }

        /// Guards the deviceName plumbing added to fix the first-launch hostName crash: a caller-supplied
        /// deviceName must reach the daemon's clientApp identity on every request, not just be stored and
        /// ignored. The initializer's default ("iOS Device") exists only so ~90 other tests can omit this
        /// parameter; production always passes `UIDevice.current.name` explicitly.
        func testDeviceNameReachesClientAppIdentityOnEveryRequest() async throws {
            let recorder = SpacesDeviceAPIClientPasteImageRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings, deviceName: "Sentinel iPhone") { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "pasted")
            }

            try await client.pasteImage(
                context: TerminalCommandContext(sessionID: "session-shell", clientID: "client-ios", ownerEpoch: 7), fileExtension: "png",
                imageData: Data([0x01]))

            let request = await recorder.snapshot().first
            XCTAssertEqual(request?.clientApp?.deviceName, "Sentinel iPhone")
        }

        func testRevisionFileReadPassesOldPathAndReturnsTheSpecializedResult() async throws {
            let recorder = SpacesDeviceAPIClientPasteImageRequestRecorder()
            let expected = SpacesDeviceWorkspaceRevisionFileReadResult(
                worktreeFile: .init(base64Data: "bGl2ZQ==", sha256: "live-sha", size: 4, isBinaryGuess: false),
                isWorktreeEquivalentToRevision: true, comparisonOldBase64Data: "b2xk")
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "read", result: .workspaceRevisionFileRead(expected))
            }

            let result = try await client.workspaceRevisionFileRead(
                workspaceID: "workspace-1", revision: String(repeating: "a", count: 40), relativePath: "renamed.swift", oldPath: "old.swift")

            guard case .workspaceRevisionFileRead(let payload)? = await recorder.snapshot().first?.command else {
                XCTFail("Expected workspaceRevisionFileRead request.")
                return
            }
            XCTAssertEqual(payload.oldPath, "old.swift")
            XCTAssertEqual(result, expected)
        }

        func testPasteImageThrowsWhenResponseNotOK() async {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: false, message: "denied") }

            do {
                try await client.pasteImage(
                    context: TerminalCommandContext(sessionID: "session-shell", clientID: "client-ios", ownerEpoch: 7), fileExtension: "png",
                    imageData: Data([0x01]))
                XCTFail("Expected pasteImage to throw when the response is not ok.")
            } catch let error as SpacesDeviceAPIClientError {
                switch error {
                case .requestFailed(let message, _): XCTAssertEqual(message, "denied")
                default: XCTFail("Expected requestFailed, got \(error).")
                }
            } catch { XCTFail("Expected SpacesDeviceAPIClientError, got \(error).") }
        }
    }
#endif
