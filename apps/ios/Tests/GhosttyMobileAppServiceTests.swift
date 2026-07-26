#if canImport(UIKit)
    import Darwin
    import Foundation
    import GhosttyKit
    import UIKit
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile
    @testable import spacesterminalmobileghostty

    @MainActor final class TerminalViewerModelTests: XCTestCase {
        private actor LinkPreviewGate {
            private var didStartSlow = false
            private var isReleased = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markSlowStarted() {
                didStartSlow = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }

            func waitForSlowStart() async {
                guard !didStartSlow else { return }
                await withCheckedContinuation { continuation in startWaiters.append(continuation) }
            }

            func waitForRelease() async {
                guard !isReleased else { return }
                await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
            }

            func releaseSlow() {
                isReleased = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        private actor LinkPreviewAttemptCounter {
            private var value = 0

            func next() -> Int {
                value += 1
                return value
            }
        }

        private actor ExternalDownloadProbe {
            private var didStartSlow = false
            private var didCancelSlow = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

            func markSlowStarted() {
                didStartSlow = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }

            func markSlowCancelled() {
                didCancelSlow = true
                let waiters = cancelWaiters
                cancelWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }

            func waitForSlowStart() async {
                guard !didStartSlow else { return }
                await withCheckedContinuation { continuation in startWaiters.append(continuation) }
            }

            func waitForSlowCancel() async {
                guard !didCancelSlow else { return }
                await withCheckedContinuation { continuation in cancelWaiters.append(continuation) }
            }
        }

        private actor DeviceAPIRequestRecorder {
            private var requests: [SpacesDeviceAPIRequest] = []

            func append(_ request: SpacesDeviceAPIRequest) { requests.append(request) }

            func snapshot() -> [SpacesDeviceAPIRequest] { requests }

            func containsTerminalControlAction(_ action: SpacesDeviceTerminalControlAction) -> Bool {
                requests.contains { request in
                    if case .terminalControl(let payload) = request.command { return payload.action == action }
                    return false
                }
            }

            func countTerminalControlAction(_ action: SpacesDeviceTerminalControlAction) -> Int {
                requests.filter { request in
                    if case .terminalControl(let payload) = request.command { return payload.action == action }
                    return false
                }.count
            }

            func countStateRequests() -> Int {
                requests.filter { request in
                    if case .state = request.command { return true }
                    return false
                }.count
            }

            func lastAttachedClient() -> TerminalClient? {
                for request in requests.reversed() {
                    guard case .terminalControl(let payload) = request.command, payload.action == .attach else { continue }
                    return payload.client
                }
                return nil
            }
        }

        private actor AuthenticationPromptRecorder {
            private var messages: [String] = []

            func append(_ message: String) { messages.append(message) }

            func firstMessage() -> String? { messages.first }
        }

        private final class HoldOpenTCPServer: @unchecked Sendable {
            private let socketFD: Int32
            private let acceptQueue = DispatchQueue(label: "spaces.mobile.tests.hold-open-tcp")
            private let lock = NSLock()
            private var acceptedSockets: [Int32] = []
            private var isStopped = false
            let port: Int

            init() throws {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw Self.currentPOSIXError() }
                var reuse: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    close(fd)
                    throw Self.currentPOSIXError()
                }

                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(0)
                inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
                let bindResult = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bindResult == 0 else {
                    close(fd)
                    throw Self.currentPOSIXError()
                }
                guard listen(fd, SOMAXCONN) == 0 else {
                    close(fd)
                    throw Self.currentPOSIXError()
                }

                var boundAddress = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in getsockname(fd, sockaddrPointer, &length) }
                }
                guard nameResult == 0 else {
                    close(fd)
                    throw Self.currentPOSIXError()
                }

                socketFD = fd
                port = Int(UInt16(bigEndian: boundAddress.sin_port))
                acceptQueue.async { [weak self] in self?.acceptConnections() }
            }

            func stop() {
                lock.lock()
                guard !isStopped else {
                    lock.unlock()
                    return
                }
                isStopped = true
                let sockets = acceptedSockets
                acceptedSockets.removeAll()
                lock.unlock()

                shutdown(socketFD, SHUT_RDWR)
                close(socketFD)
                for socket in sockets {
                    shutdown(socket, SHUT_RDWR)
                    close(socket)
                }
            }

            deinit { stop() }

            private func acceptConnections() {
                while true {
                    let acceptedSocket = Darwin.accept(socketFD, nil, nil)
                    guard acceptedSocket >= 0 else { return }
                    lock.lock()
                    if isStopped {
                        lock.unlock()
                        shutdown(acceptedSocket, SHUT_RDWR)
                        close(acceptedSocket)
                        return
                    }
                    acceptedSockets.append(acceptedSocket)
                    lock.unlock()
                }
            }

            private static func currentPOSIXError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        private func settings() -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = 12345
            settings.authToken = "token"
            settings.certificateFingerprint = "SHA256:test"
            return settings
        }

        private func session(state: TerminalSessionState = .running) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: "terminal-session", title: "terminal", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, state: state,
                backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: 200, workspaceID: "workspace-1",
                workspaceTitle: nil, projectID: nil, projectName: nil, createdAt: "2026-06-04T14:23:10Z", updatedAt: "2026-06-04T14:23:23Z",
                isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .process,
                rowSourceID: "process-row", hasFinalRender: false)
        }

        func testEndedSessionDoesNotOfferTakeOverWhenFinalRenderIsMissing() {
            let settings = settings()
            let session = SpacesDeviceTerminalSessionSummary(
                id: "ended-session", title: "ended", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, state: .exited,
                backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: 200, workspaceID: "workspace-1",
                workspaceTitle: nil, projectID: nil, projectName: nil, createdAt: "2026-06-04T14:23:10Z", updatedAt: "2026-06-04T14:23:23Z",
                isControlAvailable: false, isSubscriptionAvailable: false, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .process,
                rowSourceID: "process-row", hasFinalRender: false)
            let model = TerminalViewerModel(
                session: session, settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })

            XCTAssertEqual(model.renderMode, "ended")
            XCTAssertFalse(model.showsTakeOverAction)
            XCTAssertFalse(model.acceptsInput)
            XCTAssertEqual(model.visibleText, "This terminal session ended before a final render was available.")
        }

        func testStartingSessionShowsPreparingAndDoesNotOfferTakeOver() {
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })

            XCTAssertEqual(model.visibleText, "Preparing terminal…")
            XCTAssertFalse(model.showsTakeOverAction)
            XCTAssertFalse(model.acceptsInput)
        }

        func testStartingSessionAttachesViewerBeforeSubscribing() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            model.start()
            for _ in 0..<40 {
                if await recorder.containsTerminalControlAction(.attach) { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            model.stop()

            let requests = await recorder.snapshot()
            guard case .terminalControl(let payload)? = requests.first?.command else {
                XCTFail("Expected starting terminal connect to attach the viewer before subscribing.")
                return
            }
            XCTAssertEqual(payload.action, .attach)
            XCTAssertEqual(payload.sessionID, "terminal-session")
            XCTAssertEqual(payload.attachmentMode, .viewer)
            XCTAssertEqual(payload.client?.kind, .remoteViewer)
        }

        func testStartingSessionAttachSendsResolvedAppearance() async throws {
            let defaults = UserDefaults.standard
            let originalAppearance = defaults.string(forKey: AppAppearanceStorage.key)
            defaults.set(AppAppearanceMode.light.rawValue, forKey: AppAppearanceStorage.key)
            defer {
                if let originalAppearance {
                    defaults.set(originalAppearance, forKey: AppAppearanceStorage.key)
                } else {
                    defaults.removeObject(forKey: AppAppearanceStorage.key)
                }
            }

            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            model.start()
            for _ in 0..<40 {
                if await recorder.containsTerminalControlAction(.attach) { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            model.stop()

            let requests = await recorder.snapshot()
            let attachPayload = requests.compactMap { request -> SpacesDeviceTerminalControlRequest? in
                if case .terminalControl(let payload) = request.command, payload.action == .attach { return payload }
                return nil
            }.first
            let payload = try XCTUnwrap(attachPayload, "Expected the starting terminal connect to send an attach request.")
            XCTAssertEqual(payload.appearance, .light)
        }

        func testAppearanceChangeSendsSetAppearanceThroughBridge() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            await model.sendAppearance(.dark)

            let requests = await recorder.snapshot()
            let setAppearancePayload = requests.compactMap { request -> SpacesDeviceTerminalControlRequest? in
                if case .terminalControl(let payload) = request.command, payload.action == .setAppearance { return payload }
                return nil
            }.first
            let payload = try XCTUnwrap(setAppearancePayload, "Expected sendAppearance to send a setAppearance control request.")
            XCTAssertEqual(payload.appearance, .dark)
            XCTAssertEqual(payload.sessionID, "terminal-session")

            // A repeat of the same appearance dedupes against the last value sent, issuing no second request.
            await model.sendAppearance(.dark)
            let setAppearanceCount = await recorder.countTerminalControlAction(.setAppearance)
            XCTAssertEqual(setAppearanceCount, 1)
        }

        func testStartingSessionRetriesUnavailableAttachWithoutMarkingEnded() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .attach {
                    return SpacesDeviceAPIResponse(ok: false, message: "Terminal session terminal-session is not available.")
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            model.start()
            for _ in 0..<40 {
                if await recorder.countTerminalControlAction(.attach) >= 2 { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            model.stop()

            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertGreaterThanOrEqual(attachCount, 2)
            XCTAssertEqual(model.visibleText, "Preparing terminal…")
            XCTAssertFalse(model.showsTakeOverAction)
            XCTAssertFalse(model.acceptsInput)
        }

        func testStartingSessionRefreshesFailedStateWhenAttachReportsNotRunning() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let failedState = GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-04T14:23:30Z",
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "terminal-session", servicePID: 100, childPID: nil, state: .failed, updatedAt: "2026-06-04T14:23:30Z",
                    exitedAt: "2026-06-04T14:23:30Z"), attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "terminal",
                workingDirectory: "/tmp/work", outputByteCount: 0)
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                switch request.command {
                case .terminalControl(let payload) where payload.action == .attach:
                    return SpacesDeviceAPIResponse(ok: false, message: "Terminal session terminal-session is not running.")
                case .state: return Self.terminalStateResponse(failedState)
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            model.start()
            for _ in 0..<40 {
                if model.latestState?.runtimeState?.state == .failed { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            model.stop()

            let attachCount = await recorder.countTerminalControlAction(.attach)
            let stateRequestCount = await recorder.countStateRequests()
            XCTAssertEqual(attachCount, 1)
            XCTAssertEqual(stateRequestCount, 1)
            XCTAssertEqual(model.latestState?.runtimeState?.state, .failed)
            XCTAssertEqual(model.renderMode, "ended")
            XCTAssertFalse(model.showsTakeOverAction)
            XCTAssertFalse(model.acceptsInput)
        }

        func testStopDetachesEveryRestartedViewerLifecycle() async throws {
            let streamServer = try HoldOpenTCPServer()
            defer { streamServer.stop() }
            var settings = settings()
            settings.port = streamServer.port
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if case .state = request.command, let client = await recorder.lastAttachedClient() {
                    return Self.terminalStateResponse(Self.runningTerminalState(attachedClient: client))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            model.start()
            let didAttachInitially = try await waitForTerminalControlAction(.attach, count: 1, recorder: recorder)
            XCTAssertTrue(didAttachInitially, "Expected the initial viewer start to attach before subscribing.")
            let didRefreshStateInitially = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didRefreshStateInitially, "Expected the initial viewer start to reach the post-subscribe state refresh.")

            model.stop()
            let didDetachInitially = try await waitForTerminalControlAction(.detach, count: 1, recorder: recorder)
            XCTAssertTrue(didDetachInitially, "Expected stopping the initial viewer lifecycle to detach it.")
            model.start()

            let didAttachAfterRestart = try await waitForTerminalControlAction(.attach, count: 2, recorder: recorder)
            XCTAssertTrue(didAttachAfterRestart, "Expected restarting the same viewer model after stop() to open a fresh stream.")

            model.stop()
            let didDetachAfterRestart = try await waitForTerminalControlAction(.detach, count: 2, recorder: recorder)
            XCTAssertTrue(didDetachAfterRestart, "Expected stopping the restarted viewer lifecycle to detach it again.")
        }

        func testAuthenticationFailureAfterSubscribingCancelsStreamBeforeRestartingViewer() async throws {
            let streamServer = try HoldOpenTCPServer()
            defer { streamServer.stop() }
            var settings = settings()
            settings.port = streamServer.port
            let recorder = DeviceAPIRequestRecorder()
            let authenticationRecorder = AuthenticationPromptRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if case .state = request.command { return SpacesDeviceAPIResponse(ok: false, message: "Invalid device auth token.") }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings,
                onAuthenticationRequired: { message in Task { await authenticationRecorder.append(message) } }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didAttachInitially = try await waitForTerminalControlAction(.attach, count: 1, recorder: recorder)
            XCTAssertTrue(didAttachInitially, "Expected the initial viewer start to attach before subscribing.")
            let authenticationMessage = try await waitForAuthenticationMessage(recorder: authenticationRecorder)
            XCTAssertEqual(authenticationMessage, "This Mac no longer recognizes this device. Open Devices and pair this device again.")

            model.start()

            let didAttachAfterAuthentication = try await waitForTerminalControlAction(.attach, count: 2, recorder: recorder)
            XCTAssertTrue(didAttachAfterAuthentication, "Expected restarting after an authentication failure to open a fresh stream.")
        }

        func testOpenTerminalLinkShowsWebPagePreviewForNonMediaExternalURL() async throws {
            let settings = settings()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                XCTAssertEqual(request.commandName, "resolveTerminalLink")
                XCTAssertEqual(request.terminalLink, "https://example.com/docs")
                return Self.metadataResponse(
                    SpacesDeviceTerminalLinkMetadata(
                        id: "external|https://example.com/docs", source: .externalURL, originalLink: "https://example.com/docs", displayName: "docs",
                        contentType: nil, artifactKind: nil, byteCount: nil, externalURL: "https://example.com/docs"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            await model.openTerminalLink("https://example.com/docs")

            let preview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(preview.content, .webPage(URL(string: "https://example.com/docs")!))
            XCTAssertNil(preview.kind)
            XCTAssertNil(model.linkPreviewErrorMessage)
        }

        /// The raw link text (a local path, so it routes as `.fileLink`) must reach `resolveTerminalLink`
        /// unmodified, spaces included. The mocked resolver response's exact shape is incidental — this
        /// asserts on the request, not the resulting preview.
        func testOpenTerminalLinkSendsSpacedPathUnchanged() async {
            let settings = settings()
            let spacedPath = "/Users/yogesh/Downloads/Screen Recording 2026-03-20 at 11.17.57 AM.mov"
            var resolvedLinks: [String] = []
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                XCTAssertEqual(request.commandName, "resolveTerminalLink")
                resolvedLinks.append(request.terminalLink ?? "")
                return Self.metadataResponse(
                    SpacesDeviceTerminalLinkMetadata(
                        id: "external|https://example.com/docs", source: .externalURL, originalLink: spacedPath, displayName: "docs",
                        contentType: nil, artifactKind: nil, byteCount: nil, externalURL: "https://example.com/docs"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            await model.openTerminalLink(spacedPath)

            XCTAssertEqual(resolvedLinks, [spacedPath])
            XCTAssertEqual(model.linkPreview?.content, .webPage(URL(string: "https://example.com/docs")!))
        }

        func testOpenTerminalLinkDownloadsExternalMediaPreview() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cacheRoot) }
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { _ in
                Self.metadataResponse(
                    SpacesDeviceTerminalLinkMetadata(
                        id: "external|https://example.com/image.png", source: .externalURL, originalLink: "https://example.com/image.png",
                        displayName: "image.png", contentType: "image/png", artifactKind: .image, byteCount: nil,
                        externalURL: "https://example.com/image.png"))
            }
            let payload = Data([0x89, 0x50, 0x4E, 0x47])
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient,
                remoteMediaDownloader: { url, expectedArtifactKind in
                    XCTAssertEqual(url, URL(string: "https://example.com/image.png"))
                    XCTAssertEqual(expectedArtifactKind, .image)
                    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
                    let downloadedURL = cacheRoot.appendingPathComponent("downloaded-image.png")
                    try payload.write(to: downloadedURL)
                    return downloadedURL
                }, linkPreviewCacheDirectory: cacheRoot)

            await model.openTerminalLink("https://example.com/image.png")

            let preview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(preview.kind, .image)
            XCTAssertEqual(preview.content, .quickLook(preview.content.url))
            XCTAssertEqual(try Data(contentsOf: preview.content.url), payload)
            XCTAssertNil(model.linkPreviewErrorMessage)
        }

        func testOpenTerminalLinkDownloadsExtensionClassifiedMarkdownServedAsPlainText() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let downloadRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: cacheRoot)
                try? FileManager.default.removeItem(at: downloadRoot)
            }
            let url = URL(string: "https://raw.githubusercontent.com/example/project/main/README.md")!
            let payload = Data("# Read Me\n".utf8)
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { _ in
                Self.metadataResponse(
                    SpacesDeviceTerminalLinkMetadata(
                        id: "external|https://raw.githubusercontent.com/example/project/main/README.md", source: .externalURL,
                        originalLink: url.absoluteString, displayName: "README.md", contentType: "text/markdown", artifactKind: .markdown,
                        byteCount: nil, externalURL: url.absoluteString))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient,
                remoteMediaDownloader: { requestedURL, expectedArtifactKind in
                    XCTAssertEqual(requestedURL, url)
                    XCTAssertEqual(expectedArtifactKind, .markdown)
                    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
                    let downloadedURL = downloadRoot.appendingPathComponent("README.md")
                    try payload.write(to: downloadedURL)
                    guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])
                    else { throw SpacesDeviceAPIClientError.requestFailed("Missing HTTP response.") }
                    return try TerminalViewerModel.validatedRemoteMediaDownloadURL(
                        downloadedURL, response: response, expectedArtifactKind: expectedArtifactKind, sourceURL: requestedURL)
                }, linkPreviewCacheDirectory: cacheRoot)

            await model.openTerminalLink(url.absoluteString)

            let preview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(preview.kind, .markdown)
            XCTAssertEqual(preview.content, .markdown(preview.content.url))
            XCTAssertEqual(try Data(contentsOf: preview.content.url), payload)
            XCTAssertNil(model.linkPreviewErrorMessage)
        }

        func testOpenTerminalLinkRejectsFailedExternalMediaHTTPStatusBeforeCaching() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let downloadRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: cacheRoot)
                try? FileManager.default.removeItem(at: downloadRoot)
            }
            let url = URL(string: "https://example.com/missing.png")!
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { _ in
                Self.metadataResponse(
                    SpacesDeviceTerminalLinkMetadata(
                        id: "external|https://example.com/missing.png", source: .externalURL, originalLink: "https://example.com/missing.png",
                        displayName: "missing.png", contentType: "image/png", artifactKind: .image, byteCount: nil,
                        externalURL: "https://example.com/missing.png"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient,
                remoteMediaDownloader: { requestedURL, expectedArtifactKind in
                    XCTAssertEqual(requestedURL, url)
                    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
                    let downloadedURL = downloadRoot.appendingPathComponent("error-page.html")
                    try Data("<html>not found</html>".utf8).write(to: downloadedURL)
                    guard let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else {
                        throw SpacesDeviceAPIClientError.requestFailed("Missing HTTP response.")
                    }
                    return try TerminalViewerModel.validatedRemoteMediaDownloadURL(
                        downloadedURL, response: response, expectedArtifactKind: expectedArtifactKind, sourceURL: requestedURL)
                }, linkPreviewCacheDirectory: cacheRoot)

            await model.openTerminalLink("https://example.com/missing.png")

            XCTAssertNil(model.linkPreview)
            XCTAssertEqual(model.linkPreviewErrorMessage, "The media link returned HTTP status 404.")
            let cachedFiles = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
            XCTAssertTrue(cachedFiles.isEmpty)
        }

        func testOpenTerminalLinkRejectsNonMediaExternalHTTPContentBeforeCaching() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let downloadRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: cacheRoot)
                try? FileManager.default.removeItem(at: downloadRoot)
            }
            let url = URL(string: "https://example.com/login.png")!
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { _ in
                Self.metadataResponse(
                    SpacesDeviceTerminalLinkMetadata(
                        id: "external|https://example.com/login.png", source: .externalURL, originalLink: "https://example.com/login.png",
                        displayName: "login.png", contentType: "image/png", artifactKind: .image, byteCount: nil,
                        externalURL: "https://example.com/login.png"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient,
                remoteMediaDownloader: { requestedURL, expectedArtifactKind in
                    XCTAssertEqual(requestedURL, url)
                    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
                    let downloadedURL = downloadRoot.appendingPathComponent("login.html")
                    try Data("<html>sign in</html>".utf8).write(to: downloadedURL)
                    guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])
                    else { throw SpacesDeviceAPIClientError.requestFailed("Missing HTTP response.") }
                    return try TerminalViewerModel.validatedRemoteMediaDownloadURL(
                        downloadedURL, response: response, expectedArtifactKind: expectedArtifactKind, sourceURL: requestedURL)
                }, linkPreviewCacheDirectory: cacheRoot)

            await model.openTerminalLink("https://example.com/login.png")

            XCTAssertNil(model.linkPreview)
            XCTAssertEqual(model.linkPreviewErrorMessage, "The media link did not return image content.")
            let cachedFiles = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
            XCTAssertTrue(cachedFiles.isEmpty)
        }

        func testOpenTerminalLinkRejectsOversizedExternalTextPreviewBeforeCaching() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let downloadRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: cacheRoot)
                try? FileManager.default.removeItem(at: downloadRoot)
            }
            let oversizedByteCount = 4 * 1024 * 1024 + 1
            let downloadedURL = downloadRoot.appendingPathComponent("huge.log")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { _ in
                Self.metadataResponse(
                    SpacesDeviceTerminalLinkMetadata(
                        id: "external|https://example.com/huge.log", source: .externalURL, originalLink: "https://example.com/huge.log",
                        displayName: "huge.log", contentType: "text/plain", artifactKind: .text, byteCount: nil,
                        externalURL: "https://example.com/huge.log"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient,
                remoteMediaDownloader: { _, expectedArtifactKind in
                    XCTAssertEqual(expectedArtifactKind, .text)
                    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
                    try Data(repeating: 0x41, count: oversizedByteCount).write(to: downloadedURL)
                    return downloadedURL
                }, linkPreviewCacheDirectory: cacheRoot)

            await model.openTerminalLink("https://example.com/huge.log")

            XCTAssertNil(model.linkPreview)
            XCTAssertEqual(model.linkPreviewErrorMessage, "huge.log is too large to preview on this device.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedURL.path))
            let cachedFiles = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
            XCTAssertTrue(cachedFiles.isEmpty)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testValidatedRemoteMediaDownloadRejectsNonHTTPSFinalURL() throws {
            let downloadedURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: downloadedURL)
            let finalURL = try XCTUnwrap(URL(string: "http://example.com/image.png"))
            let response = try XCTUnwrap(
                HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]))

            XCTAssertThrowsError(
                try TerminalViewerModel.validatedRemoteMediaDownloadURL(downloadedURL, response: response, expectedArtifactKind: .image)
            ) { error in XCTAssertEqual(error.localizedDescription, "The media link redirected to a non-HTTPS URL.") }
        }

        func testValidatedRemoteMediaDownloadRejectsUnsupportedSpecificTypeDespiteResolvedExtension() throws {
            let downloadedURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            try Data("<svg></svg>".utf8).write(to: downloadedURL)
            let url = try XCTUnwrap(URL(string: "https://example.com/image.png"))
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/svg+xml"]))

            XCTAssertThrowsError(
                try TerminalViewerModel.validatedRemoteMediaDownloadURL(
                    downloadedURL, response: response, expectedArtifactKind: .image, sourceURL: url)
            ) { error in XCTAssertEqual(error.localizedDescription, "The media link did not return image content.") }
        }

        func testOpenTerminalLinkCancelsStaleExternalMediaDownload() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cacheRoot) }
            let probe = ExternalDownloadProbe()
            let fastPayload = Data([0x02, 0x02, 0x02])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                let link = request.terminalLink ?? ""
                return Self.metadataResponse(
                    SpacesDeviceTerminalLinkMetadata(
                        id: "external|\(link)", source: .externalURL, originalLink: link, displayName: URL(string: link)?.lastPathComponent ?? link,
                        contentType: "image/png", artifactKind: .image, byteCount: nil, externalURL: link))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient,
                remoteMediaDownloader: { url, _ in
                    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
                    if url.lastPathComponent == "slow.png" {
                        await probe.markSlowStarted()
                        // The slow download must still be suspended when the fresher request cancels it, so
                        // only cancellation should end this sleep; the ceiling exists solely so a cancellation
                        // regression fails in bounded time. If the sleep completes naturally, fail loudly AND
                        // still mark the cancel so waitForSlowCancel() below unblocks instead of hanging.
                        do {
                            try await Task.sleep(for: .seconds(30))
                            XCTFail("slow download completed naturally; the fresher request never cancelled it")
                            await probe.markSlowCancelled()
                        } catch {
                            await probe.markSlowCancelled()
                            throw error
                        }
                    }
                    let downloadedURL = cacheRoot.appendingPathComponent("downloaded-\(UUID().uuidString).png")
                    try fastPayload.write(to: downloadedURL)
                    return downloadedURL
                }, linkPreviewCacheDirectory: cacheRoot)

            let slowTask = Task { await model.openTerminalLink("https://example.com/slow.png") }
            await probe.waitForSlowStart()
            await model.openTerminalLink("https://example.com/fast.png")
            await probe.waitForSlowCancel()
            await slowTask.value

            let preview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(preview.title, "fast.png")
            XCTAssertEqual(try Data(contentsOf: preview.content.url), fastPayload)
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testOpenTerminalLinkRemovesStaleExternalDownloadedFile() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let downloadRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: cacheRoot)
                try? FileManager.default.removeItem(at: downloadRoot)
            }
            let gate = LinkPreviewGate()
            let slowDownloadedURL = downloadRoot.appendingPathComponent("slow-download.png")
            let fastDownloadedURL = downloadRoot.appendingPathComponent("fast-download.png")
            let fastPayload = Data([0x02, 0x02, 0x02])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                let link = request.terminalLink ?? ""
                return Self.metadataResponse(
                    SpacesDeviceTerminalLinkMetadata(
                        id: "external|\(link)", source: .externalURL, originalLink: link, displayName: URL(string: link)?.lastPathComponent ?? link,
                        contentType: "image/png", artifactKind: .image, byteCount: nil, externalURL: link))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient,
                remoteMediaDownloader: { url, _ in
                    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
                    if url.lastPathComponent == "slow.png" {
                        await gate.markSlowStarted()
                        await gate.waitForRelease()
                        try Data([0x01, 0x01, 0x01]).write(to: slowDownloadedURL)
                        return slowDownloadedURL
                    }
                    try fastPayload.write(to: fastDownloadedURL)
                    return fastDownloadedURL
                }, linkPreviewCacheDirectory: cacheRoot)

            let slowTask = Task { await model.openTerminalLink("https://example.com/slow.png") }
            await gate.waitForSlowStart()
            await model.openTerminalLink("https://example.com/fast.png")
            await gate.releaseSlow()
            await slowTask.value

            let preview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(preview.title, "fast.png")
            XCTAssertEqual(try Data(contentsOf: preview.content.url), fastPayload)
            XCTAssertFalse(FileManager.default.fileExists(atPath: slowDownloadedURL.path))
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testOpenTerminalLinkDownloadsLocalMediaChunks() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cacheRoot) }
            let payload = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "resolveTerminalLink":
                    return Self.metadataResponse(
                        SpacesDeviceTerminalLinkMetadata(
                            id: "link-1", source: .localFile, originalLink: "image.png", displayName: "image.png", contentType: "image/png",
                            artifactKind: .image, byteCount: Int64(payload.count), externalURL: nil))
                case "readTerminalLinkChunk":
                    let offset = Int(request.chunkOffset ?? 0)
                    let end = min(offset + 4, payload.count)
                    let chunk = payload[offset..<end]
                    return Self.chunkResponse(
                        SpacesDeviceTerminalLinkChunk(
                            linkID: "link-1", offset: Int64(offset), byteCount: chunk.count, isFinal: end >= payload.count,
                            base64Data: Data(chunk).base64EncodedString()))
                default: return SpacesDeviceAPIResponse(ok: false, message: "unexpected command")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient, linkPreviewCacheDirectory: cacheRoot)

            await model.openTerminalLink("image.png")

            let preview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(preview.kind, .image)
            XCTAssertEqual(preview.content, .quickLook(preview.content.url))
            XCTAssertEqual(try Data(contentsOf: preview.content.url), payload)
            XCTAssertNil(model.linkPreviewErrorMessage)
        }

        func testOpenTerminalLinkNoticesLoopbackURLWithoutResolving() async {
            let settings = settings()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { _ in
                XCTFail("Loopback links must not trigger a resolveTerminalLink round trip.")
                return SpacesDeviceAPIResponse(ok: false, message: "unexpected")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            await model.openTerminalLink("http://localhost:3000/dashboard")

            XCTAssertEqual(model.linkNotice, "This address runs on the session's host machine and isn't reachable from this device yet.")
            XCTAssertNil(model.linkPreview)
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        /// A `spaces://terminal/…` link tapped inside the terminal is an in-app navigation: it must
        /// invoke the injected navigator callback with the parsed deep link and never reach the daemon's
        /// `resolveTerminalLink`, which rejects the `spaces` scheme.
        func testOpenTerminalLinkRoutesSpacesTerminalDeepLinkWithoutResolving() async {
            let settings = settings()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { _ in
                XCTFail("A spaces://terminal link must not trigger a resolveTerminalLink round trip.")
                return SpacesDeviceAPIResponse(ok: false, message: "unexpected")
            }
            var openedLink: SpacesTerminalDeepLink?
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { openedLink = $0 },
                bridgeClient: bridgeClient)

            await model.openTerminalLink("spaces://terminal/abc")

            XCTAssertEqual(openedLink, SpacesTerminalDeepLink(sessionID: "abc"))
            XCTAssertNil(model.linkPreview)
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertNil(model.linkNotice)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testOpenTerminalLinkIgnoresUnknownScheme() async {
            let settings = settings()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { _ in
                XCTFail("An unrecognized scheme must not trigger a resolveTerminalLink round trip.")
                return SpacesDeviceAPIResponse(ok: false, message: "unexpected")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            await model.openTerminalLink("mailto:person@example.com")

            XCTAssertNil(model.linkPreview)
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertNil(model.linkNotice)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testOpenTerminalLinkUnknownSchemeCancelsStalePreviewRequest() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cacheRoot) }
            let gate = LinkPreviewGate()
            let payload = Data([0x89, 0x50, 0x4E, 0x47])
            let linkID = "slow-link"
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "resolveTerminalLink":
                    await gate.markSlowStarted()
                    await gate.waitForRelease()
                    return Self.previewMetadata(id: linkID, originalLink: "slow.png", displayName: "slow.png", byteCount: payload.count)
                case "readTerminalLinkChunk": return Self.previewChunk(id: linkID, payload: payload, offset: request.chunkOffset ?? 0)
                default: return SpacesDeviceAPIResponse(ok: false, message: "unexpected command")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient, linkPreviewCacheDirectory: cacheRoot)

            let slowTask = Task { await model.openTerminalLink("slow.png") }
            await gate.waitForSlowStart()

            await model.openTerminalLink("mailto:person@example.com")

            XCTAssertNil(model.linkPreview)
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertNil(model.linkNotice)
            XCTAssertFalse(model.isPreparingLinkPreview)

            await gate.releaseSlow()
            await slowTask.value

            XCTAssertNil(model.linkPreview)
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertNil(model.linkNotice)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testOpenTerminalLinkDownloadsLocalDocumentPreviewsByKind() async throws {
            let cases:
                [(artifactKind: SpacesDeviceTerminalLinkArtifactKind, contentType: String, expectedContent: (URL) -> TerminalLinkPreviewContent)] = [
                    (.text, "text/plain", { .text($0) }), (.markdown, "text/markdown", { .markdown($0) }), (.html, "text/html", { .htmlFile($0) }),
                    (.pdf, "application/pdf", { .quickLook($0) }),
                ]
            for testCase in cases {
                let settings = settings()
                let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: cacheRoot) }
                let payload = Data("preview contents".utf8)
                let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                    switch request.commandName {
                    case "resolveTerminalLink":
                        return Self.metadataResponse(
                            SpacesDeviceTerminalLinkMetadata(
                                id: "link-1", source: .localFile, originalLink: "file.\(testCase.artifactKind.rawValue)",
                                displayName: "file.\(testCase.artifactKind.rawValue)", contentType: testCase.contentType,
                                artifactKind: testCase.artifactKind, byteCount: Int64(payload.count), externalURL: nil))
                    case "readTerminalLinkChunk":
                        return Self.previewChunk(id: request.terminalLinkID ?? "", payload: payload, offset: request.chunkOffset ?? 0)
                    default: return SpacesDeviceAPIResponse(ok: false, message: "unexpected command")
                    }
                }
                let model = TerminalViewerModel(
                    session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                    bridgeClient: bridgeClient, linkPreviewCacheDirectory: cacheRoot)

                await model.openTerminalLink("file.\(testCase.artifactKind.rawValue)")

                let preview = try XCTUnwrap(model.linkPreview, "kind=\(testCase.artifactKind)")
                XCTAssertEqual(preview.kind, testCase.artifactKind)
                XCTAssertEqual(preview.content, testCase.expectedContent(preview.content.url), "kind=\(testCase.artifactKind)")
                XCTAssertEqual(try Data(contentsOf: preview.content.url), payload, "kind=\(testCase.artifactKind)")
                XCTAssertNil(model.linkPreviewErrorMessage, "kind=\(testCase.artifactKind)")
            }
        }

        func testOpenTerminalLinkRejectsOversizedTextFamilyPreview() async {
            let settings = settings()
            let oversizedByteCount: Int64 = 4 * 1024 * 1024 + 1
            var didRequestChunk = false
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "resolveTerminalLink":
                    return Self.metadataResponse(
                        SpacesDeviceTerminalLinkMetadata(
                            id: "link-1", source: .localFile, originalLink: "huge.log", displayName: "huge.log", contentType: "text/plain",
                            artifactKind: .text, byteCount: oversizedByteCount, externalURL: nil))
                case "readTerminalLinkChunk":
                    didRequestChunk = true
                    return SpacesDeviceAPIResponse(ok: false, message: "unexpected chunk request")
                default: return SpacesDeviceAPIResponse(ok: false, message: "unexpected command")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            await model.openTerminalLink("huge.log")

            XCTAssertNil(model.linkPreview)
            XCTAssertEqual(model.linkPreviewErrorMessage, "huge.log is too large to preview on this device.")
            XCTAssertFalse(didRequestChunk)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testOpenTerminalLinkDeletesPartialLocalPreviewOnTransferFailure() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cacheRoot) }
            let firstChunk = Data([0x89, 0x50, 0x4E, 0x47])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "resolveTerminalLink":
                    return Self.previewMetadata(id: "link-1", originalLink: "image.png", displayName: "image.png", byteCount: 8)
                case "readTerminalLinkChunk":
                    let offset = request.chunkOffset ?? 0
                    if offset == 0 {
                        return Self.chunkResponse(
                            SpacesDeviceTerminalLinkChunk(
                                linkID: "link-1", offset: 0, byteCount: firstChunk.count, isFinal: false, base64Data: firstChunk.base64EncodedString()
                            ))
                    }
                    return Self.chunkResponse(
                        SpacesDeviceTerminalLinkChunk(
                            linkID: "link-1", offset: offset, byteCount: 2, isFinal: true, base64Data: Data([0x01]).base64EncodedString()))
                default: return SpacesDeviceAPIResponse(ok: false, message: "unexpected command")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient, linkPreviewCacheDirectory: cacheRoot)

            await model.openTerminalLink("image.png")

            XCTAssertNil(model.linkPreview)
            XCTAssertEqual(model.linkPreviewErrorMessage, "Terminal link 'link-1' transfer returned an invalid chunk size (reported 2, decoded 1).")
            let cachedFiles = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
            XCTAssertTrue(cachedFiles.isEmpty)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testOpenTerminalLinkKeepsVisiblePreviewWhenLaterDuplicateFails() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cacheRoot) }
            let payload = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
            let attempts = LinkPreviewAttemptCounter()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "resolveTerminalLink":
                    if await attempts.next() == 1 {
                        return Self.previewMetadata(id: "link-1", originalLink: "image.png", displayName: "image.png", byteCount: payload.count)
                    }
                    return SpacesDeviceAPIResponse(ok: false, message: "This file path is not available to mobile preview.")
                case "readTerminalLinkChunk":
                    return Self.previewChunk(id: request.terminalLinkID ?? "", payload: payload, offset: request.chunkOffset ?? 0)
                default: return SpacesDeviceAPIResponse(ok: false, message: "unexpected command")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient, linkPreviewCacheDirectory: cacheRoot)

            await model.openTerminalLink("image.png")
            let preview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(preview.title, "image.png")

            await model.openTerminalLink("image.png")

            let retainedPreview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(retainedPreview.title, "image.png")
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testOpenTerminalLinkRecordsFailedTransferState() async {
            let settings = settings()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: false, message: "Only image and video files can be previewed on iOS.")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            await model.openTerminalLink("notes.txt")

            XCTAssertNil(model.linkPreview)
            XCTAssertEqual(model.linkPreviewErrorMessage, "Only image and video files can be previewed on iOS.")
        }

        func testOpenTerminalLinkIgnoresStaleEarlierPreviewResult() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cacheRoot) }
            let gate = LinkPreviewGate()
            let slowPayload = Data([1, 1, 1])
            let fastPayload = Data([2, 2, 2])
            let slowID = "slow-link"
            let fastID = "fast-link"
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "resolveTerminalLink":
                    if request.terminalLink == "slow.png" {
                        await gate.markSlowStarted()
                        await gate.waitForRelease()
                        return Self.previewMetadata(id: slowID, originalLink: "slow.png", displayName: "slow.png", byteCount: slowPayload.count)
                    }
                    return Self.previewMetadata(id: fastID, originalLink: "fast.png", displayName: "fast.png", byteCount: fastPayload.count)
                case "readTerminalLinkChunk":
                    let payload = request.terminalLinkID == slowID ? slowPayload : fastPayload
                    return Self.previewChunk(id: request.terminalLinkID ?? "", payload: payload, offset: request.chunkOffset ?? 0)
                default: return SpacesDeviceAPIResponse(ok: false, message: "unexpected command")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient, linkPreviewCacheDirectory: cacheRoot)

            let slowTask = Task { await model.openTerminalLink("slow.png") }
            await gate.waitForSlowStart()
            await model.openTerminalLink("fast.png")

            let fastPreview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(fastPreview.title, "fast.png")
            XCTAssertEqual(try Data(contentsOf: fastPreview.content.url), fastPayload)

            await gate.releaseSlow()
            await slowTask.value

            let finalPreview = try XCTUnwrap(model.linkPreview)
            XCTAssertEqual(finalPreview.title, "fast.png")
            XCTAssertEqual(try Data(contentsOf: finalPreview.content.url), fastPayload)
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testOpenTerminalLinkUsesDistinctCacheURLsForLongSimilarLinkIDs() async throws {
            let settings = settings()
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cacheRoot) }
            let sharedPrefix = String(repeating: "a", count: 60)
            let firstID = "\(sharedPrefix)1"
            let secondID = "\(sharedPrefix)2"
            let firstPayload = Data([0x01, 0x02, 0x03])
            let secondPayload = Data([0x04, 0x05, 0x06])
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "resolveTerminalLink":
                    if request.terminalLink == "first.png" {
                        return Self.previewMetadata(id: firstID, originalLink: "first.png", displayName: "first.png", byteCount: firstPayload.count)
                    }
                    return Self.previewMetadata(id: secondID, originalLink: "second.png", displayName: "second.png", byteCount: secondPayload.count)
                case "readTerminalLinkChunk":
                    let payload = request.terminalLinkID == firstID ? firstPayload : secondPayload
                    return Self.previewChunk(id: request.terminalLinkID ?? "", payload: payload, offset: request.chunkOffset ?? 0)
                default: return SpacesDeviceAPIResponse(ok: false, message: "unexpected command")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient, linkPreviewCacheDirectory: cacheRoot)

            await model.openTerminalLink("first.png")
            let firstURL = try XCTUnwrap(model.linkPreview?.content.url)
            await model.openTerminalLink("second.png")
            let secondURL = try XCTUnwrap(model.linkPreview?.content.url)

            XCTAssertNotEqual(firstURL, secondURL)
            XCTAssertEqual(try Data(contentsOf: firstURL), firstPayload)
            XCTAssertEqual(try Data(contentsOf: secondURL), secondPayload)
        }

        private nonisolated static func previewMetadata(id: String, originalLink: String, displayName: String, byteCount: Int)
            -> SpacesDeviceAPIResponse
        {
            Self.metadataResponse(
                SpacesDeviceTerminalLinkMetadata(
                    id: id, source: .localFile, originalLink: originalLink, displayName: displayName, contentType: "image/png", artifactKind: .image,
                    byteCount: Int64(byteCount), externalURL: nil))
        }

        private nonisolated static func previewChunk(id: String, payload: Data, offset: Int64) -> SpacesDeviceAPIResponse {
            let offset = Int(offset)
            let chunk = payload[offset..<payload.count]
            return Self.chunkResponse(
                SpacesDeviceTerminalLinkChunk(
                    linkID: id, offset: Int64(offset), byteCount: chunk.count, isFinal: true, base64Data: Data(chunk).base64EncodedString()))
        }

        private func waitForTerminalControlAction(
            _ action: SpacesDeviceTerminalControlAction, count expectedCount: Int, recorder: DeviceAPIRequestRecorder
        ) async throws -> Bool {
            for _ in 0..<40 {
                if await recorder.countTerminalControlAction(action) >= expectedCount { return true }
                try await Task.sleep(for: .milliseconds(25))
            }
            return await recorder.countTerminalControlAction(action) >= expectedCount
        }

        private func waitForAuthenticationMessage(recorder: AuthenticationPromptRecorder) async throws -> String? {
            for _ in 0..<40 {
                if let message = await recorder.firstMessage() { return message }
                try await Task.sleep(for: .milliseconds(25))
            }
            return await recorder.firstMessage()
        }

        private func waitForStateRequestCount(_ expectedCount: Int, recorder: DeviceAPIRequestRecorder) async throws -> Bool {
            for _ in 0..<40 {
                if await recorder.countStateRequests() >= expectedCount { return true }
                try await Task.sleep(for: .milliseconds(25))
            }
            return await recorder.countStateRequests() >= expectedCount
        }

        private nonisolated static func runningTerminalState(attachedClient: TerminalClient) -> GhosttyRemoteSessionStatePayload {
            let attachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: attachedClient.id, mode: .viewer, attachedAt: "2026-06-04T14:23:30Z")
            return GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-06-04T14:23:30Z",
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "terminal-session", servicePID: 100, childPID: 200, state: .running, updatedAt: "2026-06-04T14:23:30Z"),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [attachedClient], attachments: [attachment]), title: "terminal",
                workingDirectory: "/tmp/work", outputByteCount: 0)
        }

        private nonisolated static func metadataResponse(_ metadata: SpacesDeviceTerminalLinkMetadata) -> SpacesDeviceAPIResponse {
            SpacesDeviceAPIResponse(ok: true, message: "ok", result: .terminalLinkMetadata(metadata))
        }

        private nonisolated static func terminalStateResponse(_ payload: GhosttyRemoteSessionStatePayload) -> SpacesDeviceAPIResponse {
            SpacesDeviceAPIResponse(ok: true, message: "ok", result: .terminalState(payload))
        }

        private nonisolated static func chunkResponse(_ chunk: SpacesDeviceTerminalLinkChunk) -> SpacesDeviceAPIResponse {
            SpacesDeviceAPIResponse(ok: true, message: "ok", result: .terminalLinkChunk(chunk))
        }
    }

    @MainActor final class GhosttyMobileAppServiceTests: XCTestCase {
        override func setUp() {
            super.setUp()
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = false
        }

        override func tearDown() {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            super.tearDown()
        }

        func testRuntimeConfigProvidesRequiredCallbacks() {
            let runtimeConfig = GhosttyMobileAppService.makeRuntimeConfig()

            XCTAssertNotNil(runtimeConfig.wakeup_cb)
            XCTAssertNotNil(runtimeConfig.action_cb)
            XCTAssertNotNil(runtimeConfig.read_clipboard_cb)
            XCTAssertNotNil(runtimeConfig.confirm_read_clipboard_cb)
            XCTAssertNotNil(runtimeConfig.write_clipboard_cb)
            XCTAssertNotNil(runtimeConfig.close_surface_cb)
            XCTAssertFalse(runtimeConfig.supports_selection_clipboard)
        }

        func testMobileActionParserParsesOpenURLAndMouseOverLinkEvents() {
            var open = ghostty_action_s()
            open.tag = GHOSTTY_ACTION_OPEN_URL
            "https://example.com/movie.mp4".withCString { pointer in
                open.action.open_url = ghostty_action_open_url_s(
                    kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: pointer, len: UInt("https://example.com/movie.mp4".utf8.count))
                XCTAssertEqual(GhosttyMobileActionEventParser.parse(open), .openURL(kind: .unknown, value: "https://example.com/movie.mp4"))
            }

            var hover = ghostty_action_s()
            hover.tag = GHOSTTY_ACTION_MOUSE_OVER_LINK
            "image.png".withCString { pointer in
                hover.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: pointer, len: "image.png".utf8.count)
                XCTAssertEqual(GhosttyMobileActionEventParser.parse(hover), .mouseOverLink("image.png"))
            }
            hover.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: nil, len: 0)
            XCTAssertEqual(GhosttyMobileActionEventParser.parse(hover), .mouseOverLink(nil))
        }

        func testRuntimeActionCallbackDispatchesMainThreadOpenURLSynchronously() {
            let service = GhosttyMobileAppService.shared
            let surface = UnsafeMutableRawPointer(bitPattern: 0x1234)!
            let url = "https://example.com/image.png"
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = surface
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_OPEN_URL
            var handledEvents: [GhosttyMobileActionEvent] = []

            service.registerActionHandler(for: surface) { event in handledEvents.append(event) }
            defer { service.unregisterActionHandler(for: surface) }

            url.withCString { pointer in
                action.action.open_url = ghostty_action_open_url_s(
                    kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: pointer, len: UInt(url.utf8.count))
                let runtimeConfig = GhosttyMobileAppService.makeRuntimeConfig()
                XCTAssertTrue(runtimeConfig.action_cb(nil, target, action))
                XCTAssertEqual(handledEvents, [.openURL(kind: .unknown, value: url)])
            }
        }

        func testPhoneViewportKeepsRenderableSurfaceColumns() {
            let viewport = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: 80, rawRows: 24, bounds: CGRect(x: 0, y: 0, width: 393, height: 700), idiom: .phone)

            XCTAssertEqual(viewport.columns, 80)
            XCTAssertEqual(viewport.rows, 24)
        }

        func testPadViewportKeepsGhosttyColumns() {
            let viewport = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: 120, rawRows: 40, bounds: CGRect(x: 0, y: 0, width: 1024, height: 900), idiom: .pad)

            XCTAssertEqual(viewport.columns, 120)
            XCTAssertEqual(viewport.rows, 40)
        }

        func testTouchScrollFingerDownMapsTowardOlderScrollback() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: CGPoint(x: 0, y: 12), scaleFactor: 2)

            XCTAssertEqual(delta.y, 12)
        }

        func testTouchScrollFingerUpMapsTowardLiveBottom() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: CGPoint(x: 0, y: -12), scaleFactor: 2)

            XCTAssertEqual(delta.y, -12)
        }

        func testTouchScrollUsesScaleFactorAsPointToPixelConversion() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: CGPoint(x: 4, y: 10), scaleFactor: 3)

            XCTAssertEqual(delta.x, -6)
            XCTAssertEqual(delta.y, 15)
        }

        func testHighVelocityMomentumProducesBoundedDeltas() {
            let delta = GhosttyRemoteTerminalScrollMapper.momentumFrameDelta(velocity: CGPoint(x: 20_000, y: 20_000), elapsed: 1, scaleFactor: 3)

            XCTAssertEqual(delta.x, -120)
            XCTAssertEqual(delta.y, 120)
        }

        func testResolveResourcesPathUsesBundledGhosttyResources() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundledResources = root.appendingPathComponent("ghostty", isDirectory: true)
            try FileManager.default.createDirectory(at: bundledResources, withIntermediateDirectories: true)

            let resolved = try GhosttyMobileAppService.resolveResourcesPath(
                environment: [:], bundleResourceURL: root,
                sourceFilePath: "/unavailable/Sources/spacesterminalmobileghostty/GhosttyMobileAppService.swift")

            XCTAssertEqual(resolved, bundledResources.path)
        }

        func testConfigureGhosttyProcessEnvironmentSetsHomeAndXDGDirectories() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent("home", isDirectory: true)
            let support = root.appendingPathComponent("support", isDirectory: true)
            let caches = root.appendingPathComponent("caches", isDirectory: true)
            var environment: [String: (value: String, overwrite: Int32)] = [:]

            try GhosttyMobileAppService.configureGhosttyProcessEnvironment(
                homeDirectory: home, applicationSupportDirectory: support, cachesDirectory: caches,
                setEnvironment: { name, value, overwrite in
                    environment[name] = (value, overwrite)
                    return 0
                })

            XCTAssertEqual(environment["HOME"]?.value, home.path)
            XCTAssertEqual(environment["HOME"]?.overwrite, 1)
            XCTAssertEqual(environment["SHELL"]?.value, "/bin/sh")
            XCTAssertEqual(environment["XDG_CONFIG_HOME"]?.value, support.appendingPathComponent("ghostty/config", isDirectory: true).path)
            XCTAssertEqual(environment["XDG_STATE_HOME"]?.value, support.appendingPathComponent("ghostty/state", isDirectory: true).path)
            XCTAssertEqual(environment["XDG_CACHE_HOME"]?.value, caches.appendingPathComponent("ghostty/cache", isDirectory: true).path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: environment["XDG_CONFIG_HOME"]?.value ?? ""))
            XCTAssertTrue(FileManager.default.fileExists(atPath: environment["XDG_STATE_HOME"]?.value ?? ""))
            XCTAssertTrue(FileManager.default.fileExists(atPath: environment["XDG_CACHE_HOME"]?.value ?? ""))
        }

        func testRepairStandardFileDescriptorsRepairsOutputBeforeInstallingKeepAliveStandardInputWhenStdinIsMissing() throws {
            var validDescriptors: Set<Int32> = []
            var duplicateCalls: [(source: Int32, target: Int32)] = []
            var closeCalls: [Int32] = []
            var operations: [String] = []

            let repair = try GhosttyMobileAppService.repairStandardFileDescriptors(
                isDescriptorValid: { validDescriptors.contains($0) },
                createStandardInputPipe: {
                    operations.append("createPipe")
                    validDescriptors.insert(5)
                    validDescriptors.insert(6)
                    return (5, 6)
                },
                openReadWriteNull: {
                    operations.append("openNull")
                    validDescriptors.insert(7)
                    return 7
                },
                duplicateDescriptor: { source, target in
                    duplicateCalls.append((source, target))
                    validDescriptors.insert(target)
                    return target
                },
                closeDescriptor: { descriptor in
                    closeCalls.append(descriptor)
                    validDescriptors.remove(descriptor)
                    return 0
                })

            XCTAssertEqual(operations, ["openNull", "createPipe"])
            XCTAssertEqual(duplicateCalls.map(\.source), [7, 7, 5])
            XCTAssertEqual(duplicateCalls.map(\.target), [STDOUT_FILENO, STDERR_FILENO, STDIN_FILENO])
            XCTAssertEqual(closeCalls, [7, 5])
            XCTAssertTrue(validDescriptors.contains(STDIN_FILENO))
            XCTAssertTrue(validDescriptors.contains(STDOUT_FILENO))
            XCTAssertTrue(validDescriptors.contains(STDERR_FILENO))
            XCTAssertEqual(repair.retainedStandardInputWriteDescriptor, 6)
            XCTAssertTrue(validDescriptors.contains(6))
        }

        func testRepairStandardFileDescriptorsReusesStandardInputDescriptorWhenPipeReadEndLandsOnStdin() throws {
            var validDescriptors: Set<Int32> = [STDOUT_FILENO, STDERR_FILENO]
            var duplicateCalls: [(source: Int32, target: Int32)] = []
            var closeCalls: [Int32] = []

            let repair = try GhosttyMobileAppService.repairStandardFileDescriptors(
                isDescriptorValid: { validDescriptors.contains($0) },
                createStandardInputPipe: {
                    validDescriptors.insert(STDIN_FILENO)
                    validDescriptors.insert(4)
                    return (STDIN_FILENO, 4)
                },
                duplicateDescriptor: { source, target in
                    duplicateCalls.append((source, target))
                    validDescriptors.insert(target)
                    return target
                },
                closeDescriptor: { descriptor in
                    closeCalls.append(descriptor)
                    validDescriptors.remove(descriptor)
                    return 0
                })

            XCTAssertEqual(duplicateCalls.count, 1)
            XCTAssertEqual(duplicateCalls.first?.source, STDIN_FILENO)
            XCTAssertEqual(duplicateCalls.first?.target, STDIN_FILENO)
            XCTAssertTrue(closeCalls.isEmpty)
            XCTAssertTrue(validDescriptors.contains(STDIN_FILENO))
            XCTAssertTrue(validDescriptors.contains(STDOUT_FILENO))
            XCTAssertTrue(validDescriptors.contains(STDERR_FILENO))
            XCTAssertEqual(repair.retainedStandardInputWriteDescriptor, 4)
            XCTAssertTrue(validDescriptors.contains(4))
        }

        func testRepairStandardFileDescriptorsReplacesValidStandardInputWithKeepAlivePipe() throws {
            var validDescriptors: Set<Int32> = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]
            var duplicateCalls: [(source: Int32, target: Int32)] = []
            var closeCalls: [Int32] = []
            var openNullCallCount = 0

            let repair = try GhosttyMobileAppService.repairStandardFileDescriptors(
                isDescriptorValid: { validDescriptors.contains($0) },
                createStandardInputPipe: {
                    validDescriptors.insert(5)
                    validDescriptors.insert(6)
                    return (5, 6)
                },
                openReadWriteNull: {
                    openNullCallCount += 1
                    return -1
                },
                duplicateDescriptor: { source, target in
                    duplicateCalls.append((source, target))
                    validDescriptors.insert(target)
                    return target
                },
                closeDescriptor: { descriptor in
                    closeCalls.append(descriptor)
                    validDescriptors.remove(descriptor)
                    return 0
                })

            XCTAssertEqual(duplicateCalls.map(\.source), [5])
            XCTAssertEqual(duplicateCalls.map(\.target), [STDIN_FILENO])
            XCTAssertEqual(closeCalls, [5])
            XCTAssertEqual(openNullCallCount, 0)
            XCTAssertEqual(repair.retainedStandardInputWriteDescriptor, 6)
            XCTAssertTrue(validDescriptors.contains(STDIN_FILENO))
            XCTAssertTrue(validDescriptors.contains(6))
        }

        func testRemoteTerminalHostViewDoesNotCreateMirrorBeforeRenderState() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: nil, renderStateKey: "viewer|runtime=0x0|snapshot=0x0|interactive=0", fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertFalse(hostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(hostView.subviews.contains { $0 is UILabel })

            window.isHidden = true
        }

        func testRemoteTerminalHostViewDisablesSmartTextFeatures() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)

            XCTAssertEqual(hostView.autocapitalizationType, .none)
            XCTAssertEqual(hostView.autocorrectionType, .no)
            XCTAssertEqual(hostView.spellCheckingType, .no)
            XCTAssertEqual(hostView.smartQuotesType, .no)
            XCTAssertEqual(hostView.smartDashesType, .no)
            XCTAssertEqual(hostView.smartInsertDeleteType, .no)
            XCTAssertEqual(hostView.keyboardType, .asciiCapable)
        }

        func testRemoteTerminalHostViewTapOnLinkConsumesTapBeforeFocus() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            hostView.setAcceptsTerminalInput(true)
            hostView.debugTapLinkHandlerForTesting = { point in
                XCTAssertEqual(point, CGPoint(x: 12, y: 18))
                return true
            }

            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .openedLink)

            hostView.setAcceptsTerminalInput(false)
            hostView.debugTapLinkHandlerForTesting = { point in
                XCTAssertEqual(point, CGPoint(x: 12, y: 18))
                return true
            }
            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .openedLink)

            hostView.debugTapLinkHandlerForTesting = { _ in false }
            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .ignored)

            hostView.setAcceptsTerminalInput(true)
            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .focused)
        }

        func testRemoteTerminalHostViewDispatchesOpenURLAction() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var openedLinks: [String] = []
            hostView.onOpenLink = { openedLinks.append($0) }

            hostView.debugApplyActionEventForTesting(.openURL(kind: .unknown, value: "https://example.com/image.png"))
            hostView.debugApplyActionEventForTesting(.mouseOverLink("https://example.com/image.png"))

            XCTAssertEqual(openedLinks, ["https://example.com/image.png"])
        }

        func testRemoteTerminalHostViewIgnoresHoveredLinkDuringTapProbe() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var openedLinks: [String] = []
            hostView.onOpenLink = { openedLinks.append($0) }

            XCTAssertFalse(hostView.debugApplyActionEventsDuringTapProbeForTesting([.mouseOverLink(" image.png ")]))

            XCTAssertEqual(openedLinks, [])
        }

        func testRemoteTerminalHostViewOpensFullURLAfterTruncatedHoverDuringTapProbe() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            let fullPath = "/Users/yogesh/Downloads/Screen Recording 2026-03-20 at 11.17.57 AM.mov"
            var openedLinks: [String] = []
            hostView.onOpenLink = { openedLinks.append($0) }

            XCTAssertTrue(
                hostView.debugApplyActionEventsDuringTapProbeForTesting([
                    .mouseOverLink("/Users/yogesh/Downloads/Screen"), .openURL(kind: .unknown, value: fullPath),
                ]))

            XCTAssertEqual(openedLinks, [fullPath])
        }

        func testRemoteTerminalHostViewSuppressesSystemKeyboardAssistant() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)

            XCTAssertTrue(hostView.inputAssistantIsSuppressedForTesting)
        }

        func testRemoteTerminalAccessoryToolbarKeepsTrailingControlsPinned() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            XCTAssertNil(hostView.inputAccessoryView)

            hostView.setAcceptsTerminalInput(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            XCTAssertEqual(accessoryView.intrinsicContentSize.height, 46)
            XCTAssertEqual(accessoryView.frame.height, 46)
            XCTAssertEqual(accessoryView.sizeThatFits(CGSize(width: 320, height: 0)).height, 46)
            XCTAssertTrue(accessoryView.autoresizingMask.contains(.flexibleHeight))

            let scrollView = try XCTUnwrap(descendants(of: accessoryView, matching: UIScrollView.self).first)
            let buttons = descendants(of: accessoryView, matching: UIButton.self)
            let scrollableButtons = buttons.filter { $0.isDescendant(of: scrollView) }
            let pinnedButtons = buttons.filter { !$0.isDescendant(of: scrollView) }
            XCTAssertEqual(
                scrollableButtons.compactMap(\.accessibilityLabel), ["tab", "/", "~", "|", "-", "_", "esc", "Shift", "Control", "Command", "Option"])
            XCTAssertEqual(pinnedButtons.compactMap(\.accessibilityLabel), ["Compose message", "Arrow key joystick", "Hide keyboard"])
            let joystickButton = try XCTUnwrap(pinnedButtons.first { $0.accessibilityLabel == "Arrow key joystick" })
            XCTAssertEqual(joystickButton.accessibilityCustomActions?.map(\.name) ?? [], ["Up arrow", "Down arrow", "Left arrow", "Right arrow"])

            let phoneFrames = hostView.accessoryToolbarLayoutFramesForTesting(width: 320, userInterfaceIdiom: .phone)
            XCTAssertGreaterThan(phoneFrames.scrollView.width, 0)
            XCTAssertGreaterThan(phoneFrames.scrollContentSize.width, phoneFrames.scrollView.width)
            XCTAssertGreaterThanOrEqual(phoneFrames.joystickButton.minX, phoneFrames.scrollView.maxX + 4.5)
            XCTAssertGreaterThanOrEqual(phoneFrames.keyboardButton.minX, phoneFrames.joystickButton.maxX + 4.5)
            XCTAssertLessThanOrEqual(phoneFrames.keyboardButton.maxX, 314.5)
            XCTAssertEqual(phoneFrames.joystickButton.width, 40, accuracy: 0.5)
            XCTAssertEqual(phoneFrames.keyboardButton.width, 40, accuracy: 0.5)
            let phoneWidths = hostView.accessoryToolbarButtonWidthsForTesting(width: 320, userInterfaceIdiom: .phone)
            for width in phoneWidths.scrollable { XCTAssertEqual(width, 44, accuracy: 0.5) }
            for width in phoneWidths.pinned { XCTAssertEqual(width, 40, accuracy: 0.5) }

            let padFrames = hostView.accessoryToolbarLayoutFramesForTesting(width: 320, userInterfaceIdiom: .pad)
            XCTAssertGreaterThan(padFrames.scrollContentSize.width, padFrames.scrollView.width)
            XCTAssertGreaterThanOrEqual(padFrames.joystickButton.minX, padFrames.scrollView.maxX + 5.5)
            XCTAssertGreaterThanOrEqual(padFrames.keyboardButton.minX, padFrames.joystickButton.maxX + 5.5)
            XCTAssertLessThanOrEqual(padFrames.keyboardButton.maxX, 310.5)
            XCTAssertEqual(padFrames.joystickButton.width, 48, accuracy: 0.5)
            XCTAssertEqual(padFrames.keyboardButton.width, 48, accuracy: 0.5)
            let padWidths = hostView.accessoryToolbarButtonWidthsForTesting(width: 320, userInterfaceIdiom: .pad)
            for width in padWidths.scrollable { XCTAssertEqual(width, 58, accuracy: 0.5) }
            for width in padWidths.pinned { XCTAssertEqual(width, 48, accuracy: 0.5) }

            hostView.setSoftwareKeyboardVisible(false)
            XCTAssertEqual(
                hostView.accessoryToolbarButtonAccessibilityLabelsForTesting.pinned, ["Compose message", "Arrow key joystick", "Show keyboard"])

            hostView.setAcceptsTerminalInput(false)
            XCTAssertNil(hostView.inputAccessoryView)
        }

        func testRemoteTerminalJoystickSwipeDirectionIgnoresStartLocation() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.setAcceptsTerminalInput(true)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)

            // Start near the right edge, then slide left: the swipe direction wins and only
            // "left" fires. The starting location never dispatches a key on its own.
            hostView.accessoryToolbarBeginJoystickTrackingForTesting(
                at: CGPoint(x: 44, y: 18), bounds: bounds, initialDelay: .seconds(10), interval: .seconds(10))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 10, y: 18))
            hostView.accessoryToolbarEndJoystickTrackingForTesting()

            XCTAssertEqual(sentKeys, ["left"])
        }

        func testRemoteTerminalJoystickStationaryTapSendsNothing() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.setAcceptsTerminalInput(true)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)

            // A press and release without sliding past the activation distance stays neutral.
            hostView.accessoryToolbarBeginJoystickTrackingForTesting(
                at: CGPoint(x: 30, y: 18), bounds: bounds, initialDelay: .milliseconds(50), interval: .milliseconds(10))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 34, y: 18))
            hostView.accessoryToolbarEndJoystickTrackingForTesting()

            XCTAssertEqual(sentKeys, [])
        }

        func testRemoteTerminalJoystickHoldRepeatsSwipedDirection() async throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.setAcceptsTerminalInput(true)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)

            hostView.accessoryToolbarBeginJoystickTrackingForTesting(
                at: CGPoint(x: 23, y: 18), bounds: bounds, initialDelay: .milliseconds(5), interval: .milliseconds(5))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 0, y: 18))

            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while sentKeys.count < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            hostView.accessoryToolbarEndJoystickTrackingForTesting()
            let countAtRelease = sentKeys.count

            XCTAssertGreaterThanOrEqual(countAtRelease, 4, "holding a swipe should emit the first key plus repeats")
            XCTAssertTrue(sentKeys.allSatisfy { $0 == "left" })

            // Releasing stops further repeats.
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(sentKeys.count, countAtRelease)
        }

        func testRemoteTerminalJoystickChangingSwipeSwitchesDirection() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.setAcceptsTerminalInput(true)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)

            // Long delays keep repeats from firing, isolating the per-direction key.
            hostView.accessoryToolbarBeginJoystickTrackingForTesting(
                at: CGPoint(x: 23, y: 18), bounds: bounds, initialDelay: .seconds(10), interval: .seconds(10))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 46, y: 18))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 0, y: 18))
            hostView.accessoryToolbarEndJoystickTrackingForTesting()

            XCTAssertEqual(sentKeys, ["right", "left"])
        }

        func testRemoteTerminalAccessoryModifiersApplyToInput() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            var sentText: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.onSendText = { text, _ in sentText.append(text) }
            hostView.setAcceptsTerminalInput(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let buttons = descendants(of: accessoryView, matching: UIButton.self)
            func tapButton(_ accessibilityLabel: String) throws {
                let button = try XCTUnwrap(buttons.first { $0.accessibilityLabel == accessibilityLabel })
                button.sendActions(for: .touchUpInside)
            }

            try tapButton("Control")
            hostView.insertText("c")

            try tapButton("Command")
            let joystickButton = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Arrow key joystick" })
            let leftArrowAction = try XCTUnwrap(joystickButton.accessibilityCustomActions?.first { $0.name == "Left arrow" })
            XCTAssertTrue(leftArrowAction.actionHandler?(leftArrowAction) ?? false)

            try tapButton("Command")
            hostView.deleteBackward()

            try tapButton("Option")
            hostView.deleteBackward()

            try tapButton("Command")
            hostView.insertText("k")

            XCTAssertEqual(sentKeys, ["ctrl+c", "cmd+left", "cmd+backspace", "opt+backspace", "cmd+k"])
            XCTAssertEqual(sentText, [])
        }

        /// Return arrives as plain text with no modifier flags, so the accessory's Shift is the only way
        /// to reach Shift+Enter on a device with no hardware keyboard. An unmodified Return must still be
        /// a plain Enter.
        func testRemoteTerminalAccessoryShiftAppliesToReturn() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            var sentText: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.onSendText = { text, _ in sentText.append(text) }
            hostView.setAcceptsTerminalInput(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let buttons = descendants(of: accessoryView, matching: UIButton.self)
            let shiftButton = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Shift" })

            shiftButton.sendActions(for: .touchUpInside)
            hostView.insertText("\n")
            // The modifier is consumed by that one press, so the next Return is unmodified again.
            hostView.insertText("\n")

            XCTAssertEqual(sentKeys, ["shift+enter", "enter"])
            XCTAssertEqual(sentText, [])
        }

        func testRemoteTerminalPasteMarksTextAsPaste() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentText: [(String, Bool)] = []
            hostView.onSendText = { text, asPaste in sentText.append((text, asPaste)) }
            hostView.setAcceptsTerminalInput(true)

            hostView.pasteTextForTesting("line one\nline two")

            XCTAssertEqual(sentText.count, 1)
            XCTAssertEqual(sentText.first?.0, "line one\nline two")
            XCTAssertEqual(sentText.first?.1, true)
        }

        func testRemoteTerminalAccessoryJoystickRequiresDirectionalRelease() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)
            func direction(dx: CGFloat, dy: CGFloat) -> String? {
                hostView.accessoryToolbarJoystickDirectionForTesting(translationX: dx, translationY: dy)
            }
            func acceptsRelease(x: CGFloat, y: CGFloat) -> Bool {
                hostView.accessoryToolbarJoystickAcceptsReleaseForTesting(point: CGPoint(x: x, y: y), bounds: bounds)
            }
            func acceptsActivation(x: CGFloat, y: CGFloat) -> Bool {
                hostView.accessoryToolbarJoystickAcceptsActivationForTesting(point: CGPoint(x: x, y: y), bounds: bounds)
            }

            // Direction comes from how far the finger slid since touch-down, not absolute position.
            XCTAssertNil(direction(dx: 0, dy: 0))
            XCTAssertNil(direction(dx: 16, dy: 0))
            XCTAssertEqual(direction(dx: 17, dy: 0), "right")
            XCTAssertEqual(direction(dx: -17, dy: 0), "left")
            XCTAssertEqual(direction(dx: 0, dy: -17), "up")
            XCTAssertEqual(direction(dx: 0, dy: 17), "down")
            XCTAssertTrue(acceptsActivation(x: bounds.minX - 7, y: bounds.midY))
            XCTAssertFalse(acceptsActivation(x: bounds.minX - 9, y: bounds.midY))
            XCTAssertTrue(acceptsActivation(x: bounds.midX, y: bounds.minY - 11))
            XCTAssertFalse(acceptsActivation(x: bounds.midX, y: bounds.minY - 13))
            XCTAssertTrue(acceptsRelease(x: bounds.maxX + 99, y: bounds.midY))
            XCTAssertFalse(acceptsRelease(x: bounds.maxX + 101, y: bounds.midY))
        }

        func testRemoteTerminalHostViewRendersSnapshot() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertGreaterThanOrEqual(renderedSnapshot.columns, 4)
            XCTAssertGreaterThanOrEqual(renderedSnapshot.rows, 2)
            XCTAssertEqual(renderedSnapshot.cells.first?.codepoint, UInt32(Character("h").unicodeScalars.first?.value ?? 0))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewKeepsPhoneSurfaceColumnsVisible() throws {
            let phoneBounds = CGRect(x: 0, y: 0, width: 393, height: 700)
            let window = UIWindow(frame: phoneBounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: phoneBounds)
            hostView.userInterfaceIdiomOverrideForTesting = .phone
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()
            hostView.setSurfaceViewportSizeForTesting(columns: 80, rows: 24)

            let wideText = String(repeating: ".", count: 42) + "WIDE"
            hostView.update(
                snapshot: snapshot(columns: 80, rows: 24, text: wideText), renderStateKey: "viewer|runtime=80x24|snapshot=80x24|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.5))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertEqual(renderedSnapshot.columns, 80)
            XCTAssertTrue(renderedText.localizedStandardContains("WIDE"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewUsesKeyboardVisibleViewportForRenderedSnapshot() throws {
            let phoneBounds = CGRect(x: 0, y: 0, width: 393, height: 640)
            let window = UIWindow(frame: phoneBounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: phoneBounds)
            hostView.userInterfaceIdiomOverrideForTesting = .phone
            var reportedViewports: [(columns: Int, rows: Int)] = []
            hostView.onViewportSizeChanged = { columns, rows in reportedViewports.append((columns: columns, rows: rows)) }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let fullViewport = hostView.viewportSizeForTesting()
            let keyboardHeight: CGFloat = 260
            hostView.setKeyboardOccludedHeightForTesting(keyboardHeight)
            let keyboardOnlyViewport = hostView.viewportSizeForTesting()

            XCTAssertGreaterThan(fullViewport.rows, keyboardOnlyViewport.rows)
            XCTAssertEqual(hostView.visibleRenderBoundsForTesting().height, 380, accuracy: 0.5)

            hostView.setAcceptsTerminalInput(true)
            hostView.setKeyboardOccludedHeightForTesting(keyboardHeight)
            viewController.view.layoutIfNeeded()
            let keyboardViewport = hostView.viewportSizeForTesting()

            XCTAssertLessThan(keyboardViewport.rows, keyboardOnlyViewport.rows)
            XCTAssertEqual(hostView.visibleRenderBoundsForTesting().height, 334, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(reportedViewports.last).rows, keyboardViewport.rows)

            let longSnapshot = promptAtBottomSnapshot(columns: 80, rows: fullViewport.rows + 20)
            hostView.update(
                snapshot: longSnapshot, renderStateKey: "viewer|runtime=80x\(longSnapshot.rows)|snapshot=80x\(longSnapshot.rows)|interactive=0",
                fallbackText: "Waiting for terminal state...")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertEqual(renderedSnapshot.rows, keyboardViewport.rows)
            XCTAssertTrue(renderedText.localizedStandardContains("shell %"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("SEQ 000000"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewUsesSurfaceRowsForKeyboardHiddenPrompt() throws {
            let phoneBounds = CGRect(x: 0, y: 0, width: 393, height: 700)
            let window = UIWindow(frame: phoneBounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: phoneBounds)
            hostView.userInterfaceIdiomOverrideForTesting = .phone
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.setAcceptsTerminalInput(true)
            XCTAssertTrue(hostView.becomeFirstResponder())
            hostView.setSoftwareKeyboardVisible(false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            XCTAssertEqual(hostView.visibleRenderBoundsForTesting().height, phoneBounds.height - 46, accuracy: 0.5)
            let fallbackViewport = hostView.viewportSizeForTesting()
            let surfaceRows = max(fallbackViewport.rows - 12, 1)
            hostView.setSurfaceViewportSizeForTesting(columns: 80, rows: surfaceRows)

            let surfaceViewport = hostView.viewportSizeForTesting()
            XCTAssertEqual(surfaceViewport.columns, 80)
            XCTAssertEqual(surfaceViewport.rows, surfaceRows)

            let longSnapshot = promptAtBottomSnapshot(columns: 80, rows: surfaceRows + 20)
            hostView.update(
                snapshot: longSnapshot,
                renderStateKey: "viewer|runtime=80x\(longSnapshot.rows)|snapshot=80x\(longSnapshot.rows)|interactive=0|keyboard=hidden",
                fallbackText: "Waiting for terminal state...")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertEqual(renderedSnapshot.rows, surfaceRows)
            XCTAssertTrue(renderedText.localizedStandardContains("shell %"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("SEQ 000000"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewRendersBootstrapSnapshotOnFreshSession() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertTrue(GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot).localizedStandardContains("hi"))
            XCTAssertFalse(GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot).localizedStandardContains("WRONG"))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewTearsDownSessionWhenRemovedFromWindow() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertTrue(hostView.hasActiveSessionForTesting)
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)

            hostView.removeFromSuperview()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertFalse(hostView.hasActiveSessionForTesting)
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)
            XCTAssertNil(hostView.capturedSnapshotForTesting())

            viewController.view.addSubview(hostView)
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()
            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=2",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertTrue(hostView.hasActiveSessionForTesting)
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)
            XCTAssertNotNil(hostView.capturedSnapshotForTesting())

            window.isHidden = true
        }

        func testRemoteTerminalHostViewTeardownDoesNotBlockWhileFreeRuns() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=teardown",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertTrue(hostView.hasActiveSessionForTesting)

            let freeCompleted = expectation(description: "background free completed")
            let originalSessionFreeHandler = GhosttyRemoteTerminalHostView.sessionFreeHandlerForTesting
            // Gate the free handler on a semaphore so the "dismantle didn't block on it" assertion below is
            // checked while the handler is still provably in flight, instead of picking a duration long enough
            // that it's probably still running. Always released via defer so a failed assertion above can't
            // leave the handler's background thread blocked forever.
            let releaseFree = DispatchSemaphore(value: 0)
            defer { releaseFree.signal() }
            GhosttyRemoteTerminalHostView.sessionFreeHandlerForTesting = { _ in
                // Bounded wait: if prepareForDismantle() ever regresses to running this handler
                // synchronously, the test thread would otherwise block on its own gate forever;
                // the timeout turns that regression into a failed elapsed-time assertion instead.
                _ = releaseFree.wait(timeout: .now() + 30)
                freeCompleted.fulfill()
            }
            defer { GhosttyRemoteTerminalHostView.sessionFreeHandlerForTesting = originalSessionFreeHandler }

            let startedAt = Date()
            hostView.prepareForDismantle()
            let elapsed = Date().timeIntervalSince(startedAt)

            XCTAssertLessThan(elapsed, 0.2)
            XCTAssertFalse(hostView.hasActiveSessionForTesting)
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)

            releaseFree.signal()
            wait(for: [freeCompleted], timeout: 30)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewTeardownParksTheSharedMirrorWithoutBlocking() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "native-teardown")

            let startedAt = Date()
            hostView.prepareForDismantle()
            let elapsed = Date().timeIntervalSince(startedAt)

            XCTAssertLessThan(elapsed, 0.2)
            XCTAssertFalse(hostView.hasActiveSessionForTesting)
            XCTAssertFalse(hostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)
            // The mirror survives the teardown parked and unattached rather than being leaked into a
            // per-teardown pile or freed on a user-facing path.
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)
            XCTAssertFalse(GhosttySharedTerminalMirror.shared.isSurfaceHostAttachedForTesting)
        }

        /// Opening a terminal and leaving it, over and over, is the navigation that used to charge the
        /// process a whole new mirror and IOSurface per visit. Every visit must land on the same
        /// native surface instead, so the footprint is bounded no matter how many sessions are opened.
        func testRepeatedTerminalVisitsReuseOneMirrorAndOneSurface() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            var surfaceIdentities: [UInt] = []
            for visit in 0..<4 {
                let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "revisit-\(visit)")
                surfaceIdentities.append(try XCTUnwrap(GhosttySharedTerminalMirror.shared.mirrorSurfaceIdentityForTesting))
                hostView.removeFromSuperview()

                XCTAssertFalse(hostView.hasMirrorSurfaceForTesting)
                XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)
            }

            XCTAssertEqual(Set(surfaceIdentities).count, 1)
        }

        /// A terminal view can mount while the outgoing one is still in the hierarchy — a session
        /// swap on the same route does exactly this. The newcomer takes the mirror over, so the two
        /// never render into the same surface, and only one mirror exists across the handover.
        func testMirrorMovesToTheTerminalViewThatMountsWhileAnotherHoldsIt() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let firstHostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "handover-first")
            let secondHostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "handover-second")

            XCTAssertTrue(secondHostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(firstHostView.hasMirrorSurfaceForTesting)
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)

            // The surrendering view keeps its place in the hierarchy without clawing the mirror back,
            // so an outgoing view cannot trade it with the incoming one for the whole transition.
            firstHostView.setNeedsLayout()
            firstHostView.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertTrue(secondHostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(firstHostView.hasMirrorSurfaceForTesting)

            firstHostView.removeFromSuperview()
            secondHostView.removeFromSuperview()
        }

        /// Two sessions in succession share one surface, so the surface must stay hidden from the
        /// moment it is handed over until the new holder has drawn its own session onto it.
        func testRebindHidesTheSharedSurfaceUntilTheNewHolderRendersIt() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let firstHostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            let secondHostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            viewController.view.addSubview(firstHostView)
            viewController.view.addSubview(secondHostView)
            viewController.view.layoutIfNeeded()
            defer {
                firstHostView.removeFromSuperview()
                secondHostView.removeFromSuperview()
            }

            let mirror = GhosttySharedTerminalMirror.shared
            _ = try mirror.acquire(for: firstHostView, fontSize: .default, scaleFactor: 2)
            XCTAssertFalse(mirror.isSurfaceHostVisibleForTesting)

            mirror.revealSurface(from: firstHostView)
            XCTAssertTrue(mirror.isSurfaceHostVisibleForTesting)

            _ = try mirror.acquire(for: secondHostView, fontSize: .default, scaleFactor: 2)
            XCTAssertFalse(mirror.isSurfaceHostVisibleForTesting)
            XCTAssertTrue(mirror.isSurfaceHostAttachedForTesting)
            // The surface spans the whole holder, which is what the renderer sizes its target from.
            XCTAssertEqual(secondHostView.surfaceHostFrameForTesting(), secondHostView.bounds)

            // A late release from the view that already lost the mirror must not disturb the holder.
            mirror.release(from: firstHostView)
            XCTAssertTrue(mirror.isSurfaceHostAttachedForTesting)

            mirror.release(from: secondHostView)
            XCTAssertFalse(mirror.isSurfaceHostAttachedForTesting)
            XCTAssertFalse(mirror.isSurfaceHostVisibleForTesting)
        }

        /// Changing the font size retunes the live surface rather than building a second mirror, and
        /// the daemon still sees the resize as a new grid.
        func testChangingFontSizeRetunesTheSharedMirrorWithoutBuildingAnother() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            var reportedColumns: [Int] = []
            let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "font-size") { hostView in
                hostView.onViewportSizeChanged = { columns, _ in reportedColumns.append(columns) }
            }
            defer { hostView.removeFromSuperview() }

            let surfaceIdentity = try XCTUnwrap(GhosttySharedTerminalMirror.shared.mirrorSurfaceIdentityForTesting)
            let columnsAtDefaultSize = try XCTUnwrap(reportedColumns.last)

            hostView.setTerminalFontSize(.nine)

            XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.appliedFontSizeForTesting, .nine)
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.mirrorSurfaceIdentityForTesting, surfaceIdentity)
            XCTAssertGreaterThan(try XCTUnwrap(reportedColumns.last), columnsAtDefaultSize)
        }

        /// Mounts a terminal host view with a live native mirror and waits until it holds one.
        private func mountNativeMirrorHostView(
            in viewController: UIViewController, window: UIWindow, screenKey: String, configure: (GhosttyRemoteTerminalHostView) -> Void = { _ in }
        ) throws -> GhosttyRemoteTerminalHostView {
            viewController.view.frame = window.bounds
            let hostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            configure(hostView)
            viewController.view.addSubview(hostView)
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=\(screenKey)",
                fallbackText: "Waiting for terminal state...")

            let deadline = Date().addingTimeInterval(2)
            while !hostView.hasMirrorSurfaceForTesting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertTrue(hostView.hasMirrorSurfaceForTesting)
            return hostView
        }

        func testRemoteTerminalHostViewDoesNotRepublishInputReadinessWhenInstallingCallback() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.setAcceptsTerminalInput(true)
            XCTAssertTrue(hostView.becomeFirstResponder())
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            let unexpectedInitialPublication = expectation(description: "input readiness should not publish on callback install")
            unexpectedInitialPublication.isInverted = true
            hostView.onInputReadinessChanged = { _ in unexpectedInitialPublication.fulfill() }
            wait(for: [unexpectedInitialPublication], timeout: 0.2)

            let unexpectedResponderPublication = expectation(description: "input readiness should not track responder status")
            unexpectedResponderPublication.isInverted = true
            var reportedReadiness: [Bool] = []
            hostView.onInputReadinessChanged = { ready in
                reportedReadiness.append(ready)
                unexpectedResponderPublication.fulfill()
            }

            XCTAssertTrue(hostView.resignFirstResponder())
            wait(for: [unexpectedResponderPublication], timeout: 0.2)
            XCTAssertTrue(reportedReadiness.isEmpty)

            let readinessChanged = expectation(description: "input readiness changed after input was disabled")
            hostView.onInputReadinessChanged = { ready in
                reportedReadiness.append(ready)
                if ready == false { readinessChanged.fulfill() }
            }

            hostView.setAcceptsTerminalInput(false)
            wait(for: [readinessChanged], timeout: 2)
            XCTAssertEqual(reportedReadiness.last, false)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewCanRecreateSessionsAcrossMultipleMountCycles() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            viewController.view.frame = window.bounds

            for cycle in 1...3 {
                let hostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
                viewController.view.addSubview(hostView)
                hostView.frame = viewController.view.bounds
                viewController.view.layoutIfNeeded()

                hostView.update(
                    snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=\(cycle)",
                    fallbackText: "Waiting for terminal state…")

                RunLoop.main.run(until: Date().addingTimeInterval(0.25))

                XCTAssertTrue(hostView.hasActiveSessionForTesting)
                XCTAssertNotNil(hostView.capturedSnapshotForTesting())

                hostView.removeFromSuperview()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))

                XCTAssertFalse(hostView.hasActiveSessionForTesting)
            }

            window.isHidden = true
        }

        func testRemoteTerminalHostViewPublishesRenderedTextUpdates() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let renderedExpectation = expectation(description: "rendered text published")
            var renderedText = ""
            hostView.onRenderedTextChanged = { text in
                renderedText = text
                if text.localizedStandardContains("hi") { renderedExpectation.fulfill() }
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            wait(for: [renderedExpectation], timeout: 2)
            XCTAssertTrue(renderedText.localizedStandardContains("hi"))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewPublishesRenderedTextAfterFreshOwnerSnapshot() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let renderedExpectation = expectation(description: "fresh owner snapshot published")
            var renderedText = ""
            hostView.onRenderedTextChanged = { text in
                renderedText = text
                if text.localizedStandardContains("shell % !") { renderedExpectation.fulfill() }
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let bootstrapSnapshot = snapshot(columns: 12, rows: 2, text: "shell % ")
            let refreshedSnapshot = snapshot(columns: 12, rows: 2, text: "shell % !")
            let ownerEpochID = "owner|test"
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: ownerEpochID, bootstrapSnapshot: bootstrapSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state...")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: ownerEpochID, bootstrapSnapshot: refreshedSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state...")

            wait(for: [renderedExpectation], timeout: 2)
            XCTAssertTrue(renderedText.localizedStandardContains("shell % !"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewPublishesRepeatedTokenOutputWhenSnapshotCarriesIt() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let bootstrapSnapshot = snapshot(columns: 16, rows: 4, text: "shell % first\nsecond")
            let ownerEpochID = "owner|repeated-output-token"
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: ownerEpochID, bootstrapSnapshot: bootstrapSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state...")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertTrue(renderedText.localizedStandardContains("first"), renderedText)
            XCTAssertTrue(renderedText.localizedStandardContains("second"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewClearsAutosuggestionOverwriteFromRenderedText() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let renderedExpectation = expectation(description: "autosuggestion-cleared output published")
            var renderedText = ""
            hostView.onRenderedTextChanged = { text in
                renderedText = text
                if text.localizedStandardContains("t not found") { renderedExpectation.fulfill() }
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let ownerEpochID = "owner|autosuggestion-clear"
            let bootstrapSnapshot = snapshot(columns: 80, rows: 8, text: "shell % which t\nt not found\nshell % ")
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: ownerEpochID, bootstrapSnapshot: bootstrapSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state...")

            wait(for: [renderedExpectation], timeout: 2)
            XCTAssertTrue(renderedText.localizedStandardContains("t not found"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("ailscale"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewAppliesInitialOwnerPendingOutputOverBootstrapSnapshot() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let renderedExpectation = expectation(description: "initial owner output repaired bootstrap snapshot")
            var renderedText = ""
            hostView.onRenderedTextChanged = { text in
                renderedText = text
                if text.localizedStandardContains("python not found") { renderedExpectation.fulfill() }
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let repairedSnapshot = snapshot(columns: 80, rows: 8, text: "shell % which python\npython not found\nshell % ")

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session", id: "owner|initial-output-repair", bootstrapSnapshot: repairedSnapshot), endedRender: nil,
                fallbackText: "Waiting for terminal state...")

            wait(for: [renderedExpectation], timeout: 2)
            XCTAssertTrue(renderedText.localizedStandardContains("which python"), renderedText)
            XCTAssertTrue(renderedText.localizedStandardContains("python not found"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("check_for_update_on_startup"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("resu"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewRepublishesRenderedTextAfterVisibilityToggle() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let initialRenderedExpectation = expectation(description: "initial rendered text published")
            let republishedRenderedExpectation = expectation(description: "rendered text republished after visibility toggle")
            republishedRenderedExpectation.expectedFulfillmentCount = 1

            var renderedEvents: [String] = []
            hostView.onRenderedTextChanged = { text in
                guard text.localizedStandardContains("hi") else { return }
                renderedEvents.append(text)
                if renderedEvents.count == 1 {
                    initialRenderedExpectation.fulfill()
                } else if renderedEvents.count == 2 {
                    republishedRenderedExpectation.fulfill()
                }
            }

            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.setTerminalVisible(false)
            hostView.update(snapshot: nil, renderStateKey: "status", fallbackText: "Current owner: Mac")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.setTerminalVisible(true)
            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            wait(for: [republishedRenderedExpectation], timeout: 2)
            XCTAssertEqual(renderedEvents.count, 2)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewRepublishesRenderedTextAfterObserverIsReattached() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let initialRenderedExpectation = expectation(description: "initial rendered text published")
            let republishedRenderedExpectation = expectation(description: "rendered text republished after observer is reattached")

            hostView.onRenderedTextChanged = { text in if text.localizedStandardContains("hi") { initialRenderedExpectation.fulfill() } }

            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.onRenderedTextChanged = nil
            hostView.update(
                snapshot: sampleSnapshotWithExclamation(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.onRenderedTextChanged = { text in if text.localizedStandardContains("hi!") { republishedRenderedExpectation.fulfill() } }
            hostView.update(
                snapshot: sampleSnapshotWithExclamation(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            wait(for: [republishedRenderedExpectation], timeout: 2)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewClearsRenderedTextWhenSurfaceIsHidden() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let initialRenderedExpectation = expectation(description: "initial rendered text published")
            let clearedRenderedExpectation = expectation(description: "rendered text cleared after hiding the surface")

            var renderedEvents: [String] = []
            hostView.onRenderedTextChanged = { text in
                renderedEvents.append(text)
                if text.localizedStandardContains("hi") {
                    initialRenderedExpectation.fulfill()
                } else if text.isEmpty {
                    clearedRenderedExpectation.fulfill()
                }
            }

            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.setTerminalVisible(false)
            hostView.update(snapshot: nil, renderStateKey: "status", fallbackText: "Current owner: Mac")

            wait(for: [clearedRenderedExpectation], timeout: 2)
            XCTAssertEqual(renderedEvents.last, "")

            window.isHidden = true
        }

        func testRemoteTerminalHostViewEncodesPreciseScrollMods() {
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .changed)), Int32(0b0000_0111))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .ended)), Int32(0b0000_1001))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .cancelled)), Int32(0b0000_1011))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .possible)), Int32(0b0000_1101))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: false, momentumState: .ended)), Int32(0b0000_1000))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: false, momentumState: .possible)), Int32(0b0000_1100))
        }

        func testRemoteTerminalHostViewForwardsPreciseScrollMods() {
            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            var sentScrolls: [(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)] = []
            hostView.onSendScroll = { horizontal, vertical, scrollMods, pointerPosition in
                sentScrolls.append((horizontal, vertical, scrollMods, pointerPosition))
            }

            XCTAssertTrue(
                hostView.debugSendScrollForTesting(
                    horizontal: 0, vertical: 8, location: CGPoint(x: 160, y: 120), hasPreciseDeltas: true, momentumState: .changed))

            XCTAssertEqual(sentScrolls.last?.horizontal, 0)
            XCTAssertEqual(sentScrolls.last?.vertical, 8)
            XCTAssertEqual(sentScrolls.last?.scrollMods, Int32(0b0000_0111))
            XCTAssertEqual(sentScrolls.last?.pointerPosition, .init(x: 0.25, y: 0.25))
        }

        func testRemoteTerminalHostViewTinyScrollDeltaDoesNotForceRowJump() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)

            XCTAssertTrue(hostView.debugSendScrollForTesting(horizontal: 0, vertical: 1))

            let tinyScrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: tinyScrolledSnapshot), bottomText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewTinyScrollDeltasForwardWithoutLocalViewportMutation() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            var sentScrollCount = 0
            hostView.onSendScroll = { _, _, _, _ in sentScrollCount += 1 }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)

            for _ in 0..<20 { XCTAssertTrue(hostView.debugSendScrollForTesting(horizontal: 0, vertical: 1)) }

            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertEqual(scrolledText, bottomText)
            XCTAssertEqual(sentScrollCount, 20)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewForwardsScrollbackWithoutLocalViewportMutation() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            var sentScrolls: [(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)] = []
            hostView.onSendScroll = { horizontal, vertical, scrollMods, pointerPosition in
                sentScrolls.append((horizontal, vertical, scrollMods, pointerPosition))
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)
            XCTAssertTrue(bottomText.localizedStandardContains("SEQ 000219"), bottomText)

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0, vertical: 10_000, location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY))
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertEqual(scrolledText, bottomText)
            XCTAssertEqual(sentScrolls.last?.horizontal, 0)
            XCTAssertEqual(sentScrolls.last?.vertical, 10_000)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewDoesNotLocallyScrollAfterResizeChurn() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            var sentScrolls: [(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)] = []
            hostView.onSendScroll = { horizontal, vertical, scrollMods, pointerPosition in
                sentScrolls.append((horizontal, vertical, scrollMods, pointerPosition))
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=6x4|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            hostView.frame = CGRect(x: 0, y: 0, width: 700, height: 420)
            viewController.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let preScrollSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let preScrollText = GhosttyTerminalSnapshotLayout.plainText(for: preScrollSnapshot)

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0, vertical: 10_000, location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY))
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertEqual(scrolledText, preScrollText)
            XCTAssertEqual(sentScrolls.last?.horizontal, 0)
            XCTAssertEqual(sentScrolls.last?.vertical, 10_000)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewResetsRenderedOutputForNewOwnerEpochWithSameSnapshot() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let bootstrapSnapshot = snapshot(columns: 16, rows: 2, text: "old-output-line\nshell % ")
            let refreshedBootstrapSnapshot = snapshot(columns: 16, rows: 2, text: "shell % ")
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: "owner-epoch-1", bootstrapSnapshot: bootstrapSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            let outputSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let outputText = GhosttyTerminalSnapshotLayout.plainText(for: outputSnapshot)
            XCTAssertTrue(outputText.localizedStandardContains("old-output-line"), outputText)

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session", id: "owner-epoch-2", bootstrapSnapshot: refreshedBootstrapSnapshot), endedRender: nil,
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            let refreshedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let refreshedText = GhosttyTerminalSnapshotLayout.plainText(for: refreshedSnapshot)
            XCTAssertFalse(refreshedText.localizedStandardContains("old-output-line"), refreshedText)
            XCTAssertTrue(refreshedText.localizedStandardContains("shell %"), refreshedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewClearsStaleSnapshotBeforeFreshSnapshot() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: promptSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedSnapshotText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertFalse(renderedSnapshotText.localizedStandardContains("hi"), renderedSnapshotText)
            XCTAssertTrue(renderedSnapshotText.localizedStandardContains("shell %"), renderedSnapshotText)
            XCTAssertEqual(renderedSnapshotText.components(separatedBy: "shell %").count - 1, 1, renderedSnapshotText)

            window.isHidden = true
        }

        private func terminalSurfaceLayer(in hostView: GhosttyRemoteTerminalHostView) -> CALayer? {
            hostView.layer.sublayers?.first(where: { layer in
                abs(layer.frame.width - hostView.bounds.width) < 0.5 && abs(layer.frame.height - hostView.bounds.height) < 0.5
            })
        }

        private func sampleSnapshot() -> GhosttyTerminalSnapshot {
            let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
            let characters = Array("hi".unicodeScalars)
            let cells: [GhosttyTerminalSnapshot.Cell] = [
                GhosttyTerminalSnapshot.Cell(codepoint: characters[0].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: characters[1].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0), blank,
                blank, blank, blank, blank, blank,
            ]

            return GhosttyTerminalSnapshot(
                columns: 4, rows: 2, cursorColumn: 2, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26, cells: cells)
        }

        private func sampleSnapshotWithExclamation() -> GhosttyTerminalSnapshot {
            let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
            let characters = Array("hi!".unicodeScalars)
            let cells: [GhosttyTerminalSnapshot.Cell] = [
                GhosttyTerminalSnapshot.Cell(codepoint: characters[0].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: characters[1].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: characters[2].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0), blank,
                blank, blank, blank, blank,
            ]

            return GhosttyTerminalSnapshot(
                columns: 4, rows: 2, cursorColumn: 3, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26, cells: cells)
        }

        private func promptSnapshot() -> GhosttyTerminalSnapshot { snapshot(columns: 8, rows: 2, text: "shell % ") }

        private func scrollbackSnapshot(lineCount: Int) -> GhosttyTerminalSnapshot {
            let lines = (0..<lineCount).map { index in "SEQ \(String(format: "%06d", index)) scrollback-line-\(index)" }
            return snapshot(columns: 80, rows: lineCount, text: lines.joined(separator: "\n"))
        }

        private func promptAtBottomSnapshot(columns: Int, rows: Int) -> GhosttyTerminalSnapshot {
            let historyRows = max(rows - 1, 0)
            let lines = (0..<historyRows).map { index in "SEQ \(String(format: "%06d", index)) keyboard-safe-row-\(index)" }
            return snapshot(columns: columns, rows: rows, text: (lines + ["shell %"]).joined(separator: "\n"))
        }

        private func snapshotSignature(_ snapshot: GhosttyTerminalSnapshot?) -> String {
            guard let snapshot else { return "nil" }
            let sampleCells = snapshot.cells.prefix(12).map { "\($0.codepoint):\($0.flags)" }.joined(separator: ",")
            return "\(snapshot.columns)x\(snapshot.rows)|cursor=\(snapshot.cursorColumn),\(snapshot.cursorRow)|cells=\(sampleCells)"
        }

        private func snapshot(columns: Int, rows: Int, text: String) -> GhosttyTerminalSnapshot {
            let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
            let cellCount = max(columns * rows, 0)
            var cells = Array(repeating: blank, count: cellCount)
            var cursorColumn = 0
            var cursorRow = 0

            for scalar in text.unicodeScalars where rows > 0 && columns > 0 {
                if scalar == "\n" {
                    cursorColumn = 0
                    cursorRow += 1
                    continue
                }
                guard cursorRow < rows else { break }
                if cursorColumn >= columns {
                    cursorColumn = 0
                    cursorRow += 1
                }
                guard cursorRow < rows else { break }
                let cellIndex = cursorRow * columns + cursorColumn
                cells[cellIndex] = GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
                cursorColumn += 1
            }

            return GhosttyTerminalSnapshot(
                columns: columns, rows: rows, cursorColumn: min(max(cursorColumn, 0), max(columns - 1, 0)),
                cursorRow: min(max(cursorRow, 0), max(rows - 1, 0)), cursorVisible: true, defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26, cells: cells)
        }

    }

    private func descendants<ViewType: UIView>(of view: UIView, matching type: ViewType.Type) -> [ViewType] {
        var matches: [ViewType] = []
        if let typedView = view as? ViewType { matches.append(typedView) }
        for subview in view.subviews { matches.append(contentsOf: descendants(of: subview, matching: type)) }
        return matches
    }

    extension SpacesDeviceAPIRequest {
        fileprivate var terminalLink: String? { if case .resolveTerminalLink(let payload) = command { payload.terminalLink } else { nil } }

        fileprivate var terminalLinkID: String? { if case .readTerminalLinkChunk(let payload) = command { payload.terminalLinkID } else { nil } }

        fileprivate var chunkOffset: Int64? { if case .readTerminalLinkChunk(let payload) = command { payload.offset } else { nil } }
    }

    extension GhosttyRemoteTerminalHostView {
        fileprivate func update(snapshot: GhosttyTerminalSnapshot?, renderStateKey: String, fallbackText: String) {
            let ownerEpoch: GhosttyRemoteTerminalOwnerEpoch?
            if snapshot != nil {
                let epochID = "owner|\(renderStateKey)|\(snapshotSignature(snapshot))"
                ownerEpoch = GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: epochID, bootstrapSnapshot: snapshot)
            } else {
                ownerEpoch = nil
            }
            update(ownerEpoch: ownerEpoch, endedRender: nil, fallbackText: fallbackText)
        }

        private func snapshotSignature(_ snapshot: GhosttyTerminalSnapshot?) -> String {
            guard let snapshot else { return "nil" }
            let sampleCells = snapshot.cells.prefix(12).map { "\($0.codepoint):\($0.flags)" }.joined(separator: ",")
            return "\(snapshot.columns)x\(snapshot.rows)|cursor=\(snapshot.cursorColumn),\(snapshot.cursorRow)|cells=\(sampleCells)"
        }
    }
#endif
