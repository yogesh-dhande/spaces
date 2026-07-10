#if canImport(UIKit)
    import UIKit
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor
    final class TerminalComposerSendTests: XCTestCase {
        private actor ComposerAPIRecorder {
            private var requests: [SpacesDeviceAPIRequest] = []
            private var pasteImageCount = 0
            private let failPasteImageAtIndex: Int?

            init(failPasteImageAtIndex: Int? = nil) { self.failPasteImageAtIndex = failPasteImageAtIndex }

            func handle(_ request: SpacesDeviceAPIRequest) -> SpacesDeviceAPIResponse {
                requests.append(request)
                if case .terminalPasteImage = request.command {
                    pasteImageCount += 1
                    if let failPasteImageAtIndex, pasteImageCount == failPasteImageAtIndex {
                        return SpacesDeviceAPIResponse(ok: false, message: "denied")
                    }
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func tokens() -> [String] { requests.map(Self.token) }

            private static func token(_ request: SpacesDeviceAPIRequest) -> String {
                switch request.command {
                case .terminalControl(let payload):
                    switch payload.action {
                    case .send: return "send:\(payload.text ?? "")"
                    case .key: return "key:\(payload.key ?? "")"
                    default: return "control:\(payload.action.rawValue)"
                    }
                case .terminalPasteImage: return "paste"
                default: return "other"
                }
            }
        }

        private func settings() -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.host = "127.0.0.1"
            settings.port = 12345
            settings.authToken = "token"
            settings.certificateFingerprint = "SHA256:test"
            return settings
        }

        private func session() -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: "terminal-session",
                title: "terminal",
                workingDirectory: "/tmp/work",
                shell: "/bin/zsh",
                command: nil,
                state: .running,
                backend: .ghosttyEmbedded,
                lifetimePolicy: .persistent,
                servicePID: 100,
                childPID: 200,
                workspaceID: "workspace-1",
                workspaceTitle: nil,
                projectID: nil,
                projectName: nil,
                createdAt: "2026-06-04T14:23:10Z",
                updatedAt: "2026-06-04T14:23:23Z",
                isControlAvailable: true,
                isSubscriptionAvailable: true,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                rowKind: .process,
                rowSourceID: "process-row",
                hasFinalRender: false
            )
        }

        private func attachment(_ label: String) -> TerminalComposerAttachment {
            TerminalComposerAttachment(
                payload: TerminalImageAttachmentPayload(fileExtension: "png", imageData: Data([0x89, 0x50, 0x4E, 0x47])),
                thumbnail: UIImage(),
                sourceLabel: label)
        }

        private func waitUntilSendCompletes(_ model: TerminalViewerModel) async throws {
            for _ in 0..<400 {
                if !model.isSendingComposedMessage { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Composed send did not complete in time.")
        }

        func testComposedSendTextThenImagesThenEnterInOrder() async throws {
            let recorder = ComposerAPIRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.handle(request)
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 7)
            model.composerDraftText = "hello"
            model.attachComposerImage(attachment("Screenshot"))
            model.attachComposerImage(attachment("Clipboard"))

            XCTAssertTrue(model.canSendComposedMessage)
            await model.sendComposedMessage()
            try await waitUntilSendCompletes(model)

            let tokens = await recorder.tokens()
            XCTAssertEqual(tokens, ["send:hello ", "paste", "send: ", "paste", "key:enter"])
            XCTAssertEqual(model.composerDraftText, "")
            XCTAssertTrue(model.composerAttachments.isEmpty)
            XCTAssertNil(model.composerErrorMessage)
        }

        func testComposedSendStopsBeforeEnterWhenAnImageFails() async throws {
            let recorder = ComposerAPIRecorder(failPasteImageAtIndex: 2)
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.handle(request)
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 7)
            model.composerDraftText = "hello"
            model.attachComposerImage(attachment("Screenshot"))
            model.attachComposerImage(attachment("Clipboard"))

            await model.sendComposedMessage()
            try await waitUntilSendCompletes(model)

            let tokens = await recorder.tokens()
            XCTAssertEqual(tokens, ["send:hello ", "paste", "send: ", "paste"])
            XCTAssertFalse(tokens.contains("key:enter"), "Enter must not be sent after a failed image.")
            XCTAssertEqual(model.composerDraftText, "hello")
            XCTAssertEqual(model.composerAttachments.count, 2)
            XCTAssertNotNil(model.composerErrorMessage)
        }

        func testComposedSendClearsDraftOnSuccess() async throws {
            let recorder = ComposerAPIRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.handle(request)
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 3)
            model.composerDraftText = "just text"

            await model.sendComposedMessage()
            try await waitUntilSendCompletes(model)

            let tokens = await recorder.tokens()
            XCTAssertEqual(tokens, ["send:just text", "key:enter"])
            XCTAssertEqual(model.composerDraftText, "")
            XCTAssertTrue(model.composerAttachments.isEmpty)
            XCTAssertNil(model.composerErrorMessage)
        }
    }
#endif
