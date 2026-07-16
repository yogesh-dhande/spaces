#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor final class TerminalComposerSendTests: XCTestCase {
        private actor ComposerAPIRecorder {
            private var requests: [SpacesDeviceAPIRequest] = []
            private var pasteImageCount = 0
            private let failPasteImageAtIndex: Int?
            private let failuresByToken: [String: SpacesDeviceAPIResponse]
            private let delaysByToken: [String: Duration]

            init(failPasteImageAtIndex: Int? = nil, failuresByToken: [String: SpacesDeviceAPIResponse] = [:], delaysByToken: [String: Duration] = [:])
            {
                self.failPasteImageAtIndex = failPasteImageAtIndex
                self.failuresByToken = failuresByToken
                self.delaysByToken = delaysByToken
            }

            func handle(_ request: SpacesDeviceAPIRequest) async -> SpacesDeviceAPIResponse {
                requests.append(request)
                let token = Self.token(request)
                if let delay = delaysByToken[token] { try? await Task.sleep(for: delay) }
                if let failure = failuresByToken[token] { return failure }
                if case .terminalPasteImage = request.command {
                    pasteImageCount += 1
                    if let failPasteImageAtIndex, pasteImageCount == failPasteImageAtIndex {
                        return SpacesDeviceAPIResponse(ok: false, message: "denied")
                    }
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func tokens() -> [String] { requests.map(Self.token) }

            func sendPasteFlags() -> [Bool] {
                requests.compactMap { request in
                    guard case .terminalControl(let payload) = request.command, payload.action == .send else { return nil }
                    return payload.asPaste
                }
            }

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

        private actor AuthenticationPromptRecorder {
            private var messages: [String] = []

            func append(_ message: String) { messages.append(message) }

            func firstMessage() -> String? { messages.first }
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
                id: "terminal-session", title: "terminal", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, state: .running,
                backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: 200, workspaceID: "workspace-1",
                workspaceTitle: nil, projectID: nil, projectName: nil, createdAt: "2026-06-04T14:23:10Z", updatedAt: "2026-06-04T14:23:23Z",
                isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .process,
                rowSourceID: "process-row", hasFinalRender: false)
        }

        private func attachment(_ label: String) -> TerminalComposerAttachment {
            TerminalComposerAttachment(
                payload: TerminalImageAttachmentPayload(fileExtension: "png", imageData: Data([0x89, 0x50, 0x4E, 0x47])), thumbnail: UIImage(),
                sourceLabel: label)
        }

        private func waitUntilSendCompletes(_ model: TerminalViewerModel) async throws {
            for _ in 0..<400 {
                if !model.isSendingComposedMessage { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Composed send did not complete in time.")
        }

        private func waitUntilSendStarts(_ model: TerminalViewerModel) async throws {
            for _ in 0..<100 {
                if model.isSendingComposedMessage { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Composed send did not start in time.")
        }

        private func waitUntilRecorderContains(_ token: String, recorder: ComposerAPIRecorder) async throws {
            for _ in 0..<100 {
                let tokens = await recorder.tokens()
                if tokens.contains(token) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Expected recorder token \(token) did not appear.")
        }

        private func waitForAuthenticationMessage(recorder: AuthenticationPromptRecorder) async throws -> String? {
            for _ in 0..<100 {
                if let message = await recorder.firstMessage() { return message }
                try await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }

        private func firstComposerTextInput(in view: UIView) -> (
            view: UIView, autocapitalization: UITextAutocapitalizationType, autocorrection: UITextAutocorrectionType
        )? {
            if let textField = view as? UITextField { return (textField, textField.autocapitalizationType, textField.autocorrectionType) }
            if let textView = view as? UITextView { return (textView, textView.autocapitalizationType, textView.autocorrectionType) }
            for subview in view.subviews { if let input = firstComposerTextInput(in: subview) { return input } }
            return nil
        }

        func testComposerMessageFieldDisablesTextMutationTraits() throws {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })
            let sheet = TerminalComposerSheet(model: model, stagedScreenshots: StagedScreenshotStore())
            let controller = UIHostingController(rootView: sheet)
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = controller
            window.isHidden = false
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            defer { window.isHidden = true }

            let input = try XCTUnwrap(firstComposerTextInput(in: controller.view))
            XCTAssertEqual(input.autocapitalization, .none)
            XCTAssertEqual(input.autocorrection, .no)
        }

        func testComposerMessageFieldDisablesEditingWhileSending() async throws {
            let recorder = ComposerAPIRecorder(delaysByToken: ["paste": .milliseconds(500)])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 7)
            model.composerDraftText = "hello"
            model.attachComposerImage(attachment("Screenshot"))

            let sheet = TerminalComposerSheet(model: model, stagedScreenshots: StagedScreenshotStore())
            let controller = UIHostingController(rootView: sheet)
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = controller
            window.isHidden = false
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            defer { window.isHidden = true }

            await model.sendComposedMessage()
            try await waitUntilSendStarts(model)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()

            let input = try XCTUnwrap(firstComposerTextInput(in: controller.view))
            let inputCenter = input.view.convert(CGPoint(x: input.view.bounds.midX, y: input.view.bounds.midY), to: controller.view)
            let hitView = controller.view.hitTest(inputCenter, with: nil)
            XCTAssertFalse(hitView === input.view || hitView?.isDescendant(of: input.view) == true)

            try await waitUntilSendCompletes(model)
        }

        func testCancelingQueuedComposedSendClearsSendingState() async throws {
            let recorder = ComposerAPIRecorder(delaysByToken: ["send:blocking": .milliseconds(500)])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 7)

            await model.sendText("blocking", asPaste: true)
            try await waitUntilRecorderContains("send:blocking", recorder: recorder)
            model.composerDraftText = "queued"
            model.attachComposerImage(attachment("Screenshot"))

            await model.sendComposedMessage()
            XCTAssertTrue(model.isSendingComposedMessage)

            model.stop()
            try await Task.sleep(for: .milliseconds(50))

            XCTAssertFalse(model.isSendingComposedMessage)
            XCTAssertEqual(model.composerDraftText, "queued")
            XCTAssertEqual(model.composerAttachments.count, 1)
            let tokens = await recorder.tokens()
            XCTAssertFalse(tokens.contains("send:queued "))
            XCTAssertFalse(tokens.contains("paste"))
        }

        func testComposedSendTextThenImagesThenEnterInOrder() async throws {
            let recorder = ComposerAPIRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 7)
            model.composerDraftText = "hello"
            model.attachComposerImage(attachment("Screenshot"))
            model.attachComposerImage(attachment("Clipboard"))

            XCTAssertTrue(model.canSendComposedMessage)
            await model.sendComposedMessage()
            try await waitUntilSendCompletes(model)

            let tokens = await recorder.tokens()
            XCTAssertEqual(tokens, ["send:hello ", "paste", "send: ", "paste", "key:enter"])
            let sendPasteFlags = await recorder.sendPasteFlags()
            XCTAssertEqual(sendPasteFlags, [true, true])
            XCTAssertEqual(model.composerDraftText, "")
            XCTAssertTrue(model.composerAttachments.isEmpty)
            XCTAssertNil(model.composerErrorMessage)
        }

        func testComposedSendPreservesDraftEditsMadeDuringInFlightSend() async throws {
            let recorder = ComposerAPIRecorder(delaysByToken: ["paste": .milliseconds(200)])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 7)
            model.composerDraftText = "original"
            model.attachComposerImage(attachment("Screenshot"))
            let sentAttachmentID = try XCTUnwrap(model.composerAttachments.first?.id)

            await model.sendComposedMessage()
            try await waitUntilSendStarts(model)
            model.composerDraftText = "edited while sending"
            model.removeComposerAttachment(id: sentAttachmentID)
            model.attachComposerImage(attachment("Late"))
            XCTAssertEqual(model.composerAttachments.map(\.id), [sentAttachmentID])

            try await waitUntilSendCompletes(model)

            let tokens = await recorder.tokens()
            XCTAssertEqual(tokens, ["send:original ", "paste", "key:enter"])
            XCTAssertEqual(model.composerDraftText, "edited while sending")
            XCTAssertTrue(model.composerAttachments.isEmpty)
            XCTAssertNil(model.composerErrorMessage)
        }

        func testComposedSendStopsBeforeEnterWhenAnImageFails() async throws {
            let recorder = ComposerAPIRecorder(failPasteImageAtIndex: 2)
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in }, bridgeClient: bridgeClient)
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
            XCTAssertEqual(model.composerErrorMessage, "Couldn't send an image. Nothing was submitted — the terminal line may contain partial text.")
        }

        func testComposedSendClearsDraftOnSuccess() async throws {
            let recorder = ComposerAPIRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 3)
            model.composerDraftText = "just text"

            await model.sendComposedMessage()
            try await waitUntilSendCompletes(model)

            let tokens = await recorder.tokens()
            XCTAssertEqual(tokens, ["send:just text", "key:enter"])
            let sendPasteFlags = await recorder.sendPasteFlags()
            XCTAssertEqual(sendPasteFlags, [true])
            XCTAssertEqual(model.composerDraftText, "")
            XCTAssertTrue(model.composerAttachments.isEmpty)
            XCTAssertNil(model.composerErrorMessage)
        }

        func testTextOnlyFailureUsesMessageErrorInsteadOfImageError() async throws {
            let recorder = ComposerAPIRecorder(failuresByToken: [
                "send:just text": SpacesDeviceAPIResponse(ok: false, message: "Input was rejected.", errorCode: .internalError)
            ])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 5)
            model.composerDraftText = "just text"

            await model.sendComposedMessage()
            try await waitUntilSendCompletes(model)

            let tokens = await recorder.tokens()
            XCTAssertEqual(tokens, ["send:just text"])
            XCTAssertEqual(model.composerDraftText, "just text")
            XCTAssertTrue(model.composerAttachments.isEmpty)
            XCTAssertEqual(model.composerErrorMessage, "Couldn't send the message. Nothing was submitted.")
        }

        func testComposedSendEnterFailureKeepsDraftWithSubmitMessage() async throws {
            let recorder = ComposerAPIRecorder(failuresByToken: [
                "key:enter": SpacesDeviceAPIResponse(ok: false, message: "Input was rejected.", errorCode: .internalError)
            ])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in }, bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 5)
            model.composerDraftText = "hello"
            model.attachComposerImage(attachment("Screenshot"))
            model.attachComposerImage(attachment("Clipboard"))

            await model.sendComposedMessage()
            try await waitUntilSendCompletes(model)

            let tokens = await recorder.tokens()
            XCTAssertEqual(tokens, ["send:hello ", "paste", "send: ", "paste", "key:enter"])
            XCTAssertEqual(model.composerDraftText, "hello")
            XCTAssertEqual(model.composerAttachments.count, 2)
            XCTAssertEqual(model.composerErrorMessage, "The message was sent but couldn't be submitted. Retrying will send the whole message again.")
        }

        func testTextSendAuthenticationFailurePromptsRepairInsteadOfImageError() async throws {
            let authenticationRecorder = AuthenticationPromptRecorder()
            let recorder = ComposerAPIRecorder(failuresByToken: [
                "send:just text": SpacesDeviceAPIResponse(ok: false, message: "Invalid device auth token.", errorCode: .unauthorized)
            ])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(
                session: session(), settings: settings(),
                onAuthenticationRequired: { message in Task { await authenticationRecorder.append(message) } }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 5)
            model.composerDraftText = "just text"

            await model.sendComposedMessage()
            try await waitUntilSendCompletes(model)

            let authenticationMessage = try await waitForAuthenticationMessage(recorder: authenticationRecorder)
            XCTAssertEqual(authenticationMessage, "This Mac no longer recognizes this device. Open Devices and pair this device again.")
            XCTAssertNil(model.composerErrorMessage)
        }

        func testImageUploadAuthenticationFailurePromptsRepairInsteadOfImageError() async throws {
            let authenticationRecorder = AuthenticationPromptRecorder()
            let recorder = ComposerAPIRecorder(failuresByToken: [
                "paste": SpacesDeviceAPIResponse(ok: false, message: "Invalid device auth token.", errorCode: .unauthorized)
            ])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in await recorder.handle(request) }
            let model = TerminalViewerModel(
                session: session(), settings: settings(),
                onAuthenticationRequired: { message in Task { await authenticationRecorder.append(message) } }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            model.configureOwnerInteractiveForTesting(ownerEpoch: 5)
            model.composerDraftText = "hello"
            model.attachComposerImage(attachment("Screenshot"))

            await model.sendComposedMessage()
            try await waitUntilSendCompletes(model)

            let tokens = await recorder.tokens()
            XCTAssertEqual(tokens, ["send:hello ", "paste"])
            let authenticationMessage = try await waitForAuthenticationMessage(recorder: authenticationRecorder)
            XCTAssertEqual(authenticationMessage, "This Mac no longer recognizes this device. Open Devices and pair this device again.")
            XCTAssertNil(model.composerErrorMessage)
            XCTAssertEqual(model.composerDraftText, "hello")
            XCTAssertEqual(model.composerAttachments.count, 1)
        }
    }
#endif
